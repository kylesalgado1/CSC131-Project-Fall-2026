import {
  InMemoryStationSource,
  PathRouteResolver,
} from '../providers/routing/pathResolver';
import {
  CachedPathProvider,
  OsrmPathProvider,
} from '../providers/routing/osrm';
import { matchStations } from '../providers/routing/routeMatch';
import { RoutePath, RoutePathProvider } from '../providers/routing/types';
import { PemsStation } from '../providers/pems/types';
import { LatLng, Route } from '../types';

// A straight eastbound road at latitude 38.5, about 0.0865 degrees of
// longitude per 5 miles at this latitude.
const LAT = 38.5;
const LNG_PER_MILE = 0.01845;
const at = (miles: number, northMeters = 0): LatLng => ({
  lat: LAT + northMeters / 110_574,
  lng: -122 + miles * LNG_PER_MILE,
});
const road = (miles: number): LatLng[] =>
  Array.from({ length: miles * 10 + 1 }, (_, i) => at(i / 10));

const station = (
  id: number,
  miles: number,
  over: Partial<PemsStation> = {},
  northMeters = 0,
): PemsStation => ({
  id,
  freeway: '80',
  direction: 'E',
  lengthMiles: 1,
  ...at(miles, northMeters),
  latitude: at(miles, northMeters).lat,
  longitude: at(miles, northMeters).lng,
  ...over,
});

describe('matchStations', () => {
  it('finds stations along the path, in driving order', () => {
    const result = matchStations(road(10), [
      station(3, 7),
      station(1, 1),
      station(2, 4),
    ]);
    expect(result.segments.map(s => s.stationId)).toEqual([1, 2, 3]);
  });

  it('gives each station the road halfway to its neighbors', () => {
    const stations = [station(1, 1), station(2, 4), station(3, 7)];
    const result = matchStations(road(10), stations);
    // Station 2 stands for miles 2.5 to 5.5.
    expect(result.segments[1].lengthMiles).toBeCloseTo(3, 1);
    // A tighter same-road cap stops each side 1 mile out.
    const capped = matchStations(road(10), stations, { maxFreewayGapMiles: 2 });
    expect(capped.segments[1].lengthMiles).toBeCloseTo(2, 1);
  });

  it('counts the rest of the path as uncovered', () => {
    const result = matchStations(road(10), [station(1, 4), station(2, 6)], {
      maxGapMiles: 10,
    });
    const covered = result.segments.reduce((s, x) => s + x.lengthMiles, 0);
    // Station 1 covers 3.5-5, station 2 covers 5-6.5 (own half-length each end).
    expect(covered).toBeCloseTo(3, 1);
    expect(covered + result.uncoveredMiles).toBeCloseTo(10, 1);
  });

  it('ignores stations far from the path', () => {
    const result = matchStations(
      road(10),
      [station(1, 3), station(2, 5, {}, 500)], // 500 m north of the road
    );
    expect(result.segments.map(s => s.stationId)).toEqual([1]);
  });

  it('ignores the opposite carriageway', () => {
    const result = matchStations(road(10), [
      station(1, 3),
      station(2, 3, { direction: 'W' }, 20),
    ]);
    expect(result.segments.map(s => s.stationId)).toEqual([1]);
  });

  it('ignores a freeway that crosses at a right angle', () => {
    const result = matchStations(road(10), [
      station(1, 3),
      station(2, 5, { direction: 'N' }, 30),
      station(3, 5, { direction: 'S' }, 30),
    ]);
    expect(result.segments.map(s => s.stationId)).toEqual([1]);
  });

  it('accepts a freeway running at an angle to the compass', () => {
    // Heading northeast: a station labeled N or E both agree.
    const diagonal: LatLng[] = Array.from({ length: 101 }, (_, i) => ({
      lat: LAT + i * 0.001,
      lng: -122 + i * 0.001 * 1.27,
    }));
    const onPath = (id: number, i: number, direction: string): PemsStation => ({
      id,
      freeway: '80',
      direction,
      lengthMiles: 1,
      latitude: diagonal[i].lat,
      longitude: diagonal[i].lng,
    });
    const result = matchStations(diagonal, [
      onPath(1, 20, 'N'),
      onPath(2, 40, 'E'),
      onPath(3, 60, 'S'),
      onPath(4, 80, 'W'),
    ]);
    expect(result.segments.map(s => s.stationId)).toEqual([1, 2]);
  });

  it('fills a gap on the same freeway from the neighboring stations', () => {
    // 10 miles between stations on the same road: filled up to the 8 mile cap.
    const result = matchStations(road(14), [station(1, 2), station(2, 12)]);
    const covered = result.segments.reduce((s, x) => s + x.lengthMiles, 0);
    // 4 miles on each side of the gap, plus 0.5 mile at each outer end.
    expect(covered).toBeCloseTo(9, 1);
    expect(result.uncoveredMiles).toBeCloseTo(5, 1);
  });

  it('fills a gap between different roads only a little', () => {
    const result = matchStations(road(14), [
      station(1, 2),
      station(2, 12, { freeway: '50' }),
    ]);
    const covered = result.segments.reduce((s, x) => s + x.lengthMiles, 0);
    // 1 mile into the gap from each side, plus 0.5 mile at each outer end.
    expect(covered).toBeCloseTo(3, 1);
  });

  it('does not bridge a gap on the same freeway in opposite directions', () => {
    const result = matchStations(road(14), [
      station(1, 2),
      station(2, 12, { direction: 'W' }, 0),
    ]);
    // The westbound station is filtered out entirely, leaving only station 1.
    expect(result.segments.map(s => s.stationId)).toEqual([1]);
  });

  it('reports the whole path as uncovered when nothing matches', () => {
    const result = matchStations(road(10), [station(1, 3, {}, 900)]);
    expect(result.segments).toEqual([]);
    expect(result.uncoveredMiles).toBeCloseTo(10, 1);
  });

  it('handles a path too short to have a direction', () => {
    expect(matchStations([at(0)], [station(1, 0)])).toEqual({
      segments: [],
      uncoveredMiles: 0,
    });
  });

  it('skips stations with an unknown direction', () => {
    const result = matchStations(road(10), [station(1, 3, { direction: '?' })]);
    expect(result.segments).toEqual([]);
  });
});

