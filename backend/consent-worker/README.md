# OpenBat consent + upload Worker

Cloudflare Worker + D1 (+ R2) backend for device consent records and the
recording upload endpoint (see `openbat-onboarding-consent-upload-spec.md`
§2/§6 and the implementation plan). Chosen over val.town so the same
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
RESEND_API_KEY=unset
```

The R2 bucket (`openbat-community-recordings`) already exists and is bound
in `wrangler.toml`/`src/index.ts`.

**Email (erasure notifications):** sent via [Resend](https://resend.com) —
Cloudflare's own Email Sending needs the paid Workers plan just to
authenticate a sender domain, so this uses Resend's free tier (3,000
emails/month) instead. One-time setup:

1. Sign up at resend.com (free), add `openbat.app` as a sending domain.
2. Resend gives you DNS records (SPF/DKIM) to add — since the domain is on
   Cloudflare DNS already, add them there. Wait for Resend's dashboard to
   show the domain verified.
3. Create an API key in Resend, then set it as a Worker secret (never commit
   it, and don't paste it into a Worker's source or `wrangler.toml`):
   ```
   wrangler secret put RESEND_API_KEY
   ```
   (paste the key when prompted).

**Erasure notifications are durable.** Every erasure request is written to
`erasure_requests` *before* anything is deleted, and the notification email is
retried by the hourly cron trigger until it succeeds. Previously that email was
the only record an erasure had happened and its failures went to
`console.error`, so an unset key or an unverified domain meant nobody ever knew
— and the `device_id` needed to find archive copies was gone with the consent row.

Check for anything needing attention:

```
wrangler d1 execute openbat-consent --command \
  "SELECT device_id, requested_at, deleted_objects, attempts, last_error \
   FROM erasure_requests WHERE notified_at IS NULL ORDER BY requested_at"
```

Rows there are erasures the privacy team has **not** been told about yet. Rows
with `attempts >= 24` have stopped being retried and need a human. Rows with a
NULL `deleted_objects` were interrupted part-way and should be re-run.

Notified rows are purged after `ERASURE_LOG_RETENTION_DAYS` (365). That window is
a policy choice: the table is proof an erasure was honoured, which justifies
keeping a `device_id` belonging to someone who asked to be forgotten — but only
for as long as the proof is needed. Make sure it matches the published privacy
notice.

`openbat.app` also needs Email Routing enabled (Email → Email Routing on the
zone) with `privacy@openbat.app` routed to a real inbox, so the notification
actually reaches someone — that's independent of the Resend send path above.

Until the API key is set, `handleErase`'s notification send will fail; it's
designed to fail silently (logged via `console.error`, visible in
`wrangler tail`) rather than blocking the R2/D1 deletion it's a follow-up to.

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
