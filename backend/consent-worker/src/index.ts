// OpenBat consent + upload Worker.
//
//   POST   /consent   { device_id, consent_version, status, granted_at?, revoked_at? }
//   GET    /consent?device_id=...
//   DELETE /consent?device_id=...   — GDPR-style erasure: deletes the D1 row
//                                      AND every R2 object under that device_id
//   PUT    /upload/{device_id}/{date}/{recording_id}.flac   (body: file bytes)
//
// Deliberately minimal, matching the spec's "val.town + SQL is sufficient"
// sizing for consent — just current-state-per-device, no auth beyond the
// device_id itself (an app-generated UUID, not guessable/enumerable in
// practice). The upload route binds directly to R2 (no S3 request-signing)
// since Worker and bucket live in the same Cloudflare account — see
// wrangler.toml's commented-out r2_buckets block, uncommented once the
// bucket exists (manual step, see backend/README.md).

export interface Env {
  DB: D1Database;
  RECORDINGS: R2Bucket;
  // Set via `wrangler secret put RESEND_API_KEY` — never committed. Using
  // Resend (not Cloudflare's own send_email binding) because Cloudflare's
  // Email Sending requires the paid Workers plan just to authenticate a
  // sender domain; Resend's free tier (3,000 emails/month) covers this
  // easily with no ongoing cost.
  RESEND_API_KEY: string;
  // Set via `wrangler secret put DEVICE_TOKEN_SECRET`. Every device token is
  // an HMAC of the device_id under this key, so tokens are verifiable without
  // storing them — rotating this secret invalidates every device at once.
  DEVICE_TOKEN_SECRET: string;
  // Optional: the Workers rate-limiting binding (see wrangler.toml). Declared
  // optional so a deploy still works where the binding isn't available, rather
  // than every request failing on an undefined property.
  RATE_LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

/// Upper bound on an accepted upload. Previously absent entirely — `bucket.put`
/// took an unbounded stream.
///
/// Set to match Cloudflare's own per-request body cap (100 MB on Free/Pro; 200 MB
/// Business, 500 MB Enterprise) rather than to what a recording could
/// theoretically be. Going higher would be a lie: the edge rejects an oversized
/// body before this Worker ever runs, so the app would get an opaque platform
/// error instead of the clean 413 it can act on. Raise this only alongside the
/// plan that permits it.
///
/// Comfortably clear of anything the client will actually send: the app only
/// considers captures up to 30 s eligible to upload
/// (`RecordingUploader.maxUploadDurationSeconds`), which is ~22 MB of raw PCM at
/// 384 kHz/16-bit and less again after FLAC. The client checks the encoded size
/// against the same number before starting a transfer, so this is the backstop
/// rather than the primary limit.
const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

/// `{device_id}/{YYYY-MM-DD}/{recording_id}.flac` and nothing else. The key
/// used to be whatever followed `/upload/`, so a request could write an object
/// at the bucket root or under an arbitrary path shape.
const UPLOAD_KEY_PATTERN =
  /^[0-9A-Fa-f-]{36}\/\d{4}-\d{2}-\d{2}\/[0-9A-Fa-f-]{36}\.flac$/;

// Notified on every full erasure — the manual backstop for anything moved to
// long-term archive storage outside R2 (see handleErase). Not app-configurable;
// changing where this goes is a backend deploy, not a user-facing setting.
const PRIVACY_NOTIFICATION_ADDRESS = "privacy@openbat.app";
const PRIVACY_SENDER_ADDRESS = "noreply@openbat.app";

/// Give up retrying a notification after this many tries — the row stays in the
/// table for a human rather than being deleted. See `retryPendingNotifications`.
const MAX_NOTIFICATION_ATTEMPTS = 24;

/// How long a *notified* erasure record is kept as proof of compliance before
/// being purged. A policy choice — see `purgeExpiredErasureRecords`.
const ERASURE_LOG_RETENTION_DAYS = 365;

interface ConsentBody {
  device_id: string;
  consent_version: string;
  status: "granted" | "revoked";
  granted_at?: string | null;
  revoked_at?: string | null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Device tokens
//
// The device_id alone used to be the only credential on every route, including
// the destructive one — anyone holding it could erase that device's
// contributions or upload junk under its identity. That matters more than
// "a UUID isn't guessable" suggests, because the app shows the ID in Settings
// with a Copy button and invites users to quote it in support email.
//
// A token is HMAC-SHA256(secret, device_id), so nothing extra is stored and
// verification is a recompute. It's handed out exactly once, on the device's
// FIRST consent registration: an attacker who knows an existing device_id
// can't ask for one, because by then the row is already marked as issued.
// ---------------------------------------------------------------------------

function hmacKey(env: Env): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.DEVICE_TOKEN_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
}

async function issueDeviceToken(env: Env, deviceID: string): Promise<string> {
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(env), new TextEncoder().encode(deviceID));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

/// `crypto.subtle.verify` rather than a string compare: it's constant-time, so
/// a token can't be recovered a byte at a time by timing the response.
async function isValidDeviceToken(env: Env, deviceID: string, token: string | null): Promise<boolean> {
  if (!token) return false;
  const signature = hexToBytes(token);
  // Length-checked before verifying: SHA-256 HMACs are always 32 bytes, and
  // handing `verify` a wrong-sized buffer throws rather than returning false —
  // which surfaced as a 500 on a malformed token instead of a clean 401.
  if (!signature || signature.length !== 32) return false;
  try {
    return await crypto.subtle.verify(
      "HMAC",
      await hmacKey(env),
      signature,
      new TextEncoder().encode(deviceID)
    );
  } catch {
    return false;
  }
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.toLowerCase().startsWith("bearer ")) return null;
  return header.slice(7).trim() || null;
}

