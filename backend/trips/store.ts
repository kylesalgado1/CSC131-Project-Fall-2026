import { randomUUID } from 'crypto';
import { Database, Queryable } from '../db/db';
import { Confidence, LatLng, PredictionSource } from '../prediction/types';
import { addMinutes, HOUR_MS } from '../util/time';
import { sha256Hex } from './auth';
import { DEVICE_RETENTION_DAYS, PLANNING_HORIZON_MINUTES } from './config';
import { sqlStateOf, UNDEFINED_TABLE } from './databaseFailures';
import { RevisionConflictError, UnauthorizedError } from './errors';
import { AlertKind } from './types';

/** The migration that creates everything in this file. */
export const TRIP_MIGRATION = '005_trip_monitoring.sql';

/** Whether a trip is being monitored, and if not, why it stopped. */
export type TripStatus = 'active' | 'cancelled' | 'departed' | 'ended';
/** How far an active trip has got. Clients are told a phase derived from it. */
export type StoredPhase = 'scheduled' | 'planning' | 'planned' | 'monitoring';
/** Whether the trip's one heads-up is still to come, queued, or not needed. */
export type HeadsUpState = 'pending' | 'sent' | 'skipped';

/** One app installation. */
export interface Device {
  id: string;
  secretHash: string;
  platform: 'ios';
  syncRevision: number;
  syncDigest: string | null;
  apnsToken: string | null;
  apnsEnvironment: 'sandbox' | 'production' | null;
  /** Null until the device reports it. */
  notificationsAuthorized: boolean | null;
  pushFailureReason: string | null;
  pushFailureAt: Date | null;
  createdAt: Date;
  lastSeenAt: Date;
}

/** One trip, as stored. */
export interface TripRow {
  /** The row's own id. Clients never see it. */
  id: string;
  deviceId: string;
  /** The app's id for the trip, unique for the device. */
  clientId: string;
  title: string;
  origin: LatLng;
  destination: LatLng;
  destinationName: string | null;
  arriveBy: Date;
  startsAt: Date | null;
  timeZone: string;
  status: TripStatus;
  phase: StoredPhase;
  contentVersion: number;

  action: 'leave_now' | 'wait' | 'leave_later' | null;
  departAt: Date | null;
  arriveAt: Date | null;
  driveMinutes: number | null;
  reason: string | null;
  confidence: Confidence | null;
  confidenceReason: string | null;
  notes: string[] | null;
  lateByMinutes: number | null;
  marginMinutes: number | null;
  source: PredictionSource | null;
  evaluatedAt: Date | null;
  noPlanReason: string | null;

  evalFailures: number;
  lastErrorCode: string | null;
  lastErrorAt: Date | null;

  anchorAt: Date | null;
  monitoringStartedAt: Date | null;
  headsUpState: HeadsUpState;
  /** When the heads-up was queued. Whether it was sent is in the outbox. */
  headsUpSentAt: Date | null;
  notifiedDepartAt: Date | null;
  candidateDepartAt: Date | null;
  notifiedDegraded: boolean | null;
  lastUpdateAt: Date | null;
  updateCount: number;
  leaveSentAt: Date | null;
  lateSentAt: Date | null;
  departedAt: Date | null;

  nextCheckAt: Date | null;
  leaseToken: string | null;
  leaseUntil: Date | null;

  createdAt: Date;
  updatedAt: Date;
  endedAt: Date | null;
}

/** One trip of a snapshot, checked and with its dates parsed. */
export interface SnapshotTrip {
  id: string;
  title: string;
  origin: LatLng;
  destination: LatLng;
  destinationName: string | null;
  arriveBy: Date;
  startsAt: Date | null;
  timeZone: string;
}

/** What became of a snapshot. */
export interface SnapshotResult {
  /** True when the snapshot replaced what was stored. */
  applied: boolean;
  /** The revision stored once the request was handled. */
  revision: number;
  /** The digest of the snapshot stored once the request was handled. */
  digest: string;
}

/** What a device reports about where its alerts should go. */
export interface PushRegistration {
  apnsToken: string | null;
  environment: 'sandbox' | 'production';
  authorized: boolean;
}

/** One alert of a trip, as a client is told about it. */
export interface TripAlert {
  kind: AlertKind;
  status: 'queued' | 'sent' | 'dropped' | 'failed';
  /** When APNs accepted it; for any other status, when it was queued. */
  at: Date;
  reason?: string;
}

/** What the outbox says about one trip's alerts. */
export interface TripAlerts {
  /** When APNs accepted the heads-up, if it has. */
  headsUpSentAt: Date | null;
  /** When APNs accepted the leave alert, if it has. */
  leaveAlertSentAt: Date | null;
  lastAlert: TripAlert | null;
}

/** A trip no alert was ever queued for. */
export const NO_ALERTS: TripAlerts = {
  headsUpSentAt: null,
  leaveAlertSentAt: null,
  lastAlert: null,
};

/** What became of "I've left": done, no such trip, or a trip since moved. */
export type DepartedOutcome =
  | { outcome: 'ok'; trip: TripRow }
  | { outcome: 'not_found' }
  | { outcome: 'superseded' };

/** How much a purge removed. */
export interface PurgeReport {
  trips: number;
  devices: number;
}

