// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// PGlite, the in-memory Postgres these tests use, cannot load inside Jest.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Database } from '../../db/db';
import { runMigrations } from '../../db/migrate';
import { createPgliteDatabase } from '../../db/pglite';
import { issueCredential } from '../auth';
import { PLANNING_HORIZON_MINUTES } from '../config';
import { RevisionConflictError, UnauthorizedError } from '../errors';
import {
  applySnapshot,
  countDevicesCreatedSince,
  createDevice,
  deleteDevice,
  EMPTY_SNAPSHOT_DIGEST,
  findDevice,
  getTrip,
  getTripAlerts,
  getTrips,
  isMonitoringSchemaReady,
  mapTrip,
  markDeparted,
  purgeExpired,
  snapshotDigest,
  SnapshotTrip,
  touchDevice,
  tripColumns,
  TripRecord,
  TripRow,
  updatePush,
} from '../store';

const NOW = new Date('2026-11-20T15:00:00.000Z');
const minutes = (n: number, from: Date = NOW) =>
  new Date(from.getTime() + n * 60_000);
const hours = (n: number, from: Date = NOW) => minutes(n * 60, from);

const LAB = 'A1B2C3@2026-11-20';
const GYM = 'D4E5F6@2026-11-20';

const trip = (over: Partial<SnapshotTrip> = {}): SnapshotTrip => ({
  id: LAB,
  title: 'Chem lab',
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  destinationName: 'Sac State',
  arriveBy: hours(3),
  startsAt: minutes(190),
  timeZone: 'America/Los_Angeles',
  ...over,
});

const TOKEN = 'ab'.repeat(32);

let db: Database;

// One database for the whole file, emptied before each test: starting a
// fresh PGlite for every test would make this suite several times slower.
before(async () => {
  db = await createPgliteDatabase();
  await runMigrations(db);
});

after(async () => {
  await db.close();
});

beforeEach(async () => {
  // Takes the trips and the queued alerts with it.
  await db.exec('TRUNCATE devices CASCADE');
});

const newDevice = async (now: Date = NOW): Promise<string> => {
  const credential = issueCredential();
  await createDevice(db, {
    id: credential.deviceId,
    secretHash: credential.secretHash,
    platform: 'ios',
    now,
  });
  return credential.deviceId;
};

/** A trip's row whatever its status, which the public readers do not show. */
const stored = async (deviceId: string, clientId = LAB): Promise<TripRow> => {
  const { rows } = await db.query<TripRecord>(
    `SELECT ${tripColumns()} FROM trips
      WHERE device_id = $1::uuid AND client_id = $2`,
    [deviceId, clientId],
  );
  assert.equal(rows.length, 1, `no row for ${clientId}`);
  return mapTrip(rows[0]);
};

const DEPART_AT = minutes(125);
const LEASE = '0b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d';

/**
 * What the monitor would have stored by the time it has planned a trip, sent
 * its heads-up and one update, and is in the middle of checking it again.
 */
const giveMonitoringState = async (deviceId: string, clientId = LAB) => {
  await db.query(
    `UPDATE trips SET
       phase = 'monitoring', action = 'leave_later',
       depart_at = $3::timestamptz, arrive_at = $4::timestamptz,
       drive_minutes = 45, reason = 'Leave at 9:05 to arrive by 10.',
       confidence = 'High', confidence_reason = 'Plenty of data.',
       notes = $5::jsonb, margin_minutes = 10, source = $6::jsonb,
       evaluated_at = $7::timestamptz, eval_failures = 2,
       last_error_code = 'routing_unavailable',
       last_error_at = $7::timestamptz, anchor_at = $3::timestamptz,
       monitoring_started_at = $7::timestamptz, heads_up_state = 'sent',
       heads_up_sent_at = $7::timestamptz,
       notified_depart_at = $3::timestamptz,
       candidate_depart_at = $3::timestamptz, notified_degraded = false,
       last_update_at = $7::timestamptz, update_count = 1,
       next_check_at = $8::timestamptz, lease_token = $9::uuid,
       lease_until = $8::timestamptz
     WHERE device_id = $1::uuid AND client_id = $2`,
    [
      deviceId,
      clientId,
      DEPART_AT.toISOString(),
      minutes(170).toISOString(),
      JSON.stringify(['Light rain expected.']),
      JSON.stringify({ baseline: 'tomtom', fallback: false, live: true }),
      NOW.toISOString(),
      minutes(15).toISOString(),
      LEASE,
    ],
  );
};

interface AlertOver {
  kind?: string;
  status?: string;
  contentVersion?: number;
  createdAt?: Date;
  sentAt?: Date | null;
  lastError?: string | null;
  /** The departure the alert names. */
  departAt?: Date;
}

/** Puts an alert in the outbox the way the monitor would. */
const queueAlert = async (row: TripRow, over: AlertOver = {}) => {
  const kind = over.kind ?? 'heads_up';
  const createdAt = over.createdAt ?? NOW;
  await db.query(
    `INSERT INTO trip_notifications
            (id, trip_id, device_id, content_version, kind, dedupe_key, title,
             body, payload, status, next_attempt_at, expires_at, created_at,
             sent_at, last_error)
     VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, 'Heads up', 'Body',
             $7::jsonb, $8, $9::timestamptz, $10::timestamptz,
             $9::timestamptz, $11::timestamptz, $12)`,
    [
      randomUUID(),
      row.id,
      row.deviceId,
      over.contentVersion ?? row.contentVersion,
      kind,
      `${kind}:${createdAt.getTime()}`,
      JSON.stringify({
        tripId: row.clientId,
        kind,
        ...(over.departAt ? { departAt: over.departAt.toISOString() } : {}),
      }),
      over.status ?? 'pending',
      createdAt.toISOString(),
      hours(4).toISOString(),
      over.sentAt ? over.sentAt.toISOString() : null,
      over.lastError ?? null,
    ],
  );
};

