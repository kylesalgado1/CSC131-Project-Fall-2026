import { FetchLike } from '../../util/http';
import { addMinutes } from '../../util/time';
import {
  FallbackBaselineProvider,
  FallbackPathProvider,
} from '../providers/fallback';
import { BaselineProvider } from '../providers/baseline';
import { pathProximity } from '../providers/routing/routeMatch';
import { routeKey } from '../providers/routing/routeKey';
import { TomTomRoutingClient } from '../providers/routing/tomtom';
import { TomTomTraffic } from '../providers/routing/tomtomTraffic';
import { RoutePath, RoutePathProvider } from '../providers/routing/types';
import { BaselineResult, LatLng, Route } from '../types';

const NOW = new Date('2026-10-21T14:00:00Z'); // 07:00 Pacific daylight time
const route: Route = {
  origin: { lat: 38.0, lng: -122.0 },
  destination: { lat: 38.1, lng: -121.9 },
};

/** A straight path from the origin to the destination. */
const line = (from: LatLng, to: LatLng, steps = 10): LatLng[] =>
  Array.from({ length: steps + 1 }, (_, i) => ({
    lat: from.lat + ((to.lat - from.lat) * i) / steps,
    lng: from.lng + ((to.lng - from.lng) * i) / steps,
  }));

interface FakeIncident {
  id: string;
  at: LatLng[];
  magnitude?: number;
  delaySeconds?: number | null;
  road?: string;
  description?: string;
}

interface FakeOptions {
  path?: LatLng[];
  /** Typical minutes for a local minute of day. */
  typical?: (minuteOfDay: number) => number;
  live?: number;
  /** Typical minutes right now. Null leaves the figure out of the response. */
  historicNow?: number | null;
  incidents?: FakeIncident[];
  failIncidents?: boolean;
  failRoute?: boolean;
}

/** A TomTom stand-in that counts the requests it gets. */
function fakeTomTom(options: FakeOptions = {}) {
  const {
    path = line(route.origin, route.destination),
    typical = m => 60 + (m - 420) / 3,
    live = 60,
    historicNow = 60,
    incidents = [],
    failIncidents = false,
    failRoute = false,
  } = options;
  const calls = { routing: 0, incidents: 0, departAt: [] as string[] };

  const fetchFn: FetchLike = async raw => {
    const url = new URL(raw);
    if (url.pathname.includes('calculateRoute')) {
      calls.routing += 1;
      if (failRoute) {
        return { ok: false, status: 503, json: async () => ({}) };
      }
      const departAt = url.searchParams.get('departAt');
      let travel = live;
      let historic: number | null = historicNow;
      if (departAt) {
        calls.departAt.push(departAt);
        const [, hh, mm] = /T(\d{2}):(\d{2})/.exec(departAt)!;
        travel = typical(Number(hh) * 60 + Number(mm));
        historic = travel;
      }
      return {
        ok: true,
        status: 200,
        json: async () => ({
          routes: [
            {
              summary: {
                lengthInMeters: 16093.44,
                travelTimeInSeconds: travel * 60,
                noTrafficTravelTimeInSeconds: 50 * 60,
                ...(historic === null
                  ? {}
                  : { historicTrafficTravelTimeInSeconds: historic * 60 }),
              },
              legs: [
                {
                  points: path.map(p => ({
                    latitude: p.lat,
                    longitude: p.lng,
                  })),
                },
              ],
            },
          ],
        }),
      };
    }
    calls.incidents += 1;
    if (failIncidents) {
      return { ok: false, status: 500, json: async () => ({}) };
    }
    const [minLng, minLat, maxLng, maxLat] = url.searchParams
      .get('bbox')!
      .split(',')
      .map(Number);
    const inBox = incidents.filter(i =>
      i.at.some(
        p =>
          p.lat >= minLat &&
          p.lat <= maxLat &&
          p.lng >= minLng &&
          p.lng <= maxLng,
      ),
    );
    return {
      ok: true,
      status: 200,
      json: async () => ({
        incidents: inBox.map(i => ({
          geometry: {
            coordinates:
              i.at.length === 1
                ? [i.at[0].lng, i.at[0].lat]
                : i.at.map(p => [p.lng, p.lat]),
          },
          properties: {
            id: i.id,
            magnitudeOfDelay: i.magnitude ?? 0,
            delay: i.delaySeconds === undefined ? 0 : i.delaySeconds,
            roadNumbers: i.road ? [i.road] : [],
            events: [{ description: i.description ?? 'Lane closed' }],
          },
        })),
      }),
    };
  };
  const client = new TomTomRoutingClient('KEY', fetchFn, {
    minIntervalMs: 0,
    sleep: async () => undefined,
  });
  return { client, calls };
}