// Both drivers must read a timestamp the same way, so it leaves the database
// as epoch milliseconds: `pg` and PGlite parse a timestamptz differently.
const epochMs = (column: string, prefix = ''): string =>
  `(extract(epoch FROM ${prefix}${column}) * 1000)::float8 AS ${column}`;

const toDate = (ms: number | null): Date | null =>
  ms === null ? null : new Date(Math.round(ms));

const iso = (date: Date | null): string | null =>
  date === null ? null : date.toISOString();

const DEVICE_COLUMNS = [
  'id',
  'secret_hash',
  'platform',
  // A bigint comes back as a string from `pg` and a number from PGlite.
  'sync_revision::text AS sync_revision',
  'sync_digest',
  'apns_token',
  'apns_environment',
  'notifications_authorized',
  'push_failure_reason',
  epochMs('push_failure_at'),
  epochMs('created_at'),
  epochMs('last_seen_at'),
].join(', ');

interface DeviceRecord {
  id: string;
  secret_hash: string;
  platform: 'ios';
  sync_revision: string;
  sync_digest: string | null;
  apns_token: string | null;
  apns_environment: 'sandbox' | 'production' | null;
  notifications_authorized: boolean | null;
  push_failure_reason: string | null;
  push_failure_at: number | null;
  created_at: number;
  last_seen_at: number;
}

const mapDevice = (r: DeviceRecord): Device => ({
  id: r.id,
  secretHash: r.secret_hash,
  platform: r.platform,
  syncRevision: Number(r.sync_revision),
  syncDigest: r.sync_digest,
  apnsToken: r.apns_token,
  apnsEnvironment: r.apns_environment,
  notificationsAuthorized: r.notifications_authorized,
  pushFailureReason: r.push_failure_reason,
  pushFailureAt: toDate(r.push_failure_at),
  createdAt: new Date(Math.round(r.created_at)),
  lastSeenAt: new Date(Math.round(r.last_seen_at)),
});

const TRIP_PLAIN_COLUMNS = [
  'id',
  'device_id',
  'client_id',
  'title',
  'origin_lat',
  'origin_lng',
  'dest_lat',
  'dest_lng',
  'dest_name',
  'time_zone',
  'status',
  'phase',
  'content_version',
  'action',
  'drive_minutes',
  'reason',
  'confidence',
  'confidence_reason',
  'late_by_minutes',
  'margin_minutes',
  'no_plan_reason',
  'eval_failures',
  'last_error_code',
  'heads_up_state',
  'notified_degraded',
  'update_count',
  'lease_token',
];
// Read back as text and parsed here, which both drivers agree on.
const TRIP_JSON_COLUMNS = ['notes', 'source'];
const TRIP_TIME_COLUMNS = [
  'arrive_by',
  'starts_at',
  'depart_at',
  'arrive_at',
  'evaluated_at',
  'last_error_at',
  'anchor_at',
  'monitoring_started_at',
  'heads_up_sent_at',
  'notified_depart_at',
  'candidate_depart_at',
  'last_update_at',
  'leave_sent_at',
  'late_sent_at',
  'departed_at',
  'next_check_at',
  'lease_until',
  'created_at',
  'updated_at',
  'ended_at',
];

/**
 * The select list that `mapTrip` reads, for SELECT and RETURNING alike. Give
 * the table's alias when the query joins, e.g. `tripColumns('t')`.
 */
export function tripColumns(alias?: string): string {
  const prefix = alias ? `${alias}.` : '';
  return [
    ...TRIP_PLAIN_COLUMNS.map(column => `${prefix}${column}`),
    ...TRIP_JSON_COLUMNS.map(column => `${prefix}${column}::text AS ${column}`),
    ...TRIP_TIME_COLUMNS.map(column => epochMs(column, prefix)),
  ].join(', ');
}

/** A trip as `tripColumns` selects it. */
export interface TripRecord {
  id: string;
  device_id: string;
  client_id: string;
  title: string;
  origin_lat: number;
  origin_lng: number;
  dest_lat: number;
  dest_lng: number;
  dest_name: string | null;
  time_zone: string;
  status: TripStatus;
  phase: StoredPhase;
  content_version: number;
  action: TripRow['action'];
  drive_minutes: number | null;
  reason: string | null;
  confidence: Confidence | null;
  confidence_reason: string | null;
  late_by_minutes: number | null;
  margin_minutes: number | null;
  no_plan_reason: string | null;
  eval_failures: number;
  last_error_code: string | null;
  heads_up_state: HeadsUpState;
  notified_degraded: boolean | null;
  update_count: number;
  lease_token: string | null;
  notes: string | null;
  source: string | null;
  arrive_by: number;
  starts_at: number | null;
  depart_at: number | null;
  arrive_at: number | null;
  evaluated_at: number | null;
  last_error_at: number | null;
  anchor_at: number | null;
  monitoring_started_at: number | null;
  heads_up_sent_at: number | null;
  notified_depart_at: number | null;
  candidate_depart_at: number | null;
  last_update_at: number | null;
  leave_sent_at: number | null;
  late_sent_at: number | null;
  departed_at: number | null;
  next_check_at: number | null;
  lease_until: number | null;
  created_at: number;
  updated_at: number;
  ended_at: number | null;
}

const parseJson = <T>(text: string | null): T | null =>
  text === null ? null : (JSON.parse(text) as T);