/** How many rows a device has, whatever their status. */
const tripCount = async (deviceId: string): Promise<number> => {
  const { rows } = await db.query<{ n: string }>(
    'SELECT count(*)::text AS n FROM trips WHERE device_id = $1::uuid',
    [deviceId],
  );
  return Number(rows[0].n);
};

const alertCount = async (tripId: string): Promise<number> => {
  const { rows } = await db.query<{ n: string }>(
    `SELECT count(*)::text AS n FROM trip_notifications
      WHERE trip_id = $1::uuid`,
    [tripId],
  );
  return Number(rows[0].n);
};

describe('the trip schema', () => {
  it('is not ready before its migration has run', async () => {
    const empty = await createPgliteDatabase();
    try {
      assert.equal(await isMonitoringSchemaReady(empty), false);
    } finally {
      await empty.close();
    }
  });

  it('is ready once its migration has run', async () => {
    assert.equal(await isMonitoringSchemaReady(db), true);
  });

  it('is not ready when the migration is recorded but the table is gone', async () => {
    const broken = await createPgliteDatabase();
    try {
      await runMigrations(broken);
      await broken.exec('DROP TABLE trip_notifications; DROP TABLE trips;');
      assert.equal(await isMonitoringSchemaReady(broken), false);
    } finally {
      await broken.close();
    }
  });

  it('does not take a database that could not be asked for one without the tables', async () => {
    class ConnectionLost extends Error {}
    const unreachable = {
      ...db,
      query: async () => {
        throw new ConnectionLost('Connection terminated unexpectedly');
      },
    };
    // The tables are there; nobody could say so. That is not "not ready".
    await assert.rejects(isMonitoringSchemaReady(unreachable), ConnectionLost);

    // Nor is any refusal other than "no such table".
    const refused = {
      ...db,
      query: async () => {
        throw Object.assign(new Error('too many clients'), { code: '53300' });
      },
    };
    await assert.rejects(isMonitoringSchemaReady(refused), /too many clients/);
  });

  it('starts the monitor heartbeat as one empty row', async () => {
    const { rows } = await db.query(
      'SELECT id, last_tick_at, budget_used FROM monitor_state',
    );
    assert.deepEqual(rows, [{ id: 1, last_tick_at: null, budget_used: 0 }]);
    await assert.rejects(db.exec('INSERT INTO monitor_state (id) VALUES (2)'));
  });
});

describe('devices', () => {
  it('stores a device by the hash of its secret', async () => {
    const credential = issueCredential();
    await createDevice(db, {
      id: credential.deviceId,
      secretHash: credential.secretHash,
      platform: 'ios',
      now: NOW,
    });
    const device = await findDevice(db, credential.deviceId);
    assert.deepEqual(device, {
      id: credential.deviceId,
      secretHash: credential.secretHash,
      platform: 'ios',
      syncRevision: 0,
      syncDigest: null,
      apnsToken: null,
      apnsEnvironment: null,
      notificationsAuthorized: null,
      pushFailureReason: null,
      pushFailureAt: null,
      createdAt: NOW,
      lastSeenAt: NOW,
    });
    const everything = JSON.stringify(
      (await db.query('SELECT * FROM devices')).rows,
    );
    assert.ok(!everything.includes(credential.secret));
  });

  it('finds nothing for an id no device has', async () => {
    assert.equal(await findDevice(db, randomUUID()), undefined);
  });

  it('counts the devices registered since a time', async () => {
    await newDevice(minutes(-90));
    await newDevice(minutes(-30));
    await newDevice(NOW);
    assert.equal(await countDevicesCreatedSince(db, hours(-1)), 2);
    assert.equal(await countDevicesCreatedSince(db, hours(-2)), 3);
  });

  it('notes when a device was last heard from', async () => {
    const id = await newDevice();
    await touchDevice(db, id, minutes(5));
    assert.deepEqual((await findDevice(db, id))?.lastSeenAt, minutes(5));
  });

  it('deletes a device with its trips and queued alerts', async () => {
    const id = await newDevice();
    const other = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, other, 1, [trip()], NOW);
    await queueAlert(await stored(id));

    assert.equal(await deleteDevice(db, id), true);
    assert.equal(await findDevice(db, id), undefined);
    const left = await db.query<{ device_id: string }>(
      'SELECT device_id FROM trips',
    );
    assert.deepEqual(left.rows, [{ device_id: other }]);
    const alerts = await db.query('SELECT id FROM trip_notifications');
    assert.deepEqual(alerts.rows, []);
    assert.equal(await deleteDevice(db, id), false);
  });
});

