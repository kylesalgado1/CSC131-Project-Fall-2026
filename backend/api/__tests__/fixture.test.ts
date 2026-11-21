// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify and PGlite, the in-memory Postgres the fixture uses, cannot load
// inside Jest.
import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';
import {
  buildFixture,
  Fixture,
  FIXTURE_DRIVE_MINUTES,
} from '../../scripts/fixture';
import { Registration } from '../../trips/types';

const START = new Date('2026-11-20T13:00:00.000Z');
const minutes = (n: number) => new Date(START.getTime() + n * 60_000);
const at = (n: number) => minutes(n).toISOString();
const LAB = 'A1B2C3@2026-11-20';
const TOKEN = 'ab'.repeat(32);
const ORIGIN = { lat: 38.2383, lng: -122.0402 };
const DESTINATION = { lat: 38.5593, lng: -121.4237 };

let fixture: Fixture;
let logs: string[];

beforeEach(async () => {
  logs = [];
  fixture = await buildFixture({ now: START, log: line => logs.push(line) });
});

afterEach(async () => {
  await fixture.close();
});

const post = (url: string, payload?: object, token?: string) =>
  fixture.app.inject({
    method: 'POST',
    url,
    payload,
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

const get = (url: string, token?: string) =>
  fixture.app.inject({
    method: 'GET',
    url,
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

const put = (url: string, payload: object, token: string) =>
  fixture.app.inject({
    method: 'PUT',
    url,
    payload,
    headers: { authorization: `Bearer ${token}` },
  });

/** Registers a device with a token and syncs a trip to arrive in three hours. */
const withTrip = async (): Promise<string> => {
  const registered = await post('/devices', { platform: 'ios' });
  assert.equal(registered.statusCode, 201);
  const { token } = registered.json() as Registration;
  const push = await put(
    '/devices/me/push',
    { apnsToken: TOKEN, environment: 'sandbox', authorized: true },
    token,
  );
  assert.equal(push.statusCode, 200);
  const synced = await put(
    '/trips',
    {
      revision: 1,
      trips: [
        {
          id: LAB,
          title: 'Chem lab',
          origin: ORIGIN,
          destination: DESTINATION,
          arriveBy: at(180),
          timeZone: 'America/Los_Angeles',
        },
      ],
    },
    token,
  );
  assert.equal(synced.statusCode, 200);
  return token;
};

const pushes = async () =>
  (await get('/fixture/pushes')).json().pushes as Array<{
    sentAt: string;
    payload: { kind: string; aps: { alert: { title: string; body: string } } };
  }>;

describe('the fixture server', () => {
  it('starts with a clock that stands still, steady traffic and nothing sent', async () => {
    const state = (await get('/fixture/state')).json();
    assert.deepEqual(state, {
      now: START.toISOString(),
      driveMinutes: 25,
      live: { available: false, extraMinutes: 0 },
      pushes: 0,
      trips: [],
    });
    assert.equal(FIXTURE_DRIVE_MINUTES, 25);
    assert.deepEqual((await get('/fixture/pushes')).json(), { pushes: [] });
    assert.equal(fixture.now().getTime(), START.getTime());
  });

  it('refuses to be built in production', async () => {
    await assert.rejects(
      buildFixture({ now: START, env: { NODE_ENV: 'production' } }),
      /must not run in production/,
    );
    // Any other environment is fine.
    const staging = await buildFixture({ env: { NODE_ENV: 'development' } });
    await staging.close();
  });

  it('starts at the real time, to the minute, unless told', async () => {
    const before = Date.now();
    const real = await buildFixture();
    try {
      const now = real.now().getTime();
      assert.equal(now % 60_000, 0);
      assert.ok(now <= Date.now() && now > before - 60_000);
    } finally {
      await real.close();
    }
  });

  it('answers /verdict from its own traffic and labels it as fixture data', async () => {
    const res = await post('/verdict', {
      origin: ORIGIN,
      destination: DESTINATION,
      arriveBy: at(180),
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.deepEqual(body.source, {
      baseline: 'fixture',
      fallback: false,
      live: false,
    });
    assert.equal(body.verdict.action, 'leave_later');
    assert.equal(body.verdict.recommended.driveMinutes, 25);
    assert.equal(body.verdict.generatedAt, START.toISOString());
  });

  it('follows the traffic and the live conditions it is given', async () => {
    const traffic = await post('/fixture/traffic', { driveMinutes: 40 });
    assert.deepEqual(traffic.json(), { driveMinutes: 40 });
    const live = await post('/fixture/live', {
      available: true,
      extraMinutes: 12,
    });
    assert.deepEqual(live.json(), {
      live: { available: true, extraMinutes: 12 },
    });
    const body = (
      await post('/verdict', { origin: ORIGIN, destination: DESTINATION })
    ).json();
    assert.equal(body.source.live, true);
    // 40 typical minutes plus the 12 of live delay, for leaving now.
    assert.equal(body.verdict.leaveNow.driveMinutes, 52);
    const state = (await get('/fixture/state')).json();
    assert.equal(state.driveMinutes, 40);
    assert.deepEqual(state.live, { available: true, extraMinutes: 12 });

    const off = await post('/fixture/live', {
      available: false,
      extraMinutes: 9,
    });
    assert.deepEqual(off.json(), {
      live: { available: false, extraMinutes: 0 },
    });
  });

  it('draws a short straight path, labelled as made up', async () => {
    const res = await post('/route', {
      origin: ORIGIN,
      destination: DESTINATION,
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.source, 'fixture');
    assert.equal(body.fallback, false);
    assert.equal(body.points.length, 9);
    assert.deepEqual(body.points[0], ORIGIN);
    assert.deepEqual(body.points[8], DESTINATION);
    assert.ok(body.distanceMiles > 30 && body.distanceMiles < 50);
  });

  it('finds well-known places by name without going online', async () => {
    const res = await get('/places?q=sac%20state');
    assert.equal(res.statusCode, 200);
    assert.ok(res.json().places.length >= 1);
    assert.deepEqual((await get('/places?q=zzzzqqq')).json(), { places: [] });
  });

  it('reports a monitor that can be counted on, and push that is set up', async () => {
    const token = await withTrip();
    const body = (await get('/trips', token)).json();
    assert.deepEqual(body.monitor, {
      enabled: true,
      dependable: true,
      lastTickAt: null,
    });
    assert.deepEqual(body.push, {
      configured: true,
      registered: true,
      authorized: true,
    });
    assert.equal(body.serverTime, START.toISOString());
  });

  it('has no monitoring tick route of its own to guess at', async () => {
    const res = await post('/internal/monitor/tick');
    assert.equal(res.statusCode, 404);
  });

  it('follows a trip from sync to the leave alert as its clock is moved', async () => {
    // Arrive in three hours with a 25-minute drive: leave in 2 h 15 min.
    const token = await withTrip();
    let trip = (await get('/trips', token)).json().trips[0];
    assert.equal(trip.phase, 'planned');
    assert.equal(trip.recommendation.departAt, at(135));
    assert.equal(trip.recommendation.source.baseline, 'fixture');
    assert.equal(trip.monitoring.startsAt, at(15));
    assert.equal(trip.monitoring.headsUpAt, at(45));

    // To the start of monitoring, a tick a minute.
    const first = await post('/fixture/clock', {
      advanceMinutes: 15,
      tick: true,
    });
    assert.deepEqual(first.json(), {
      now: at(15),
      ticks: 15,
      report: { evaluated: 1, queued: 0, delivered: 0, failed: 0, dropped: 0 },
    });
    trip = (await get('/trips', token)).json().trips[0];
    assert.equal(trip.phase, 'monitoring');
    assert.equal(trip.monitoring.startedAt, at(15));
    assert.deepEqual(await pushes(), []);

    // To the heads-up.
    await post('/fixture/clock', { now: at(44), tick: true });
    assert.deepEqual(await pushes(), []);
    const second = await post('/fixture/clock', {
      advanceMinutes: 1,
      tick: true,
    });
    assert.equal(second.json().report.delivered, 1);
    let sent = await pushes();
    assert.equal(sent.length, 1);
    assert.equal(sent[0].sentAt, at(45));
    assert.equal(sent[0].payload.kind, 'heads_up');
    assert.equal(sent[0].payload.aps.alert.title, 'Heads up: Chem lab');
    assert.equal(
      sent[0].payload.aps.alert.body,
      "Plan to leave around 7:15 AM to arrive by 8:00 AM. We'll keep checking traffic.",
    );
    // The device's token is not kept with it.
    assert.ok(!JSON.stringify(sent).includes(TOKEN));

    // Traffic worsens: the next check moves the departure a slot earlier.
    await post('/fixture/traffic', { driveMinutes: 40 });
    await post('/fixture/clock', { advanceMinutes: 15, tick: true });
    sent = await pushes();
    assert.equal(sent.length, 2);
    assert.equal(sent[1].sentAt, at(60));
    assert.equal(sent[1].payload.kind, 'update');
    assert.equal(
      sent[1].payload.aps.alert.body,
      'Leave at 7:00 AM instead of 7:15 AM. Predicted arrival 7:40 AM; your target is 8:00 AM.',
    );

    // To the departure.
    await post('/fixture/clock', { now: at(120), tick: true });
    sent = await pushes();
    assert.deepEqual(
      sent.map(one => [one.sentAt, one.payload.kind]),
      [
        [at(45), 'heads_up'],
        [at(60), 'update'],
        [at(120), 'leave_now'],
      ],
    );
    assert.equal(
      sent[2].payload.aps.alert.body,
      'Leave at 7:00 AM to arrive around 7:40 AM. Your target is 8:00 AM.',
    );
    trip = (await get('/trips', token)).json().trips[0];
    assert.equal(trip.monitoring.headsUpSentAt, at(45));
    assert.equal(trip.monitoring.leaveAlertSentAt, at(120));

    const state = (await get('/fixture/state')).json();
    assert.equal(state.now, at(120));
    assert.equal(state.pushes, 3);
    assert.deepEqual(state.trips, [
      {
        id: LAB,
        status: 'active',
        phase: 'monitoring',
        arriveBy: at(180),
        departAt: at(120),
        nextCheckAt: at(180),
        headsUpState: 'sent',
        leaveSentAt: at(120),
        lateSentAt: null,
        updateCount: 1,
        alerts: [
          { kind: 'heads_up', status: 'sent', reason: null },
          { kind: 'update', status: 'sent', reason: null },
          { kind: 'leave_now', status: 'sent', reason: null },
        ],
      },
    ]);
    // Nothing in the state says where the trip goes or what it is called.
    assert.ok(!JSON.stringify(state).includes('Chem lab'));
    assert.ok(!JSON.stringify(state).includes('38.2383'));

    // To the arrival target, where monitoring ends.
    await post('/fixture/clock', { advanceMinutes: 60, tick: true });
    trip = (await get('/trips', token)).json().trips[0];
    assert.equal(trip.phase, 'ended');
    assert.equal((await pushes()).length, 3);
    assert.deepEqual(logs, []);
  });

  it('jumps the clock without ticking unless asked to tick, as a server that slept', async () => {
    const token = await withTrip();
    const jumped = await post('/fixture/clock', { advanceMinutes: 50 });
    assert.deepEqual(jumped.json(), {
      now: at(50),
      ticks: 0,
      report: { evaluated: 0, queued: 0, delivered: 0, failed: 0, dropped: 0 },
    });
    assert.deepEqual(await pushes(), []);
    assert.equal((await get('/trips', token)).json().trips[0].phase, 'planned');

    // One tick, 35 minutes after monitoring should have started: it starts
    // now, and the one heads-up goes out as a catch-up.
    const report = await post('/fixture/tick');
    assert.equal(report.statusCode, 200);
    assert.deepEqual(report.json(), {
      evaluated: 1,
      queued: 1,
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    const sent = await pushes();
    assert.equal(sent.length, 1);
    assert.equal(sent[0].payload.kind, 'heads_up');
    assert.equal(sent[0].sentAt, at(50));
    assert.equal(
      (await get('/trips', token)).json().trips[0].phase,
      'monitoring',
    );
  });

  it('ticks at each whole minute on the way, and on arrival', async () => {
    await post('/fixture/clock', {
      now: new Date(START.getTime() + 30_000).toISOString(),
    });
    const res = await post('/fixture/clock', {
      now: new Date(START.getTime() + 150_000).toISOString(),
      tick: true,
    });
    // At 1:00 and 2:00, and at 2:30 where it stops.
    assert.equal(res.json().ticks, 3);
    assert.equal(
      res.json().now,
      new Date(START.getTime() + 150_000).toISOString(),
    );
    assert.equal(
      (await post('/fixture/clock', { advanceMinutes: 0, tick: true })).json()
        .ticks,
      1,
    );
  });

  it('refuses a clock change it cannot make', async () => {
    const bad: Array<[object, string]> = [
      [{}, 'Give either now or advanceMinutes.'],
      [{ now: at(5), advanceMinutes: 5 }, 'Give either now or advanceMinutes.'],
      [{ now: at(-1) }, 'The fixture clock only moves forward.'],
      [
        { advanceMinutes: 1441, tick: true },
        'With tick, the clock moves at most 1440 minutes at a time.',
      ],
    ];
    for (const [payload, message] of bad) {
      const res = await post('/fixture/clock', payload);
      assert.equal(res.statusCode, 400);
      assert.deepEqual(res.json(), { error: 'bad_request', message });
    }
    for (const payload of [
      { advanceMinutes: -5 },
      { advanceMinutes: 'ten' },
      { now: 'tomorrow' },
    ]) {
      assert.equal((await post('/fixture/clock', payload)).statusCode, 400);
    }
    assert.equal((await get('/fixture/state')).json().now, START.toISOString());
  });

  it('refuses traffic and live conditions that make no sense', async () => {
    for (const payload of [{}, { driveMinutes: 0 }, { driveMinutes: 'slow' }]) {
      assert.equal((await post('/fixture/traffic', payload)).statusCode, 400);
    }
    for (const payload of [{}, { available: 'yes' }, { extraMinutes: 5 }]) {
      assert.equal((await post('/fixture/live', payload)).statusCode, 400);
    }
    assert.equal((await get('/fixture/state')).json().driveMinutes, 25);
  });
});
