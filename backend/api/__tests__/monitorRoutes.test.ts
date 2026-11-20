// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify and PGlite, the in-memory Postgres these tests use, cannot load
// inside Jest.
//
// The API with a real monitor behind it: the tick route, what clients are
// told about the monitor, and a trip followed from sync to "I've left" over
// HTTP. The route's own rules (secrets, 202 and ?wait) are in trips.test.ts.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { buildServer } from '../server';
import { Database } from '../../db/db';
import {
  LAB,
  migratedDatabase,
  resetDatabase,
  t,
  TOKEN,
  tripInput,
  World,
  WorldOptions,
} from '../../trips/__tests__/harness';
import { Registration } from '../../trips/types';

const TICK_SECRET = 'tick-secret-'.repeat(3);
const iso = (clock: string): string => t(clock).toISOString();
const UNAVAILABLE = {
  error: 'monitoring_unavailable',
  message: 'Trip monitoring is not set up on this server.',
};
const NOTHING = {
  evaluated: 0,
  queued: 0,
  delivered: 0,
  failed: 0,
  dropped: 0,
};

let db: Database;

// One database for the whole file, emptied before each test.
before(async () => {
  db = await migratedDatabase();
});

after(async () => {
  await db.close();
});

beforeEach(async () => {
  await resetDatabase(db);
});

/** A server wired as serve.ts wires it, on the test's clock and traffic. */
const serverAt = (
  now: Date,
  options: Partial<WorldOptions> & { tickSecret?: string } = {},
) => {
  const { tickSecret = TICK_SECRET, ...rest } = options;
  const w = new World(db, { now, ...rest });
  const app = buildServer({
    providers: w.traffic.providers(),
    now: () => w.clock,
    trips: w.service,
    tickSecret: tickSecret || undefined,
    tick: w.externalTick,
  });
  return { w, app };
};

type App = ReturnType<typeof serverAt>['app'];

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

const tick = (app: App, secret = TICK_SECRET, wait = true) =>
  app.inject({
    method: 'POST',
    url: `/internal/monitor/tick${wait ? '?wait=1' : ''}`,
    headers: bearer(secret),
  });