/** Turns a row selected with `tripColumns` into a trip. */
export function mapTrip(r: TripRecord): TripRow {
  return {
    id: r.id,
    deviceId: r.device_id,
    clientId: r.client_id,
    title: r.title,
    origin: { lat: r.origin_lat, lng: r.origin_lng },
    destination: { lat: r.dest_lat, lng: r.dest_lng },
    destinationName: r.dest_name,
    arriveBy: new Date(Math.round(r.arrive_by)),
    startsAt: toDate(r.starts_at),
    timeZone: r.time_zone,
    status: r.status,
    phase: r.phase,
    contentVersion: r.content_version,
    action: r.action,
    departAt: toDate(r.depart_at),
    arriveAt: toDate(r.arrive_at),
    driveMinutes: r.drive_minutes,
    reason: r.reason,
    confidence: r.confidence,
    confidenceReason: r.confidence_reason,
    notes: parseJson<string[]>(r.notes),
    lateByMinutes: r.late_by_minutes,
    marginMinutes: r.margin_minutes,
    source: parseJson<PredictionSource>(r.source),
    evaluatedAt: toDate(r.evaluated_at),
    noPlanReason: r.no_plan_reason,
    evalFailures: r.eval_failures,
    lastErrorCode: r.last_error_code,
    lastErrorAt: toDate(r.last_error_at),
    anchorAt: toDate(r.anchor_at),
    monitoringStartedAt: toDate(r.monitoring_started_at),
    headsUpState: r.heads_up_state,
    headsUpSentAt: toDate(r.heads_up_sent_at),
    notifiedDepartAt: toDate(r.notified_depart_at),
    candidateDepartAt: toDate(r.candidate_depart_at),
    notifiedDegraded: r.notified_degraded,
    lastUpdateAt: toDate(r.last_update_at),
    updateCount: r.update_count,
    leaveSentAt: toDate(r.leave_sent_at),
    lateSentAt: toDate(r.late_sent_at),
    departedAt: toDate(r.departed_at),
    nextCheckAt: toDate(r.next_check_at),
    leaseToken: r.lease_token,
    leaseUntil: toDate(r.lease_until),
    createdAt: new Date(Math.round(r.created_at)),
    updatedAt: new Date(Math.round(r.updated_at)),
    endedAt: toDate(r.ended_at),
  };
}

/**
 * Erases a trip's recommendation and what the last evaluation said. Used
 * whenever a trip stops being active: nothing derived from a traffic
 * provider is kept for a trip nobody is monitoring.
 */
export const CLEAR_PLAN_SQL = `
  action = NULL, depart_at = NULL, arrive_at = NULL, drive_minutes = NULL,
  reason = NULL, confidence = NULL, confidence_reason = NULL, notes = NULL,
  late_by_minutes = NULL, margin_minutes = NULL, source = NULL,
  evaluated_at = NULL, no_plan_reason = NULL,
  eval_failures = 0, last_error_code = NULL, last_error_at = NULL`;

/** Gives up whatever claim a worker holds on a trip. */
export const CLEAR_LEASE_SQL = 'lease_token = NULL, lease_until = NULL';

// What the monitor has done for a trip: which alerts it queued, and for
// which departure. Forgotten only when the trip materially changes.
const RESET_LEDGER_SQL = `
  anchor_at = NULL, monitoring_started_at = NULL, heads_up_state = 'pending',
  heads_up_sent_at = NULL, notified_depart_at = NULL,
  candidate_depart_at = NULL, notified_degraded = NULL,
  last_update_at = NULL, update_count = 0, leave_sent_at = NULL,
  late_sent_at = NULL, departed_at = NULL`;

/**
 * Whether the trip tables exist: migration 005 is recorded and readable.
 * False is a definite answer from the database that they are not there. A
 * database that could not be asked is not an answer, and is thrown: a
 * dropped connection must never read as "trip monitoring is not set up".
 */
export async function isMonitoringSchemaReady(db: Queryable): Promise<boolean> {
  try {
    const { rows } = await db.query(
      'SELECT 1 AS applied FROM schema_migrations WHERE version = $1',
      [TRIP_MIGRATION],
    );
    if (rows.length === 0) {
      return false;
    }
    await db.query('SELECT 1 FROM trips LIMIT 0');
    return true;
  } catch (error) {
    if (sqlStateOf(error) === UNDEFINED_TABLE) {
      // No migrations table at all, or one that says more than is there.
      return false;
    }
    throw error;
  }
}

/** Stores a new device. Only the hash of its secret is given, and kept. */
export async function createDevice(
  db: Queryable,
  device: { id: string; secretHash: string; platform: 'ios'; now: Date },
): Promise<void> {
  await db.query(
    `INSERT INTO devices (id, secret_hash, platform, created_at, last_seen_at)
     VALUES ($1::uuid, $2, $3, $4::timestamptz, $4::timestamptz)`,
    [device.id, device.secretHash, device.platform, iso(device.now)],
  );
}

/** How many devices registered at or after the given time. */
export async function countDevicesCreatedSince(
  db: Queryable,
  since: Date,
): Promise<number> {
  const { rows } = await db.query<{ n: string }>(
    `SELECT count(*)::text AS n FROM devices
      WHERE created_at >= $1::timestamptz`,
    [iso(since)],
  );
  return Number(rows[0].n);
}