async function authorize(request: Request, env: Env, deviceID: string): Promise<boolean> {
  return isValidDeviceToken(env, deviceID, bearerToken(request));
}

/// Best-effort throttle, keyed per device so one device can't drown the
/// service. Open (allows the request) when the binding isn't configured — the
/// auth checks above are the real gate; this only bounds volume.
async function withinRateLimit(env: Env, key: string): Promise<boolean> {
  if (!env.RATE_LIMITER) return true;
  try {
    const { success } = await env.RATE_LIMITER.limit({ key });
    return success;
  } catch {
    return true;
  }
}

async function currentStatus(env: Env, deviceID: string): Promise<string | null> {
  const row = await env.DB.prepare("SELECT status FROM consent_records WHERE device_id = ?")
    .bind(deviceID)
    .first<{ status: string }>();
  return row?.status ?? null;
}

/// PUT /upload/{device_id}/{date}/{recording_id}.flac — matches the object key
/// convention from the spec (§6) exactly, so the R2 key is just the URL path
/// with the leading "/upload/" stripped. Filterable fields (species, quality
/// score, location, verified status) come in as headers and are mirrored into
/// R2 customMetadata (§5.4) rather than needing a separate query database.
async function handleUpload(request: Request, env: Env, path: string): Promise<Response> {
  const bucket = env.RECORDINGS;
  const key = path.replace(/^\/upload\//, "");
  if (!UPLOAD_KEY_PATTERN.test(key)) {
    return json({ error: "malformed object key" }, 400);
  }
  const deviceID = key.split("/")[0];

  if (!(await authorize(request, env, deviceID))) {
    return json({ error: "invalid or missing device token" }, 401);
  }
  if (!(await withinRateLimit(env, `upload:${deviceID}`))) {
    return json({ error: "rate limit exceeded" }, 429);
  }

  // Length is required, not merely capped: without it there's no way to reject
  // an oversized body before streaming the whole thing into R2.
  const declaredLength = request.headers.get("content-length");
  if (declaredLength === null) {
    return json({ error: "content-length required" }, 411);
  }
  const length = Number(declaredLength);
  if (!Number.isFinite(length) || length <= 0) {
    return json({ error: "invalid content-length" }, 400);
  }
  if (length > MAX_UPLOAD_BYTES) {
    return json({ error: "recording too large", maxBytes: MAX_UPLOAD_BYTES }, 413);
  }

  const status = await currentStatus(env, deviceID);
  if (status !== "granted") {
    return json({ error: "device has not granted upload consent" }, 403);
  }

  const metadataHeaderNames = ["species", "quality-score", "location", "verified"] as const;
  const customMetadata: Record<string, string> = {};
  for (const name of metadataHeaderNames) {
    const value = request.headers.get(`x-openbat-${name}`);
    if (value) customMetadata[name] = value;
  }

  await bucket.put(key, request.body, { customMetadata });
  return json({ ok: true, key });
}

/// Still never fails the erasure — the R2/D1 deletion is the part that matters
/// and has already happened — but the outcome is now RETURNED rather than
/// swallowed, so `erasure_requests.notified_at` only gets stamped on a real
/// success and `retryPendingNotifications` can pick up anything that didn't land.
async function notifyPrivacyTeam(
  env: Env,
  deviceID: string,
  requestedAt: string,
  deletedObjects: number | null
): Promise<{ ok: true } | { ok: false; error: string }> {
  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: PRIVACY_SENDER_ADDRESS,
        to: PRIVACY_NOTIFICATION_ADDRESS,
        subject: `Erasure request: device ${deviceID}`,
        text:
          `Device ${deviceID} requested full data erasure at ${requestedAt}.\n\n` +
          `${deletedObjects ?? "an unknown number of"} object(s) deleted from R2 automatically, ` +
          `and the D1 consent record was removed.\n\n` +
          `If any recordings from this device were previously moved to long-term archive storage ` +
          `(outside R2), they still need to be located and deleted manually as a follow-up to this request.`,
      }),
    });
    if (!response.ok) {
      const body = await response.text();
      console.error("notifyPrivacyTeam failed", deviceID, response.status, body);
      return { ok: false, error: `HTTP ${response.status}: ${body}`.slice(0, 500) };
    }
    return { ok: true };
  } catch (error) {
    console.error("notifyPrivacyTeam failed", deviceID, error);
    return { ok: false, error: String(error).slice(0, 500) };
  }
}

