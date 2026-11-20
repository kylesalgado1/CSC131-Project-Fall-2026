import { FetchLike } from '../../util/http';
import { addMinutes } from '../../util/time';
import { getVerdict } from '../index';
import { predict, predictSlots } from '../predict';
import { BaselineProvider } from '../providers/baseline';
import { FakeBaselineProvider, FakeLiveProvider } from '../providers/fake';
import {
  FallbackBaselineProvider,
  FallbackPathProvider,
} from '../providers/fallback';
import { LiveConditionsProvider, NoLiveConditions } from '../providers/live';
import { PemsBaselineProvider } from '../providers/pems/provider';
import { InMemoryProfileStore } from '../providers/pems/store';
import { ProfileRow } from '../providers/pems/types';
import {
  CachedPathProvider,
  OsrmPathProvider,
} from '../providers/routing/osrm';
import { TomTomClient, TomTomPathProvider } from '../providers/routing/tomtom';
import { TomTomTraffic } from '../providers/routing/tomtomTraffic';
import { RoutePath, RoutePathProvider } from '../providers/routing/types';
import {
  BaselineResult,
  DEFAULT_PREFERENCES,
  Route,
  TripRequest,
} from '../types';

const NOW = new Date('2026-10-21T15:00:00Z'); // 08:00 Pacific, a Wednesday
const route: Route = {
  origin: { lat: 38.0, lng: -122.0 },
  destination: { lat: 38.1, lng: -121.9 },
};
const request: TripRequest = {
  route,
  now: NOW,
  preferences: DEFAULT_PREFERENCES,
};
const times = [NOW, addMinutes(NOW, 15), addMinutes(NOW, 30)];

/** A TomTom stand-in: a 60 minute drive at any hour, or always failing. */
function tomtomClient(fails = false): TomTomClient {
  const fetchFn: FetchLike = async url => {
    if (fails) {
      return { ok: false, status: 503, json: async () => ({}) };
    }
    if (!url.includes('calculateRoute')) {
      return { ok: true, status: 200, json: async () => ({ incidents: [] }) };
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({
        routes: [
          {
            summary: {
              lengthInMeters: 16093.44,
              travelTimeInSeconds: 3600,
              noTrafficTravelTimeInSeconds: 3000,
              historicTrafficTravelTimeInSeconds: 3600,
            },
            legs: [
              {
                points: [route.origin, route.destination].map(p => ({
                  latitude: p.lat,
                  longitude: p.lng,
                })),
              },
            ],
          },
        ],
      }),
    };
  };
  return new TomTomClient('KEY', fetchFn, {
    minIntervalMs: 0,
    sleep: async () => undefined,
  });
}

/** PeMS with one 5 mile station at 60 mph all day: a 5 minute drive. */
function pemsProvider(): PemsBaselineProvider {
  const rows: ProfileRow[] = Array.from({ length: 96 }, (_, bucket) => ({
    stationId: 101,
    dayType: 'weekday',
    bucket,
    avgSpeedMph: 60,
    sampleCount: 40,
    observedShare: 1,
  }));
  return new PemsBaselineProvider(new InMemoryProfileStore(rows), {
    resolve: async () => ({
      segments: [{ stationId: 101, lengthMiles: 5 }],
      uncoveredMiles: 0,
    }),
  });
}

const osrmProvider = () =>
  new OsrmPathProvider('http://osrm.test', async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      code: 'Ok',
      routes: [
        {
          distance: 16093.44,
          duration: 600,
          geometry: {
            coordinates: [
              [-122, 38],
              [-121.9, 38.1],
            ],
          },
        },
      ],
    }),
  }));

describe('the source a baseline says it is from', () => {
  it('is TomTom for every departure TomTom predicts', async () => {
    const traffic = new TomTomTraffic(tomtomClient());
    const batch = await traffic.getBaselines(route, times);
    expect(batch.map(r => r.source)).toEqual(['tomtom', 'tomtom', 'tomtom']);
    expect((await traffic.getBaseline(route, NOW)).source).toBe('tomtom');
  });

  it('is PeMS for every departure PeMS predicts', async () => {
    const pems = pemsProvider();
    const batch = await pems.getBaselines(route, times);
    expect(batch.map(r => r.source)).toEqual(['pems', 'pems', 'pems']);
    expect((await pems.getBaseline(route, NOW)).source).toBe('pems');
  });

  it('is left out by the fake unless it is told one', async () => {
    const plain = await new FakeBaselineProvider(() => 30).getBaseline(
      route,
      NOW,
    );
    expect(plain.source).toBeUndefined();
    const fixture = await new FakeBaselineProvider(
      () => 30,
      100,
      undefined,
      'fixture',
    ).getBaseline(route, NOW);
    expect(fixture.source).toBe('fixture');
    expect(fixture.minutes).toBe(30);
    expect(fixture.sampleCount).toBe(100);
  });

  it('never claims to be a fallback by itself', async () => {
    const results = await Promise.all([
      new TomTomTraffic(tomtomClient()).getBaseline(route, NOW),
      pemsProvider().getBaseline(route, NOW),
      new FakeBaselineProvider(() => 30).getBaseline(route, NOW),
    ]);
    expect(results.map(r => r.fallback)).toEqual([
      undefined,
      undefined,
      undefined,
    ]);
  });
});