describe('a snapshot of new trips', () => {
  it('starts a trip inside the planning horizon due for its first plan', async () => {
    const id = await newDevice();
    const result = await applySnapshot(db, id, 1, [trip()], NOW);
    assert.deepEqual(result, {
      applied: true,
      revision: 1,
      digest: snapshotDigest([trip()]),
    });
    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.phase, 'planning');
    assert.deepEqual(row.nextCheckAt, NOW);
    assert.equal(row.contentVersion, 1);
    assert.equal(row.headsUpState, 'pending');
    assert.equal(row.endedAt, null);
    assert.deepEqual(row.createdAt, NOW);
  });

  it('stores what the device sent', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    const row = await stored(id);
    assert.equal(row.clientId, LAB);
    assert.equal(row.deviceId, id);
    assert.equal(row.title, 'Chem lab');
    assert.deepEqual(row.origin, { lat: 38.2383, lng: -122.0402 });
    assert.deepEqual(row.destination, { lat: 38.5593, lng: -121.4237 });
    assert.equal(row.destinationName, 'Sac State');
    assert.deepEqual(row.arriveBy, hours(3));
    assert.deepEqual(row.startsAt, minutes(190));
    assert.equal(row.timeZone, 'America/Los_Angeles');
    assert.equal(row.action, null);
    assert.equal(row.departAt, null);
    assert.equal(row.notes, null);
    assert.equal(row.source, null);
  });

  it('keeps awkward text and millisecond times intact', async () => {
    const id = await newDevice();
    const awkward = trip({
      title: 'He said "hi", {ok} \\ back — café ☕ 東京',
      destinationName: null,
      startsAt: null,
      arriveBy: new Date('2026-11-20T18:00:00.123Z'),
    });
    await applySnapshot(db, id, 1, [awkward], NOW);
    const row = await stored(id);
    assert.equal(row.title, awkward.title);
    assert.equal(row.destinationName, null);
    assert.equal(row.startsAt, null);
    assert.deepEqual(row.arriveBy, awkward.arriveBy);
  });

  it('makes a trip beyond the horizon wait until it enters it', async () => {
    const id = await newDevice();
    const far = trip({ arriveBy: minutes(PLANNING_HORIZON_MINUTES + 1) });
    const edge = trip({ id: GYM, arriveBy: minutes(PLANNING_HORIZON_MINUTES) });
    await applySnapshot(db, id, 1, [far, edge], NOW);

    const waiting = await stored(id, LAB);
    assert.equal(waiting.phase, 'scheduled');
    assert.deepEqual(waiting.nextCheckAt, minutes(1));
    const due = await stored(id, GYM);
    assert.equal(due.phase, 'planning');
    assert.deepEqual(due.nextCheckAt, NOW);
  });

  it('stores a trip whose arrival time has passed as ended', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip({ arriveBy: minutes(-10) })], NOW);
    const row = await stored(id);
    assert.equal(row.status, 'ended');
    assert.equal(row.nextCheckAt, null);
    assert.deepEqual(row.endedAt, minutes(-10));
  });

  it('lists a device’s trips by arrival time, and only its own', async () => {
    const id = await newDevice();
    const other = await newDevice();
    await applySnapshot(
      db,
      id,
      1,
      [trip({ arriveBy: hours(5) }), trip({ id: GYM, arriveBy: hours(2) })],
      NOW,
    );
    await applySnapshot(db, other, 1, [trip({ id: 'theirs' })], NOW);
    assert.deepEqual(
      (await getTrips(db, id)).map(row => row.clientId),
      [GYM, LAB],
    );
    assert.equal((await getTrip(db, id, GYM))?.clientId, GYM);
    assert.equal(await getTrip(db, id, 'theirs'), undefined);
  });
});

describe('snapshot revisions', () => {
  it('records the revision and the digest on the device', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 4, [trip()], NOW);
    const device = await findDevice(db, id);
    assert.equal(device?.syncRevision, 4);
    assert.equal(device?.syncDigest, snapshotDigest([trip()]));
  });

  it('changes nothing for a retry of the revision it holds', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);

    const retry = await applySnapshot(db, id, 1, [trip()], minutes(1));
    assert.deepEqual(retry, {
      applied: false,
      revision: 1,
      digest: snapshotDigest([trip()]),
    });
    assert.deepEqual(await stored(id), original);
  });

  it('refuses a different snapshot under the revision it holds', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 3, [trip()], NOW);
    await assert.rejects(
      applySnapshot(db, id, 3, [], minutes(1)),
      (error: unknown) =>
        error instanceof RevisionConflictError && error.revision === 3,
    );
    assert.equal((await stored(id)).status, 'active');
    assert.equal((await findDevice(db, id))?.syncRevision, 3);
  });

  it('treats a device that never synced as holding the empty snapshot', async () => {
    const id = await newDevice();
    assert.deepEqual(await applySnapshot(db, id, 1, [], NOW), {
      applied: true,
      revision: 1,
      digest: EMPTY_SNAPSHOT_DIGEST,
    });
  });

  it('does not let an older revision restore a cancelled trip', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    // With alerts on record, so its row is kept when it is cancelled.
    await giveMonitoringState(id);
    await applySnapshot(db, id, 2, [], minutes(1));

    // The first request again, arriving late.
    const late = await applySnapshot(db, id, 1, [trip()], minutes(2));
    assert.deepEqual(late, {
      applied: false,
      revision: 2,
      digest: EMPTY_SNAPSHOT_DIGEST,
    });
    assert.equal((await stored(id)).status, 'cancelled');
    assert.deepEqual(await getTrips(db, id), []);
  });

  it('does not let an older revision undo a reschedule', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, id, 2, [trip({ arriveBy: hours(4) })], NOW);
    await applySnapshot(db, id, 1, [trip()], minutes(1));
    assert.deepEqual((await stored(id)).arriveBy, hours(4));
  });

  it('has nothing to apply for a device that is gone', async () => {
    await assert.rejects(
      applySnapshot(db, randomUUID(), 1, [trip()], NOW),
      UnauthorizedError,
    );
  });
});