/// Records the notification outcome against the request row.
async function recordNotificationOutcome(
  env: Env,
  deviceID: string,
  outcome: { ok: true } | { ok: false; error: string }
): Promise<void> {
  if (outcome.ok) {
    await env.DB.prepare(
      "UPDATE erasure_requests SET notified_at = ?, attempts = attempts + 1, last_error = NULL WHERE device_id = ?"
    )
      .bind(new Date().toISOString(), deviceID)
      .run();
  } else {
    await env.DB.prepare(
      "UPDATE erasure_requests SET attempts = attempts + 1, last_error = ? WHERE device_id = ?"
    )
      .bind(outcome.error, deviceID)
      .run();
  }
}

/// DELETE /consent?device_id=... — full erasure, not just a status flip.
/// Deletes every R2 object under `{device_id}/` (paginated: R2 `list` caps at
/// 1000 keys per call) then removes the D1 row entirely, so no record of the
/// device — consent state included — survives the request. This is a
/// separate, more destructive action than a plain consent revoke (which only
/// stops future uploads); the app gates it behind an explicit
/// type-to-confirm step before ever calling this. Also notifies the privacy
/// team by email — the manual backstop for anything moved to archive storage
/// this endpoint can't reach on its own (see notifyPrivacyTeam).
async function handleErase(env: Env, deviceID: string, ctx: ExecutionContext): Promise<Response> {
  const requestedAt = new Date().toISOString();

  // Logged FIRST, before anything is destroyed. A Worker can be terminated
  // mid-request, and an erasure that deleted some objects and then vanished
  // without trace is the worst case — this row is what makes it recoverable.
  // `deleted_objects` stays NULL until the sweep below completes, so an old row
  // with a NULL count is itself the signal that a request was interrupted.
  // ON CONFLICT so a repeated request re-opens the row rather than failing.
  await env.DB.prepare(
    `INSERT INTO erasure_requests (device_id, requested_at, deleted_objects, notified_at, attempts, last_error)
     VALUES (?, ?, NULL, NULL, 0, NULL)
     ON CONFLICT(device_id) DO UPDATE SET
       requested_at = excluded.requested_at,
       deleted_objects = NULL,
       notified_at = NULL,
       attempts = 0,
       last_error = NULL`
  )
    .bind(deviceID, requestedAt)
    .run();

  let deletedObjects = 0;
  let cursor: string | undefined;
  do {
    const listing = await env.RECORDINGS.list({ prefix: `${deviceID}/`, cursor });
    if (listing.objects.length > 0) {
      await env.RECORDINGS.delete(listing.objects.map((o) => o.key));
      deletedObjects += listing.objects.length;
    }
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);

  await env.DB.prepare("UPDATE erasure_requests SET deleted_objects = ? WHERE device_id = ?")
    .bind(deletedObjects, deviceID)
    .run();
  await env.DB.prepare("DELETE FROM consent_records WHERE device_id = ?").bind(deviceID).run();

  // `waitUntil` rather than awaited: the deletion is done, and the app's erase
  // dialog is sitting on this response. If the send fails (or this Worker is
  // torn down before it finishes) the row stays unnotified and the scheduled
  // handler retries it — which is the whole point of the table.
  ctx.waitUntil(
    notifyPrivacyTeam(env, deviceID, requestedAt, deletedObjects).then((outcome) =>
      recordNotificationOutcome(env, deviceID, outcome)
    )
  );

  return json({ ok: true, deletedObjects });
}