/** The device with this id, if there is one. The id must be a UUID. */
export async function findDevice(
  db: Queryable,
  id: string,
): Promise<Device | undefined> {
  const { rows } = await db.query<DeviceRecord>(
    `SELECT ${DEVICE_COLUMNS} FROM devices WHERE id = $1::uuid`,
    [id],
  );
  return rows[0] ? mapDevice(rows[0]) : undefined;
}

/** Notes that a device was just heard from. */
export async function touchDevice(
  db: Queryable,
  id: string,
  now: Date,
): Promise<void> {
  await db.query(
    'UPDATE devices SET last_seen_at = $2::timestamptz WHERE id = $1::uuid',
    [id, iso(now)],
  );
}

/** Deletes a device with its trips and queued alerts. False if it was gone. */
export async function deleteDevice(
  db: Queryable,
  id: string,
): Promise<boolean> {
  const { rows } = await db.query(
    'DELETE FROM devices WHERE id = $1::uuid RETURNING id',
    [id],
  );
  return rows.length > 0;
}

/**
 * Takes trips out of monitoring: cancelled, departed or past their arrival
 * time. Their recommendation is erased and their queued alerts are deleted,
 * so nothing more is sent for them. What the monitor already did for them
 * stays on the row: a trip that is added back unchanged must not be alerted
 * about twice. A trip that ended is taken to have ended at its arrival time.
 * Run it inside the transaction that decided the trips are over. To cancel
 * trips use `cancelTrips`, which also settles what is remembered of them.
 */
export async function retireTrips(
  tx: Queryable,
  tripIds: string[],
  status: Exclude<TripStatus, 'active'>,
  now: Date,
): Promise<void> {
  if (tripIds.length === 0) {
    return;
  }
  await tx.query(
    `UPDATE trips SET
       status = $2::text,
       ended_at = COALESCE(ended_at, CASE WHEN $2::text = 'ended'
                                          THEN LEAST(arrive_by, $3::timestamptz)
                                          ELSE $3::timestamptz END),
       departed_at = CASE WHEN $2::text = 'departed'
                          THEN COALESCE(departed_at, $3::timestamptz)
                          ELSE departed_at END,
       next_check_at = NULL,
       updated_at = $3::timestamptz,
       ${CLEAR_LEASE_SQL},
       ${CLEAR_PLAN_SQL}
     WHERE id = ANY($1::uuid[])`,
    [tripIds, status, iso(now)],
  );
  await tx.query(
    'DELETE FROM trip_notifications WHERE trip_id = ANY($1::uuid[])',
    [tripIds],
  );
}

/**
 * Cancels trips: their device no longer wants them monitored. A cancelled
 * trip may be added back unchanged, and is then monitored again with the
 * record of its alerts, so before that record is kept it is made true:
 *
 * - An alert that was queued and never went out dies with the cancellation,
 *   so the record of it is undone and the trip, if it comes back, is told
 *   again. Waiting alerts always count as not sent. One that is being sent
 *   at this very moment counts as not sent only when hearing it twice beats
 *   missing it ("time to leave", "running late"), as at delivery.
 * - What the user was last told is then what the last alert APNs accepted
 *   said.
 * - A trip with nothing left to remember (no heads-up, update, leave or late
 *   alert on record, and not left) is deleted outright. Added back, it
 *   starts as a new trip, which comes to the same thing, and a device cannot
 *   pile up rows by listing trips and dropping them.
 * - The rest are kept as cancelled for the retention time, as `retireTrips`
 *   leaves them.
 *
 * One thing is not restored: whether the departure the user was last told
 * came from a poorer source (`notified_degraded`) is not kept per alert, so
 * after an update that never went out it is the unsent update's.
 *
 * Run it inside the transaction that decided the trips are cancelled.
 */
export async function cancelTrips(
  tx: Queryable,
  tripIds: string[],
  now: Date,
): Promise<void> {
  if (tripIds.length === 0) {
    return;
  }
  await tx.query(
    `UPDATE trips t SET
       heads_up_state = CASE WHEN u.heads_up THEN 'pending'
                             ELSE t.heads_up_state END,
       heads_up_sent_at = CASE WHEN u.heads_up THEN NULL
                               ELSE t.heads_up_sent_at END,
       leave_sent_at = CASE WHEN u.leave_now THEN NULL
                            ELSE t.leave_sent_at END,
       late_sent_at = CASE WHEN u.late THEN NULL ELSE t.late_sent_at END,
       update_count = GREATEST(t.update_count - u.updates, 0),
       notified_depart_at = CASE WHEN u.told THEN said.depart_at
                                 ELSE t.notified_depart_at END,
       last_update_at = CASE WHEN u.told THEN said.created_at
                             ELSE t.last_update_at END,
       notified_degraded = CASE WHEN u.told AND said.depart_at IS NULL
                                THEN NULL ELSE t.notified_degraded END,
       candidate_depart_at = CASE WHEN u.told THEN NULL
                                  ELSE t.candidate_depart_at END
      FROM (
        SELECT o.id AS trip_id, o.content_version,
               bool_or(n.kind = 'heads_up') AS heads_up,
               bool_or(n.kind = 'leave_now') AS leave_now,
               bool_or(n.kind = 'late') AS late,
               (count(*) FILTER (WHERE n.kind = 'update'))::integer AS updates,
               bool_or(n.kind <> 'leave_now') AS told
          FROM trip_notifications n
          JOIN trips o ON o.id = n.trip_id
         WHERE n.trip_id = ANY($1::uuid[])
           AND n.content_version = o.content_version
           AND (n.status = 'pending'
                OR (n.status = 'sending' AND n.kind IN ('leave_now', 'late')))
         GROUP BY o.id, o.content_version
      ) u
      LEFT JOIN LATERAL (
        SELECT (s.payload->>'departAt')::timestamptz AS depart_at,
               s.created_at
          FROM trip_notifications s
         WHERE s.trip_id = u.trip_id
           AND s.content_version = u.content_version
           AND s.status = 'sent' AND s.kind <> 'leave_now'
         ORDER BY s.created_at DESC, s.id DESC
         LIMIT 1
      ) said ON true
     WHERE t.id = u.trip_id`,
    [tripIds],
  );
  // Their alerts go with them.
  await tx.query(
    `DELETE FROM trips
      WHERE id = ANY($1::uuid[])
        AND heads_up_state <> 'sent' AND update_count = 0
        AND leave_sent_at IS NULL AND late_sent_at IS NULL
        AND departed_at IS NULL`,
    [tripIds],
  );
  await retireTrips(tx, tripIds, 'cancelled', now);
}