describe('a snapshot of trips already stored', () => {
  it('keeps the plan and the alerts when only the labels change', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);
    await queueAlert(original);

    const renamed = trip({
      title: 'Chemistry lab',
      destinationName: 'Sequoia Hall',
      startsAt: minutes(195),
    });
    await applySnapshot(db, id, 2, [renamed], minutes(1));

    assert.deepEqual(await stored(id), {
      ...original,
      title: 'Chemistry lab',
      destinationName: 'Sequoia Hall',
      startsAt: minutes(195),
      updatedAt: minutes(1),
    });
    assert.equal(await alertCount(original.id), 1);
  });

  it('writes nothing for a trip that is listed again unchanged', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);
    await applySnapshot(db, id, 2, [trip(), trip({ id: GYM })], minutes(1));
    assert.deepEqual(await stored(id), original);
  });

  it('starts a trip over when its arrival time changes', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);

    const moved = trip({ arriveBy: hours(4), title: 'Chem lab (moved)' });
    await applySnapshot(db, id, 2, [moved], minutes(1));

    const row = await stored(id);
    assert.equal(row.id, original.id);
    assert.equal(row.contentVersion, 2);
    assert.equal(row.status, 'active');
    assert.equal(row.phase, 'planning');
    assert.deepEqual(row.arriveBy, hours(4));
    assert.equal(row.title, 'Chem lab (moved)');
    assert.deepEqual(row.nextCheckAt, minutes(1));
    for (const key of [
      'action',
      'departAt',
      'arriveAt',
      'driveMinutes',
      'reason',
      'confidence',
      'confidenceReason',
      'notes',
      'lateByMinutes',
      'marginMinutes',
      'source',
      'evaluatedAt',
      'noPlanReason',
      'lastErrorCode',
      'lastErrorAt',
      'anchorAt',
      'monitoringStartedAt',
      'headsUpSentAt',
      'notifiedDepartAt',
      'candidateDepartAt',
      'notifiedDegraded',
      'lastUpdateAt',
      'leaveSentAt',
      'lateSentAt',
      'departedAt',
      'leaseToken',
      'leaseUntil',
      'endedAt',
    ] as const) {
      assert.equal(row[key], null, `${key} should be cleared`);
    }
    assert.equal(row.headsUpState, 'pending');
    assert.equal(row.updateCount, 0);
    assert.equal(row.evalFailures, 0);
  });

  const materialChanges: Array<[string, Partial<SnapshotTrip>]> = [
    ['origin', { origin: { lat: 38.2384, lng: -122.0402 } }],
    ['destination', { destination: { lat: 38.5593, lng: -121.4238 } }],
    ['time zone', { timeZone: 'America/New_York' }],
    ['arrival time', { arriveBy: minutes(181) }],
  ];
  for (const [name, change] of materialChanges) {
    it(`starts a trip over when its ${name} changes`, async () => {
      const id = await newDevice();
      await applySnapshot(db, id, 1, [trip()], NOW);
      await giveMonitoringState(id);
      await applySnapshot(db, id, 2, [trip(change)], minutes(1));
      const row = await stored(id);
      assert.equal(row.contentVersion, 2);
      assert.equal(row.headsUpState, 'pending');
      assert.equal(row.departAt, null);
    });
  }

  it('does not start over for a place that moved less than its 6th decimal', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const jitter = trip({
      origin: { lat: 38.2383001, lng: -122.0402004 },
      destination: { lat: 38.5593004, lng: -121.4237001 },
    });
    await applySnapshot(db, id, 2, [jitter], minutes(1));
    const row = await stored(id);
    assert.equal(row.contentVersion, 1);
    assert.equal(row.headsUpState, 'sent');
    assert.deepEqual(row.departAt, DEPART_AT);
  });

  it('cancels trips that are no longer listed', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip(), trip({ id: GYM })], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);
    await queueAlert(original, { status: 'sent', sentAt: NOW });
    await queueAlert(await stored(id, GYM));

    await applySnapshot(db, id, 2, [trip({ id: GYM })], minutes(5));

    const row = await stored(id);
    assert.equal(row.status, 'cancelled');
    assert.deepEqual(row.endedAt, minutes(5));
    assert.equal(row.nextCheckAt, null);
    assert.equal(row.leaseToken, null);
    assert.equal(row.leaseUntil, null);
    // The recommendation is erased at once, and nothing more is sent.
    assert.equal(row.action, null);
    assert.equal(row.departAt, null);
    assert.equal(row.reason, null);
    assert.equal(row.notes, null);
    assert.equal(row.source, null);
    assert.equal(row.evaluatedAt, null);
    assert.equal(row.lastErrorCode, null);
    assert.equal(await alertCount(original.id), 0);
    // What was already sent for it is remembered.
    assert.equal(row.contentVersion, 1);
    assert.equal(row.headsUpState, 'sent');
    assert.deepEqual(row.notifiedDepartAt, DEPART_AT);
    assert.equal(row.updateCount, 1);

    assert.deepEqual(
      (await getTrips(db, id)).map(r => r.clientId),
      [GYM],
    );
    assert.equal(await getTrip(db, id, LAB), undefined);
    assert.equal(await alertCount((await stored(id, GYM)).id), 1);
  });

  it('monitors a cancelled trip again without forgetting its alerts', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await applySnapshot(db, id, 2, [], minutes(5));
    await applySnapshot(db, id, 3, [trip()], minutes(10));

    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.endedAt, null);
    assert.deepEqual(row.nextCheckAt, minutes(10));
    assert.equal(row.leaseToken, null);
    // The same version of the trip, with its alerts on record, so it gets no
    // second heads-up.
    assert.equal(row.contentVersion, 1);
    assert.equal(row.headsUpState, 'sent');
    assert.deepEqual(row.headsUpSentAt, NOW);
    assert.deepEqual(row.notifiedDepartAt, DEPART_AT);
    assert.deepEqual(row.candidateDepartAt, DEPART_AT);
    assert.deepEqual(row.anchorAt, DEPART_AT);
    assert.equal(row.updateCount, 1);
    // The plan itself was erased and is worked out again.
    assert.equal(row.departAt, null);
  });

  it('starts a cancelled trip over when it comes back changed', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await applySnapshot(db, id, 2, [], minutes(5));
    await applySnapshot(db, id, 3, [trip({ arriveBy: hours(5) })], minutes(10));

    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.contentVersion, 2);
    assert.equal(row.headsUpState, 'pending');
    assert.equal(row.anchorAt, null);
    assert.equal(row.endedAt, null);
  });

  it('ends an active trip whose arrival time has passed', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);
    await queueAlert(original);

    await applySnapshot(db, id, 2, [trip()], hours(4));

    const row = await stored(id);
    assert.equal(row.status, 'ended');
    // It ended when it was due to arrive, not when the server noticed.
    assert.deepEqual(row.endedAt, hours(3));
    assert.equal(row.departAt, null);
    assert.equal(row.nextCheckAt, null);
    assert.equal(await alertCount(original.id), 0);
  });

  it('never monitors an ended trip again unless its arrival moves ahead', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, id, 2, [trip()], hours(4));
    assert.equal((await stored(id)).status, 'ended');

    // Dropped and listed again, still with the arrival time that passed.
    await applySnapshot(db, id, 3, [], hours(4));
    await applySnapshot(db, id, 4, [trip()], hours(4));
    assert.equal((await stored(id)).status, 'ended');

    // Moved, but to a time that has also passed.
    await applySnapshot(db, id, 5, [trip({ arriveBy: hours(3.5) })], hours(4));
    assert.equal((await stored(id)).status, 'ended');

    await applySnapshot(db, id, 6, [trip({ arriveBy: hours(6) })], hours(4));
    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.contentVersion, 3);
    assert.equal(row.endedAt, null);
    assert.deepEqual(row.nextCheckAt, hours(4));
  });

  it('leaves the trips of other devices alone', async () => {
    const id = await newDevice();
    const other = await newDevice();
    await applySnapshot(db, other, 1, [trip()], NOW);
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, id, 2, [], minutes(1));
    assert.equal((await stored(other)).status, 'active');
    assert.equal(await tripCount(id), 0);
    assert.equal(await tripCount(other), 1);
  });
});

