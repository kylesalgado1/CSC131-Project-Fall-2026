import { fetchJson, FetchLike } from '../../../util/http';
import { metersToMiles } from '../../../util/geo';
import { TtlCache } from '../../../util/ttlCache';
import { Route } from '../../types';
import { routeKey } from './routeKey';
import { RoutePath, RoutePathProvider, RoutingError } from './types';

interface OsrmResponse {
  code: string;
  routes?: Array<{
    distance: number;
    duration: number;
    geometry: { coordinates: Array<[number, number]> };
  }>;
}

/**
 * Route paths from an OSRM server. The public demo server is for development
 * only: it is rate limited and has no uptime promise. Production should use a
 * keyed service such as TomTom.
 */
export class OsrmPathProvider implements RoutePathProvider {
  constructor(
    private readonly baseUrl = 'https://router.project-osrm.org',
    private readonly fetchFn: FetchLike = url => fetch(url),
  ) {}

  async getPath({ origin, destination }: Route): Promise<RoutePath> {
    const coords = `${origin.lng},${origin.lat};${destination.lng},${destination.lat}`;
    const body = await fetchJson<OsrmResponse>(
      this.fetchFn,
      `${this.baseUrl}/route/v1/driving/${coords}?overview=full&geometries=geojson`,
      'OSRM',
      RoutingError,
    );
    const route = body.routes?.[0];
    if (body.code !== 'Ok' || !route) {
      throw new RoutingError(`OSRM found no route (${body.code})`);
    }
    return {
      points: route.geometry.coordinates.map(([lng, lat]) => ({ lat, lng })),
      distanceMiles: metersToMiles(route.distance),
      freeFlowMinutes: route.duration / 60,
    };
  }
}

/** Remembers paths so repeat requests for a trip do not hit the service. */
export class CachedPathProvider implements RoutePathProvider {
  private readonly cache: TtlCache<RoutePath>;

  constructor(
    private readonly inner: RoutePathProvider,
    ttlMs = 6 * 60 * 60_000,
    now: () => number = Date.now,
  ) {
    this.cache = new TtlCache(ttlMs, now);
  }

  getPath(route: Route): Promise<RoutePath> {
    const key = routeKey(route);
    return this.cache.get(key, () => this.inner.getPath(route));
  }
}