/**
 * Stores where a device's alerts go. One APNs token belongs to one device:
 * storing a token takes it away from any other device that had it and cancels
 * that device's active trips, since its alerts would now reach somebody else
 * (in practice the same phone, registered again). Returns the device as it
 * now is, or nothing if it no longer exists.
 */
export async function updatePush(
  db: Database,
  deviceId: string,
  push: PushRegistration,
  now: Date,
): Promise<Device | undefined> {
  return db.transaction(async tx => {
    if (push.apnsToken !== null) {
      // Two devices claiming one token at the same moment take turns.
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [
        push.apnsToken,
      ]);
      // Its stored snapshot no longer describes what is monitored, so the
      // digest goes too: the device's next sync is then applied afresh.
      const silenced = await tx.query<{ id: string }>(
        `UPDATE devices SET apns_token = NULL, sync_digest = NULL
          WHERE apns_token = $1 AND id <> $2::uuid
        RETURNING id`,
        [push.apnsToken, deviceId],
      );
      if (silenced.rows.length > 0) {
        const active = await tx.query<{ id: string }>(
          `SELECT id FROM trips
            WHERE device_id = ANY($1::uuid[]) AND status = 'active'`,
          [silenced.rows.map(r => r.id)],
        );
        await cancelTrips(
          tx,
          active.rows.map(r => r.id),
          now,
        );
      }
    }
    const { rows } = await tx.query<DeviceRecord>(
      `UPDATE devices
          SET apns_token = $2, apns_environment = $3,
              notifications_authorized = $4
        WHERE id = $1::uuid
      RETURNING ${DEVICE_COLUMNS}`,
      [deviceId, push.apnsToken, push.environment, push.authorized],
    );
    return rows[0] ? mapDevice(rows[0]) : undefined;
  });
}

/** Every trip of a device that is not cancelled, by arrival time. */
export async function getTrips(
  db: Queryable,
  deviceId: string,
): Promise<TripRow[]> {
  const { rows } = await db.query<TripRecord>(
    `SELECT ${tripColumns()} FROM trips
      WHERE device_id = $1::uuid AND status <> 'cancelled'
      ORDER BY trips.arrive_by, client_id`,
    [deviceId],
  );
  return rows.map(mapTrip);
}

/** One trip of a device by the app's id for it, unless it is cancelled. */
export async function getTrip(
  db: Queryable,
  deviceId: string,
  clientId: string,
): Promise<TripRow | undefined> {
  const { rows } = await db.query<TripRecord>(
    `SELECT ${tripColumns()} FROM trips
      WHERE device_id = $1::uuid AND client_id = $2 AND status <> 'cancelled'`,
    [deviceId, clientId],
  );
  return rows[0] ? mapTrip(rows[0]) : undefined;
}

const ALERT_STATUS: Record<string, TripAlert['status']> = {
  pending: 'queued',
  sending: 'queued',
  sent: 'sent',
  dropped: 'dropped',
  failed: 'failed',
};

/**
 * What the outbox says about each of a device's trips, keyed by the trip
 * row's id. Only alerts for the trip as it now is count: one queued before
 * the trip was rescheduled says nothing about the new plan. An alert counts
 * as sent only once APNs accepted it.
 */
export async function getTripAlerts(
  db: Queryable,
  deviceId: string,
): Promise<Map<string, TripAlerts>> {
  const { rows } = await db.query<{
    trip_id: string;
    kind: AlertKind;
    status: string;
    last_error: string | null;
    created_at: number;
    sent_at: number | null;
  }>(
    `SELECT n.trip_id, n.kind, n.status, n.last_error,
            ${epochMs('created_at', 'n.')}, ${epochMs('sent_at', 'n.')}
       FROM trip_notifications n
       JOIN trips t ON t.id = n.trip_id
      WHERE n.device_id = $1::uuid AND n.content_version = t.content_version
      ORDER BY n.created_at, n.id`,
    [deviceId],
  );
  const byTrip = new Map<string, TripAlerts>();
  // Oldest first, so the last one seen for a trip is its newest.
  for (const row of rows) {
    const alerts = byTrip.get(row.trip_id) ?? { ...NO_ALERTS };
    const status = ALERT_STATUS[row.status] ?? 'failed';
    const sentAt = status === 'sent' ? toDate(row.sent_at) : null;
    if (sentAt && row.kind === 'heads_up') {
      alerts.headsUpSentAt = sentAt;
    }
    if (sentAt && row.kind === 'leave_now') {
      alerts.leaveAlertSentAt = sentAt;
    }
    alerts.lastAlert = {
      kind: row.kind,
      status,
      at: sentAt ?? new Date(Math.round(row.created_at)),
      ...(status !== 'sent' && row.last_error
        ? { reason: row.last_error }
        : {}),
    };
    byTrip.set(row.trip_id, alerts);
  }
  return byTrip;
}

