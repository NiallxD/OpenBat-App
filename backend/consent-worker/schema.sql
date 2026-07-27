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

-- Aggregate count of consent erasures, by month. No identifiers.
--
-- This replaces an `erasure_requests` table that held a device_id, timestamps,
-- retry counters and error strings for every request. Nearly all of that existed
-- to support a deletion process that no longer exists: erasure used to delete R2
-- objects under a device-id prefix, could be interrupted part-way, and ended with
-- an email asking a human to find copies in archive storage. Erasure is now a
-- single DELETE against one row — atomic, synchronous, nothing to resume.
--
-- What was left once that fell away was a permanent list of the identifiers of
-- people who had asked to be forgotten. That is retained personal data about
-- data subjects who explicitly asked for none, it needs its own lawful basis to
-- hold, and it needs a retention policy and a purge job to stop it becoming a
-- shadow profile. A count gives the same accountability answer — erasures are
-- processed, here is the volume — while being incapable of identifying anyone,
-- so none of that machinery is needed.
--
-- Deliberately not per-device and deliberately not per-day: month granularity
-- means this cannot be correlated against anything, including object creation
-- times in R2.
CREATE TABLE IF NOT EXISTS erasure_counts (
    month TEXT PRIMARY KEY,          -- 'YYYY-MM'
    count INTEGER NOT NULL DEFAULT 0
);