describe('what is kept of a cancelled trip', () => {
  /** A trip the monitor has planned, with nothing said about it yet. */
  const plannedOnly = async (deviceId: string) => {
    await db.query(
      `UPDATE trips SET phase = 'monitoring', anchor_at = $2::timestamptz,
              monitoring_started_at = $3::timestamptz
        WHERE device_id = $1::uuid`,
      [deviceId, DEPART_AT.toISOString(), NOW.toISOString()],
    );
  };

  /** Sets what the monitor's ledger says of the trip's alerts. */
  const ledger = async (deviceId: string, columns: string) => {
    await db.query(`UPDATE trips SET ${columns} WHERE device_id = $1::uuid`, [
      deviceId,
    ]);
  };

  const cancelAndAddBack = async (deviceId: string) => {
    await applySnapshot(db, deviceId, 2, [], minutes(5));
    await applySnapshot(db, deviceId, 3, [trip()], minutes(10));
  };

  it('is nothing, when no alert was ever queued for it', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip(), trip({ id: GYM })], NOW);
    await plannedOnly(id);
    await applySnapshot(db, id, 2, [trip({ id: GYM })], minutes(5));
    assert.equal(await tripCount(id), 1);
    assert.equal((await stored(id, GYM)).status, 'active');

    // Added back, it is a new trip, which comes to the same thing.
    await applySnapshot(db, id, 3, [trip(), trip({ id: GYM })], minutes(10));
    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.contentVersion, 1);
    assert.equal(row.headsUpState, 'pending');
    assert.equal(row.anchorAt, null);
    assert.deepEqual(row.nextCheckAt, minutes(10));
  });

  it('does not let a device pile up rows by listing trips and dropping them', async () => {
    const id = await newDevice();
    for (let round = 0; round < 5; round++) {
      const fresh = Array.from({ length: 10 }, (_, i) =>
        trip({ id: `R${round}T${i}` }),
      );
      await applySnapshot(db, id, round + 1, fresh, minutes(round));
    }
    assert.equal(await tripCount(id), 10);
  });

  it('is the row, for as long as an alert is on record or the user had left', async () => {
    const cases: Array<[string, string]> = [
      ['a heads-up', "heads_up_state = 'sent'"],
      ['an update', 'update_count = 1'],
      ['a leave alert', 'leave_sent_at = now()'],
      ['a late alert', 'late_sent_at = now()'],
      ['"I have left"', 'departed_at = now()'],
    ];
    for (const [name, columns] of cases) {
      await db.exec('TRUNCATE devices CASCADE');
      const id = await newDevice();
      await applySnapshot(db, id, 1, [trip()], NOW);
      await ledger(id, columns);
      await applySnapshot(db, id, 2, [], minutes(5));
      assert.equal(await tripCount(id), 1, name);
      assert.equal((await stored(id)).status, 'cancelled', name);
    }
  });

  it('forgets a heads-up that was still waiting to go out, and with it the trip', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await ledger(id, 'update_count = 0');
    await queueAlert(await stored(id));

    await cancelAndAddBack(id);
    // Nothing reached the user, so nothing is remembered: a new trip, due
    // its heads-up like any other.
    const row = await stored(id);
    assert.equal(row.headsUpState, 'pending');
    assert.equal(row.headsUpSentAt, null);
    assert.equal(row.notifiedDepartAt, null);
    assert.equal(row.lastUpdateAt, null);
    assert.equal(await alertCount(row.id), 0);
  });

  it('remembers a heads-up APNs accepted', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await queueAlert(await stored(id), { status: 'sent', sentAt: NOW });
    await cancelAndAddBack(id);
    const row = await stored(id);
    assert.equal(row.headsUpState, 'sent');
    assert.deepEqual(row.headsUpSentAt, NOW);
    assert.deepEqual(row.notifiedDepartAt, DEPART_AT);
  });

  it('remembers a heads-up that was given up on, as it would be for a trip never cancelled', async () => {
    for (const status of ['failed', 'dropped']) {
      await db.exec('TRUNCATE devices CASCADE');
      const id = await newDevice();
      await applySnapshot(db, id, 1, [trip()], NOW);
      await giveMonitoringState(id);
      await queueAlert(await stored(id), { status });
      await cancelAndAddBack(id);
      assert.equal((await stored(id)).headsUpState, 'sent', status);
    }
  });

  it('does not count a heads-up that is being sent right now as not sent', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await queueAlert(await stored(id), { status: 'sending' });
    await cancelAndAddBack(id);
    // It may have gone out; a second heads-up is worse than none.
    assert.equal((await stored(id)).headsUpState, 'sent');
  });

  it('forgets a leave alert or a late alert that never went out, waiting or being sent', async () => {
    for (const [kind, column] of [
      ['leave_now', 'leaveSentAt'],
      ['late', 'lateSentAt'],
    ] as const) {
      for (const status of ['pending', 'sending']) {
        await db.exec('TRUNCATE devices CASCADE');
        const id = await newDevice();
        await applySnapshot(db, id, 1, [trip()], NOW);
        await giveMonitoringState(id);
        await ledger(id, 'leave_sent_at = now(), late_sent_at = now()');
        const row = await stored(id);
        await queueAlert(row, {
          status: 'sent',
          sentAt: NOW,
          createdAt: minutes(-30),
        });
        await queueAlert(row, { kind, status });

        await cancelAndAddBack(id);
        const back = await stored(id);
        // Missing it is worse than hearing it twice: it is due again.
        assert.equal(back[column], null, `${kind} ${status}`);
        // The other, and the heads-up that did go out, stay on record.
        const other = column === 'leaveSentAt' ? 'lateSentAt' : 'leaveSentAt';
        assert.notEqual(back[other], null, `${kind} ${status}`);
        assert.equal(back.headsUpState, 'sent');
      }
    }
  });

  it('forgets an update that never went out, and goes back to what the user was last told', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    // The heads-up for 9:05 was accepted at 15:00. At 15:30 an update to
    // 8:50 was queued, and is still waiting.
    await giveMonitoringState(id);
    const earlier = minutes(110);
    await db.query(
      `UPDATE trips SET notified_depart_at = $2::timestamptz,
              last_update_at = $3::timestamptz, candidate_depart_at = NULL
        WHERE device_id = $1::uuid`,
      [id, earlier.toISOString(), minutes(30).toISOString()],
    );
    const row = await stored(id);
    await queueAlert(row, {
      status: 'sent',
      sentAt: NOW,
      departAt: DEPART_AT,
    });
    await queueAlert(row, {
      kind: 'update',
      createdAt: minutes(30),
      departAt: earlier,
    });

    await cancelAndAddBack(id);
    const back = await stored(id);
    assert.equal(back.updateCount, 0);
    assert.equal(back.headsUpState, 'sent');
    // So that the next check finds the departure moved, and says so again.
    assert.deepEqual(back.notifiedDepartAt, DEPART_AT);
    assert.deepEqual(back.lastUpdateAt, NOW);
  });

  it('leaves the record alone for alerts of an earlier version of the trip', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const row = await stored(id);
    await queueAlert(row, { status: 'sent', sentAt: NOW });
    await queueAlert(row, { kind: 'leave_now', contentVersion: 0 });
    await ledger(id, 'leave_sent_at = now()');
    await applySnapshot(db, id, 2, [], minutes(5));
    assert.notEqual((await stored(id)).leaveSentAt, null);
  });

  it('settles the record the same way when another device takes the token', async () => {
    const first = await newDevice();
    const second = await newDevice();
    await updatePush(
      db,
      first,
      { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
      NOW,
    );
    await applySnapshot(
      db,
      first,
      1,
      [trip(), trip({ id: GYM, arriveBy: hours(4) })],
      NOW,
    );
    // One trip has had its heads-up; nothing was said about the other.
    await db.query(
      `UPDATE trips SET heads_up_state = 'sent' WHERE client_id = $1`,
      [LAB],
    );
    await updatePush(
      db,
      second,
      { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
      minutes(1),
    );
    assert.equal((await stored(first)).status, 'cancelled');
    assert.equal(await tripCount(first), 1);
  });
});