/** Registers a device with a token and syncs one trip, all over HTTP. */
const withTrip = async (app: App): Promise<string> => {
  const registered = await app.inject({
    method: 'POST',
    url: '/devices',
    payload: { platform: 'ios' },
  });
  assert.equal(registered.statusCode, 201);
  const { token } = registered.json() as Registration;
  const push = await app.inject({
    method: 'PUT',
    url: '/devices/me/push',
    headers: bearer(token),
    payload: { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
  });
  assert.equal(push.statusCode, 200);
  const synced = await app.inject({
    method: 'PUT',
    url: '/trips',
    headers: bearer(token),
    payload: { revision: 1, trips: [tripInput()] },
  });
  assert.equal(synced.statusCode, 200);
  return token;
};

const trips = async (app: App, token: string) =>
  (
    await app.inject({ method: 'GET', url: '/trips', headers: bearer(token) })
  ).json();

describe('POST /internal/monitor/tick with a monitor behind it', () => {
  it('does not exist without a secret, refuses a wrong one, and answers the report to the right one', async () => {
    const none = serverAt(t('05:00'), { tickSecret: '' });
    const missing = await tick(none.app);
    assert.equal(missing.statusCode, 404);
    assert.equal(missing.json().error, 'not_found');

    await resetDatabase(db);
    const { w, app } = serverAt(t('05:00'));
    await withTrip(app);
    w.clock = t('06:00');
    const wrong = await tick(app, 'wrong-secret-'.repeat(3));
    assert.equal(wrong.statusCode, 401);
    assert.equal(wrong.json().error, 'unauthorized');
    // Nothing ran.
    assert.deepEqual(w.push.attempts, []);

    const right = await tick(app);
    assert.equal(right.statusCode, 200);
    // The 6:00 check, the heads-up it queued, and its delivery.
    assert.deepEqual(right.json(), {
      evaluated: 1,
      queued: 1,
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    assert.deepEqual((await tick(app)).json(), NOTHING);
  });

  it('answers 202 at once and runs the tick behind the answer', async () => {
    const { w, app } = serverAt(t('05:00'));
    await withTrip(app);
    w.clock = t('06:00');
    const accepted = await tick(app, TICK_SECRET, false);
    assert.equal(accepted.statusCode, 202);
    assert.deepEqual(accepted.json(), { accepted: true });
    // The monitor does one thing at a time, so this waits for that tick.
    await w.monitor.deliverDue();
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    assert.deepEqual(w.logs, []);
  });

  it('answers 503 on a server where the worker is not switched on', async () => {
    const { w, app } = serverAt(t('05:00'), { enabled: false });
    const token = await withTrip(app);
    w.clock = t('06:00');
    for (const wait of [true, false]) {
      const res = await tick(app, TICK_SECRET, wait);
      assert.equal(res.statusCode, 503);
      assert.deepEqual(res.json(), UNAVAILABLE);
    }
    assert.deepEqual(w.push.attempts, []);
    // The trip was stored, and nothing was planned for it: the app is told
    // that nothing is watching it, and is not shown a plan as if it were.
    assert.equal(w.traffic.asks, 0);
    const body = await trips(app, token);
    assert.equal(body.trips[0].phase, 'planning');
    assert.equal(body.trips[0].recommendation, null);
    assert.equal(body.trips[0].monitoring.lastAlert, null);
    assert.deepEqual(body.monitor, {
      enabled: false,
      dependable: false,
      lastTickAt: null,
    });
    assert.deepEqual(await w.outbox(), []);
    // /verdict still answers, which is what the app falls back on.
    const verdict = await app.inject({
      method: 'POST',
      url: '/verdict',
      payload: {
        origin: tripInput().origin,
        destination: tripInput().destination,
        arriveBy: iso('08:00'),
      },
    });
    assert.equal(verdict.statusCode, 200);
    assert.equal(verdict.json().verdict.action, 'leave_later');
  });
});

describe('the monitor a client is told about, with a monitor behind it', () => {
  it('is dependable only while something outside keeps ticking it', async () => {
    const { w, app } = serverAt(t('05:00'));
    const token = await withTrip(app);
    assert.deepEqual((await trips(app, token)).monitor, {
      enabled: true,
      dependable: false,
      lastTickAt: null,
    });

    // The server's own ticker is not enough: it stops when the host sleeps.
    await w.tickAt(t('05:01'));
    assert.deepEqual((await trips(app, token)).monitor, {
      enabled: true,
      dependable: false,
      lastTickAt: iso('05:01'),
    });

    // A scheduler calls the tick route.
    w.clock = t('05:02');
    assert.equal((await tick(app)).statusCode, 200);
    assert.deepEqual((await trips(app, token)).monitor, {
      enabled: true,
      dependable: true,
      lastTickAt: iso('05:02'),
    });
    const one = await app.inject({
      method: 'GET',
      url: `/trips/${encodeURIComponent(LAB)}`,
      headers: bearer(token),
    });
    assert.equal(one.json().monitor.dependable, true);

    // It stops calling. Three minutes later the claim lapses.
    w.clock = t('05:05');
    assert.equal((await trips(app, token)).monitor.dependable, true);
    w.clock = t('05:06');
    assert.deepEqual((await trips(app, token)).monitor, {
      enabled: true,
      dependable: false,
      lastTickAt: iso('05:02'),
    });
  });

  it('is dependable without a scheduler on a server declared always on', async () => {
    const { app } = serverAt(t('05:00'), { alwaysOn: true });
    const token = await withTrip(app);
    assert.deepEqual((await trips(app, token)).monitor, {
      enabled: true,
      dependable: true,
      lastTickAt: null,
    });
  });
});

describe('a trip followed over HTTP', () => {
  it('is planned at sync, alerted by ticks, and left alone after "I’ve left"', async () => {
    const { w, app } = serverAt(t('05:00'));
    const token = await withTrip(app);
    let body = await trips(app, token);
    assert.equal(body.trips[0].phase, 'planned');
    assert.equal(body.trips[0].recommendation.departAt, iso('07:30'));
    assert.deepEqual(body.push, {
      configured: true,
      registered: true,
      authorized: true,
    });

    // A scheduler ticks every minute until 6:30.
    for (let minute = 1; minute <= 90; minute++) {
      w.clock = new Date(t('05:00').getTime() + minute * 60_000);
      assert.equal((await tick(app)).statusCode, 200);
    }
    body = await trips(app, token);
    assert.equal(body.serverTime, iso('06:30'));
    assert.equal(body.trips[0].phase, 'monitoring');
    assert.equal(body.trips[0].monitoring.startedAt, iso('05:30'));
    assert.equal(body.trips[0].monitoring.headsUpSentAt, iso('06:00'));
    assert.deepEqual(body.trips[0].monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'sent',
      at: iso('06:00'),
    });
    assert.equal(body.monitor.dependable, true);

    const left = await app.inject({
      method: 'POST',
      url: `/trips/${encodeURIComponent(LAB)}/departed`,
      headers: bearer(token),
      payload: { arriveBy: iso('08:00') },
    });
    assert.equal(left.statusCode, 200);
    assert.equal(left.json().trip.phase, 'departed');

    for (let minute = 91; minute <= 185; minute++) {
      w.clock = new Date(t('05:00').getTime() + minute * 60_000);
      await tick(app);
    }
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    body = await trips(app, token);
    assert.equal(body.trips[0].phase, 'departed');
    assert.equal(body.trips[0].recommendation, null);
  });
});
