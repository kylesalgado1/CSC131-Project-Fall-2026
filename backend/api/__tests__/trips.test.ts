// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify and PGlite, the in-memory Postgres these tests use, cannot load
// inside Jest.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';
import { buildServer, ServerDeps } from '../server';
import { Database } from '../../db/db';
import { runMigrations } from '../../db/migrate';
import { createPgliteDatabase } from '../../db/pglite';
import { FakeBaselineProvider } from '../../prediction/providers/fake';
import { NoLiveConditions } from '../../prediction/providers/live';
import { TripService, TripServiceDeps } from '../../trips/service';
import { Registration, TickReport } from '../../trips/types';

const NOW = new Date('2026-11-20T15:00:00.000Z');
const minutes = (n: number, from: Date = NOW) =>
  new Date(from.getTime() + n * 60_000);
const at = (n: number) => minutes(n).toISOString();

const LAB = 'A1B2C3@2026-11-20';
const GYM = 'D4E5F6@2026-11-20';
const TOKEN = 'ab'.repeat(32);
const TICK_SECRET = 'tick-secret-'.repeat(3);

const LIMITS = {
  planningHorizonMinutes: 690,
  monitorLeadMinutes: 120,
  headsUpLeadMinutes: 90,
  meaningfulShiftMinutes: 5,
  maxTrips: 50,
};
const NO_PUSH = { configured: false, registered: false, authorized: false };
const NO_MONITOR = { enabled: false, dependable: false, lastTickAt: null };
const UNAUTHORIZED = {
  error: 'unauthorized',
  message: 'This device is not registered.',
};
const NOT_FOUND = { error: 'not_found', message: 'No such trip.' };
const UNAVAILABLE = {
  error: 'monitoring_unavailable',
  message: 'Trip monitoring is not set up on this server.',
};
const TROUBLE = {
  error: 'temporarily_unavailable',
  message: 'The server is having trouble right now. Try again shortly.',
};
const MONITOR_ON = async () => ({
  enabled: true,
  dependable: false,
  lastTickAt: null,
});

const tripInput = (over: Record<string, unknown> = {}) => ({
  id: LAB,
  title: 'Chem lab',
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  destinationName: 'Sac State',
  arriveBy: at(180),
  startsAt: at(190),
  timeZone: 'America/Los_Angeles',
  ...over,
});

/** A trip nothing has been planned or sent for yet. */
const freshState = (over: Record<string, unknown> = {}) => ({
  id: LAB,
  arriveBy: at(180),
  phase: 'planning',
  recommendation: null,
  noPlanReason: null,
  planAvailableAt: null,
  monitoring: {
    startsAt: null,
    startedAt: null,
    headsUpAt: null,
    headsUpSentAt: null,
    leaveAlertSentAt: null,
    endsAt: at(180),
    nextCheckAt: NOW.toISOString(),
    lastAlert: null,
  },
  lastError: null,
  ...over,
});

let db: Database;
let clock: Date;
let logs: string[];

// One database for the whole file, emptied before each test: starting a
// fresh PGlite for every test would make this the slowest suite by far.
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
  clock = NOW;
  logs = [];
});

type Options = Partial<TripServiceDeps> &
  Pick<ServerDeps, 'tickSecret' | 'tick' | 'trustProxy' | 'tripSyncsPerHour'>;

const build = ({
  tickSecret,
  tick,
  trustProxy,
  tripSyncsPerHour,
  ...deps
}: Options = {}) =>
  buildServer({
    providers: {
      baseline: new FakeBaselineProvider(() => 35),
      live: new NoLiveConditions(),
    },
    now: () => clock,
    trips: new TripService({
      db,
      now: () => clock,
      log: line => logs.push(line),
      ...deps,
    }),
    tickSecret,
    tick,
    trustProxy,
    tripSyncsPerHour,
  });

type App = ReturnType<typeof build>;

class ConnectionLost extends Error {}

/**
 * The database with the queries a test picks made to fail, as when the
 * connection drops. `fails` is asked about every query, in or out of a
 * transaction, and its answer is what the query throws.
 */
const failing = (fails: (text: string) => Error | undefined): Database => {
  const guard = <Q extends Pick<Database, 'query' | 'exec'>>(inner: Q): Q => ({
    ...inner,
    query: async (text: string, params?: unknown[]) => {
      const failure = fails(text);
      if (failure) {
        throw failure;
      }
      return inner.query(text, params);
    },
  });
  return {
    ...guard(db),
    transaction: fn => db.transaction(tx => fn(guard(tx))),
  };
};

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

const register = async (app: App): Promise<Registration> => {
  const res = await app.inject({
    method: 'POST',
    url: '/devices',
    payload: { platform: 'ios' },
  });
  assert.equal(res.statusCode, 201);
  return res.json();
};

const sync = (app: App, token: string, revision: number, trips: unknown[]) =>
  app.inject({
    method: 'PUT',
    url: '/trips',
    headers: bearer(token),
    payload: { revision, trips },
  });

const list = (app: App, token: string) =>
  app.inject({ method: 'GET', url: '/trips', headers: bearer(token) });

const getTrip = (app: App, token: string, id: string = LAB) =>
  app.inject({
    method: 'GET',
    url: `/trips/${encodeURIComponent(id)}`,
    headers: bearer(token),
  });

const leave = (
  app: App,
  token: string,
  id: string = LAB,
  payload: object = { arriveBy: at(180) },
) =>
  app.inject({
    method: 'POST',
    url: `/trips/${encodeURIComponent(id)}/departed`,
    headers: bearer(token),
    payload,
  });

const setPush = (app: App, token: string, payload: object) =>
  app.inject({
    method: 'PUT',
    url: '/devices/me/push',
    headers: bearer(token),
    payload,
  });

const PUSH = { apnsToken: TOKEN, environment: 'sandbox', authorized: true };

const DEPART_AT = minutes(125);

/**
 * What the monitor would have stored once it has planned a trip and queued
 * its heads-up.
 */
