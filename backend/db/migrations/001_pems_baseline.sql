-- PeMS stations, raw readings, baseline profiles and ingest run logging.
-- Covers stories 1-1 (baseline data) and 1-4 (automatic collection).

CREATE TABLE pems_stations (
  id            integer PRIMARY KEY,
  freeway       text             NOT NULL,
  direction     char(1)          NOT NULL,
  length_miles  numeric(6, 3)    NOT NULL CHECK (length_miles > 0),
  latitude      double precision,
  longitude     double precision
);

-- One row per station per 5-minute reading, on the local clock.
-- The primary key serves "this station over a time range" queries.
CREATE TABLE pems_observations (
  station_id    integer  NOT NULL REFERENCES pems_stations (id),
  observed_on   date     NOT NULL,
  minute_of_day smallint NOT NULL CHECK (minute_of_day BETWEEN 0 AND 1439),
  avg_speed_mph real     NOT NULL CHECK (avg_speed_mph > 0),
  total_flow    integer,
  pct_observed  real     CHECK (pct_observed BETWEEN 0 AND 100),
  PRIMARY KEY (station_id, observed_on, minute_of_day)
);

-- "Everything on this date" and time-range scans across stations.
CREATE INDEX pems_observations_by_date
  ON pems_observations (observed_on, station_id);

-- Typical speed per station, day type and 15-minute bucket. Rebuilt from
-- pems_observations by the aggregation job.
CREATE TABLE baseline_profiles (
  station_id    integer  NOT NULL REFERENCES pems_stations (id),
  day_type      text     NOT NULL CHECK (day_type IN ('weekday', 'weekend', 'holiday')),
  bucket        smallint NOT NULL CHECK (bucket BETWEEN 0 AND 95),
  avg_speed_mph real     NOT NULL CHECK (avg_speed_mph > 0),
  sample_count  integer  NOT NULL CHECK (sample_count > 0),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (station_id, day_type, bucket)
);

-- One row per attempt, so failed pulls are visible and retries are counted.
CREATE TABLE ingest_runs (
  id             bigserial PRIMARY KEY,
  source         text        NOT NULL,
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz,
  status         text        NOT NULL CHECK (status IN ('running', 'succeeded', 'failed')),
  attempt        smallint    NOT NULL DEFAULT 1,
  rows_ingested  integer,
  error          text
);

CREATE INDEX ingest_runs_recent ON ingest_runs (source, started_at DESC);
