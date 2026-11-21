// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify depends on an ES-module-only package that Jest cannot load.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { buildServer, MAX_ROUTE_POINTS, samplePath } from '../server';
import { NoLiveConditions } from '../../prediction/providers/live';
import {
  FakeBaselineProvider,
  FakeLiveProvider,
} from '../../prediction/providers/fake';
import { BaselineProvider } from '../../prediction/providers/baseline';
import { NoBaselineCoverageError } from '../../prediction/providers/pems/provider';
import {
  RoutePath,
  RoutePathProvider,
  RoutingError,
} from '../../prediction/providers/routing/types';
import { LatLng, Route } from '../../prediction/types';
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

  describe('the goal follows from whether there is a deadline', () => {
    // A 35 minute drive all day, so only the goal decides when to leave.
    const flat = new FakeBaselineProvider(() => 35);
    const inTwoHours = new Date(NOW.getTime() + 2 * 60 * 60_000).toISOString();

    it('plans to arrive just in time when there is one', async () => {
      const body = (
        await post(serverWith(flat), { ...trip, arriveBy: inTwoHours })
      ).json();
      assert.equal(body.verdict.action, 'leave_later');
      assert.ok(body.verdict.waitMinutes > 60);
      assert.ok(body.verdict.deadline.marginMinutes >= 10);
    });

    it('waits only for clearing traffic when there is not', async () => {
      const body = (await post(serverWith(flat), trip)).json();
      assert.equal(body.verdict.action, 'leave_now');
    });

    it('still lets a client ask for least driving with a deadline', async () => {
      const body = (
        await post(serverWith(flat), {
          ...trip,
          arriveBy: inTwoHours,
          preferences: { goal: 'minimize_time' },
        })
      ).json();
      assert.notEqual(body.verdict.action, 'leave_later');
    });
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

  describe('where the figures came from', () => {
    it('is unknown, with no live data, for providers that do not say', async () => {
      const body = (await post(serverWith(), trip)).json();
      assert.deepEqual(body.source, {
        baseline: 'unknown',
        fallback: false,
        live: false,
      });
    });

    it('names the source a provider gives', async () => {
      const fixture = new FakeBaselineProvider(
        () => 35,
        100,
        undefined,
        'fixture',
      );
      const body = (await post(serverWith(fixture), trip)).json();
      assert.equal(body.source.baseline, 'fixture');
      assert.equal(body.source.fallback, false);
    });

    it('says when a fallback answered and when live data was used', async () => {
      const fromFallback: BaselineProvider = {
        getBaseline: async () => ({
          minutes: 35,
          sampleCount: 100,
          source: 'pems',
          fallback: true,
        }),
      };
      const app = buildServer({
        providers: {
          baseline: fromFallback,
          live: new FakeLiveProvider({
            available: true,
            extraMinutes: 0,
            incidents: [],
          }),
        },
        now: () => NOW,
      });
      assert.deepEqual((await post(app, trip)).json().source, {
        baseline: 'pems',
        fallback: true,
        live: true,
      });
    });
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

describe('POST /route', () => {
  /** Points in a straight line from the trip's start to its destination. */
  const straight = (count: number): LatLng[] =>
    Array.from({ length: count }, (_, i) => ({
      lat:
        trip.origin.lat +
        ((trip.destination.lat - trip.origin.lat) * i) / (count - 1),
      lng:
        trip.origin.lng +
        ((trip.destination.lng - trip.origin.lng) * i) / (count - 1),
    }));
  const serving = (path: RoutePath): RoutePathProvider => ({
    getPath: async () => path,
  });
  const withPaths = (paths?: RoutePathProvider) =>
    buildServer({
      providers: { baseline: clearing, live: new NoLiveConditions() },
      paths,
      now: () => NOW,
    });
  const ask = (app: ReturnType<typeof withPaths>, payload: unknown = trip) =>
    app.inject({ method: 'POST', url: '/route', payload: payload as object });

  it('returns the path, its length and where it came from', async () => {
    const points = straight(5);
    const res = await ask(
      withPaths(
        serving({
          points,
          distanceMiles: 41.5,
          freeFlowMinutes: 48,
          source: 'tomtom',
        }),
      ),
    );
    assert.equal(res.statusCode, 200);
    // The no-traffic time is not part of the answer.
    assert.deepEqual(res.json(), {
      points,
      distanceMiles: 41.5,
      source: 'tomtom',
      fallback: false,
    });
  });

  it('asks for the trip it was given', async () => {
    const asked: Route[] = [];
    const paths: RoutePathProvider = {
      getPath: async route => {
        asked.push(route);
        return { points: straight(2), distanceMiles: 41.5 };
      },
    };
    await ask(withPaths(paths));
    assert.deepEqual(asked, [trip]);
  });

  it('says when the fallback service drew the path', async () => {
    const body = (
      await ask(
        withPaths(
          serving({
            points: straight(3),
            distanceMiles: 40,
            source: 'osrm',
            fallback: true,
          }),
        ),
      )
    ).json();
    assert.equal(body.source, 'osrm');
    assert.equal(body.fallback, true);
  });

  it('calls the source unknown when the service does not say', async () => {
    const body = (
      await ask(withPaths(serving({ points: straight(3), distanceMiles: 40 })))
    ).json();
    assert.equal(body.source, 'unknown');
    assert.equal(body.fallback, false);
  });

  it('sends only coordinates for each point', async () => {
    const tagged = straight(3).map((p, i) => ({ ...p, name: `stop ${i}` }));
    const body = (
      await ask(withPaths(serving({ points: tagged, distanceMiles: 40 })))
    ).json();
    assert.deepEqual(body.points, straight(3));
  });

  it('thins a long path to 400 points, keeping both ends', async () => {
    const points = straight(2500);
    const body = (
      await ask(withPaths(serving({ points, distanceMiles: 41.5 })))
    ).json();
    assert.equal(body.points.length, 400);
    assert.deepEqual(body.points[0], points[0]);
    assert.deepEqual(body.points[399], points[2499]);
    // Still in driving order: the line runs north, so latitude only grows.
    const lats: number[] = body.points.map((p: LatLng) => p.lat);
    assert.ok(lats.every((lat, i) => i === 0 || lat > lats[i - 1]));
  });

  it('sends a path of 400 points or fewer whole', async () => {
    const points = straight(400);
    const body = (
      await ask(withPaths(serving({ points, distanceMiles: 41.5 })))
    ).json();
    assert.deepEqual(body.points, points);
  });

  it('ignores a property it does not know, such as a deadline', async () => {
    const res = await ask(
      withPaths(serving({ points: straight(2), distanceMiles: 41.5 })),
      { ...trip, arriveBy: '2026-10-21T17:00:00Z' },
    );
    assert.equal(res.statusCode, 200);
  });

  it('says so when route geometry is not set up', async () => {
    const res = await ask(withPaths(undefined));
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.json(), {
      error: 'route_unavailable',
      message: 'Route geometry is not set up on this server.',
    });
  });

  it('says when routing is unavailable', async () => {
    const failing: RoutePathProvider = {
      getPath: async () => {
        throw new RoutingError('TomTom request failed: HTTP 503');
      },
    };
    const res = await ask(withPaths(failing));
    assert.equal(res.statusCode, 502);
    assert.equal(res.json().error, 'routing_unavailable');
    assert.ok(!res.body.includes('TomTom'));
  });

  it('treats a path with no line to draw as a routing failure', async () => {
    for (const points of [[], straight(2).slice(0, 1)]) {
      const res = await ask(withPaths(serving({ points, distanceMiles: 0 })));
      assert.equal(res.statusCode, 502);
      assert.equal(res.json().error, 'routing_unavailable');
    }
  });

  it('hides the details of an unexpected error', async () => {
    const broken: RoutePathProvider = {
      getPath: async () => {
        throw new Error('connect to router.secret-host failed');
      },
    };
    const res = await ask(withPaths(broken));
    assert.equal(res.statusCode, 500);
    assert.equal(res.json().error, 'internal');
    assert.ok(!res.body.includes('secret-host'));
  });

  describe('validation', () => {
    const cases: Array<[string, unknown]> = [
      ['a missing origin', { destination: trip.destination }],
      ['a missing destination', { origin: trip.origin }],
      ['a latitude out of range', { ...trip, origin: { lat: 91, lng: 0 } }],
      [
        'a longitude out of range',
        { ...trip, destination: { lat: 0, lng: -181 } },
      ],
      ['a point missing a coordinate', { ...trip, origin: { lat: 38 } }],
      ['a point that is not an object', { ...trip, destination: 'campus' }],
      ['a body that is not an object', [trip.origin, trip.destination]],
    ];
    for (const [name, payload] of cases) {
      it(`rejects ${name}`, async () => {
        const called: Route[] = [];
        const paths: RoutePathProvider = {
          getPath: async route => {
            called.push(route);
            return { points: straight(2), distanceMiles: 41.5 };
          },
        };
        const res = await ask(withPaths(paths), payload);
        assert.equal(res.statusCode, 400);
        assert.equal(res.json().error, 'bad_request');
        assert.equal(called.length, 0);
      });
    }
  });
});

describe('samplePath', () => {
  const numbered = (count: number): LatLng[] =>
    Array.from({ length: count }, (_, i) => ({ lat: i, lng: -i }));
  const indexes = (points: LatLng[]) => points.map(p => p.lat);

  it('returns a path that is short enough as it is', () => {
    const points = numbered(7);
    assert.equal(samplePath(points, 7), points);
    assert.equal(samplePath(points, 10), points);
    assert.deepEqual(samplePath([], 10), []);
  });

  it('keeps the first and last points and strides evenly between', () => {
    assert.deepEqual(indexes(samplePath(numbered(10), 4)), [0, 3, 6, 9]);
    assert.deepEqual(
      indexes(samplePath(numbered(101), 5)),
      [0, 25, 50, 75, 100],
    );
    assert.deepEqual(indexes(samplePath(numbered(8), 2)), [0, 7]);
  });

  it('never repeats or reorders a point, whatever the length', () => {
    for (const length of [401, 402, 799, 800, 801, 1234, 9999]) {
      const picked = indexes(samplePath(numbered(length)));
      assert.equal(picked.length, MAX_ROUTE_POINTS);
      assert.equal(picked[0], 0);
      assert.equal(picked[picked.length - 1], length - 1);
      assert.ok(picked.every((at, i) => i === 0 || at > picked[i - 1]));
    }
  });

  it('spreads the points it keeps evenly', () => {
    const picked = indexes(samplePath(numbered(1234)));
    const gaps = picked.slice(1).map((at, i) => at - picked[i]);
    // 1233 steps over 399 gaps is just over 3 each.
    assert.ok(Math.max(...gaps) - Math.min(...gaps) <= 1);
  });

  it('keeps both ends even when asked for fewer than two points', () => {
    assert.deepEqual(indexes(samplePath(numbered(9), 1)), [0, 8]);
    assert.deepEqual(indexes(samplePath(numbered(9), 0)), [0, 8]);
  });
});