const giveMonitoringState = async (deviceId: string, clientId = LAB) => {
  await db.query(
    `UPDATE trips SET
       phase = 'monitoring', action = 'leave_later',
       depart_at = $3::timestamptz, arrive_at = $4::timestamptz,
       drive_minutes = 45, reason = 'Leave at 9:05 to arrive by 10.',
       confidence = 'High', confidence_reason = 'Plenty of data.',
       notes = $5::jsonb, margin_minutes = 10, source = $6::jsonb,
       evaluated_at = $7::timestamptz, anchor_at = $3::timestamptz,
       monitoring_started_at = $7::timestamptz, heads_up_state = 'sent',
       heads_up_sent_at = $7::timestamptz,
       notified_depart_at = $3::timestamptz,
       last_update_at = $7::timestamptz,
       next_check_at = $8::timestamptz
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
    ],
  );
};

/** The trip as `giveMonitoringState` leaves it, as a client is told. */
const monitoredState = (over: Record<string, unknown> = {}) => ({
  id: LAB,
  arriveBy: at(180),
  phase: 'monitoring',
  recommendation: {
    action: 'leave_later',
    departAt: at(125),
    arriveAt: at(170),
    driveMinutes: 45,
    reason: 'Leave at 9:05 to arrive by 10.',
    confidence: 'High',
    confidenceReason: 'Plenty of data.',
    notes: ['Light rain expected.'],
    marginMinutes: 10,
    evaluatedAt: NOW.toISOString(),
    source: { baseline: 'tomtom', fallback: false, live: true },
    stale: false,
  },
  noPlanReason: null,
  planAvailableAt: null,
  monitoring: {
    startsAt: at(5),
    startedAt: NOW.toISOString(),
    headsUpAt: at(35),
    headsUpSentAt: null,
    leaveAlertSentAt: null,
    endsAt: at(180),
    nextCheckAt: at(15),
    lastAlert: null,
  },
  lastError: null,
  ...over,
});

/** Puts an alert in the outbox the way the monitor would. */
const queueAlert = async (
  deviceId: string,
  status: string,
  sentAt: Date | null = null,
  clientId = LAB,
) => {
  await db.query(
    `INSERT INTO trip_notifications
            (id, trip_id, device_id, content_version, kind, dedupe_key, title,
             body, payload, status, next_attempt_at, expires_at, created_at,
             sent_at)
     SELECT $1::uuid, t.id, t.device_id, t.content_version, 'heads_up',
            'heads_up', 'Heads up', 'Body', '{}'::jsonb, $4,
            $5::timestamptz, $6::timestamptz, $5::timestamptz,
            $7::timestamptz
       FROM trips t WHERE t.device_id = $2::uuid AND t.client_id = $3`,
    [
      randomUUID(),
      deviceId,
      clientId,
      status,
      NOW.toISOString(),
      at(125),
      sentAt ? sentAt.toISOString() : null,
    ],
  );
};

const count = async (table: string): Promise<number> => {
  const { rows } = await db.query<{ n: string }>(
    `SELECT count(*)::text AS n FROM ${table}`,
  );
  return Number(rows[0].n);
};

const column = async <T>(sql: string, params: unknown[] = []): Promise<T> => {
  const { rows } = await db.query<{ value: T }>(sql, params);
  return rows[0].value;
};

describe('POST /devices', () => {
  it('registers a device and shows its token once', async () => {
    const app = build();
    const res = await app.inject({
      method: 'POST',
      url: '/devices',
      payload: { platform: 'ios' },
    });
    assert.equal(res.statusCode, 201);
    const body = res.json();
    assert.deepEqual(Object.keys(body).sort(), ['deviceId', 'limits', 'token']);
    assert.match(
      body.deviceId,
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    assert.match(body.token, /^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/);
    assert.ok(body.token.startsWith(`${body.deviceId}.`));
    assert.deepEqual(body.limits, LIMITS);
  });

  it('stores only the hash of the secret', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    const secret = token.slice(37);
    const { rows } = await db.query('SELECT * FROM devices');
    assert.equal(rows.length, 1);
    assert.ok(!JSON.stringify(rows).includes(secret));
    assert.equal(
      await column('SELECT secret_hash AS value FROM devices WHERE id = $1', [
        deviceId,
      ]),
      createHash('sha256').update(secret).digest('hex'),
    );
  });

  const invalid: Array<[string, unknown]> = [
    ['no platform', {}],
    ['a platform it does not serve', { platform: 'android' }],
    ['a platform of null', { platform: null }],
  ];
  for (const [name, payload] of invalid) {
    it(`rejects ${name}`, async () => {
      const res = await build().inject({
        method: 'POST',
        url: '/devices',
        payload: payload as object,
      });
      assert.equal(res.statusCode, 400);
      assert.equal(res.json().error, 'bad_request');
      assert.equal(await count('devices'), 0);
    });
  }

  it('lets one address register 20 devices an hour', async () => {
    const app = build();
    const from = (remoteAddress: string) =>
      app.inject({
        method: 'POST',
        url: '/devices',
        payload: { platform: 'ios' },
        remoteAddress,
      });
    for (let i = 0; i < 20; i++) {
      assert.equal((await from('203.0.113.5')).statusCode, 201);
    }
    clock = minutes(10);
    const refused = await from('203.0.113.5');
    assert.equal(refused.statusCode, 429);
    assert.deepEqual(refused.json(), {
      error: 'rate_limited',
      message: 'Too many new devices from this network. Try again later.',
    });
    assert.equal(String(refused.headers['retry-after']), '3000');
    assert.equal(await count('devices'), 20);

    // Another address is not held back, and the hour passes.
    assert.equal((await from('203.0.113.6')).statusCode, 201);
    clock = minutes(60);
    assert.equal((await from('203.0.113.5')).statusCode, 201);
  });

  it('counts by the socket address unless told to trust a proxy', async () => {
    const app = build();
    const via = (forwardedFor: string) =>
      app.inject({
        method: 'POST',
        url: '/devices',
        payload: { platform: 'ios' },
        headers: { 'x-forwarded-for': forwardedFor },
      });
    for (let i = 0; i < 20; i++) {
      assert.equal((await via(`198.51.100.${i}`)).statusCode, 201);
    }
    // A header anyone can write does not buy a fresh allowance.
    assert.equal((await via('198.51.100.99')).statusCode, 429);
  });

  it('counts by the forwarded address behind a trusted proxy', async () => {
    const app = build({ trustProxy: 1 });
    const via = (forwardedFor: string) =>
      app.inject({
        method: 'POST',
        url: '/devices',
        payload: { platform: 'ios' },
        headers: { 'x-forwarded-for': forwardedFor },
      });
    for (let i = 0; i < 20; i++) {
      assert.equal((await via('198.51.100.7')).statusCode, 201);
    }
    assert.equal((await via('198.51.100.7')).statusCode, 429);
    assert.equal((await via('198.51.100.8')).statusCode, 201);
    // Only the nearest proxy is believed: what the client claims to its left
    // changes nothing.
    assert.equal((await via('10.9.9.9, 198.51.100.7')).statusCode, 429);
  });

  it('closes registration after 200 new devices in an hour', async () => {
    const app = build();
    await db.query(
      `INSERT INTO devices (id, secret_hash, platform, created_at)
       SELECT gen_random_uuid(), 'x', 'ios', $1::timestamptz
         FROM generate_series(1, 200)`,
      [at(-30)],
    );
    const res = await app.inject({
      method: 'POST',
      url: '/devices',
      payload: { platform: 'ios' },
    });
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.json(), {
      error: 'registrations_closed',
      message:
        'This server is not taking new devices right now. Try again later.',
    });
    assert.equal(await count('devices'), 200);

    // Once those are more than an hour old there is room again.
    clock = minutes(31);
    await register(app);
  });
});

describe('the device credential', () => {
  const guarded: Array<[string, string, object?]> = [
    ['PUT', '/devices/me/push', PUSH],
    ['DELETE', '/devices/me'],
    ['PUT', '/trips', { revision: 2, trips: [] }],
    ['GET', '/trips'],
    ['GET', `/trips/${LAB}`],
    ['POST', `/trips/${LAB}/departed`, { arriveBy: at(180) }],
  ];
  const rejected: Array<
    [string, (device: Registration) => string | undefined]
  > = [
    ['no credential', () => undefined],
    ['a malformed credential', () => 'Bearer nonsense'],
    ['the token without a scheme', device => device.token],
    [
      'an unknown device',
      device => `Bearer ${randomUUID()}.${device.token.slice(37)}`,
    ],
    ['a wrong secret', device => `Bearer ${device.deviceId}.${'A'.repeat(43)}`],
    [
      'an id the database could not even look up',
      device => `Bearer ${'-'.repeat(36)}.${device.token.slice(37)}`,
    ],
  ];
  for (const [name, header] of rejected) {
    it(`is refused on every route when it is ${name}`, async () => {
      const app = build();
      const device = await register(app);
      await sync(app, device.token, 1, [tripInput()]);
      const authorization = header(device);
      for (const [method, url, payload] of guarded) {
        const res = await app.inject({
          method: method as 'GET',
          url,
          payload,
          headers: authorization === undefined ? {} : { authorization },
        });
        assert.equal(res.statusCode, 401, `${method} ${url}`);
        assert.deepEqual(res.json(), UNAUTHORIZED);
      }
      // And nothing was changed along the way.
      assert.equal(await count('devices'), 1);
      const state = (await list(app, device.token)).json();
      assert.equal(state.revision, 1);
      assert.equal(state.trips[0].phase, 'planning');
      assert.equal(state.push.registered, false);
    });
  }

  it('is checked before the request is read', async () => {
    const res = await build().inject({
      method: 'PUT',
      url: '/trips',
      payload: { revision: 'nonsense' },
    });
    assert.equal(res.statusCode, 401);
    assert.deepEqual(res.json(), UNAUTHORIZED);
  });

  it('notes when the device was last seen, at most once a minute', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    const lastSeen = () =>
      column<number>(
        `SELECT (extract(epoch FROM last_seen_at) * 1000)::float8 AS value
           FROM devices WHERE id = $1`,
        [deviceId],
      );
    clock = minutes(0.5);
    await list(app, token);
    assert.equal(await lastSeen(), NOW.getTime());
    clock = minutes(1);
    await list(app, token);
    assert.equal(await lastSeen(), minutes(1).getTime());
  });
});

describe('PUT /devices/me/push', () => {
  it('stores where alerts go and whether they are allowed', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await setPush(app, token, PUSH);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), {
      push: { configured: false, registered: true, authorized: true },
    });
    assert.deepEqual((await list(app, token)).json().push, {
      configured: false,
      registered: true,
      authorized: true,
    });
  });

  it('says so when the server can send alerts', async () => {
    const app = build({ push: { configured: true } });
    const { token } = await register(app);
    assert.deepEqual((await list(app, token)).json().push, {
      configured: true,
      registered: false,
      authorized: false,
    });
  });

  it('clears the token with null', async () => {
    const app = build();
    const { token } = await register(app);
    await setPush(app, token, PUSH);
    const res = await setPush(app, token, {
      apnsToken: null,
      environment: 'production',
      authorized: false,
    });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), { push: NO_PUSH });
  });

  it('stores a token in lower case, whatever case it came in', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await setPush(app, token, { ...PUSH, apnsToken: 'AB'.repeat(32) });
    assert.equal(
      await column('SELECT apns_token AS value FROM devices WHERE id = $1', [
        deviceId,
      ]),
      TOKEN,
    );
  });

  it('reports the last delivery failure', async () => {
    const app = build({ push: { configured: true } });
    const { deviceId, token } = await register(app);
    await db.query(
      `UPDATE devices SET push_failure_reason = 'BadDeviceToken',
              push_failure_at = $2::timestamptz WHERE id = $1`,
      [deviceId, at(-3)],
    );
    assert.deepEqual((await list(app, token)).json().push, {
      configured: true,
      registered: false,
      authorized: false,
      lastFailure: { reason: 'BadDeviceToken', at: at(-3) },
    });
  });

  const invalid: Array<[string, unknown]> = [
    ['a token that is not hex', { ...PUSH, apnsToken: 'zz'.repeat(32) }],
    ['a token that is too short', { ...PUSH, apnsToken: 'ab'.repeat(15) }],
    ['a token that is too long', { ...PUSH, apnsToken: 'ab'.repeat(201) }],
    ['an empty token', { ...PUSH, apnsToken: '' }],
    ['a missing token', { environment: 'sandbox', authorized: true }],
    ['an unknown environment', { ...PUSH, environment: 'staging' }],
    ['a missing environment', { apnsToken: TOKEN, authorized: true }],
    ['a missing permission', { apnsToken: TOKEN, environment: 'sandbox' }],
    ['a permission of null', { ...PUSH, authorized: null }],
    ['a permission given as text', { ...PUSH, authorized: 'true' }],
    ['a permission given as a number', { ...PUSH, authorized: 1 }],
    ['a token given as a number', { ...PUSH, apnsToken: 1234 }],
    ['an environment of null', { ...PUSH, environment: null }],
  ];
  for (const [name, payload] of invalid) {
    it(`rejects ${name}`, async () => {
      const app = build();
      const { token } = await register(app);
      const res = await setPush(app, token, payload as object);
      assert.equal(res.statusCode, 400);
      assert.equal(res.json().error, 'bad_request');
      assert.deepEqual((await list(app, token)).json().push, NO_PUSH);
    });
  }

  it('does not take a permission of null for "not allowed"', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    const res = await setPush(app, token, { ...PUSH, authorized: null });
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.json(), {
      error: 'bad_request',
      message: 'body/authorized must be boolean',
    });
    // Still "not reported yet", which makes alerts wait; false would have
    // them dropped as if the user had turned them off.
    assert.equal(
      await column(
        'SELECT notifications_authorized AS value FROM devices WHERE id = $1',
        [deviceId],
      ),
      null,
    );
    assert.equal(
      await column('SELECT apns_token AS value FROM devices WHERE id = $1', [
        deviceId,
      ]),
      null,
    );
  });

  it('silences the first device when a second registers the same token', async () => {
    const app = build();
    const first = await register(app);
    const second = await register(app);
    await setPush(app, first.token, PUSH);
    await sync(app, first.token, 1, [tripInput()]);

    assert.equal((await setPush(app, second.token, PUSH)).statusCode, 200);

    const silenced = (await list(app, first.token)).json();
    assert.deepEqual(silenced.trips, []);
    assert.equal(silenced.push.registered, false);
    assert.equal((await getTrip(app, first.token)).statusCode, 404);
    assert.equal((await list(app, second.token)).json().push.registered, true);

    // The first device finds out when it sends its trips again: the same
    // revision is refused, and a new one is applied.
    const retry = await sync(app, first.token, 1, [tripInput()]);
    assert.equal(retry.statusCode, 409);
    const again = (await sync(app, first.token, 2, [tripInput()])).json();
    assert.equal(again.applied, true);
    assert.equal(again.trips.length, 1);
  });
});

describe('DELETE /devices/me', () => {
  it('forgets the device, its trips and its queued alerts', async () => {
    const app = build();
    const device = await register(app);
    const other = await register(app);
    await sync(app, device.token, 1, [tripInput(), tripInput({ id: GYM })]);
    await sync(app, other.token, 1, [tripInput()]);
    await queueAlert(device.deviceId, 'pending');

    const res = await app.inject({
      method: 'DELETE',
      url: '/devices/me',
      headers: bearer(device.token),
    });
    assert.equal(res.statusCode, 204);
    assert.equal(res.body, '');

    assert.equal(await count('devices'), 1);
    assert.equal(await count('trips'), 1);
    assert.equal(await count('trip_notifications'), 0);
    // Its credential is worth nothing now; the other device is untouched.
    assert.equal((await list(app, device.token)).statusCode, 401);
    assert.equal((await list(app, other.token)).json().trips.length, 1);
  });

  it('does not mind a client that calls an empty request JSON', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await app.inject({
      method: 'DELETE',
      url: '/devices/me',
      headers: { ...bearer(token), 'content-type': 'application/json' },
    });
    assert.equal(res.statusCode, 204);
    assert.equal(await count('devices'), 0);
  });
});

describe('PUT /trips', () => {
  it('stores the trips and answers with the state of each', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await sync(app, token, 1, [tripInput()]);
    assert.equal(res.statusCode, 200);
    // The digest is over the canonical form of what was sent.
    const digest = createHash('sha256')
      .update(
        JSON.stringify([
          {
            id: LAB,
            title: 'Chem lab',
            origin: { lat: 38.2383, lng: -122.0402 },
            destination: { lat: 38.5593, lng: -121.4237 },
            destinationName: 'Sac State',
            arriveBy: at(180),
            startsAt: at(190),
            timeZone: 'America/Los_Angeles',
          },
        ]),
      )
      .digest('hex');
    assert.deepEqual(res.json(), {
      revision: 1,
      applied: true,
      digest,
      serverTime: NOW.toISOString(),
      limits: LIMITS,
      push: NO_PUSH,
      monitor: NO_MONITOR,
      trips: [freshState()],
    });
  });

  it('accepts times with an offset or without fractional seconds', async () => {
    const app = build();
    const { token } = await register(app);
    const body = (
      await sync(app, token, 1, [
        tripInput({
          arriveBy: '2026-11-20T10:00:00-08:00',
          startsAt: '2026-11-20T18:10:00Z',
        }),
      ])
    ).json();
    assert.equal(body.trips[0].arriveBy, at(180));
    // The same snapshot, written the canonical way, is the same snapshot.
    const retry = (await sync(app, token, 1, [tripInput()])).json();
    assert.equal(retry.applied, false);
    assert.equal(retry.digest, body.digest);
  });

  it('lists trips by arrival time and leaves out optional fields', async () => {
    const app = build();
    const { token } = await register(app);
    const bare = { ...tripInput({ id: GYM, arriveBy: at(60) }) } as Record<
      string,
      unknown
    >;
    delete bare.destinationName;
    delete bare.startsAt;
    const body = (await sync(app, token, 1, [tripInput(), bare])).json();
    assert.deepEqual(
      body.trips.map((trip: { id: string }) => trip.id),
      [GYM, LAB],
    );
  });

  it('makes a trip beyond the planning horizon wait for its plan', async () => {
    const app = build();
    const { token } = await register(app);
    const body = (
      await sync(app, token, 1, [tripInput({ arriveBy: at(720) })])
    ).json();
    assert.deepEqual(body.trips, [
      freshState({
        arriveBy: at(720),
        phase: 'scheduled',
        planAvailableAt: at(30),
        monitoring: {
          ...freshState().monitoring,
          endsAt: at(720),
          nextCheckAt: at(30),
        },
      }),
    ]);

    // Half an hour on it is inside the horizon, whoever is watching.
    clock = minutes(30);
    const later = (await list(app, token)).json();
    assert.equal(later.trips[0].phase, 'planning');
    assert.equal(later.trips[0].planAvailableAt, null);
  });

  it('accepts a trip whose arrival time has passed, as ended', async () => {
    const app = build();
    const { token } = await register(app);
    const body = (
      await sync(app, token, 1, [tripInput({ arriveBy: at(-30) })])
    ).json();
    assert.equal(body.trips[0].phase, 'ended');
    assert.equal(body.trips[0].monitoring.nextCheckAt, null);
  });

  it('cancels the trips a new snapshot leaves out', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput(), tripInput({ id: GYM })]);
    const body = (await sync(app, token, 2, [tripInput({ id: GYM })])).json();
    assert.equal(body.applied, true);
    assert.equal(body.revision, 2);
    assert.deepEqual(
      body.trips.map((trip: { id: string }) => trip.id),
      [GYM],
    );
    assert.equal((await getTrip(app, token, LAB)).statusCode, 404);

    const none = (await sync(app, token, 3, [])).json();
    assert.deepEqual(none.trips, []);
  });

  it('changes nothing for a retry of the same snapshot', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    const first = (await sync(app, token, 1, [tripInput()])).json();
    await giveMonitoringState(deviceId);

    clock = minutes(1);
    const retry = await sync(app, token, 1, [tripInput()]);
    assert.equal(retry.statusCode, 200);
    assert.deepEqual(retry.json(), {
      ...first,
      applied: false,
      serverTime: at(1),
      trips: [monitoredState()],
    });
  });

  it('refuses a different snapshot under a revision already used', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 3, [tripInput()]);
    const res = await sync(app, token, 3, [tripInput({ arriveBy: at(240) })]);
    assert.equal(res.statusCode, 409);
    assert.deepEqual(res.json(), {
      error: 'revision_conflict',
      message:
        'A different set of trips already used this revision. Send it again with a higher one.',
      revision: 3,
    });
    const state = (await list(app, token)).json();
    assert.equal(state.revision, 3);
    assert.equal(state.trips[0].arriveBy, at(180));
  });

  it('does not let an older request restore a cancelled trip', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await sync(app, token, 2, []);

    // The first request again, arriving late.
    const late = await sync(app, token, 1, [tripInput()]);
    assert.equal(late.statusCode, 200);
    const body = late.json();
    assert.equal(body.applied, false);
    assert.equal(body.revision, 2);
    assert.deepEqual(body.trips, []);
    assert.deepEqual((await list(app, token)).json().trips, []);
  });

  it('keeps a late retry harmless even once its trips are out of range', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    clock = minutes(2 * 24 * 60);
    const res = await sync(app, token, 1, [tripInput()]);
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().applied, false);
  });

  it('keeps the plan and the alerts when only the labels change', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    await queueAlert(deviceId, 'sent', minutes(1));

    const body = (
      await sync(app, token, 2, [
        tripInput({ title: 'Chemistry lab', destinationName: 'Sequoia Hall' }),
      ])
    ).json();
    assert.equal(body.applied, true);
    assert.deepEqual(body.trips, [
      monitoredState({
        monitoring: {
          ...monitoredState().monitoring,
          headsUpSentAt: at(1),
          lastAlert: { kind: 'heads_up', status: 'sent', at: at(1) },
        },
      }),
    ]);
    assert.equal(
      await column('SELECT title AS value FROM trips'),
      'Chemistry lab',
    );
    assert.equal(await column('SELECT content_version AS value FROM trips'), 1);
  });

  it('starts planning over when the trip materially changes', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    await queueAlert(deviceId, 'sent', minutes(1));

    clock = minutes(2);
    const body = (
      await sync(app, token, 2, [tripInput({ arriveBy: at(240) })])
    ).json();
    assert.deepEqual(body.trips, [
      freshState({
        arriveBy: at(240),
        monitoring: {
          ...freshState().monitoring,
          endsAt: at(240),
          nextCheckAt: at(2),
        },
      }),
    ]);
    assert.equal(await column('SELECT content_version AS value FROM trips'), 2);
    assert.equal(
      await column('SELECT heads_up_state AS value FROM trips'),
      'pending',
    );
  });

  it('does not alert twice for a trip that is cancelled and added back', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    await sync(app, token, 2, []);
    const body = (await sync(app, token, 3, [tripInput()])).json();

    assert.equal(body.trips.length, 1);
    // Monitoring picks up where it was; the plan itself is worked out again.
    assert.equal(body.trips[0].phase, 'monitoring');
    assert.equal(body.trips[0].recommendation, null);
    assert.equal(
      await column('SELECT heads_up_state AS value FROM trips'),
      'sent',
    );
    assert.equal(await column('SELECT content_version AS value FROM trips'), 1);
  });

  it('strips properties it does not know', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await app.inject({
      method: 'PUT',
      url: '/trips',
      headers: bearer(token),
      payload: {
        revision: 1,
        now: at(-600),
        trips: [tripInput({ status: 'departed', phase: 'monitoring' })],
      },
    });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json().trips, [freshState()]);
    assert.equal(res.json().serverTime, NOW.toISOString());
  });

  it('accepts 50 trips and rejects 51', async () => {
    const app = build();
    const { token } = await register(app);
    const many = (n: number) =>
      Array.from({ length: n }, (_, i) =>
        tripInput({ id: `trip-${i}`, arriveBy: at(60 + i) }),
      );
    const tooMany = await sync(app, token, 1, many(51));
    assert.equal(tooMany.statusCode, 400);
    assert.equal(tooMany.json().error, 'bad_request');
    assert.equal(await count('trips'), 0);

    const full = await sync(app, token, 1, many(50));
    assert.equal(full.statusCode, 200);
    assert.equal(full.json().trips.length, 50);
  });

  it('accepts arrival times from 24 hours ago to 8 days ahead', async () => {
    const app = build();
    const { token } = await register(app);
    const day = 24 * 60;
    // With no start time: that has a rule of its own, tied to the arrival.
    const arriving = (arriveBy: string, over: Record<string, unknown> = {}) =>
      tripInput({ arriveBy, startsAt: undefined, ...over });
    const rejected = async (arriveBy: string, message: string) => {
      const res = await sync(app, token, 1, [arriving(arriveBy)]);
      assert.equal(res.statusCode, 400);
      assert.deepEqual(res.json(), { error: 'bad_request', message });
    };
    await rejected(
      at(-day),
      "A trip's arrival time passed more than 24 hours ago.",
    );
    await rejected(
      at(8 * day),
      "A trip's arrival time is more than 8 days away.",
    );
    assert.equal(await count('trips'), 0);

    const res = await sync(app, token, 1, [
      arriving(at(1 - day)),
      arriving(at(8 * day - 1), { id: GYM }),
    ]);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(
      res.json().trips.map((trip: { phase: string }) => trip.phase),
      ['ended', 'scheduled'],
    );
  });

  it('accepts a start time up to 24 hours from the arrival time, either side', async () => {
    const app = build();
    const { token } = await register(app);
    const day = 24 * 60;
    const rejected = async (startsAt: string) => {
      const res = await sync(app, token, 1, [tripInput({ startsAt })]);
      assert.equal(res.statusCode, 400);
      assert.deepEqual(res.json(), {
        error: 'bad_request',
        message:
          "A trip's start time is more than 24 hours from its arrival time.",
      });
    };
    await rejected(at(180 + day + 1));
    await rejected(at(180 - day - 1));
    // Dates the request format allows and the database does not take.
    await rejected('0000-01-01T00:00:00Z');
    await rejected('9999-12-31T23:59:59-23:59');
    assert.equal(await count('trips'), 0);

    const res = await sync(app, token, 1, [
      tripInput({ startsAt: at(180 + day) }),
      tripInput({ id: GYM, startsAt: at(180 - day) }),
    ]);
    assert.equal(res.statusCode, 200);
    assert.equal(await count('trips'), 2);
  });

  it('rejects two trips with the same id', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await sync(app, token, 1, [
      tripInput(),
      tripInput({ arriveBy: at(240) }),
    ]);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.json(), {
      error: 'bad_request',
      message: 'Two trips in the list have the same id.',
    });
    assert.equal(await count('trips'), 0);
  });

  const invalidTrips: Array<[string, Record<string, unknown>]> = [
    ['an empty id', { id: '' }],
    ['an id with a dot', { id: 'a.b' }],
    ['an id with a slash', { id: 'a/b' }],
    ['an id with a space', { id: 'a b' }],
    ['an id that starts with a symbol', { id: '@2026-11-20' }],
    ['an id over 80 characters', { id: 'a'.repeat(81) }],
    ['an empty title', { title: '' }],
    ['a title over 120 characters', { title: 't'.repeat(121) }],
    [
      'a destination name over 120 characters',
      { destinationName: 'd'.repeat(121) },
    ],
    ['a latitude off the map', { origin: { lat: 91, lng: 0 } }],
    ['a longitude off the map', { destination: { lat: 0, lng: -181 } }],
    ['an origin with no longitude', { origin: { lat: 38 } }],
    ['an arrival time with no zone', { arriveBy: '2026-11-20T18:00:00' }],
    ['an arrival time that is not a time', { arriveBy: 'soon' }],
    ['a start time that is not a time', { startsAt: 'later' }],
    ['an empty time zone', { timeZone: '' }],
    ['a time zone over 64 characters', { timeZone: 'z'.repeat(65) }],
    // A value of the wrong JSON type is refused, never converted: a null
    // coordinate must not become the equator.
    ['a latitude of null', { origin: { lat: null, lng: -122.0402 } }],
    ['coordinates of null', { destination: { lat: null, lng: null } }],
    ['a latitude given as text', { origin: { lat: '38.2', lng: -122 } }],
    ['a longitude of true', { origin: { lat: 38.2, lng: true } }],
    ['an origin of null', { origin: null }],
    ['a title of null', { title: null }],
    ['a title that is a number', { title: 42 }],
    ['a destination name of null', { destinationName: null }],
    ['an arrival time of null', { arriveBy: null }],
    ['a start time of null', { startsAt: null }],
    ['a time zone of null', { timeZone: null }],
    ['an id that is a number', { id: 7 }],
    // Text the database cannot store.
    ['a title with a NUL in it', { title: 'abc\u0000def' }],
    ['a destination name with a NUL in it', { destinationName: 'a\u0000' }],
    ['a time zone with a NUL in it', { timeZone: 'America\u0000' }],
  ];
  for (const [name, change] of invalidTrips) {
    it(`rejects ${name}`, async () => {
      const app = build();
      const { token } = await register(app);
      const res = await sync(app, token, 1, [tripInput(change)]);
      assert.equal(res.statusCode, 400);
      assert.equal(res.json().error, 'bad_request');
      assert.equal(await count('trips'), 0);
    });
  }

  const invalidBodies: Array<[string, unknown]> = [
    ['a missing revision', { trips: [] }],
    ['a revision of zero', { revision: 0, trips: [] }],
    ['a fractional revision', { revision: 1.5, trips: [] }],
    ['a missing list of trips', { revision: 1 }],
    [
      'a trip with no arrival time',
      { revision: 1, trips: [{ ...tripInput(), arriveBy: undefined }] },
    ],
    [
      'a trip with no time zone',
      { revision: 1, trips: [{ ...tripInput(), timeZone: undefined }] },
    ],
    ['a revision of null', { revision: null, trips: [] }],
    ['a revision given as text', { revision: '1', trips: [] }],
    ['a revision of true', { revision: true, trips: [] }],
    ['a list of trips of null', { revision: 1, trips: null }],
    ['one trip in place of the list', { revision: 1, trips: tripInput() }],
    ['a trip of null', { revision: 1, trips: [null] }],
  ];
  for (const [name, payload] of invalidBodies) {
    it(`rejects ${name}`, async () => {
      const app = build();
      const { token } = await register(app);
      const res = await app.inject({
        method: 'PUT',
        url: '/trips',
        headers: bearer(token),
        payload: payload as object,
      });
      assert.equal(res.statusCode, 400);
      assert.equal(res.json().error, 'bad_request');
      assert.equal((await list(app, token)).json().revision, 0);
    });
  }

  it('accepts the longest id, title and names it allows', async () => {
    const app = build();
    const { token } = await register(app);
    const id = `A${'b:_-@9'.repeat(13)}Z`;
    assert.equal(id.length, 80);
    const res = await sync(app, token, 1, [
      tripInput({
        id,
        // Counted in characters, not in bytes.
        title: '東'.repeat(120),
        destinationName: 'd'.repeat(120),
        timeZone: 'z'.repeat(64),
      }),
    ]);
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().trips[0].id, id);
    assert.equal((await getTrip(app, token, id)).statusCode, 200);
  });

  it('says which value has the wrong type', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await sync(app, token, 1, [
      tripInput(),
      tripInput({ id: GYM, origin: { lat: null, lng: -122.0402 } }),
    ]);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.json(), {
      error: 'bad_request',
      message: 'body/trips/1/origin/lat must be number',
    });
  });

  it('answers 400, not a server error, for a value only the database refuses', async () => {
    // Nothing the request rules let through is known to do this; if one
    // did, it is the request that cannot be stored.
    const refusing = failing(text =>
      text.includes('INSERT INTO trips')
        ? Object.assign(new Error('invalid byte sequence'), { code: '22021' })
        : undefined,
    );
    const app = build({ db: refusing });
    const { token } = await register(app);
    const res = await sync(app, token, 1, [tripInput()]);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.json(), {
      error: 'bad_request',
      message: 'The request holds a value the server cannot store.',
    });
    assert.equal(await count('trips'), 0);
    assert.equal((await list(app, token)).json().revision, 0);
    assert.deepEqual(logs, []);
  });

  it('lets one device send 120 lists of trips an hour', async () => {
    const app = build();
    const mine = await register(app);
    const theirs = await register(app);
    for (let i = 1; i <= 120; i++) {
      // Retries count like anything else.
      const res = await sync(app, mine.token, 1, []);
      assert.equal(res.statusCode, 200, `request ${i}`);
    }
    clock = minutes(15);
    const refused = await sync(app, mine.token, 2, [tripInput()]);
    assert.equal(refused.statusCode, 429);
    assert.deepEqual(refused.json(), {
      error: 'rate_limited',
      message: 'Too many trip updates from this device. Try again later.',
    });
    assert.equal(String(refused.headers['retry-after']), '2700');
    assert.equal(await count('trips'), 0);
    // Reading is not counted, and nobody else is held back.
    assert.equal((await list(app, mine.token)).statusCode, 200);
    assert.equal((await sync(app, theirs.token, 1, [])).statusCode, 200);

    clock = minutes(60);
    const allowed = await sync(app, mine.token, 2, [tripInput()]);
    assert.equal(allowed.statusCode, 200);
    assert.equal(allowed.json().applied, true);
  });

  it('counts only requests it would otherwise act on against that limit', async () => {
    const app = build({ tripSyncsPerHour: 2 });
    const { token } = await register(app);
    // Refused before they are counted: no credential, and a body that is
    // not a list of trips.
    for (let i = 0; i < 5; i++) {
      assert.equal((await sync(app, 'nobody', 1, [])).statusCode, 401);
      const bad = await sync(app, token, 1, [tripInput({ title: '' })]);
      assert.equal(bad.statusCode, 400);
    }
    assert.equal((await sync(app, token, 1, [])).statusCode, 200);
    assert.equal((await sync(app, token, 2, [])).statusCode, 200);
    assert.equal((await sync(app, token, 3, [])).statusCode, 429);
  });
});

describe('a sync and the first evaluation', () => {
  it('evaluates the device’s trips before answering', async () => {
    const evaluated: string[] = [];
    let deviceId = '';
    const app = build({
      monitorStatus: MONITOR_ON,
      evaluateNow: async id => {
        evaluated.push(id);
        await giveMonitoringState(id);
      },
    });
    const device = await register(app);
    deviceId = device.deviceId;
    const body = (await sync(app, device.token, 1, [tripInput()])).json();
    assert.deepEqual(evaluated, [deviceId]);
    // The answer already carries what the evaluation stored.
    assert.deepEqual(body.trips, [monitoredState()]);
  });

  it('does not evaluate for a snapshot it did not apply', async () => {
    let evaluations = 0;
    const app = build({
      monitorStatus: MONITOR_ON,
      evaluateNow: async () => {
        evaluations += 1;
      },
    });
    const { token } = await register(app);
    await sync(app, token, 2, [tripInput()]);
    assert.equal(evaluations, 1);
    await sync(app, token, 2, [tripInput()]);
    await sync(app, token, 1, []);
    await sync(app, token, 2, []);
    await list(app, token);
    assert.equal(evaluations, 1);
  });

  it('still answers when the evaluation fails', async () => {
    class ProviderDown extends Error {}
    const app = build({
      monitorStatus: MONITOR_ON,
      evaluateNow: async () => {
        throw new ProviderDown('GET https://traffic.example/?key=secret');
      },
    });
    const { token } = await register(app);
    const res = await sync(app, token, 1, [tripInput()]);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json().trips, [freshState()]);
    // Only the kind of failure is logged.
    assert.deepEqual(logs, ['Inline evaluation failed: ProviderDown']);
  });

  it('does not wait for an evaluation that takes too long', async () => {
    let finish = () => {};
    const slow = new Promise<void>(resolve => {
      finish = resolve;
    });
    const app = build({
      monitorStatus: MONITOR_ON,
      evaluateNow: () => slow,
      inlineEvaluationTimeoutMs: 20,
    });
    const { token } = await register(app);
    const res = await sync(app, token, 1, [tripInput()]);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json().trips, [freshState()]);
    finish();
    await slow;
    assert.deepEqual(logs, []);
  });

  it('does not happen on a server that runs no monitor: the trip is stored and nothing is planned', async () => {
    let evaluations = 0;
    let asked = 0;
    for (const monitorStatus of [
      // The default: no monitor at all.
      undefined,
      async () => {
        asked += 1;
        return { enabled: false, dependable: false, lastTickAt: null };
      },
    ]) {
      await db.exec('TRUNCATE devices CASCADE');
      const app = build({
        ...(monitorStatus ? { monitorStatus } : {}),
        evaluateNow: async id => {
          evaluations += 1;
          await giveMonitoringState(id);
        },
      });
      const { token } = await register(app);
      const body = (await sync(app, token, 1, [tripInput()])).json();
      assert.equal(body.applied, true);
      assert.deepEqual(body.monitor, NO_MONITOR);
      // No plan and no alert: the app is not shown a monitored trip.
      assert.deepEqual(body.trips, [freshState()]);
      assert.equal(await count('trip_notifications'), 0);
    }
    assert.equal(evaluations, 0);
    // Asked once for the sync, not once more for its answer.
    assert.equal(asked, 1);
  });

  it('happens as soon as the server says it runs the monitor', async () => {
    let enabled = false;
    let evaluations = 0;
    const app = build({
      monitorStatus: async () => ({
        enabled,
        dependable: false,
        lastTickAt: null,
      }),
      evaluateNow: async () => {
        evaluations += 1;
      },
    });
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    assert.equal(evaluations, 0);
    enabled = true;
    const body = (await sync(app, token, 2, [])).json();
    assert.equal(evaluations, 1);
    assert.equal(body.monitor.enabled, true);
  });
});

describe('GET /trips', () => {
  it('answers a device that never synced with an empty state', async () => {
    const app = build();
    const { token } = await register(app);
    const res = await list(app, token);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), {
      revision: 0,
      applied: false,
      // sha256("[]"): the digest of wanting nothing monitored.
      digest:
        '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
      serverTime: NOW.toISOString(),
      limits: LIMITS,
      push: NO_PUSH,
      monitor: NO_MONITOR,
      trips: [],
    });
  });

  it('reads the state back without changing it', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    const synced = (await sync(app, token, 5, [tripInput()])).json();
    await giveMonitoringState(deviceId);
    clock = minutes(3);
    const res = await list(app, token);
    assert.deepEqual(res.json(), {
      ...synced,
      applied: false,
      serverTime: at(3),
      trips: [monitoredState()],
    });
  });

  it('says a heads-up was sent only once APNs accepted it', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    await queueAlert(deviceId, 'pending');

    const queued = (await list(app, token)).json().trips[0].monitoring;
    assert.equal(queued.headsUpSentAt, null);
    assert.deepEqual(queued.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: NOW.toISOString(),
    });

    await db.query(
      `UPDATE trip_notifications SET status = 'sent', sent_at = $1::timestamptz`,
      [at(1)],
    );
    const sent = (await list(app, token)).json().trips[0].monitoring;
    assert.equal(sent.headsUpSentAt, at(1));
    assert.deepEqual(sent.lastAlert, {
      kind: 'heads_up',
      status: 'sent',
      at: at(1),
    });
  });

  it('marks a recommendation stale when its check is overdue', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    clock = minutes(21);
    const [trip] = (await list(app, token)).json().trips;
    assert.equal(trip.recommendation.stale, true);
  });

  it('reports the last evaluation failure', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await db.query(
      `UPDATE trips SET last_error_code = 'budget_exhausted',
              last_error_at = $1::timestamptz, eval_failures = 1`,
      [at(1)],
    );
    assert.deepEqual((await list(app, token)).json().trips[0].lastError, {
      code: 'budget_exhausted',
      at: at(1),
    });
  });
});

describe('the monitor a client is told about', () => {
  it('is off unless the server says it runs one', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    assert.deepEqual((await list(app, token)).json().monitor, NO_MONITOR);
    assert.deepEqual((await getTrip(app, token)).json().monitor, NO_MONITOR);
  });

  it('is what the monitor reports', async () => {
    const app = build({
      monitorStatus: async () => ({
        enabled: true,
        dependable: true,
        lastTickAt: minutes(-1),
      }),
    });
    const { token } = await register(app);
    const expected = { enabled: true, dependable: true, lastTickAt: at(-1) };
    const synced = (await sync(app, token, 1, [tripInput()])).json();
    assert.deepEqual(synced.monitor, expected);
    assert.deepEqual((await list(app, token)).json().monitor, expected);
    assert.deepEqual((await getTrip(app, token)).json().monitor, expected);
  });

  it('is never dependable when it is not enabled', async () => {
    const app = build({
      monitorStatus: async () => ({
        enabled: false,
        dependable: true,
        lastTickAt: null,
      }),
    });
    const { token } = await register(app);
    assert.deepEqual((await list(app, token)).json().monitor, NO_MONITOR);
  });

  it('is reported as off when its status cannot be read', async () => {
    class StatusLost extends Error {}
    const app = build({
      monitorStatus: async () => {
        throw new StatusLost('db.example.com refused');
      },
    });
    const { token } = await register(app);
    const res = await list(app, token);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json().monitor, NO_MONITOR);
    assert.deepEqual(logs, ['Monitor status failed: StatusLost']);
  });
});

describe('GET /trips/:id', () => {
  it('returns one trip with the server’s time, push and limits', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput(), tripInput({ id: GYM })]);
    await giveMonitoringState(deviceId);
    clock = minutes(2);
    const res = await getTrip(app, token);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), {
      trip: monitoredState(),
      serverTime: at(2),
      push: NO_PUSH,
      limits: LIMITS,
      monitor: NO_MONITOR,
    });
  });

  it('takes the id as one percent-encoded path segment', async () => {
    const app = build();
    const { token } = await register(app);
    const id = '6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-11-20:2';
    await sync(app, token, 1, [tripInput({ id })]);
    const encoded = await app.inject({
      method: 'GET',
      url: '/trips/6F9619FF-8B86-D011-B42D-00C04FC964FF%402026-11-20%3A2',
      headers: bearer(token),
    });
    assert.equal(encoded.statusCode, 200);
    assert.equal(encoded.json().trip.id, id);
  });

  it('answers 404 for a trip that does not exist or was cancelled', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await sync(app, token, 2, []);
    for (const id of [LAB, 'nothing']) {
      const res = await getTrip(app, token, id);
      assert.equal(res.statusCode, 404);
      assert.deepEqual(res.json(), NOT_FOUND);
    }
  });

  const badIds = ['a.b', '@x', 'a'.repeat(81), 'a b'];
  for (const id of badIds) {
    it(`rejects the id ${JSON.stringify(id.slice(0, 12))}`, async () => {
      const app = build();
      const { token } = await register(app);
      for (const res of [
        await getTrip(app, token, id),
        await leave(app, token, id),
      ]) {
        assert.equal(res.statusCode, 400);
        assert.equal(res.json().error, 'bad_request');
      }
    });
  }
});

describe('POST /trips/:id/departed', () => {
  it('ends the monitoring of the trip', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await giveMonitoringState(deviceId);
    await queueAlert(deviceId, 'pending');

    clock = minutes(30);
    const res = await leave(app, token);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), {
      trip: {
        id: LAB,
        arriveBy: at(180),
        phase: 'departed',
        recommendation: null,
        noPlanReason: null,
        planAvailableAt: null,
        monitoring: {
          startsAt: null,
          startedAt: NOW.toISOString(),
          headsUpAt: null,
          headsUpSentAt: null,
          leaveAlertSentAt: null,
          endsAt: at(180),
          nextCheckAt: null,
          lastAlert: null,
        },
        lastError: null,
      },
    });
    // Nothing is left to send for it.
    assert.equal(await count('trip_notifications'), 0);
    assert.equal((await getTrip(app, token)).json().trip.phase, 'departed');
  });

  it('can be said twice', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    const first = await leave(app, token);
    clock = minutes(5);
    const second = await leave(app, token);
    assert.equal(second.statusCode, 200);
    assert.deepEqual(second.json(), first.json());
  });

  it('stays said through the next sync', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await leave(app, token);
    const body = (
      await sync(app, token, 2, [tripInput({ title: 'Lab' })])
    ).json();
    assert.equal(body.trips[0].phase, 'departed');
  });

  it('is refused for an arrival time the trip no longer has', async () => {
    const app = build();
    const { deviceId, token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await sync(app, token, 2, [tripInput({ arriveBy: at(240) })]);
    await giveMonitoringState(deviceId);

    // The action of a notification sent before the trip was moved.
    const res = await leave(app, token, LAB, { arriveBy: at(180) });
    assert.equal(res.statusCode, 409);
    assert.deepEqual(res.json(), {
      error: 'superseded',
      message: 'This trip was rescheduled.',
    });
    assert.equal((await getTrip(app, token)).json().trip.phase, 'monitoring');

    const current = await leave(app, token, LAB, { arriveBy: at(240) });
    assert.equal(current.statusCode, 200);
    assert.equal(current.json().trip.phase, 'departed');
  });

  it('answers 404 for a trip that does not exist or was cancelled', async () => {
    const app = build();
    const { token } = await register(app);
    await sync(app, token, 1, [tripInput()]);
    await sync(app, token, 2, []);
    for (const id of [LAB, 'nothing']) {
      const res = await leave(app, token, id);
      assert.equal(res.statusCode, 404);
      assert.deepEqual(res.json(), NOT_FOUND);
    }
  });

  const invalid: Array<[string, object]> = [
    ['no arrival time', {}],
    ['an arrival time that is not a time', { arriveBy: 'now' }],
    ['an arrival time of null', { arriveBy: null }],
    ['an arrival time given as a number', { arriveBy: 1795000000000 }],
  ];
  for (const [name, payload] of invalid) {
    it(`rejects ${name}`, async () => {
      const app = build();
      const { token } = await register(app);
      await sync(app, token, 1, [tripInput()]);
      const res = await leave(app, token, LAB, payload);
      assert.equal(res.statusCode, 400);
      assert.equal(res.json().error, 'bad_request');
      assert.equal((await getTrip(app, token)).json().trip.phase, 'planning');
    });
  }
});

describe('one device and another', () => {
  it('cannot see or change each other’s trips', async () => {
    const app = build();
    const mine = await register(app);
    const theirs = await register(app);
    await sync(app, mine.token, 1, [tripInput()]);

    // To the other device the trip does not exist, exactly like one that
    // really does not.
    assert.deepEqual((await list(app, theirs.token)).json().trips, []);
    const missing = await getTrip(app, theirs.token, 'nothing');
    for (const res of [
      await getTrip(app, theirs.token),
      await leave(app, theirs.token),
    ]) {
      assert.equal(res.statusCode, 404);
      assert.deepEqual(res.json(), NOT_FOUND);
      assert.equal(res.body, missing.body);
    }
    assert.equal(
      (await getTrip(app, mine.token)).json().trip.phase,
      'planning',
    );
  });

  it('can use the same trip id without meeting', async () => {
    const app = build();
    const mine = await register(app);
    const theirs = await register(app);
    await sync(app, mine.token, 1, [tripInput()]);
    await sync(app, theirs.token, 1, [tripInput({ arriveBy: at(300) })]);

    assert.equal(
      (await getTrip(app, mine.token)).json().trip.arriveBy,
      at(180),
    );
    assert.equal(
      (await getTrip(app, theirs.token)).json().trip.arriveBy,
      at(300),
    );

    // Leaving, cancelling and unregistering stay with the device that did it.
    await leave(app, theirs.token, LAB, { arriveBy: at(300) });
    assert.equal(
      (await getTrip(app, mine.token)).json().trip.phase,
      'planning',
    );
    await sync(app, theirs.token, 2, []);
    assert.equal((await list(app, mine.token)).json().trips.length, 1);
    await app.inject({
      method: 'DELETE',
      url: '/devices/me',
      headers: bearer(theirs.token),
    });
    assert.equal((await list(app, mine.token)).json().trips.length, 1);
  });
});

describe('a server whose trip tables are missing', () => {
  let bare: Database;

  beforeEach(async () => {
    bare = await createPgliteDatabase();
  });

  afterEach(async () => {
    await bare.close();
  });

  const credential = `${randomUUID()}.${'A'.repeat(43)}`;
  const routes: Array<[string, string, object?]> = [
    ['POST', '/devices', { platform: 'ios' }],
    ['PUT', '/devices/me/push', PUSH],
    ['DELETE', '/devices/me'],
    ['PUT', '/trips', { revision: 1, trips: [] }],
    ['GET', '/trips'],
    ['GET', `/trips/${LAB}`],
    ['POST', `/trips/${LAB}/departed`, { arriveBy: at(180) }],
    ['POST', '/internal/monitor/tick'],
  ];

  it('answers 503 on every device, trip and tick route', async () => {
    const app = build({
      db: bare,
      tickSecret: TICK_SECRET,
      tick: async () => {
        throw new Error('must not run');
      },
    });
    for (const [method, url, payload] of routes) {
      for (const token of [credential, TICK_SECRET]) {
        const res = await app.inject({
          method: method as 'GET',
          url,
          payload,
          headers: bearer(token),
        });
        // The tick route still wants its own secret first.
        const expected =
          url === '/internal/monitor/tick' && token !== TICK_SECRET ? 401 : 503;
        assert.equal(res.statusCode, expected, `${method} ${url}`);
        if (expected === 503) {
          assert.deepEqual(res.json(), UNAVAILABLE);
        }
      }
    }
  });

  it('answers 503 when only the earlier migrations have run', async () => {
    await bare.exec(
      `CREATE TABLE schema_migrations (version text PRIMARY KEY);
       INSERT INTO schema_migrations VALUES ('004_profile_free_flow.sql');`,
    );
    const res = await build({ db: bare }).inject({
      method: 'POST',
      url: '/devices',
      payload: { platform: 'ios' },
    });
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.json(), UNAVAILABLE);
  });

  it('keeps answering the routes that need no tables', async () => {
    const app = build({ db: bare });
    assert.equal(
      (await app.inject({ method: 'GET', url: '/health' })).statusCode,
      200,
    );
    const verdict = await app.inject({
      method: 'POST',
      url: '/verdict',
      payload: {
        origin: { lat: 38.2383, lng: -122.0402 },
        destination: { lat: 38.5593, lng: -121.4237 },
      },
    });
    assert.equal(verdict.statusCode, 200);
  });

  it('starts working once the migration has run, with no restart', async () => {
    const app = build({ db: bare });
    const attempt = () =>
      app.inject({
        method: 'POST',
        url: '/devices',
        payload: { platform: 'ios' },
      });
    assert.equal((await attempt()).statusCode, 503);

    await runMigrations(bare);
    // It looks again at most once a minute.
    clock = minutes(0.5);
    assert.equal((await attempt()).statusCode, 503);
    clock = minutes(1);
    assert.equal((await attempt()).statusCode, 201);
  });

  it('asks the database once however many requests are waiting', async () => {
    let asked = 0;
    const counting: Database = {
      ...bare,
      query: (text, params) => {
        asked += 1;
        return bare.query(text, params);
      },
    };
    const app = build({ db: counting });
    const attempt = () =>
      app.inject({ method: 'GET', url: '/trips', headers: bearer(credential) });
    const answers = await Promise.all([attempt(), attempt(), attempt()]);
    assert.deepEqual(
      answers.map(res => res.statusCode),
      [503, 503, 503],
    );
    assert.equal(asked, 1);
  });
});

describe('a server whose trip tables exist', () => {
  it('stops asking whether they do', async () => {
    let probes = 0;
    const counting: Database = {
      ...db,
      query: (text, params) => {
        if (text.includes('schema_migrations')) {
          probes += 1;
        }
        return db.query(text, params);
      },
    };
    const app = build({ db: counting });
    const { token } = await register(app);
    clock = minutes(5);
    await list(app, token);
    await list(app, token);
    assert.equal(probes, 1);
  });
});

describe('a database that cannot be asked', () => {
  const lost = () => new ConnectionLost('db.internal.example:5432 went away');
  const credential = `${randomUUID()}.${'A'.repeat(43)}`;
  const routes: Array<[string, string, object?]> = [
    ['POST', '/devices', { platform: 'ios' }],
    ['PUT', '/devices/me/push', PUSH],
    ['DELETE', '/devices/me'],
    ['PUT', '/trips', { revision: 1, trips: [] }],
    ['GET', '/trips'],
    ['GET', `/trips/${LAB}`],
    ['POST', `/trips/${LAB}/departed`, { arriveBy: at(180) }],
    ['POST', '/internal/monitor/tick'],
  ];

  /** A device with one trip, registered while the database was well. */
  const deviceWithTrip = async (): Promise<Registration> => {
    const app = build();
    const device = await register(app);
    await sync(app, device.token, 1, [tripInput()]);
    return device;
  };

  it('answers 503 "try again", never "not set up", on every device, trip and tick route', async () => {
    // The tables are there. Nobody can say so.
    const app = build({
      db: failing(lost),
      tickSecret: TICK_SECRET,
      tick: async () => {
        throw new Error('must not run');
      },
    });
    for (const [method, url, payload] of routes) {
      const token = url === '/internal/monitor/tick' ? TICK_SECRET : credential;
      const res = await app.inject({
        method: method as 'GET',
        url,
        payload,
        headers: bearer(token),
      });
      assert.equal(res.statusCode, 503, `${method} ${url}`);
      assert.deepEqual(res.json(), TROUBLE, `${method} ${url}`);
    }
    // Only the kind of failure is logged: the message names the host.
    assert.equal(logs.length, routes.length);
    assert.deepEqual(
      [...new Set(logs)],
      ['Database request failed: ConnectionLost'],
    );
  });

  it('asks again at the very next request, and works as soon as the database answers', async () => {
    const { token } = await deviceWithTrip();
    // A new process, as after every deploy or wake-up, whose first look at
    // the tables finds the connection gone.
    let queries = 0;
    const app = build({
      db: failing(() => {
        queries += 1;
        return queries === 1 ? lost() : undefined;
      }),
    });
    const first = await list(app, token);
    assert.equal(first.statusCode, 503);
    assert.deepEqual(first.json(), TROUBLE);
    // No minute has to pass: a failure is not an answer worth remembering.
    const second = await list(app, token);
    assert.equal(second.statusCode, 200);
    assert.equal(second.json().trips.length, 1);
  });

  it('keeps asking for as long as the database keeps failing', async () => {
    let probes = 0;
    const app = build({
      db: failing(text => {
        probes += text.includes('schema_migrations') ? 1 : 0;
        return lost();
      }),
    });
    for (let i = 0; i < 3; i++) {
      assert.equal((await list(app, credential)).statusCode, 503);
    }
    assert.equal(probes, 3);
  });

  it('gives every request waiting on one failed look the same answer, having asked once', async () => {
    let probes = 0;
    const app = build({
      db: failing(text => {
        probes += text.includes('schema_migrations') ? 1 : 0;
        return lost();
      }),
    });
    const answers = await Promise.all([
      list(app, credential),
      list(app, credential),
      list(app, credential),
    ]);
    assert.deepEqual(
      answers.map(res => res.json()),
      [TROUBLE, TROUBLE, TROUBLE],
    );
    assert.equal(probes, 1);
  });

  it('never tells a device to consider itself gone: DELETE /devices/me fails as "try again" and the device is kept', async () => {
    const { token } = await deviceWithTrip();
    let queries = 0;
    const app = build({
      db: failing(() => {
        queries += 1;
        return queries === 1 ? lost() : undefined;
      }),
    });
    const remove = () =>
      app.inject({
        method: 'DELETE',
        url: '/devices/me',
        headers: bearer(token),
      });
    const refused = await remove();
    assert.equal(refused.statusCode, 503);
    assert.deepEqual(refused.json(), TROUBLE);
    // Everything is still stored, so the app must not forget its credential.
    assert.equal(await count('devices'), 1);
    assert.equal(await count('trips'), 1);

    assert.equal((await remove()).statusCode, 204);
    assert.equal(await count('devices'), 0);
  });

  it('answers 503 "try again" when the database fails after the tables were seen', async () => {
    const { token } = await deviceWithTrip();
    let down = false;
    const app = build({ db: failing(() => (down ? lost() : undefined)) });
    assert.equal((await list(app, token)).statusCode, 200);

    down = true;
    for (const [method, url, payload] of routes.slice(0, -1)) {
      const res = await app.inject({
        method: method as 'GET',
        url,
        payload,
        headers: bearer(token),
      });
      assert.equal(res.statusCode, 503, `${method} ${url}`);
      assert.deepEqual(res.json(), TROUBLE, `${method} ${url}`);
    }
    assert.ok(logs.length > 0);
    assert.deepEqual(
      [...new Set(logs)],
      ['Database request failed: ConnectionLost'],
    );

    // Nothing was half done, and nothing has to be restarted.
    down = false;
    const back = (await list(app, token)).json();
    assert.equal(back.revision, 1);
    assert.equal(back.trips.length, 1);
    assert.equal(await count('devices'), 1);
  });

  it('answers the same when the failure comes in the middle of applying a list of trips', async () => {
    const { token } = await deviceWithTrip();
    const app = build({
      db: failing(text =>
        text.includes('INSERT INTO trips')
          ? Object.assign(new Error('terminating connection'), {
              code: '57P01',
            })
          : undefined,
      ),
    });
    const res = await sync(app, token, 2, [
      tripInput(),
      tripInput({ id: GYM }),
    ]);
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.json(), TROUBLE);
    // PostgreSQL's own code for it is safe to log; its message is not.
    assert.deepEqual(logs, ['Database request failed: Error 57P01']);
    // The transaction was rolled back: the device still holds revision 1.
    const held = (await list(app, token)).json();
    assert.equal(held.revision, 1);
    assert.equal(held.trips.length, 1);
  });

  it('still answers a refusal of its own from inside a transaction as what it is', async () => {
    const { token } = await deviceWithTrip();
    const app = build({ db: failing(() => undefined) });
    const res = await sync(app, token, 1, []);
    assert.equal(res.statusCode, 409);
    assert.equal(res.json().error, 'revision_conflict');
    assert.deepEqual(logs, []);
  });

  it('does not call a failure that is not the database’s "try again"', async () => {
    let broken = false;
    const app = build({
      now: () => {
        if (broken) {
          throw new RangeError('the clock is not a database');
        }
        return clock;
      },
    });
    const { token } = await register(app);
    broken = true;
    const res = await list(app, token);
    assert.equal(res.statusCode, 500);
    assert.deepEqual(res.json(), {
      error: 'internal',
      message: 'Something went wrong.',
    });
  });
});

describe('POST /internal/monitor/tick', () => {
  const REPORT: TickReport = {
    evaluated: 2,
    queued: 1,
    delivered: 1,
    failed: 0,
    dropped: 0,
  };
  const tickWith = (
    app: App,
    secret?: string,
    url = '/internal/monitor/tick',
  ) =>
    app.inject({
      method: 'POST',
      url,
      headers: secret === undefined ? {} : bearer(secret),
    });

  it('does not exist when no secret is set', async () => {
    let ticks = 0;
    const app = build({
      tick: async () => {
        ticks += 1;
        return REPORT;
      },
    });
    for (const secret of [undefined, '', TICK_SECRET]) {
      const res = await tickWith(app, secret);
      assert.equal(res.statusCode, 404);
      assert.deepEqual(res.json(), {
        error: 'not_found',
        message: 'There is nothing here.',
      });
    }
    assert.equal(ticks, 0);
  });

  it('ignores a secret shorter than 32 characters, with one warning', async t => {
    const warn = t.mock.method(console, 'warn', () => {});
    const short = 'only-31-characters-long-secret!';
    assert.equal(short.length, 31);
    const app = build({ tickSecret: short, tick: async () => REPORT });
    assert.equal((await tickWith(app, short)).statusCode, 404);
    assert.equal((await tickWith(app, short)).statusCode, 404);
    assert.equal(warn.mock.callCount(), 1);
    const [message] = warn.mock.calls[0].arguments;
    assert.ok(String(message).includes('MONITOR_TICK_SECRET'));
    assert.ok(!String(message).includes(short));
  });

  it('refuses a missing or wrong secret', async () => {
    let ticks = 0;
    const app = build({
      tickSecret: TICK_SECRET,
      tick: async () => {
        ticks += 1;
        return REPORT;
      },
    });
    const device = await register(app);
    for (const secret of [
      undefined,
      'wrong',
      `${TICK_SECRET}x`,
      TICK_SECRET.slice(1),
      // A device's credential opens nothing here.
      device.token,
    ]) {
      const res = await tickWith(app, secret);
      assert.equal(res.statusCode, 401);
      assert.deepEqual(res.json(), {
        error: 'unauthorized',
        message: 'The monitor secret is missing or wrong.',
      });
    }
    assert.equal(ticks, 0);
  });

  it('answers 503 on a server that does not run the monitor', async () => {
    const app = build({ tickSecret: TICK_SECRET });
    const res = await tickWith(app, TICK_SECRET);
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.json(), UNAVAILABLE);
  });

  it('accepts at once and runs the tick in the background', async () => {
    let finish = () => {};
    let started = 0;
    const running = new Promise<TickReport>(resolve => {
      finish = () => resolve(REPORT);
    });
    const app = build({
      tickSecret: TICK_SECRET,
      tick: () => {
        started += 1;
        return running;
      },
    });
    // Answered while the tick is still running.
    const res = await tickWith(app, TICK_SECRET);
    assert.equal(res.statusCode, 202);
    assert.deepEqual(res.json(), { accepted: true });
    assert.equal(started, 1);
    finish();
    await running;
  });

  it('waits for the report when asked to', async () => {
    const app = build({ tickSecret: TICK_SECRET, tick: async () => REPORT });
    for (const url of [
      '/internal/monitor/tick?wait=1',
      '/internal/monitor/tick?wait=true',
    ]) {
      const res = await tickWith(app, TICK_SECRET, url);
      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.json(), REPORT);
    }
    assert.equal(
      (await tickWith(app, TICK_SECRET, '/internal/monitor/tick?wait=0'))
        .statusCode,
      202,
    );
  });

  it('takes a scheduler’s JSON body, or none, without minding', async () => {
    const app = build({ tickSecret: TICK_SECRET, tick: async () => REPORT });
    const withBody = await app.inject({
      method: 'POST',
      url: '/internal/monitor/tick?wait=1',
      headers: bearer(TICK_SECRET),
      payload: { source: 'pg_cron' },
    });
    assert.equal(withBody.statusCode, 200);
    const labelledOnly = await app.inject({
      method: 'POST',
      url: '/internal/monitor/tick?wait=1',
      headers: { ...bearer(TICK_SECRET), 'content-type': 'application/json' },
    });
    assert.equal(labelledOnly.statusCode, 200);
  });

  it('checks the secret before it reads the request', async () => {
    const app = build({ tickSecret: TICK_SECRET, tick: async () => REPORT });
    const res = await app.inject({
      method: 'POST',
      url: '/internal/monitor/tick',
      headers: { 'content-type': 'application/json' },
      payload: '{not json',
    });
    assert.equal(res.statusCode, 401);
  });

  it('logs only the kind of failure when a background tick fails', async t => {
    const error = t.mock.method(console, 'error', () => {});
    class TickBroke extends Error {}
    const app = build({
      tickSecret: TICK_SECRET,
      tick: async () => {
        throw new TickBroke('postgres://user:hunter2@db.example.com');
      },
    });
    assert.equal((await tickWith(app, TICK_SECRET)).statusCode, 202);
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(
      error.mock.calls.map(call => call.arguments),
      [['Monitoring tick failed: TickBroke']],
    );
  });

  it('hides the details when a tick it waited for fails', async () => {
    const app = build({
      tickSecret: TICK_SECRET,
      tick: async () => {
        throw new Error('postgres://user:hunter2@db.example.com');
      },
    });
    const res = await tickWith(
      app,
      TICK_SECRET,
      '/internal/monitor/tick?wait=1',
    );
    assert.equal(res.statusCode, 500);
    assert.deepEqual(res.json(), {
      error: 'internal',
      message: 'Something went wrong.',
    });
  });
});

describe('the routes that were there before', () => {
  const trip = {
    origin: { lat: 38.2383, lng: -122.0402 },
    destination: { lat: 38.5593, lng: -121.4237 },
  };

  it('still need no credential', async () => {
    const app = build({ tickSecret: TICK_SECRET });
    const health = await app.inject({ method: 'GET', url: '/health' });
    assert.equal(health.statusCode, 200);
    assert.deepEqual(health.json(), { status: 'ok' });

    const verdict = await app.inject({
      method: 'POST',
      url: '/verdict',
      payload: trip,
    });
    assert.equal(verdict.statusCode, 200);
    assert.deepEqual(Object.keys(verdict.json()).sort(), [
      'slots',
      'source',
      'verdict',
    ]);

    // No place search is wired here; the point is that it is not a 401.
    const places = await app.inject({ method: 'GET', url: '/places?q=sac' });
    assert.equal(places.statusCode, 503);
    assert.equal(places.json().error, 'search_unavailable');

    const route = await app.inject({
      method: 'POST',
      url: '/route',
      payload: trip,
    });
    assert.equal(route.statusCode, 503);
    assert.equal(route.json().error, 'route_unavailable');
  });

  it('answer the same with and without the trip routes', async () => {
    const providers = {
      baseline: new FakeBaselineProvider(() => 35),
      live: new NoLiveConditions(),
    };
    const without = buildServer({ providers, now: () => clock });
    const request = {
      method: 'POST',
      url: '/verdict',
      payload: { ...trip, arriveBy: at(120) },
    } as const;
    assert.deepEqual(
      (await build().inject(request)).json(),
      (await without.inject(request)).json(),
    );
  });

  it('leave an unknown path to Fastify’s own 404, without the not_found code', async () => {
    const res = await build().inject({ method: 'GET', url: '/nothing' });
    assert.equal(res.statusCode, 404);
    assert.notEqual(res.json().error, 'not_found');
  });
});

describe('a server built without the trip service', () => {
  it('has no device, trip or tick routes', async () => {
    const app = buildServer({
      providers: {
        baseline: new FakeBaselineProvider(() => 35),
        live: new NoLiveConditions(),
      },
      tickSecret: TICK_SECRET,
    });
    for (const [method, url] of [
      ['POST', '/devices'],
      ['GET', '/trips'],
      ['PUT', '/trips'],
      ['POST', '/internal/monitor/tick'],
    ] as const) {
      const res = await app.inject({ method, url });
      assert.equal(res.statusCode, 404);
      // What a client takes to mean "this server predates these routes".
      assert.notEqual(res.json().error, 'not_found');
    }
  });
});
