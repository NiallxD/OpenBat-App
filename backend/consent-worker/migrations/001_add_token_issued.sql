-- Adds the device-token issuance flag to an EXISTING consent_records table.
-- Fresh databases get this from schema.sql directly and don't need this file.
--
-- Apply with:
--   wrangler d1 execute openbat-consent --file=migrations/001_add_token_issued.sql
--
-- Defaulting to 0 deliberately: every device registered before tokens existed
-- gets to collect one on its next consent change, rather than being locked out
-- of upload and erasure. See the migration-window note in README.md.

ALTER TABLE consent_records ADD COLUMN token_issued INTEGER NOT NULL DEFAULT 0;