describe('"I have left"', () => {
  it('ends the monitoring of the trip', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);
    await queueAlert(original);

    const result = await markDeparted(db, id, LAB, hours(3), minutes(30));
    assert.equal(result.outcome, 'ok');
    const row = await stored(id);
    assert.deepEqual(result, { outcome: 'ok', trip: row });
    assert.equal(row.status, 'departed');
    assert.deepEqual(row.departedAt, minutes(30));
    assert.deepEqual(row.endedAt, minutes(30));
    assert.equal(row.nextCheckAt, null);
    assert.equal(row.leaseToken, null);
    assert.equal(row.departAt, null);
    assert.equal(row.reason, null);
    assert.equal(await alertCount(original.id), 0);
  });

  it('changes nothing when said twice', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await markDeparted(db, id, LAB, hours(3), minutes(30));
    const again = await markDeparted(db, id, LAB, hours(3), minutes(45));
    assert.equal(again.outcome, 'ok');
    assert.deepEqual((await stored(id)).departedAt, minutes(30));
    assert.deepEqual((await stored(id)).endedAt, minutes(30));
  });

  it('is refused for an arrival time the trip no longer has', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, id, 2, [trip({ arriveBy: hours(4) })], NOW);
    await giveMonitoringState(id);
    const original = await stored(id);

    // The action of a notification sent before the trip was moved.
    const result = await markDeparted(db, id, LAB, hours(3), minutes(30));
    assert.deepEqual(result, { outcome: 'superseded' });
    assert.deepEqual(await stored(id), original);
  });

  it('finds no trip that is unknown, cancelled or somebody else’s', async () => {
    const id = await newDevice();
    const other = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, other, 1, [trip(), trip({ id: GYM })], NOW);
    await applySnapshot(db, other, 2, [trip()], NOW);

    assert.deepEqual(await markDeparted(db, id, 'nope', hours(3), NOW), {
      outcome: 'not_found',
    });
    assert.deepEqual(await markDeparted(db, id, GYM, hours(3), NOW), {
      outcome: 'not_found',
    });
    assert.deepEqual(await markDeparted(db, other, GYM, hours(3), NOW), {
      outcome: 'not_found',
    });
    assert.equal((await stored(other)).status, 'active');
  });

  it('leaves a trip that already ended as it is', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip({ arriveBy: minutes(-5) })], NOW);
    const result = await markDeparted(db, id, LAB, minutes(-5), NOW);
    assert.equal(result.outcome, 'ok');
    assert.equal((await stored(id)).status, 'ended');
  });

  it('stays said while the trip is listed unchanged', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await markDeparted(db, id, LAB, hours(3), minutes(30));
    await applySnapshot(db, id, 2, [trip({ title: 'Lab' })], minutes(40));
    const row = await stored(id);
    assert.equal(row.status, 'departed');
    assert.equal(row.title, 'Lab');
    assert.equal(row.nextCheckAt, null);
  });

  it('stays said when the trip is dropped and listed again', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await markDeparted(db, id, LAB, hours(3), minutes(30));

    await applySnapshot(db, id, 2, [], minutes(40));
    assert.equal((await stored(id)).status, 'cancelled');
    assert.deepEqual(await getTrips(db, id), []);

    await applySnapshot(db, id, 3, [trip()], minutes(50));
    const row = await stored(id);
    assert.equal(row.status, 'departed');
    assert.equal(row.nextCheckAt, null);
    assert.deepEqual(row.endedAt, minutes(30));
  });

  it('is forgotten once the trip materially changes', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await markDeparted(db, id, LAB, hours(3), minutes(30));
    await applySnapshot(db, id, 2, [trip({ arriveBy: hours(5) })], minutes(40));
    const row = await stored(id);
    assert.equal(row.status, 'active');
    assert.equal(row.departedAt, null);
    assert.equal(row.endedAt, null);
    assert.equal(row.contentVersion, 2);
    assert.deepEqual(row.nextCheckAt, minutes(40));
  });
});