/**
 * The fingerprint of a snapshot: SHA-256 of its trips in a fixed order and
 * shape. Two requests carry the same snapshot exactly when these are equal.
 */
export function snapshotDigest(trips: SnapshotTrip[]): string {
  const canonical = [...trips]
    // By code unit, not by locale: the order must be the same everywhere.
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .map(trip => ({
      id: trip.id,
      title: trip.title,
      origin: { lat: trip.origin.lat, lng: trip.origin.lng },
      destination: { lat: trip.destination.lat, lng: trip.destination.lng },
      destinationName: trip.destinationName,
      arriveBy: trip.arriveBy.toISOString(),
      startsAt: iso(trip.startsAt),
      timeZone: trip.timeZone,
    }));
  return sha256Hex(JSON.stringify(canonical));
}

/** The digest of a device that wants nothing monitored. */
export const EMPTY_SNAPSHOT_DIGEST = snapshotDigest([]);

// Coordinates are compared at about 11 cm: finer differences are GPS noise,
// and must not restart a trip's planning.
const sameCoordinate = (a: number, b: number): boolean =>
  Math.round(a * 1e6) === Math.round(b * 1e6);

const samePlace = (a: LatLng, b: LatLng): boolean =>
  sameCoordinate(a.lat, b.lat) && sameCoordinate(a.lng, b.lng);

/** A change that makes the stored plan and alerts say nothing any more. */
const isMaterialChange = (stored: TripRow, wanted: SnapshotTrip): boolean =>
  stored.arriveBy.getTime() !== wanted.arriveBy.getTime() ||
  stored.timeZone !== wanted.timeZone ||
  !samePlace(stored.origin, wanted.origin) ||
  !samePlace(stored.destination, wanted.destination);

const isLabelChange = (stored: TripRow, wanted: SnapshotTrip): boolean =>
  stored.title !== wanted.title ||
  stored.destinationName !== wanted.destinationName ||
  (stored.startsAt?.getTime() ?? null) !== (wanted.startsAt?.getTime() ?? null);

interface Start {
  status: 'active' | 'ended';
  phase: StoredPhase;
  nextCheckAt: Date | null;
  endedAt: Date | null;
}

/**
 * Where a trip starts, new or materially changed. Inside the planning
 * horizon it is due for its first evaluation at once. Beyond it there is
 * nothing to ask a traffic provider yet, so it waits for the moment it
 * enters the horizon. Past its arrival time it is over before it begins.
 */
function startFor(arriveBy: Date, now: Date): Start {
  if (arriveBy.getTime() <= now.getTime()) {
    return {
      status: 'ended',
      phase: 'planning',
      nextCheckAt: null,
      endedAt: arriveBy,
    };
  }
  const entersHorizonAt = addMinutes(arriveBy, -PLANNING_HORIZON_MINUTES);
  return entersHorizonAt.getTime() > now.getTime()
    ? {
        status: 'active',
        phase: 'scheduled',
        nextCheckAt: entersHorizonAt,
        endedAt: null,
      }
    : { status: 'active', phase: 'planning', nextCheckAt: now, endedAt: null };
}

async function allTripsOf(tx: Queryable, deviceId: string): Promise<TripRow[]> {
  const { rows } = await tx.query<TripRecord>(
    `SELECT ${tripColumns()} FROM trips WHERE device_id = $1::uuid`,
    [deviceId],
  );
  return rows.map(mapTrip);
}

interface Placed {
  id: string;
  trip: SnapshotTrip;
  start: Start;
}

const placedColumns = (rows: Placed[]): unknown[] => [
  rows.map(r => r.id),
  rows.map(r => r.trip.id),
  rows.map(r => r.trip.title),
  rows.map(r => r.trip.origin.lat),
  rows.map(r => r.trip.origin.lng),
  rows.map(r => r.trip.destination.lat),
  rows.map(r => r.trip.destination.lng),
  rows.map(r => r.trip.destinationName),
  rows.map(r => iso(r.trip.arriveBy)),
  rows.map(r => iso(r.trip.startsAt)),
  rows.map(r => r.trip.timeZone),
  rows.map(r => r.start.status),
  rows.map(r => r.start.phase),
  rows.map(r => iso(r.start.nextCheckAt)),
  rows.map(r => iso(r.start.endedAt)),
];

// The arrays of `placedColumns`, side by side as rows.
const PLACED_UNNEST = `unnest($1::uuid[], $2::text[], $3::text[],
       $4::float8[], $5::float8[], $6::float8[], $7::float8[], $8::text[],
       $9::timestamptz[], $10::timestamptz[], $11::text[], $12::text[],
       $13::text[], $14::timestamptz[], $15::timestamptz[])
       AS v(id, client_id, title, origin_lat, origin_lng, dest_lat, dest_lng,
            dest_name, arrive_by, starts_at, time_zone, status, phase,
            next_check_at, ended_at)`;

