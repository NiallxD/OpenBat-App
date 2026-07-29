// OpenBat consent + upload Worker.
//
//   POST   /consent   { device_id, consent_version, status, granted_at?, revoked_at? }
//   GET    /consent?device_id=...
//   DELETE /consent?device_id=...   — erases the D1 consent row (NOT recordings;
//                                      see handleErase for why that is impossible
//                                      by construction rather than merely refused)
//   PUT    /upload/{date}/{object_id}.flac   (body: file bytes,
//                                      x-openbat-device-id header for the
//                                      consent check, never persisted)
//
// Deliberately minimal: current-consent-state-per-device in D1, recordings as
// opaque objects in R2, and no relationship between the two. Every route except
// the consent bootstrap requires a device token (HMAC of the device_id under
// DEVICE_TOKEN_SECRET). The upload route binds directly to R2 (no S3
// request-signing) since Worker and bucket live in the same Cloudflare account.
//
// The privacy model in one line: a device_id can reach its consent row and
// nothing else. See handleUpload and handleErase for the two places that
// matters, and the "OpenBat App Store Review Notes" §4 for why.

export interface Env {
  DB: D1Database;
  RECORDINGS: R2Bucket;
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

/// `{YYYY-MM-DD}/{object_id}.flac` and nothing else.
///
/// The key used to lead with `{device_id}/`, which made every stored object
/// permanently attributable to the device that sent it. That prefix is gone:
/// uploaded recordings carry no identifier of any kind, and the date is the
/// client's 5-minute-bucketed timestamp truncated to a day (see
/// AnonymizedUploadBuilder), not a precise capture time.
///
/// The object id is a random UUID minted per upload attempt and never stored on
/// the device, so it is not a covert re-identifier either — see that type's
/// `objectID` doc comment.
const UPLOAD_KEY_PATTERN = /^\d{4}-\d{2}-\d{2}\/[0-9A-Fa-f-]{36}\.flac$/;

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

/// The consent wording currently in force. MUST match
/// `ConsentStore.currentConsentVersion` in the app.
///
/// Uploads are refused from a device whose stored consent names a different
/// version, not merely from one that never consented. A device holding a
/// "granted" row for superseded wording has not agreed to the terms the project
/// now operates under, and accepting its contributions would mean collecting
/// under terms that user never saw. The app enforces the same rule and
/// re-prompts, but a stale or modified client is exactly the case a server-side
/// check exists for.
///
/// Bump this in the same deploy as the app release that bumps its own constant.
/// Devices on the old version get a clean 403 and the app's re-consent prompt
/// resolves it — a deliberate pause, not a break.
const CURRENT_CONSENT_VERSION = "3.0";

async function currentConsent(
  env: Env,
  deviceID: string
): Promise<{ status: string; consent_version: string } | null> {
  const row = await env.DB.prepare(
    "SELECT status, consent_version FROM consent_records WHERE device_id = ?"
  )
    .bind(deviceID)
    .first<{ status: string; consent_version: string }>();
  return row ?? null;
}

/// PUT /upload/{date}/{object_id}.flac — the R2 key is the URL path with the
/// leading "/upload/" stripped. Filterable fields (species, quality score,
/// location, verified status) come in as headers and are mirrored into R2
/// customMetadata rather than needing a separate query database.
///
/// ---------------------------------------------------------------------------
/// THE ONE PLACE A DEVICE ID AND AN ANONYMOUS RECORDING TOUCH. Read before
/// editing.
///
/// Consent is keyed by device_id, so accepting a contribution requires knowing
/// which device is asking — but the stored object must carry no identifier at
/// all. So the device_id arrives in the `x-openbat-device-id` REQUEST HEADER,
/// is used solely to look up `consent_records.status`, and is then dropped on
/// the floor. It is never written into the object key, the object body, or
/// customMetadata. `deviceID` is deliberately not in scope by the time
/// `bucket.put` is called below.
///
/// The bearer token cannot replace this: it is HMAC(secret, device_id), which
/// isn't reversible, so there's no way to recover an id from it to do the
/// lookup. The token proves the caller holds a device_id; the header says which.
/// Both are needed, and neither is retained.
///
/// Corollary for operations: do NOT enable Logpush with request-header capture
/// on this Worker, and do not log `deviceID` alongside `key` anywhere in this
/// function. Either would re-create in the logs exactly the join this design
/// removes from the database.
/// ---------------------------------------------------------------------------
async function handleUpload(request: Request, env: Env, path: string): Promise<Response> {
  const bucket = env.RECORDINGS;
  const key = path.replace(/^\/upload\//, "");
  if (!UPLOAD_KEY_PATTERN.test(key)) {
    return json({ error: "malformed object key" }, 400);
  }

  const deviceID = request.headers.get("x-openbat-device-id");
  if (!deviceID) {
    return json({ error: "x-openbat-device-id required" }, 400);
  }

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

  const consent = await currentConsent(env, deviceID);
  if (consent?.status !== "granted") {
    return json({ error: "device has not granted upload consent" }, 403);
  }
  if (consent.consent_version !== CURRENT_CONSENT_VERSION) {
    return json(
      {
        error: "consent version superseded",
        agreed: consent.consent_version,
        required: CURRENT_CONSENT_VERSION,
      },
      403
    );
  }

  // Keys are random UUIDs the client never retains, so a collision is
  // vanishingly unlikely and a *deliberate* overwrite is the only realistic way
  // one happens. Refusing it means a caller holding a valid token still can't
  // damage an existing contribution, which matters more now that keys are no
  // longer namespaced per device.
  if (await bucket.head(key)) {
    return json({ error: "object already exists" }, 409);
  }

  // Allowlist, mirroring the client's own. `x-openbat-device-id` is absent from
  // this list and must stay absent: anything named here is persisted onto the
  // object and would re-create the join.
  const metadataHeaderNames = ["species", "quality-score", "location", "verified"] as const;
  const MAX_METADATA_VALUE_LENGTH = 200;
  const customMetadata: Record<string, string> = {};
  for (const name of metadataHeaderNames) {
    const value = request.headers.get(`x-openbat-${name}`);
    if (value) customMetadata[name] = value.slice(0, MAX_METADATA_VALUE_LENGTH);
  }

  await bucket.put(key, request.body, { customMetadata });
  // Response carries the key only. Nothing here echoes the device id back.
  return json({ ok: true, key });
}

/// DELETE /consent?device_id=... — erases the CONSENT RECORD. Not recordings,
/// and this function must never be extended to touch R2.
///
/// It used to sweep every object under `{device_id}/`. That was possible only
/// because uploads were stored under a device-id prefix — i.e. only because the
/// join this design now forbids existed. Removing the prefix removed the
/// capability along with it, deliberately and permanently:
///
///   - Uploaded recordings carry no identifier, a ~100 m grid coordinate and a
///     5-minute timestamp bucket. There is no query, here or anywhere, that
///     returns "the recordings belonging to this device". Not restricted —
///     absent.
///   - That is what makes contributed recordings non-personal-data rather than
///     personal data we promise to handle carefully, and it is what the consent
///     copy tells the user before they contribute anything.
///   - A right to erasure over data that cannot identify anyone is not a right
///     being refused; there is no data subject to connect it to.
///
/// So: if a future change makes it possible to find a device's recordings, that
/// change has broken the privacy model, and fixing it by deleting them here is
/// treating the symptom.
///
/// One statement, synchronous, and the user is told it is done on the strength
/// of this response. There is no queue, no email, no follow-up and nothing a
/// human has to finish afterwards — all of which used to exist to chase copies
/// in archive storage that this endpoint could not reach. With nothing to
/// chase, the honest thing is to do the work and confirm it, rather than to
/// promise that something will happen later.
async function handleErase(env: Env, deviceID: string): Promise<Response> {
  await env.DB.prepare("DELETE FROM consent_records WHERE device_id = ?").bind(deviceID).run();
  await recordErasure(env);
  return json({ ok: true });
}

/// Bumps a per-month counter, and records nothing else.
///
/// There used to be an `erasure_requests` table holding a device_id, timestamps,
/// retry counts and error strings per request. Most of that existed so an
/// interrupted multi-step deletion could be resumed and so a device_id could be
/// recovered to find archive copies — neither of which is now a thing that can
/// happen.
///
/// What remained was a permanent list of the identifiers of people who had
/// asked to be forgotten, which is an uncomfortable thing to keep and needs its
/// own justification to hold at all. A count carries the accountability value
/// (we can show erasures are processed, and at what volume) with none of the
/// personal data, so it needs no retention policy and no purge job. Failing
/// here must never fail the erasure: the deletion is what the user asked for
/// and it has already happened.
async function recordErasure(env: Env): Promise<void> {
  try {
    const month = new Date().toISOString().slice(0, 7); // YYYY-MM
    await env.DB.prepare(
      `INSERT INTO erasure_counts (month, count) VALUES (?, 1)
       ON CONFLICT(month) DO UPDATE SET count = count + 1`
    )
      .bind(month)
      .run();
  } catch (error) {
    console.error("recordErasure failed", error);
  }
}

// No `scheduled` handler. There used to be one, running hourly to retry erasure
// notification emails and purge expired erasure records. Both jobs existed to
// support a deletion process that was multi-step, failure-prone and finished by
// a human; erasure is now a single DELETE against one row, so there is nothing
// to retry and nothing to expire. The cron trigger is removed from wrangler.toml
// to match.
export default {
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
      if (!(await withinRateLimit(env, `consent-read:${deviceID}`))) {
        return json({ error: "rate limit exceeded" }, 429);
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
      return handleErase(env, deviceID);
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