describe('where alerts go', () => {
  it('stores the token, the environment and the permission', async () => {
    const id = await newDevice();
    const device = await updatePush(
      db,
      id,
      { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
      NOW,
    );
    assert.equal(device?.apnsToken, TOKEN);
    assert.equal(device?.apnsEnvironment, 'sandbox');
    assert.equal(device?.notificationsAuthorized, true);
    assert.deepEqual(await findDevice(db, id), device);
  });

  it('clears the token and records a refusal', async () => {
    const id = await newDevice();
    await updatePush(
      db,
      id,
      { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
      NOW,
    );
    const device = await updatePush(
      db,
      id,
      { apnsToken: null, environment: 'production', authorized: false },
      NOW,
    );
    assert.equal(device?.apnsToken, null);
    assert.equal(device?.apnsEnvironment, 'production');
    assert.equal(device?.notificationsAuthorized, false);
  });

  it('lets a device report the token it already has', async () => {
    const id = await newDevice();
    const push = {
      apnsToken: TOKEN,
      environment: 'sandbox',
      authorized: true,
    } as const;
    await updatePush(db, id, push, NOW);
    await applySnapshot(db, id, 1, [trip()], NOW);
    const device = await updatePush(db, id, push, NOW);
    assert.equal(device?.apnsToken, TOKEN);
    assert.equal((await stored(id)).status, 'active');
    assert.equal(device?.syncDigest, snapshotDigest([trip()]));
  });

  it('has nothing to update for a device that is gone', async () => {
    assert.equal(
      await updatePush(
        db,
        randomUUID(),
        { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
        NOW,
      ),
      undefined,
    );
  });

  it('silences the first device when a second registers the same token', async () => {
    const first = await newDevice();
    const second = await newDevice();
    const bystander = await newDevice();
    const push = {
      apnsToken: TOKEN,
      environment: 'production',
      authorized: true,
    } as const;
    await updatePush(db, first, push, NOW);
    await updatePush(
      db,
      bystander,
      { ...push, apnsToken: 'cd'.repeat(32) },
      NOW,
    );
    await applySnapshot(db, first, 1, [trip(), trip({ id: GYM })], NOW);
    await applySnapshot(db, bystander, 1, [trip()], NOW);
    await giveMonitoringState(first);
    await queueAlert(await stored(first));
    await markDeparted(db, first, GYM, hours(3), NOW);

    await updatePush(db, second, push, minutes(10));

    assert.equal((await findDevice(db, second))?.apnsToken, TOKEN);
    const silenced = await findDevice(db, first);
    assert.equal(silenced?.apnsToken, null);
    const lab = await stored(first);
    assert.equal(lab.status, 'cancelled');
    assert.deepEqual(lab.endedAt, minutes(10));
    assert.equal(lab.departAt, null);
    assert.equal(await alertCount(lab.id), 0);
    // Only active trips are cancelled.
    assert.equal((await stored(first, GYM)).status, 'departed');
    // Nobody else is touched.
    assert.equal((await findDevice(db, bystander))?.apnsToken, 'cd'.repeat(32));
    assert.equal((await stored(bystander)).status, 'active');

    // The first device's stored snapshot no longer holds, so sending it
    // again under the same revision is refused and a new revision applies.
    await assert.rejects(
      applySnapshot(db, first, 1, [trip(), trip({ id: GYM })], minutes(11)),
      RevisionConflictError,
    );
    await applySnapshot(db, first, 2, [trip(), trip({ id: GYM })], minutes(11));
    assert.equal((await stored(first)).status, 'active');
  });
});

describe('what the outbox says about a trip', () => {
  it('says nothing for a trip with no alerts', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    assert.equal((await getTripAlerts(db, id)).size, 0);
  });

  it('counts an alert as sent only once APNs accepted it', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip(), trip({ id: GYM })], NOW);
    const lab = await stored(id);
    const gym = await stored(id, GYM);
    await queueAlert(lab, { status: 'pending' });
    await queueAlert(gym, { status: 'sent', sentAt: minutes(1) });
    await queueAlert(gym, {
      kind: 'leave_now',
      status: 'sending',
      createdAt: minutes(90),
    });

    const alerts = await getTripAlerts(db, id);
    assert.deepEqual(alerts.get(lab.id), {
      headsUpSentAt: null,
      leaveAlertSentAt: null,
      lastAlert: { kind: 'heads_up', status: 'queued', at: NOW },
    });
    assert.deepEqual(alerts.get(gym.id), {
      headsUpSentAt: minutes(1),
      leaveAlertSentAt: null,
      lastAlert: { kind: 'leave_now', status: 'queued', at: minutes(90) },
    });
  });

  it('reports the newest alert and why it was not sent', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    const lab = await stored(id);
    await queueAlert(lab, { status: 'sent', sentAt: minutes(1) });
    await queueAlert(lab, {
      kind: 'update',
      status: 'dropped',
      lastError: 'expired',
      createdAt: minutes(30),
    });
    await queueAlert(lab, {
      kind: 'leave_now',
      status: 'sent',
      createdAt: minutes(60),
      sentAt: minutes(61),
    });
    await queueAlert(lab, {
      kind: 'late',
      status: 'failed',
      lastError: 'BadDeviceToken',
      createdAt: minutes(70),
    });

    assert.deepEqual((await getTripAlerts(db, id)).get(lab.id), {
      headsUpSentAt: minutes(1),
      leaveAlertSentAt: minutes(61),
      lastAlert: {
        kind: 'late',
        status: 'failed',
        at: minutes(70),
        reason: 'BadDeviceToken',
      },
    });
  });

  it('ignores alerts for an earlier version of the trip', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await queueAlert(await stored(id), { status: 'sent', sentAt: minutes(1) });
    await applySnapshot(db, id, 2, [trip({ arriveBy: hours(5) })], minutes(5));
    assert.equal((await getTripAlerts(db, id)).size, 0);
  });

  it('keeps each device’s alerts to itself', async () => {
    const id = await newDevice();
    const other = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await applySnapshot(db, other, 1, [trip()], NOW);
    await queueAlert(await stored(other), { status: 'sent', sentAt: NOW });
    assert.equal((await getTripAlerts(db, id)).size, 0);
    assert.equal((await getTripAlerts(db, other)).size, 1);
  });
});