async function insertTrips(
  tx: Queryable,
  deviceId: string,
  rows: Placed[],
  now: Date,
): Promise<void> {
  if (rows.length === 0) {
    return;
  }
  await tx.query(
    `INSERT INTO trips
            (id, device_id, client_id, title, origin_lat, origin_lng,
             dest_lat, dest_lng, dest_name, arrive_by, starts_at, time_zone,
             status, phase, next_check_at, ended_at, created_at, updated_at)
     SELECT v.id, $16::uuid, v.client_id, v.title, v.origin_lat,
            v.origin_lng, v.dest_lat, v.dest_lng, v.dest_name, v.arrive_by,
            v.starts_at, v.time_zone, v.status, v.phase, v.next_check_at,
            v.ended_at, $17::timestamptz, $17::timestamptz
       FROM ${PLACED_UNNEST}`,
    [...placedColumns(rows), deviceId, iso(now)],
  );
}

/** Starts trips over: a new version with no plan and no alerts to its name. */
async function resetTrips(
  tx: Queryable,
  rows: Placed[],
  now: Date,
): Promise<void> {
  if (rows.length === 0) {
    return;
  }
  await tx.query(
    `UPDATE trips t SET
       title = v.title, origin_lat = v.origin_lat, origin_lng = v.origin_lng,
       dest_lat = v.dest_lat, dest_lng = v.dest_lng, dest_name = v.dest_name,
       arrive_by = v.arrive_by, starts_at = v.starts_at,
       time_zone = v.time_zone, status = v.status, phase = v.phase,
       content_version = t.content_version + 1,
       next_check_at = v.next_check_at, ended_at = v.ended_at,
       updated_at = $16::timestamptz,
       ${CLEAR_LEASE_SQL},
       ${CLEAR_PLAN_SQL},
       ${RESET_LEDGER_SQL}
     FROM ${PLACED_UNNEST}
     WHERE t.id = v.id`,
    [...placedColumns(rows), iso(now)],
  );
}

/** Updates what a trip is called, which no plan or alert depends on. */
async function relabelTrips(
  tx: Queryable,
  rows: Array<{ id: string; trip: SnapshotTrip }>,
  now: Date,
): Promise<void> {
  if (rows.length === 0) {
    return;
  }
  await tx.query(
    `UPDATE trips t
        SET title = v.title, dest_name = v.dest_name,
            starts_at = v.starts_at, updated_at = $5::timestamptz
       FROM unnest($1::uuid[], $2::text[], $3::text[], $4::timestamptz[])
            AS v(id, title, dest_name, starts_at)
      WHERE t.id = v.id`,
    [
      rows.map(r => r.id),
      rows.map(r => r.trip.title),
      rows.map(r => r.trip.destinationName),
      rows.map(r => iso(r.trip.startsAt)),
      iso(now),
    ],
  );
}

/**
 * Makes a device's monitored trips exactly the given ones, unless the server
 * already holds this revision or a later one.
 *
 * - A lower revision changes nothing: it is a late copy of an older request,
 *   and must not bring back a trip that was since cancelled or changed.
 * - The stored revision with the same trips changes nothing: it is a retry.
 *   With different trips it is refused (RevisionConflictError), since two
 *   snapshots cannot share a revision.
 * - A higher revision is applied. A trip not seen before starts fresh. One
 *   whose arrival time, places or time zone changed starts over as a new
 *   version. One that only changed its labels keeps its plan and alerts. One
 *   that was cancelled and is back unchanged is monitored again, keeping the
 *   record of the alerts it already had. A trip the user left stays left,
 *   and one that ended stays ended. Every trip not listed is cancelled (see
 *   `cancelTrips`: one with no alert on record is deleted outright).
 *
 * All in one transaction that first locks the device's row, so two snapshots
 * of one device are handled one after the other.
 */