const slots = (start: Date, count = 13) =>
  Array.from({ length: count }, (_, i) => addMinutes(start, i * 15));

describe('TomTomTraffic path', () => {
  it('returns the path with the no-traffic time as free-flow', async () => {
    const { client } = fakeTomTom();
    const path = await new TomTomTraffic(client).getPath(route);
    expect(path.points).toHaveLength(11);
    expect(path.distanceMiles).toBeCloseTo(10);
    expect(path.freeFlowMinutes).toBe(50);
  });

  it('shares one "now" request between the path and the live adjustment', async () => {
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client);
    await traffic.getPath(route);
    await traffic.getAdjustment(route);
    await traffic.getPath(route);
    expect(calls.routing).toBe(1);
  });
});

describe('TomTomTraffic baselines', () => {
  it("uses TomTom's typical time for each departure on the grid", async () => {
    const { client } = fakeTomTom();
    const [at0700, at0730] = await new TomTomTraffic(client).getBaselines(
      route,
      [NOW, addMinutes(NOW, 30)],
    );
    expect(at0700.minutes).toBeCloseTo(60);
    expect(at0730.minutes).toBeCloseTo(70);
  });

  it('interpolates between grid points', async () => {
    const { client } = fakeTomTom();
    const [at0715] = await new TomTomTraffic(client).getBaselines(route, [
      addMinutes(NOW, 15),
    ]);
    expect(at0715.minutes).toBeCloseTo(65);
  });

  it("needs only seven requests for a verdict's 13 slots", async () => {
    const { client, calls } = fakeTomTom();
    const results = await new TomTomTraffic(client).getBaselines(
      route,
      slots(NOW),
    );
    expect(results).toHaveLength(13);
    expect(calls.routing).toBe(7); // 07:00, 07:30, ... 10:00
    expect(results[12].minutes).toBeCloseTo(60 + 180 / 3);
  });

  it('needs one more when the slots do not start on the grid', async () => {
    const { client, calls } = fakeTomTom();
    await new TomTomTraffic(client).getBaselines(
      route,
      slots(addMinutes(NOW, 10)),
    );
    expect(calls.routing).toBe(8);
  });

  it('sends departure times on the local clock', async () => {
    const { client, calls } = fakeTomTom();
    await new TomTomTraffic(client).getBaselines(route, [NOW]);
    expect(calls.departAt).toEqual(['2026-10-21T07:00:00-07:00']);
  });

  it('reports a long history, fully measured', async () => {
    const { client } = fakeTomTom();
    const [result] = await new TomTomTraffic(client).getBaselines(route, [NOW]);
    expect(result.sampleCount).toBe(100);
    expect(result.observedShare).toBe(1);
  });

  it('reuses predictions until they expire', async () => {
    let clock = 0;
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client, {
      predictionTtlMs: 1000,
      now: () => clock,
    });
    await traffic.getBaselines(route, slots(NOW));
    await traffic.getBaselines(route, slots(NOW));
    expect(calls.routing).toBe(7);
    clock = 2000;
    await traffic.getBaselines(route, slots(NOW));
    expect(calls.routing).toBe(14);
  });

  it('reuses predictions for the same weekday and time on another date', async () => {
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client);
    await traffic.getBaselines(route, [NOW]);
    await traffic.getBaselines(route, [addMinutes(NOW, 7 * 24 * 60)]);
    expect(calls.routing).toBe(1);
  });

  it('answers a single time too', async () => {
    const { client } = fakeTomTom();
    const result = await new TomTomTraffic(client).getBaseline(route, NOW);
    expect(result.minutes).toBeCloseTo(60);
  });

  it('fails when TomTom does', async () => {
    const { client } = fakeTomTom({ failRoute: true });
    await expect(
      new TomTomTraffic(client).getBaselines(route, [NOW]),
    ).rejects.toThrow('HTTP 503');
  });
});