describe('the source a path says it is from', () => {
  it('is TomTom for both TomTom path providers', async () => {
    const shared = await new TomTomTraffic(tomtomClient()).getPath(route);
    expect(shared.source).toBe('tomtom');
    expect(shared.fallback).toBeUndefined();
    const plain = await new TomTomPathProvider(tomtomClient()).getPath(route);
    expect(plain.source).toBe('tomtom');
    expect(plain.fallback).toBeUndefined();
  });

  it('is OSRM for the OSRM provider, with or without the cache', async () => {
    const direct = await osrmProvider().getPath(route);
    expect(direct.source).toBe('osrm');
    expect(direct.fallback).toBeUndefined();
    const cached = new CachedPathProvider(osrmProvider());
    expect((await cached.getPath(route)).source).toBe('osrm');
    expect((await cached.getPath(route)).source).toBe('osrm');
  });
});

describe('fallback tagging', () => {
  const primaryResult: BaselineResult = {
    minutes: 60,
    sampleCount: 100,
    observedShare: 1,
    source: 'tomtom',
  };
  const fallbackResult: BaselineResult = {
    minutes: 50,
    sampleCount: 40,
    observedShare: 0.5,
    basis: 'holiday_estimate',
    source: 'pems',
  };
  const working = (result: BaselineResult): BaselineProvider => ({
    getBaseline: async () => result,
  });
  const batching = (result: BaselineResult): BaselineProvider => ({
    getBaseline: async () => result,
    getBaselines: async (_route, departAts) => departAts.map(() => result),
  });
  const down: BaselineProvider = {
    getBaseline: () => Promise.reject(new Error('down')),
  };

  it('leaves a result from the primary exactly as it was', async () => {
    const provider = new FallbackBaselineProvider(
      working(primaryResult),
      working(fallbackResult),
    );
    expect(await provider.getBaseline(route, NOW)).toBe(primaryResult);
    const batch = await provider.getBaselines(route, times);
    expect(batch).toHaveLength(3);
    batch.forEach(result => expect(result).toBe(primaryResult));
    expect(primaryResult.fallback).toBeUndefined();
  });

  it('marks a result from the fallback, and keeps the rest of it', async () => {
    const out = await new FallbackBaselineProvider(
      down,
      working(fallbackResult),
    ).getBaseline(route, NOW);
    expect(out).toStrictEqual({ ...fallbackResult, fallback: true });
  });

  it('marks every result of a batch from the fallback', async () => {
    for (const fallback of [working, batching]) {
      const batch = await new FallbackBaselineProvider(
        down,
        fallback(fallbackResult),
      ).getBaselines(route, times);
      expect(batch).toHaveLength(3);
      batch.forEach(result =>
        expect(result).toStrictEqual({ ...fallbackResult, fallback: true }),
      );
    }
  });

  it("does not change the fallback source's own result", async () => {
    await new FallbackBaselineProvider(
      down,
      batching(fallbackResult),
    ).getBaselines(route, times);
    expect(fallbackResult.fallback).toBeUndefined();
    expect(Object.keys(fallbackResult)).not.toContain('fallback');
  });

  it('marks real PeMS figures when TomTom is down', async () => {
    const batch = await new FallbackBaselineProvider(
      new TomTomTraffic(tomtomClient(true)),
      pemsProvider(),
    ).getBaselines(route, times);
    expect(batch.map(r => [r.source, r.fallback])).toEqual([
      ['pems', true],
      ['pems', true],
      ['pems', true],
    ]);
  });

  describe('for paths', () => {
    const primaryPath: RoutePath = {
      points: [route.origin, route.destination],
      distanceMiles: 10,
      freeFlowMinutes: 50,
      source: 'tomtom',
    };
    const serving = (path: RoutePath): RoutePathProvider => ({
      getPath: async () => path,
    });
    const noPath: RoutePathProvider = {
      getPath: () => Promise.reject(new Error('down')),
    };

    it('leaves a path from the primary exactly as it was', async () => {
      const path = await new FallbackPathProvider(
        serving(primaryPath),
        osrmProvider(),
      ).getPath(route);
      expect(path).toBe(primaryPath);
      expect(primaryPath.fallback).toBeUndefined();
    });

    it('marks a path from the fallback, and keeps the rest of it', async () => {
      const path = await new FallbackPathProvider(
        noPath,
        osrmProvider(),
      ).getPath(route);
      expect(path.fallback).toBe(true);
      expect(path.source).toBe('osrm');
      expect(path.points).toEqual([route.origin, route.destination]);
      expect(path.distanceMiles).toBeCloseTo(10);
      expect(path.freeFlowMinutes).toBeCloseTo(10);
    });

    it('does not mark the copy a cache keeps for later', async () => {
      const cached = new CachedPathProvider(osrmProvider());
      const viaFallback = await new FallbackPathProvider(
        noPath,
        cached,
      ).getPath(route);
      expect(viaFallback.fallback).toBe(true);
      // Asked directly, the same cached path is nobody's fallback.
      expect((await cached.getPath(route)).fallback).toBeUndefined();
    });
  });
});

