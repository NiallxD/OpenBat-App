# OpenBat consent + upload Worker

Cloudflare Worker + D1 (+ R2) backend for device consent records and the
recording upload endpoint (see `Context.md` §11 for the settled decisions this
implements). Chosen over val.town so the same
Cloudflare account owns both the consent table and the R2 recordings bucket,
and this Worker can bind to R2 directly — no S3 request-signing needed.

## One-time setup

```
cd backend/consent-worker
npm install
wrangler d1 create openbat-consent      # copy the returned database_id into wrangler.toml
npm run db:apply                        # creates the consent_records table
wrangler secret put DEVICE_TOKEN_SECRET # any long random string — see "Device tokens"
```

If the database already existed before device tokens were added, run the
migration instead of re-applying the schema:

```
npm run db:migrate                      # adds consent_records.token_issued
```

For local development, `.dev.vars` (gitignored) supplies the secrets:

```
DEVICE_TOKEN_SECRET=local-test-secret-do-not-use
```

The R2 bucket (`openbat-community-recordings`) already exists and is bound
in `wrangler.toml`/`src/index.ts`.

**Erasure is one statement, and there is nothing behind it.**
`DELETE /consent?device_id=...` removes the device's row from `consent_records`,
bumps a per-month counter in `erasure_counts`, and returns. The app tells the
user their data is deleted on the strength of that response, because by then it
is.

There used to be considerably more here: an `erasure_requests` table written
before anything was destroyed, a Resend-delivered notification to
`privacy@openbat.app`, an hourly cron trigger retrying failed sends, an attempt
cap, and a retention window purging notified rows. All of it supported a
deletion that swept R2 objects under a `{device_id}/` prefix — an operation that
could be interrupted half-done, and that ended with a human going to look for
copies in archive storage the Worker couldn't reach.

None of that applies now. Contributed recordings carry no device identifier, so
there is no set of "this device's recordings" to delete, interrupt, or chase.
What was left was an email provider processing device identifiers, a cron job,
and a standing list of the identifiers of people who had asked to be forgotten —
costs with nothing left on the other side of the ledger. So:

- **Resend is gone.** No `RESEND_API_KEY`, no sending domain, no DNS records. If
  the deployed Worker still has the secret set, remove it with
  `wrangler secret delete RESEND_API_KEY`.
- **The cron trigger is gone.** Nothing in this Worker runs on a schedule.
- **`erasure_requests` is gone**, replaced by `erasure_counts` (month, count).
  A count answers "are erasures processed, and how many" without retaining
  anything about anyone. It needs no retention policy and no purge job, which is
  why neither exists any more.
- **Email Routing for `privacy@openbat.app` is no longer required** by the
  Worker. Keep it if you want a contact address on the privacy notice — that's a
  separate decision.

## Deploy

```
npm run deploy
```

Prints the Worker's URL — put that in the app's `ConsentAPIClient.baseURL`
(`OpenBat/Consent/ConsentAPIClient.swift`) and `UploadClient.baseURL`
(`OpenBat/Upload/UploadClient.swift`).

## Device tokens

Every route except first-time registration requires
`Authorization: Bearer <device_token>`. A token is
`HMAC-SHA256(DEVICE_TOKEN_SECRET, device_id)` in hex — nothing is stored, so
verification is a recompute, and rotating the secret invalidates every device
at once.

The token is returned **once**, from the first `POST /consent` for a given
`device_id`. After that the row is marked `token_issued = 1` and further
changes to it need the token, so knowing someone else's `device_id` gets an
attacker nothing. This matters because the app shows the device ID in Settings
with a Copy button and invites users to quote it in support email — before
this, that string alone was enough to erase their contributions or upload
under their identity.

The app stores its token in the Keychain beside the device ID (see
`DeviceIdentity.currentToken`), so the two survive reinstalls together, and
drops it when the ID is rotated after an erasure.

> **Migration window (close before public launch).** Rows created before tokens
> existed have `token_issued = 0`, so those devices can still collect a token on
> their next consent change rather than being locked out. Until that flag is 1
> for every row, someone who knows one of those older `device_id`s could claim
> its token. With the service pre-release the practical exposure is nil, but
> either clear the table or set `token_issued = 1` across the board before real
> users exist.

## Upload size ceiling

`MAX_UPLOAD_BYTES` is 100 MB, matching Cloudflare's per-request body cap on
Free/Pro (200 MB Business, 500 MB Enterprise).

Nothing the app sends comes close: only captures up to 30 s are eligible to
contribute (`RecordingUploader.maxUploadDurationSeconds`), which is ~22 MB of raw
PCM at 384 kHz/16-bit and less after FLAC. A capture longer than that means the
trigger never released — a stuck gate or continuous noise — so it isn't one pass
and isn't wanted in a reference library. The client also checks the encoded file
size against the same 100 MB figure before starting a transfer, so a 413 here
should be unreachable in practice.

Raising the duration limit means re-checking this: past roughly 2 minutes of
384 kHz audio, uploads would need to go straight to R2 (presigned PUT or
multipart) rather than through a Worker request body.

## Endpoints

All routes are per-device rate limited (60/min, see `wrangler.toml`); the binding
is optional and fails open if absent.

- `POST /consent` — body `{ device_id, consent_version, status, granted_at?, revoked_at? }`. Upserts the device's current record. Returns `{ ok, device_token }` on first registration, `{ ok }` thereafter — and requires the token once one has been issued.
- `GET /consent?device_id=...` — returns the current record, or 404 if none exists. Requires the token.
- `DELETE /consent?device_id=...` — requires the token. Full erasure: deletes every R2 object under `{device_id}/` and removes the D1 row entirely, then emails `privacy@openbat.app` with the device_id and deleted-object count. That email is the manual backstop for anything moved to long-term archive storage outside R2 (e.g. an off-Cloudflare Google Drive archive) — this endpoint can only reach R2 + D1 on its own.
- `PUT /upload/{device_id}/{date}/{recording_id}.flac` — body is the file's raw bytes; `x-openbat-species` / `x-openbat-quality-score` / `x-openbat-location` / `x-openbat-verified` headers are mirrored into the R2 object's `customMetadata`. Requires the token (401), an exactly-matching key shape (400), a `Content-Length` (411) within `MAX_UPLOAD_BYTES` (413), and `granted` consent (403).
