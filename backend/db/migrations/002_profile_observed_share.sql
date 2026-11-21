-- How much of each baseline profile came from measured readings rather than
-- values PeMS filled in. 0-1. Existing rows default to 0 (unknown, treated as
-- fully estimated); rebuild the profiles to populate real values.
ALTER TABLE baseline_profiles
  ADD COLUMN observed_share real NOT NULL DEFAULT 0
  CHECK (observed_share BETWEEN 0 AND 1);
