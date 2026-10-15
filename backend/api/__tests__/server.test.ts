// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify depends on an ES-module-only package that Jest cannot load.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { buildServer } from '../server';
import { NoLiveConditions } from '../../prediction/providers/live';
import { FakeBaselineProvider } from '../../prediction/providers/fake';
import { BaselineProvider } from '../../prediction/providers/baseline';
import { NoBaselineCoverageError } from '../../prediction/providers/pems/provider';
import { RoutingError } from '../../prediction/providers/routing/types';

const NOW = new Date('2026-10-21T15:00:00Z');
const trip = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
};

// Congested for the first hour, then 35 minutes.
const clearing = new FakeBaselineProvider(departAt => {
  const offset = (departAt.getTime() - NOW.getTime()) / 60_000;
  return offset < 60 ? 70 - offset / 2 : 35;
});

const serverWith = (baseline: BaselineProvider = clearing) =>
  buildServer({
    providers: { baseline, live: new NoLiveConditions() },
    now: () => NOW,
  });

const post = (app: ReturnType<typeof serverWith>, payload: unknown) =>
  app.inject({ method: 'POST', url: '/verdict', payload: payload as object });

describe('GET /health', () => {
  it('reports ok', async () => {
    const res = await serverWith().inject({ method: 'GET', url: '/health' });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), { status: 'ok' });
  });
});

describe('POST /verdict', () => {
  it('returns the verdict and the slots behind it', async () => {
    const res = await post(serverWith(), {
      ...trip,
      preferences: { goal: 'minimize_time' },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.verdict.action, 'wait');
    assert.equal(body.verdict.waitMinutes, 60);
    assert.equal(body.verdict.minutesSaved, 35);
    assert.equal(body.slots.length, 13);
  });

  it('sends dates as ISO strings and uses the server clock', async () => {
    const body = (await post(serverWith(), trip)).json();
    assert.equal(body.verdict.generatedAt, NOW.toISOString());
    assert.equal(body.verdict.leaveNow.departAt, NOW.toISOString());
    assert.equal(body.slots[1].departAt, '2026-10-21T15:15:00.000Z');
  });

  it('defaults to a balanced goal', async () => {
    const implicit = (await post(serverWith(), trip)).json();
    const explicit = (
      await post(serverWith(), { ...trip, preferences: { goal: 'balance' } })
    ).json();
    assert.deepEqual(implicit, explicit);
  });

  it('ignores a client-supplied clock', async () => {
    const body = (
      await post(serverWith(), { ...trip, now: '2020-01-01T00:00:00Z' })
    ).json();
    assert.equal(body.verdict.generatedAt, NOW.toISOString());
  });

  it('honors a maximum wait', async () => {
    const body = (
      await post(serverWith(), {
        ...trip,
        preferences: { goal: 'minimize_time', maxWaitMinutes: 30 },
      })
    ).json();
    assert.ok(body.verdict.waitMinutes <= 30);
  });

  it('honors an arrival deadline', async () => {
    // Leaving now takes 70 minutes, arriving 16:10Z. A 15:30Z deadline cannot
    // be met by any departure.
    const body = (
      await post(serverWith(), { ...trip, arriveBy: '2026-10-21T15:30:00Z' })
    ).json();
    assert.equal(body.verdict.action, 'leave_now');
    assert.equal(body.verdict.lateByMinutes, 40);
    assert.equal(
      body.verdict.reason,
      'Leave now, you may be late by about 40 minutes.',
    );
  });

  describe('validation', () => {
    const cases: Array<[string, unknown]> = [
      ['a missing destination', { origin: trip.origin }],
      ['a latitude out of range', { ...trip, origin: { lat: 91, lng: 0 } }],
      ['a longitude out of range', { ...trip, origin: { lat: 0, lng: 181 } }],
      ['a point missing a coordinate', { ...trip, origin: { lat: 38 } }],
      ['an unknown goal', { ...trip, preferences: { goal: 'fastest' } }],
      [
        'a maximum wait under 15 minutes',
        { ...trip, preferences: { maxWaitMinutes: 10 } },
      ],
      [
        'a maximum wait over 3 hours',
        { ...trip, preferences: { maxWaitMinutes: 240 } },
      ],
      [
        'a negative minimum saving',
        { ...trip, preferences: { minSavingsMinutes: -1 } },
      ],
      ['a malformed deadline', { ...trip, arriveBy: 'tomorrow' }],
    ];
    for (const [name, payload] of cases) {
      it(`rejects ${name}`, async () => {
        const res = await post(serverWith(), payload);
        assert.equal(res.statusCode, 400);
        assert.equal(res.json().error, 'bad_request');
      });
    }
  });

  describe('failures', () => {
    const failing = (error: Error): BaselineProvider => ({
      getBaseline: async () => {
        throw error;
      },
    });

    it('says when there is no data for the route', async () => {
      const res = await post(
        serverWith(failing(new NoBaselineCoverageError())),
        trip,
      );
      assert.equal(res.statusCode, 422);
      assert.equal(res.json().error, 'no_coverage');
    });

    it('says when routing is unavailable', async () => {
      const res = await post(
        serverWith(failing(new RoutingError('OSRM request failed: HTTP 503'))),
        trip,
      );
      assert.equal(res.statusCode, 502);
      assert.equal(res.json().error, 'routing_unavailable');
      assert.ok(!res.body.includes('OSRM'));
    });

    it('hides the details of an unexpected error', async () => {
      const res = await post(
        serverWith(failing(new Error('connection to db.secret-host failed'))),
        trip,
      );
      assert.equal(res.statusCode, 500);
      assert.equal(res.json().error, 'internal');
      assert.ok(!res.body.includes('secret-host'));
    });
  });
});