describe('TomTomTraffic live adjustment', () => {
  it('is how much slower than typical it is right now', async () => {
    const { client } = fakeTomTom({ live: 70, historicNow: 62 });
    const live = await new TomTomTraffic(client).getAdjustment(route);
    expect(live.available).toBe(true);
    expect(live.extraMinutes).toBeCloseTo(8);
  });

  it('is zero when traffic is lighter than typical', async () => {
    const { client } = fakeTomTom({ live: 55, historicNow: 62 });
    expect(
      (await new TomTomTraffic(client).getAdjustment(route)).extraMinutes,
    ).toBe(0);
  });

  it('is zero when TomTom gives no typical figure to compare with', async () => {
    const { client } = fakeTomTom({ live: 70, historicNow: null });
    expect(
      (await new TomTomTraffic(client).getAdjustment(route)).extraMinutes,
    ).toBe(0);
  });

  it('fails when the route cannot be fetched', async () => {
    const { client } = fakeTomTom({ failRoute: true });
    await expect(
      new TomTomTraffic(client).getAdjustment(route),
    ).rejects.toThrow();
  });
});

describe('TomTomTraffic incidents', () => {
  const onRoute = (i: number) => [line(route.origin, route.destination)[i]];
  const farAway: LatLng[] = [{ lat: 38.05, lng: -122.0 }]; // far from the diagonal
  const incidentsOf = async (opts: FakeOptions) => {
    const { client, calls } = fakeTomTom(opts);
    const live = await new TomTomTraffic(client).getAdjustment(route);
    return { incidents: live.incidents, calls };
  };

  it('reports moderate and major incidents on the route', async () => {
    const { incidents } = await incidentsOf({
      incidents: [
        {
          id: 'a',
          at: onRoute(3),
          magnitude: 3,
          delaySeconds: 1080,
          road: 'I-80 E',
          description: 'Stationary traffic',
        },
        { id: 'b', at: onRoute(5), magnitude: 2, delaySeconds: 120 },
      ],
    });
    expect(incidents).toHaveLength(2);
    expect(incidents[0]).toEqual({
      description: 'Stationary traffic',
      road: 'I-80 E',
      delayMinutes: 18,
    });
  });

  it('reports a long delay even if TomTom rates it small', async () => {
    const { incidents } = await incidentsOf({
      incidents: [{ id: 'a', at: onRoute(3), magnitude: 1, delaySeconds: 600 }],
    });
    expect(incidents).toHaveLength(1);
  });

  it('ignores minor lane closures with no delay', async () => {
    const { incidents } = await incidentsOf({
      incidents: [
        { id: 'a', at: onRoute(3), magnitude: 0, delaySeconds: 0 },
        { id: 'b', at: onRoute(4), magnitude: 1, delaySeconds: null },
      ],
    });
    expect(incidents).toEqual([]);
  });

  it('ignores incidents away from the route', async () => {
    const { incidents } = await incidentsOf({
      incidents: [{ id: 'a', at: farAway, magnitude: 3, delaySeconds: 900 }],
    });
    expect(incidents).toEqual([]);
  });

  it('counts an incident along a stretch that touches the route', async () => {
    const { incidents } = await incidentsOf({
      incidents: [
        {
          id: 'a',
          at: [
            { lat: 38.05, lng: -122.0 }, // away from the route
            line(route.origin, route.destination)[5], // on it
          ],
          magnitude: 2,
          delaySeconds: 300,
        },
      ],
    });
    expect(incidents).toHaveLength(1);
  });

  it('keeps the live delay when the incidents lookup fails', async () => {
    const { client } = fakeTomTom({
      live: 70,
      historicNow: 62,
      failIncidents: true,
    });
    const live = await new TomTomTraffic(client).getAdjustment(route);
    expect(live.available).toBe(true);
    expect(live.extraMinutes).toBeCloseTo(8);
    expect(live.incidents).toEqual([]);
  });

  it('covers a long route in several boxes without double counting', async () => {
    const longPath = line(
      { lat: 37.0, lng: -122.0 },
      { lat: 39.0, lng: -122.0 },
      100,
    );
    const { incidents, calls } = await incidentsOf({
      path: longPath,
      incidents: [
        { id: 'x', at: [longPath[50]], magnitude: 3, delaySeconds: 600 },
      ],
    });
    expect(calls.incidents).toBeGreaterThanOrEqual(5);
    expect(incidents).toHaveLength(1);
  });

  it('reuses incident reports for a few minutes', async () => {
    let clock = 0;
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client, {
      liveTtlMs: 1000,
      now: () => clock,
    });
    await traffic.getAdjustment(route);
    await traffic.getAdjustment(route);
    expect(calls.incidents).toBe(1);
    clock = 2000;
    await traffic.getAdjustment(route);
    expect(calls.incidents).toBe(2);
  });
});