describe('predict', () => {
  const liveOn = new FakeLiveProvider({
    available: true,
    extraMinutes: 0,
    incidents: [],
  });
  const fixture = () =>
    new FakeBaselineProvider(() => 30, 100, undefined, 'fixture');

  it('reports TomTom with live conditions when TomTom answers', async () => {
    const traffic = new TomTomTraffic(tomtomClient());
    const { slots, source } = await predict(request, {
      baseline: traffic,
      live: traffic,
    });
    expect(source).toEqual({ baseline: 'tomtom', fallback: false, live: true });
    expect(slots).toHaveLength(13);
    expect(slots[0].driveMinutes).toBe(60);
  });

  it('reports PeMS, with no live conditions, when PeMS is the source', async () => {
    const { slots, source } = await predict(request, {
      baseline: pemsProvider(),
      live: new NoLiveConditions(),
    });
    expect(source).toEqual({ baseline: 'pems', fallback: false, live: false });
    expect(slots[0].driveMinutes).toBe(5);
  });

  it('reports the fallback when the primary source fails', async () => {
    const tomtomDown = new TomTomTraffic(tomtomClient(true));
    const { slots, source } = await predict(request, {
      baseline: new FallbackBaselineProvider(tomtomDown, pemsProvider()),
      live: tomtomDown,
    });
    // TomTom is also the live feed, so that is gone too.
    expect(source).toEqual({ baseline: 'pems', fallback: true, live: false });
    expect(slots[0].driveMinutes).toBe(5);
  });

  it('reports no fallback when the primary source of a pair answers', async () => {
    const traffic = new TomTomTraffic(tomtomClient());
    const { source } = await predict(request, {
      baseline: new FallbackBaselineProvider(traffic, pemsProvider()),
      live: traffic,
    });
    expect(source).toEqual({ baseline: 'tomtom', fallback: false, live: true });
  });

  it('reports live conditions as unavailable when the feed fails', async () => {
    const failing: LiveConditionsProvider = {
      getAdjustment: () => Promise.reject(new Error('feed down')),
    };
    const { source } = await predict(request, {
      baseline: fixture(),
      live: failing,
    });
    expect(source).toEqual({
      baseline: 'fixture',
      fallback: false,
      live: false,
    });
  });

  it('reports live conditions as the feed itself describes them', async () => {
    const liveOff = new FakeLiveProvider({
      available: false,
      extraMinutes: 0,
      incidents: [],
    });
    const on = await predict(request, { baseline: fixture(), live: liveOn });
    const off = await predict(request, { baseline: fixture(), live: liveOff });
    expect(on.source.live).toBe(true);
    expect(off.source.live).toBe(false);
  });

  it('calls the baseline unknown when the source does not say', async () => {
    const { source } = await predict(request, {
      baseline: new FakeBaselineProvider(() => 30),
      live: liveOn,
    });
    expect(source).toEqual({
      baseline: 'unknown',
      fallback: false,
      live: true,
    });
  });

  it('gives the same slots as predictSlots', async () => {
    const providers = { baseline: fixture(), live: liveOn };
    const { slots } = await predict(request, providers);
    expect(await predictSlots(request, providers)).toEqual(slots);
  });
});

describe('getVerdict', () => {
  it('passes the source on with the slots and the verdict', async () => {
    const result = await getVerdict(request, {
      baseline: new FallbackBaselineProvider(
        new TomTomTraffic(tomtomClient(true)),
        pemsProvider(),
      ),
      live: new NoLiveConditions(),
    });
    expect(result.source).toEqual({
      baseline: 'pems',
      fallback: true,
      live: false,
    });
    expect(result.slots).toHaveLength(13);
    expect(result.verdict.action).toBe('leave_now');
  });
});
