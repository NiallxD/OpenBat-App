-- D1 schema for OpenBat consent records — current state per device, not an
-- append-only log (a log of "granted" events alone can't represent withdrawal).
-- Apply with: wrangler d1 execute openbat-consent --file=schema.sql

CREATE TABLE IF NOT EXISTS consent_records (
    device_id       TEXT PRIMARY KEY,
    consent_version TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('granted', 'revoked')),
    granted_at      TEXT,
    revoked_at      TEXT,
    -- 1 once this device has been handed its API token (see issueDeviceToken).
    -- The token itself is never stored: it's an HMAC of the device_id, so it's
    -- recomputed to verify. This flag exists only to make issuance one-shot,
    -- which is what stops someone who knows a device_id from requesting its
    -- token. Existing rows default to 0 so already-registered devices can
    -- collect one on their next consent change.
    token_issued    INTEGER NOT NULL DEFAULT 0
);

-- Durable record that an erasure was requested.
--
-- Previously the notification email WAS the audit trail: handleErase deleted the
-- R2 objects and the D1 consent row, then fired an email whose failure was only
-- ever logged to console.error. If that send failed — unset API key, unverified
-- sending domain, Resend outage — there was no record anywhere that a user had
-- asked to be erased, and no way to recover the device_id needed to find copies
-- in long-term archive storage. The least reliable component was carrying the
-- one fact that had to survive.
--
-- Written BEFORE anything is deleted, so an erasure interrupted part-way (a
-- Worker can be terminated mid-request) still leaves evidence it was asked for.
--
-- Deliberately minimal: an identifier and timestamps. No location, no species,
-- no recording data. Note that a device_id IS pseudonymous personal data — this
-- table retains information about someone who asked to be forgotten, which is
-- lawful as a record of compliance but must not become a permanent shadow
-- profile. Hence the retention purge in the Worker's scheduled handler.
CREATE TABLE IF NOT EXISTS erasure_requests (
    device_id       TEXT PRIMARY KEY,
    requested_at    TEXT NOT NULL,
    -- NULL until the R2 sweep finishes; a NULL here on an old row means the
    -- request was interrupted and needs looking at.
    deleted_objects INTEGER,
    -- NULL until the privacy team has actually been notified. The scheduled
    -- handler retries every row where this is still NULL.
    notified_at     TEXT,
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT
);

CREATE INDEX IF NOT EXISTS idx_erasure_pending
    ON erasure_requests (notified_at) WHERE notified_at IS NULL;