/// Retries every erasure notification that hasn't landed yet. Run from the cron
/// trigger (see wrangler.toml), which is what turns "the email silently failed
/// and nobody will ever know" into "it lands as soon as the send path works".
///
/// Attempts are capped: past `MAX_NOTIFICATION_ATTEMPTS` the row stops being
/// retried but is NOT deleted, so it still shows up in the pending query below
/// as something needing a human. An unbounded retry against a permanently
/// misconfigured sender would just burn the free-tier email quota.
async function retryPendingNotifications(env: Env): Promise<void> {
  const { results } = await env.DB.prepare(
    `SELECT device_id, requested_at, deleted_objects FROM erasure_requests
     WHERE notified_at IS NULL AND attempts < ?
     ORDER BY requested_at ASC LIMIT 25`
  )
    .bind(MAX_NOTIFICATION_ATTEMPTS)
    .all<{ device_id: string; requested_at: string; deleted_objects: number | null }>();

  for (const row of results ?? []) {
    const outcome = await notifyPrivacyTeam(env, row.device_id, row.requested_at, row.deleted_objects);
    await recordNotificationOutcome(env, row.device_id, outcome);
  }
}

/// Drops notified erasure records once they've served their purpose.
///
/// This table exists to demonstrate that an erasure was honoured, which is a
/// legitimate reason to retain a device_id belonging to someone who asked to be
/// forgotten — but only for as long as that proof is plausibly needed. Keeping
/// it forever would quietly turn "erase everything" into "erase everything
/// except a permanent list of who asked". Only rows that were actually notified
/// are purged; anything still pending or over the attempt cap is kept for a human.
///
/// The window is a policy choice, not a technical one — adjust to match whatever
/// the published privacy notice commits to.
async function purgeExpiredErasureRecords(env: Env): Promise<void> {
  const cutoff = new Date(Date.now() - ERASURE_LOG_RETENTION_DAYS * 86_400_000).toISOString();
  await env.DB.prepare(
    "DELETE FROM erasure_requests WHERE notified_at IS NOT NULL AND requested_at < ?"
  )
    .bind(cutoff)
    .run();
}