describe('retention', () => {
  it('ends active trips whose arrival time has passed', async () => {
    const id = await newDevice();
    await applySnapshot(
      db,
      id,
      1,
      [trip(), trip({ id: GYM, arriveBy: hours(9) })],
      NOW,
    );
    await giveMonitoringState(id);
    const lab = await stored(id);
    await queueAlert(lab);

    const report = await purgeExpired(db, hours(5), 24);
    assert.deepEqual(report, { trips: 0, devices: 0 });
    const row = await stored(id);
    assert.equal(row.status, 'ended');
    assert.deepEqual(row.endedAt, hours(3));
    assert.equal(row.departAt, null);
    assert.equal(await alertCount(lab.id), 0);
    assert.equal((await stored(id, GYM)).status, 'active');
  });

  it('deletes a trip once it has been over for the retention time', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip(), trip({ id: GYM })], NOW);
    // An alert on record for the gym trip, so its row outlives its cancelling.
    await giveMonitoringState(id, GYM);
    await applySnapshot(db, id, 2, [trip()], hours(1));

    // The gym trip was cancelled an hour in; the lab ended at three hours.
    assert.deepEqual(await purgeExpired(db, minutes(24 * 60 + 59), 24), {
      trips: 0,
      devices: 0,
    });
    assert.deepEqual(await purgeExpired(db, minutes(25 * 60 + 1), 24), {
      trips: 1,
      devices: 0,
    });
    assert.equal((await stored(id)).status, 'ended');
    assert.deepEqual(await purgeExpired(db, minutes(27 * 60 + 1), 24), {
      trips: 1,
      devices: 0,
    });
    const left = await db.query('SELECT id FROM trips');
    assert.deepEqual(left.rows, []);
  });

  it('keeps a trip the user left until its arrival time is that old too', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await markDeparted(db, id, LAB, hours(3), minutes(30));
    // Still listed by the device, so it must still be there to answer with.
    await purgeExpired(db, hours(26), 24);
    assert.equal((await stored(id)).status, 'departed');
    await purgeExpired(db, minutes(27 * 60 + 1), 24);
    assert.deepEqual((await db.query('SELECT id FROM trips')).rows, []);
  });

  it('deletes the alerts of the trips it deletes', async () => {
    const id = await newDevice();
    await applySnapshot(db, id, 1, [trip()], NOW);
    await giveMonitoringState(id);
    await applySnapshot(db, id, 2, [], NOW);
    const row = await stored(id);
    // Nothing queues an alert for a cancelled trip; make sure of the cascade.
    await queueAlert(row);
    await purgeExpired(db, hours(25), 24);
    assert.deepEqual(
      (await db.query('SELECT id FROM trip_notifications')).rows,
      [],
    );
  });

  it('forgets a device unseen for 30 days that has nothing to monitor', async () => {
    const idle = await newDevice();
    const busy = await newDevice();
    const recent = await newDevice();
    const days = (n: number) => hours(24 * n);
    await applySnapshot(db, idle, 1, [trip()], NOW);
    await giveMonitoringState(idle);
    await applySnapshot(db, idle, 2, [], NOW);
    await touchDevice(db, recent, days(2));
    // Arrival times this far ahead are not accepted over the API; here one
    // stands for "a device that still has something active".
    await applySnapshot(db, busy, 1, [trip({ arriveBy: days(40) })], NOW);

    assert.deepEqual(await purgeExpired(db, days(29), 24), {
      trips: 1,
      devices: 0,
    });
    assert.deepEqual(await purgeExpired(db, days(31), 24), {
      trips: 0,
      devices: 1,
    });
    assert.equal(await findDevice(db, idle), undefined);
    assert.ok(await findDevice(db, busy));
    assert.ok(await findDevice(db, recent));
  });
});