export async function applySnapshot(
  db: Database,
  deviceId: string,
  revision: number,
  trips: SnapshotTrip[],
  now: Date,
): Promise<SnapshotResult> {
  const digest = snapshotDigest(trips);
  return db.transaction(async tx => {
    const locked = await tx.query<{ revision: string; digest: string | null }>(
      `SELECT sync_revision::text AS revision, sync_digest AS digest
         FROM devices WHERE id = $1::uuid FOR UPDATE`,
      [deviceId],
    );
    if (locked.rows.length === 0) {
      throw new UnauthorizedError();
    }
    const stored = Number(locked.rows[0].revision);
    const storedDigest = locked.rows[0].digest ?? EMPTY_SNAPSHOT_DIGEST;
    if (revision < stored) {
      return { applied: false, revision: stored, digest: storedDigest };
    }
    if (revision === stored) {
      if (digest !== storedDigest) {
        throw new RevisionConflictError(stored);
      }
      return { applied: false, revision: stored, digest: storedDigest };
    }

    const existing = new Map(
      (await allTripsOf(tx, deviceId)).map(row => [row.clientId, row]),
    );
    const created: Placed[] = [];
    const restarted: Placed[] = [];
    const relabelled: Array<{ id: string; trip: SnapshotTrip }> = [];
    const reactivated: string[] = [];
    const leftAgain: string[] = [];
    const ended: string[] = [];
    for (const trip of trips) {
      const row = existing.get(trip.id);
      existing.delete(trip.id);
      if (!row) {
        created.push({
          id: randomUUID(),
          trip,
          start: startFor(trip.arriveBy, now),
        });
        continue;
      }
      if (isMaterialChange(row, trip)) {
        restarted.push({
          id: row.id,
          trip,
          start: startFor(trip.arriveBy, now),
        });
        continue;
      }
      if (isLabelChange(row, trip)) {
        relabelled.push({ id: row.id, trip });
      }
      const over = trip.arriveBy.getTime() <= now.getTime();
      if (row.status === 'cancelled') {
        if (row.departedAt) {
          leftAgain.push(row.id);
        } else if (over) {
          ended.push(row.id);
        } else {
          reactivated.push(row.id);
        }
      } else if (row.status === 'active' && over) {
        ended.push(row.id);
      }
    }
    // Whatever is left was not listed, so the device no longer wants it.
    const cancelled = [...existing.values()]
      .filter(row => row.status !== 'cancelled')
      .map(row => row.id);

    await insertTrips(tx, deviceId, created, now);
    await resetTrips(tx, restarted, now);
    await relabelTrips(tx, relabelled, now);
    if (reactivated.length > 0) {
      await tx.query(
        `UPDATE trips
            SET status = 'active', ended_at = NULL,
                next_check_at = $2::timestamptz,
                updated_at = $2::timestamptz, ${CLEAR_LEASE_SQL}
          WHERE id = ANY($1::uuid[])`,
        [reactivated, iso(now)],
      );
    }
    if (leftAgain.length > 0) {
      await tx.query(
        `UPDATE trips SET status = 'departed', updated_at = $2::timestamptz
          WHERE id = ANY($1::uuid[])`,
        [leftAgain, iso(now)],
      );
    }
    await retireTrips(tx, ended, 'ended', now);
    await cancelTrips(tx, cancelled, now);
    await tx.query(
      `UPDATE devices SET sync_revision = $2, sync_digest = $3
        WHERE id = $1::uuid`,
      [deviceId, revision, digest],
    );
    return { applied: true, revision, digest };
  });
}

/**
 * Records that the user has left for a trip, which ends its monitoring and
 * deletes its queued alerts. `arriveBy` says which version of the trip the
 * user meant: if the trip has since been rescheduled nothing changes
 * ('superseded'), so a stale notification action cannot end the monitoring
 * of the new time. Saying it twice is harmless.
 */
export async function markDeparted(
  db: Database,
  deviceId: string,
  clientId: string,
  arriveBy: Date,
  now: Date,
): Promise<DepartedOutcome> {
  return db.transaction(async tx => {
    // The same lock a snapshot takes, so the two cannot interleave.
    await tx.query('SELECT id FROM devices WHERE id = $1::uuid FOR UPDATE', [
      deviceId,
    ]);
    const trip = await getTrip(tx, deviceId, clientId);
    if (!trip) {
      return { outcome: 'not_found' };
    }
    if (trip.arriveBy.getTime() !== arriveBy.getTime()) {
      return { outcome: 'superseded' };
    }
    if (trip.status !== 'active') {
      // Already left, or already over: there is nothing to end.
      return { outcome: 'ok', trip };
    }
    await retireTrips(tx, [trip.id], 'departed', now);
    const departed = await getTrip(tx, deviceId, clientId);
    return departed
      ? { outcome: 'ok', trip: departed }
      : { outcome: 'not_found' };
  });
}

/**
 * Enforces retention. A trip whose arrival time has passed is ended, whether
 * or not a monitor was running to notice. A trip that is over is deleted,
 * with its alerts, once that is `retentionHours` in the past: counted from
 * when it was cancelled, or for a trip that ended or was left, from its
 * arrival time if that is later. A device with no active trip that has not
 * been heard from for DEVICE_RETENTION_DAYS is deleted too.
 */
export async function purgeExpired(
  db: Database,
  now: Date,
  retentionHours: number,
): Promise<PurgeReport> {
  const cutoff = iso(new Date(now.getTime() - retentionHours * HOUR_MS));
  const unseenSince = iso(
    new Date(now.getTime() - DEVICE_RETENTION_DAYS * 24 * HOUR_MS),
  );
  return db.transaction(async tx => {
    const overdue = await tx.query<{ id: string }>(
      `SELECT id FROM trips
        WHERE status = 'active' AND arrive_by <= $1::timestamptz
          FOR UPDATE`,
      [iso(now)],
    );
    await retireTrips(
      tx,
      overdue.rows.map(r => r.id),
      'ended',
      now,
    );
    const trips = await tx.query(
      `DELETE FROM trips
        WHERE status <> 'active'
          AND COALESCE(ended_at, updated_at) < $1::timestamptz
          AND (status = 'cancelled' OR arrive_by < $1::timestamptz)
      RETURNING id`,
      [cutoff],
    );
    const devices = await tx.query(
      `DELETE FROM devices d
        WHERE d.last_seen_at < $1::timestamptz
          AND NOT EXISTS (SELECT 1 FROM trips t
                           WHERE t.device_id = d.id AND t.status = 'active')
      RETURNING d.id`,
      [unseenSince],
    );
    return { trips: trips.rows.length, devices: devices.rows.length };
  });
}