export default {
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      (async () => {
        await retryPendingNotifications(env);
        await purgeExpiredErasureRecords(env);
      })()
    );
  },

  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/upload/")) {
      if (request.method !== "PUT") return json({ error: "method not allowed" }, 405);
      return handleUpload(request, env, url.pathname);
    }

    if (url.pathname !== "/consent") {
      return json({ error: "not found" }, 404);
    }

    if (request.method === "GET") {
      const deviceID = url.searchParams.get("device_id");
      if (!deviceID) return json({ error: "device_id required" }, 400);
      if (!(await authorize(request, env, deviceID))) {
        return json({ error: "invalid or missing device token" }, 401);
      }

      const row = await env.DB.prepare(
        "SELECT device_id, consent_version, status, granted_at, revoked_at FROM consent_records WHERE device_id = ?"
      )
        .bind(deviceID)
        .first();

      if (!row) return json({ error: "no consent record" }, 404);
      return json(row);
    }

    if (request.method === "DELETE") {
      const deviceID = url.searchParams.get("device_id");
      if (!deviceID) return json({ error: "device_id required" }, 400);
      // The destructive route, so it gets the same token gate as everything
      // else — knowing a device_id must not be enough to wipe its data.
      if (!(await authorize(request, env, deviceID))) {
        return json({ error: "invalid or missing device token" }, 401);
      }
      if (!(await withinRateLimit(env, `erase:${deviceID}`))) {
        return json({ error: "rate limit exceeded" }, 429);
      }
      return handleErase(env, deviceID, ctx);
    }

    if (request.method === "POST") {
      let body: ConsentBody;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid JSON" }, 400);
      }

      if (!body.device_id || !body.consent_version || !body.status) {
        return json({ error: "device_id, consent_version, and status are required" }, 400);
      }
      if (body.status !== "granted" && body.status !== "revoked") {
        return json({ error: "status must be granted or revoked" }, 400);
      }
      if (!(await withinRateLimit(env, `consent:${body.device_id}`))) {
        return json({ error: "rate limit exceeded" }, 429);
      }

      // This route is the bootstrap: it's the only way a device obtains its
      // token, so it can't itself require one on first contact. The token is
      // returned only when no token has been issued for this device yet —
      // once `token_issued` is set, changing the record needs the token, so
      // knowing someone else's device_id gets you nothing.
      //
      // `token_issued = 0` also covers rows written before tokens existed, so
      // devices already registered can collect one on their next consent
      // change instead of being locked out. That's a deliberate migration
      // window: it should be closed (or the table cleared) before public
      // launch — see README.
      const existing = await env.DB.prepare(
        "SELECT token_issued FROM consent_records WHERE device_id = ?"
      )
        .bind(body.device_id)
        .first<{ token_issued: number }>();

      let issuedToken: string | null = null;
      if (!existing || existing.token_issued === 0) {
        issuedToken = await issueDeviceToken(env, body.device_id);
      } else if (!(await authorize(request, env, body.device_id))) {
        return json({ error: "invalid or missing device token" }, 401);
      }

      await env.DB.prepare(
        `INSERT INTO consent_records (device_id, consent_version, status, granted_at, revoked_at, token_issued)
         VALUES (?, ?, ?, ?, ?, 1)
         ON CONFLICT(device_id) DO UPDATE SET
           consent_version = excluded.consent_version,
           status = excluded.status,
           granted_at = COALESCE(excluded.granted_at, consent_records.granted_at),
           revoked_at = excluded.revoked_at,
           token_issued = 1`
      )
        .bind(
          body.device_id,
          body.consent_version,
          body.status,
          body.granted_at ?? null,
          body.revoked_at ?? null
        )
        .run();

      return json(issuedToken ? { ok: true, device_token: issuedToken } : { ok: true });
    }

    return json({ error: "method not allowed" }, 405);
  },
};