describe('TomTomTraffic incident direction', () => {
  // The route runs north-east. Compass labels: E is 52 degrees off, W is 128.
  const path = line(route.origin, route.destination);
  const reversed = [...path].reverse();
  const onRoute = (i: number) => [path[i]];
  const seen = async (incident: FakeIncident, opts: FakeOptions = {}) => {
    const { client } = fakeTomTom({ incidents: [incident], ...opts });
    return (await new TomTomTraffic(client).getAdjustment(route)).incidents;
  };
  const delay = { magnitude: 3, delaySeconds: 900 };

  it('ignores an incident on the other side of the freeway, by its label', async () => {
    expect(
      await seen({ id: 'a', at: onRoute(4), road: 'I-80 W', ...delay }),
    ).toEqual([]);
    expect(
      await seen({ id: 'b', at: onRoute(4), road: 'CA-113 S', ...delay }),
    ).toEqual([]);
  });

  it('counts an incident heading the same way, by its label', async () => {
    expect(
      await seen({ id: 'a', at: onRoute(4), road: 'I-80 E', ...delay }),
    ).toHaveLength(1);
    expect(
      await seen({ id: 'b', at: onRoute(4), road: 'I-80 N', ...delay }),
    ).toHaveLength(1);
  });

  it('counts the same incident on a route that runs the other way', async () => {
    const incident = { id: 'a', at: onRoute(4), road: 'I-80 W', ...delay };
    expect(await seen(incident, { path: reversed })).toHaveLength(1);
    expect(
      await seen({ ...incident, road: 'I-80 E' }, { path: reversed }),
    ).toEqual([]);
  });

  it('reads the direction from the shape of an incident with no label', async () => {
    const along = [path[3], path[5]]; // runs the same way as the route
    const against = [path[5], path[3]];
    expect(await seen({ id: 'a', at: along, ...delay })).toHaveLength(1);
    expect(await seen({ id: 'b', at: against, ...delay })).toEqual([]);
  });

  it('trusts the label over the shape', async () => {
    const against = [path[5], path[3]];
    expect(
      await seen({ id: 'a', at: against, road: 'I-80 E', ...delay }),
    ).toHaveLength(1);
    const along = [path[3], path[5]];
    expect(
      await seen({ id: 'b', at: along, road: 'I-80 W', ...delay }),
    ).toEqual([]);
  });

  it('counts an incident whose direction cannot be told', async () => {
    const tiny = [
      path[4],
      { lat: path[4].lat - 0.00005, lng: path[4].lng - 0.00005 }, // about 7 m, pointing back
    ];
    expect(await seen({ id: 'a', at: tiny, ...delay })).toHaveLength(1);
    expect(await seen({ id: 'b', at: onRoute(4), ...delay })).toHaveLength(1); // a single point
    expect(
      await seen({ id: 'c', at: onRoute(4), road: 'I-80', ...delay }),
    ).toHaveLength(1); // no direction in the label
  });
});

describe('TomTomTraffic holidays', () => {
  // Veterans Day 2026 is Wednesday 11 November; clocks are on Pacific standard time.
  const VETERANS_7AM = new Date('2026-11-11T15:00:00Z');
  const askedFor = async (at: Date, options = {}) => {
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client, options);
    const [result] = await traffic.getBaselines(route, [at]);
    return { result, asked: calls.departAt };
  };

  it('asks about the coming Saturday on a holiday, at the same time of day', async () => {
    const { asked } = await askedFor(VETERANS_7AM);
    expect(asked).toEqual(['2026-11-14T07:00:00-08:00']);
  });

  it('marks the answer as an estimate, which lowers confidence', async () => {
    const { result } = await askedFor(VETERANS_7AM);
    expect(result.basis).toBe('holiday_estimate');
  });

  it('asks about the day itself when it is an ordinary day', async () => {
    const { result, asked } = await askedFor(NOW); // Wednesday 21 October
    expect(asked).toEqual(['2026-10-21T07:00:00-07:00']);
    expect(result.basis).toBeUndefined();
  });

  it('treats a campus break like a holiday', async () => {
    const campusBreaks = [
      { name: 'Fall break', start: '2026-10-21', end: '2026-10-23' },
    ];
    const { result, asked } = await askedFor(NOW, { campusBreaks });
    expect(asked).toEqual(['2026-10-24T07:00:00-07:00']);
    expect(result.basis).toBe('holiday_estimate');
  });

  it('keeps a holiday that is already a Saturday on that Saturday', async () => {
    // Independence Day 2026 is a Saturday.
    const { result, asked } = await askedFor(new Date('2026-07-04T14:00:00Z'));
    expect(asked).toEqual(['2026-07-04T07:00:00-07:00']);
    expect(result.basis).toBe('holiday_estimate');
  });

  it('shares what it learned with an ordinary Saturday', async () => {
    const { client, calls } = fakeTomTom();
    const traffic = new TomTomTraffic(client);
    await traffic.getBaselines(route, [VETERANS_7AM]);
    await traffic.getBaselines(route, [new Date('2026-11-14T15:00:00Z')]); // Saturday 7 AM
    expect(calls.routing).toBe(1);
  });

  it('flags only the slots that fall on the holiday', async () => {
    const { client } = fakeTomTom();
    // 11:30 PM the night before, then midnight and 12:15 AM on Veterans Day.
    const start = new Date('2026-11-11T07:30:00Z');
    const results = await new TomTomTraffic(client).getBaselines(route, [
      start,
      addMinutes(start, 15),
      addMinutes(start, 30),
      addMinutes(start, 45),
    ]);
    expect(results.map(r => r.basis)).toEqual([
      undefined,
      undefined,
      'holiday_estimate',
      'holiday_estimate',
    ]);
  });
});

