-- Adds the durable erasure-request log to an EXISTING database.
-- Fresh databases get this from schema.sql directly.
--
-- Apply with:
--   wrangler d1 execute openbat-consent --file=migrations/002_add_erasure_requests.sql
--
-- See schema.sql for why this table exists (the notification email used to be
-- the only record that an erasure happened, and its failures were silent).

CREATE TABLE IF NOT EXISTS erasure_requests (
    device_id       TEXT PRIMARY KEY,
    requested_at    TEXT NOT NULL,
    deleted_objects INTEGER,
    notified_at     TEXT,
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT
);

CREATE INDEX IF NOT EXISTS idx_erasure_pending
    ON erasure_requests (notified_at) WHERE notified_at IS NULL;