describe('PathRouteResolver', () => {
  const route: Route = { origin: at(0), destination: at(10) };

  it('matches the stations to the path a provider returns', async () => {
    const paths: RoutePathProvider = {
      getPath: async () => ({ points: road(10), distanceMiles: 10 }),
    };
    const resolver = new PathRouteResolver(
      new InMemoryStationSource([station(1, 2), station(2, 5), station(3, 8)]),
      paths,
    );
    const resolved = await resolver.resolve(route);
    expect(resolved.segments.map(s => s.stationId)).toEqual([1, 2, 3]);
  });

  it("passes on the routing service's no-traffic time", async () => {
    const paths: RoutePathProvider = {
      getPath: async () => ({
        points: road(10),
        distanceMiles: 10,
        freeFlowMinutes: 12.5,
      }),
    };
    const resolved = await new PathRouteResolver(
      new InMemoryStationSource([station(1, 5)]),
      paths,
    ).resolve(route);
    expect(resolved.freeFlowMinutes).toBe(12.5);
  });
});

describe('OsrmPathProvider', () => {
  const route: Route = { origin: at(0), destination: at(10) };
  const okBody = {
    code: 'Ok',
    routes: [
      {
        distance: 16093.44,
        duration: 600,
        geometry: {
          coordinates: [
            [-122, 38.5],
            [-121.8, 38.5],
          ],
        },
      },
    ],
  };

  it('asks for the route and reads the path, distance and time', async () => {
    const urls: string[] = [];
    const provider = new OsrmPathProvider('http://osrm.test', async url => {
      urls.push(url);
      return { ok: true, status: 200, json: async () => okBody };
    });
    const path = await provider.getPath(route);
    expect(urls[0]).toContain('/route/v1/driving/-122,38.5;');
    expect(urls[0]).toContain('geometries=geojson');
    expect(path.points[1]).toEqual({ lat: 38.5, lng: -121.8 });
    expect(path.distanceMiles).toBeCloseTo(10);
    expect(path.freeFlowMinutes).toBeCloseTo(10);
  });

  it('fails clearly on an HTTP error or when no route is found', async () => {
    const down = new OsrmPathProvider('http://osrm.test', async () => ({
      ok: false,
      status: 503,
      json: async () => ({}),
    }));
    await expect(down.getPath(route)).rejects.toThrow('HTTP 503');
    const none = new OsrmPathProvider('http://osrm.test', async () => ({
      ok: true,
      status: 200,
      json: async () => ({ code: 'NoRoute' }),
    }));
    await expect(none.getPath(route)).rejects.toThrow('NoRoute');
  });
});

describe('CachedPathProvider', () => {
  const route: Route = { origin: at(0), destination: at(10) };
  const path: RoutePath = { points: road(2), distanceMiles: 2 };

  it('reuses a path until it expires', async () => {
    let calls = 0;
    let clock = 0;
    const cached = new CachedPathProvider(
      {
        getPath: async () => {
          calls += 1;
          return path;
        },
      },
      1000,
      () => clock,
    );
    await cached.getPath(route);
    // A start about 5 m away shares the cached path.
    await cached.getPath({
      ...route,
      origin: { ...route.origin, lat: route.origin.lat + 0.00002 },
    });
    expect(calls).toBe(1);
    clock = 2000;
    await cached.getPath(route);
    expect(calls).toBe(2);
  });

  it('does not share paths between different trips', async () => {
    let calls = 0;
    const cached = new CachedPathProvider({
      getPath: async () => {
        calls += 1;
        return path;
      },
    });
    await cached.getPath(route);
    await cached.getPath({
      origin: route.destination,
      destination: route.origin,
    });
    expect(calls).toBe(2);
  });
});
