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
import { Place, PlaceSearch, SearchError } from '../../places/types';

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

  it('defaults to the least-driving goal', async () => {
    const implicit = (await post(serverWith(), trip)).json();
    const explicit = (
      await post(serverWith(), {
        ...trip,
        preferences: { goal: 'minimize_time' },
      })
    ).json();
    assert.deepEqual(implicit, explicit);
  });

  it('no longer accepts the removed balance goal', async () => {
    const response = await post(serverWith(), {
      ...trip,
      preferences: { goal: 'balance' },
    });
    assert.equal(response.statusCode, 400);
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

  it('plans a departure for a far-off deadline', async () => {
    const deadline = new Date(NOW.getTime() + 5 * 60 * 60_000).toISOString();
    const body = (
      await post(serverWith(), { ...trip, arriveBy: deadline })
    ).json();
    assert.equal(body.verdict.action, 'leave_later');
    assert.ok(body.verdict.waitMinutes > 180);
    assert.ok(
      Date.parse(body.verdict.recommended.arriveAt) <= Date.parse(deadline),
    );
    assert.equal(body.verdict.deadline.arriveBy, deadline);
    assert.ok(body.slots.length > 13, 'the forecast reaches the deadline');
  });

  it('honors a leave-by time', async () => {
    // Without it, waiting 60 minutes saves the most.
    const limit = new Date(NOW.getTime() + 30 * 60_000).toISOString();
    const body = (
      await post(serverWith(), {
        ...trip,
        leaveBy: limit,
        preferences: { goal: 'minimize_time' },
      })
    ).json();
    assert.equal(body.verdict.action, 'wait');
    assert.ok(body.verdict.waitMinutes <= 30);
  });

  it('answers leave now when the leave-by time has passed', async () => {
    const past = new Date(NOW.getTime() - 60_000).toISOString();
    const body = (
      await post(serverWith(), {
        ...trip,
        leaveBy: past,
        preferences: { goal: 'minimize_time' },
      })
    ).json();
    assert.equal(body.verdict.action, 'leave_now');
  });

  it('starts the forecast at a leave-after time', async () => {
    const after = new Date(NOW.getTime() + 2 * 60 * 60_000).toISOString();
    const body = (
      await post(serverWith(), { ...trip, leaveAfter: after })
    ).json();
    assert.equal(body.slots[0].departAt, after);
    assert.equal(body.verdict.leaveNow.departAt, after);
  });

  it('ignores a leave-after time that has passed', async () => {
    const past = new Date(NOW.getTime() - 60_000).toISOString();
    const body = (
      await post(serverWith(), { ...trip, leaveAfter: past })
    ).json();
    assert.equal(body.slots[0].departAt, NOW.toISOString());
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
      ['a malformed leave-by time', { ...trip, leaveBy: 'soon' }],
      ['a malformed leave-after time', { ...trip, leaveAfter: 'later' }],
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

describe('GET /places', () => {
  const place: Place = {
    id: 'a',
    name: 'California State University, Sacramento',
    address: '6000 J Street, Sacramento, CA 95819',
    lat: 38.56,
    lng: -121.42,
  };
  const asked: Array<[string, unknown]> = [];
  const places: PlaceSearch = {
    search: async (query, near) => {
      asked.push([query, near]);
      return [place];
    },
  };
  const withPlaces = (search?: PlaceSearch) =>
    buildServer({
      providers: { baseline: clearing, live: new NoLiveConditions() },
      places: search,
      now: () => NOW,
    });
  const get = (app: ReturnType<typeof withPlaces>, url: string) =>
    app.inject({ method: 'GET', url });

  it('returns matching places', async () => {
    const res = await get(withPlaces(places), '/places?q=sac%20state');
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), { places: [place] });
  });

  it('passes the text and the location hint on', async () => {
    asked.length = 0;
    await get(withPlaces(places), '/places?q=raleys&lat=38.2383&lng=-122.0402');
    assert.deepEqual(asked, [['raleys', { lat: 38.2383, lng: -122.0402 }]]);
    asked.length = 0;
    await get(withPlaces(places), '/places?q=raleys');
    assert.deepEqual(asked, [['raleys', undefined]]);
  });

  for (const [name, url] of [
    ['no text', '/places'],
    ['one character', '/places?q=s'],
    ['text that is too long', `/places?q=${'a'.repeat(101)}`],
    ['a latitude without a longitude', '/places?q=sac&lat=38'],
    ['a longitude without a latitude', '/places?q=sac&lng=-121'],
    ['a latitude out of range', '/places?q=sac&lat=91&lng=0'],
  ]) {
    it(`rejects ${name}`, async () => {
      const res = await get(withPlaces(places), url);
      assert.equal(res.statusCode, 400);
    });
  }

  it('ignores a parameter it does not know, so callers cannot ask for more', async () => {
    const res = await get(withPlaces(places), '/places?q=sac&limit=50');
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().places.length, 1);
  });

  it('says so when place search is not set up', async () => {
    const res = await get(withPlaces(undefined), '/places?q=sac');
    assert.equal(res.statusCode, 503);
    assert.equal(res.json().error, 'search_unavailable');
  });

  it('hides the details when the search service fails', async () => {
    const failing: PlaceSearch = {
      search: async () => {
        throw new SearchError('TomTom request failed: HTTP 503');
      },
    };
    const res = await get(withPlaces(failing), '/places?q=sac');
    assert.equal(res.statusCode, 502);
    assert.equal(res.json().error, 'search_unavailable');
    assert.ok(!res.body.includes('TomTom'));
  });
});
