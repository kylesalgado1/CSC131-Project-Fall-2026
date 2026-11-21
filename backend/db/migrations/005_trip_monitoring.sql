-- Trip monitoring for the iOS client: the device registry, the trips a device
-- asked the server to watch, the notification outbox and the monitor's
-- heartbeat.
--
-- Privacy. There are no user accounts. A device is an anonymous installation
-- id with the SHA-256 of a random secret; the secret itself is never stored.
-- A trip stores a title, two coordinates, an arrival time and a time zone for
-- that installation id, and a queued notification stores the text it will
-- show. When a trip stops being monitored (cancelled, departed or past its
-- arrival time) its recommendation is erased and its queued notifications are
-- deleted at once; the row itself is purged 24 hours later
-- (TRIP_RETENTION_HOURS), and a device with nothing to monitor is purged
-- after 30 days without contact. TomTom responses and route geometry are
-- never stored (team rule): only the recommendation derived from them, such
-- as when to leave and how sure we are, and only while the trip is active.
--
-- This file is frozen once it has been applied to the shared database: later
-- changes go in 006. Develop against PGlite (the tests), the fixture server
-- or a private Postgres.

-- One row per app installation. apns_* is where its alerts are sent.
CREATE TABLE devices (
  id                       uuid PRIMARY KEY,
  secret_hash              text        NOT NULL,
  platform                 text        NOT NULL CHECK (platform IN ('ios')),
  -- The last trip snapshot applied for this device, and its fingerprint.
  sync_revision            bigint      NOT NULL DEFAULT 0,
  sync_digest              text,
  apns_token               text,
  apns_environment         text        CHECK (apns_environment IN ('sandbox', 'production')),
  -- NULL: not reported yet. false: the user turned notifications off.
  notifications_authorized boolean,
  push_failure_reason      text,
  push_failure_at          timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  last_seen_at             timestamptz NOT NULL DEFAULT now()
);

-- One APNs token belongs to one device.
CREATE UNIQUE INDEX devices_apns_token
  ON devices (apns_token) WHERE apns_token IS NOT NULL;

-- "How many devices registered in the last hour", for the registration cap.
CREATE INDEX devices_created ON devices (created_at);

-- One row per occurrence of an activity. client_id is the app's own id for
-- it, unique for the device.
CREATE TABLE trips (
  id                    uuid PRIMARY KEY,
  device_id             uuid        NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  client_id             text        NOT NULL,
  title                 text        NOT NULL,
  origin_lat            double precision NOT NULL,
  origin_lng            double precision NOT NULL,
  dest_lat              double precision NOT NULL,
  dest_lng              double precision NOT NULL,
  dest_name             text,
  arrive_by             timestamptz NOT NULL,
  starts_at             timestamptz,
  time_zone             text        NOT NULL,
  status                text        NOT NULL CHECK (status IN ('active', 'cancelled', 'departed', 'ended')),
  phase                 text        NOT NULL CHECK (phase IN ('scheduled', 'planning', 'planned', 'monitoring')),
  -- Goes up whenever the route, arrival time or time zone changes, so work
  -- done for an older version of the trip can be told apart and discarded.
  content_version       integer     NOT NULL DEFAULT 1,

  -- The last recommendation: the decision's output only, never a provider's
  -- raw response or any geometry.
  action                text,
  depart_at             timestamptz,
  arrive_at             timestamptz,
  drive_minutes         integer,
  reason                text,
  confidence            text,
  confidence_reason     text,
  notes                 jsonb,
  late_by_minutes       integer,
  margin_minutes        integer,
  source                jsonb,
  evaluated_at          timestamptz,
  no_plan_reason        text,

  eval_failures         integer     NOT NULL DEFAULT 0,
  last_error_code       text,
  last_error_at         timestamptz,

  -- What the monitor has done for this version of the trip.
  anchor_at             timestamptz,
  monitoring_started_at timestamptz,
  heads_up_state        text        NOT NULL DEFAULT 'pending' CHECK (heads_up_state IN ('pending', 'sent', 'skipped')),
  heads_up_sent_at      timestamptz,
  notified_depart_at    timestamptz,
  candidate_depart_at   timestamptz,
  notified_degraded     boolean,
  last_update_at        timestamptz,
  update_count          integer     NOT NULL DEFAULT 0,
  leave_sent_at         timestamptz,
  late_sent_at          timestamptz,
  -- When the user said "I've left". Kept through a cancellation, so adding
  -- the same trip back does not start alerting again.
  departed_at           timestamptz,

  next_check_at         timestamptz,
  lease_token           uuid,
  lease_until           timestamptz,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  ended_at              timestamptz,
  UNIQUE (device_id, client_id)
);

-- "Which trips are due for a check".
CREATE INDEX trips_due ON trips (next_check_at) WHERE status = 'active';

-- The outbox: one row per alert to send. The unique key makes queueing the
-- same alert twice harmless.
CREATE TABLE trip_notifications (
  id              uuid PRIMARY KEY,
  trip_id         uuid        NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
  device_id       uuid        NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  content_version integer     NOT NULL,
  kind            text        NOT NULL CHECK (kind IN ('heads_up', 'update', 'leave_now', 'late')),
  dedupe_key      text        NOT NULL,
  title           text        NOT NULL,
  body            text        NOT NULL,
  payload         jsonb       NOT NULL,
  status          text        NOT NULL CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'dropped')),
  attempts        integer     NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL,
  expires_at      timestamptz NOT NULL,
  lease_token     uuid,
  lease_until     timestamptz,
  apns_id         text,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz,
  UNIQUE (trip_id, content_version, dedupe_key)
);

-- "Which alerts can be claimed": waiting ones, and ones a crashed worker left
-- half sent.
CREATE INDEX trip_notifications_due
  ON trip_notifications (next_attempt_at) WHERE status IN ('pending', 'sending');

-- Deleting a device removes its alerts without scanning the table.
CREATE INDEX trip_notifications_by_device ON trip_notifications (device_id);

-- A single row: when the monitor last ran, and how many evaluations it has
-- spent today.
CREATE TABLE monitor_state (
  id                    integer PRIMARY KEY CHECK (id = 1),
  last_tick_at          timestamptz,
  last_external_tick_at timestamptz,
  budget_day            date,
  budget_used           integer NOT NULL DEFAULT 0
);

INSERT INTO monitor_state (id) VALUES (1);

-- As in 003: no policies, so Supabase's automatic REST API can read or write
-- none of these, and only the backend, which owns the tables, can.
ALTER TABLE devices            ENABLE ROW LEVEL SECURITY;
ALTER TABLE trips              ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE monitor_state      ENABLE ROW LEVEL SECURITY;
