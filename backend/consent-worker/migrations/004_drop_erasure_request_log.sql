-- Replaces the per-device erasure log with a non-identifying monthly counter.
-- Fresh databases get the current shape from schema.sql and don't need this.
--
-- Apply with:
--   wrangler d1 execute openbat-consent --file=migrations/004_drop_erasure_request_log.sql
--
-- `erasure_requests` held a device_id per request, plus timestamps, retry counts
-- and error strings. Almost all of it supported a deletion flow that has been
-- removed: erasure no longer sweeps R2 (recordings carry no device identifier
-- and cannot be attributed to one), so there is nothing to resume after an
-- interruption and nothing for a human to finish afterwards.
--
-- Dropping it also removes a standing list of the identifiers of people who
-- asked to be forgotten — data that had to be justified, retained on a schedule
-- and purged by a cron job. The counter needs none of that.
--
-- ORDERING: deploy the Worker BEFORE running this. The old Worker writes to
-- erasure_requests on every erasure and its scheduled handler reads from it;
-- the new Worker references neither. Worker-then-migration is the only order
-- with no broken window.
--
-- Existing rows are NOT migrated into the counter. They contain device_ids of
-- users who asked to be erased, and carrying them forward to make a tidier
-- number would be the opposite of the point. The pre-launch database is test
-- data in any case.

CREATE TABLE IF NOT EXISTS erasure_counts (
    month TEXT PRIMARY KEY,
    count INTEGER NOT NULL DEFAULT 0
);

DROP TABLE IF EXISTS erasure_requests;