describe('routeKey and pathProximity', () => {
  it('gives nearby starts the same key and different trips different keys', () => {
    const nudged = {
      ...route,
      origin: { ...route.origin, lat: route.origin.lat + 0.00002 },
    };
    expect(routeKey(nudged)).toBe(routeKey(route));
    expect(
      routeKey({ origin: route.destination, destination: route.origin }),
    ).not.toBe(routeKey(route));
  });

  it('tests whether points lie near a path', () => {
    const near = pathProximity(line(route.origin, route.destination), 150);
    expect(near([{ lat: 38.05, lng: -121.95 }])).toBe(true);
    expect(near([{ lat: 38.05, lng: -122.0 }])).toBe(false);
    expect(near([])).toBe(false);
    expect(pathProximity([route.origin], 150)([route.origin])).toBe(false);
  });
});

describe('fallbacks', () => {
  const result = (minutes: number): BaselineResult => ({
    minutes,
    sampleCount: 1,
  });
  const baseline = (
    minutes: number,
    fails = false,
  ): BaselineProvider & { calls: number } => {
    const self = {
      calls: 0,
      getBaseline: async () => {
        self.calls += 1;
        if (fails) {
          throw new Error(`down ${minutes}`);
        }
        return result(minutes);
      },
    };
    return self;
  };

  it('uses the primary when it works', async () => {
    const primary = baseline(60);
    const fallback = baseline(50);
    const out = await new FallbackBaselineProvider(
      primary,
      fallback,
    ).getBaseline(route, NOW);
    expect(out.minutes).toBe(60);
    expect(fallback.calls).toBe(0);
  });

  it('uses the fallback, and says so, when the primary fails', async () => {
    const seen: unknown[] = [];
    const out = await new FallbackBaselineProvider(
      baseline(60, true),
      baseline(50),
      e => seen.push(e),
    ).getBaseline(route, NOW);
    expect(out.minutes).toBe(50);
    expect(seen).toHaveLength(1);
  });

  it("throws the primary's error when both fail", async () => {
    await expect(
      new FallbackBaselineProvider(
        baseline(60, true),
        baseline(50, true),
      ).getBaseline(route, NOW),
    ).rejects.toThrow('down 60');
  });

  it('handles several times at once, with or without a batch method', async () => {
    const batch: BaselineProvider = {
      getBaseline: async () => result(1),
      getBaselines: async (_r, ats) => ats.map(() => result(9)),
    };
    const failing = baseline(60, true);
    const viaBatch = await new FallbackBaselineProvider(
      failing,
      batch,
    ).getBaselines(route, slots(NOW, 3));
    expect(viaBatch.map(r => r.minutes)).toEqual([9, 9, 9]);
    const viaSingles = await new FallbackBaselineProvider(
      failing,
      baseline(50),
    ).getBaselines(route, slots(NOW, 3));
    expect(viaSingles.map(r => r.minutes)).toEqual([50, 50, 50]);
  });

  it('does the same for paths', async () => {
    const path = (id: number): RoutePath => ({ points: [], distanceMiles: id });
    const ok = (id: number): RoutePathProvider => ({
      getPath: async () => path(id),
    });
    const bad: RoutePathProvider = {
      getPath: () => Promise.reject(new Error('down')),
    };
    expect(
      (await new FallbackPathProvider(ok(1), ok(2)).getPath(route))
        .distanceMiles,
    ).toBe(1);
    expect(
      (await new FallbackPathProvider(bad, ok(2)).getPath(route)).distanceMiles,
    ).toBe(2);
    await expect(
      new FallbackPathProvider(bad, bad).getPath(route),
    ).rejects.toThrow('down');
  });
});
