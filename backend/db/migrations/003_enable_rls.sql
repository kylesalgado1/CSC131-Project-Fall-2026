-- Supabase exposes the public schema through an automatic REST API. Row-level
-- security with no policies denies that API every row, so only the backend,
-- which connects as the table owner, can read or write these tables.
ALTER TABLE pems_stations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE pems_observations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE baseline_profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingest_runs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE schema_migrations  ENABLE ROW LEVEL SECURITY;
