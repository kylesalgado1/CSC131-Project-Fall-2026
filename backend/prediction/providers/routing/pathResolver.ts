import { Queryable } from '../../../db/db';
import { TtlCache } from '../../../util/ttlCache';
import { Route } from '../../types';
import { PemsStation, ResolvedRoute, RouteResolver } from '../pems/types';
import { matchStations, MatchOptions } from './routeMatch';
import { RoutePathProvider, StationSource } from './types';

/** Finds stations along the path a routing service returns for the trip. */
export class PathRouteResolver implements RouteResolver {
  constructor(
    private readonly stations: StationSource,
    private readonly paths: RoutePathProvider,
    private readonly options: MatchOptions = {},
  ) {}

  async resolve(route: Route): Promise<ResolvedRoute> {
    const [stations, path] = await Promise.all([
      this.stations.getStations(),
      this.paths.getPath(route),
    ]);
    return {
      ...matchStations(path.points, stations, this.options),
      freeFlowMinutes: path.freeFlowMinutes,
    };
  }
}

export class InMemoryStationSource implements StationSource {
  constructor(private readonly stations: PemsStation[]) {}

  async getStations(): Promise<PemsStation[]> {
    return this.stations;
  }
}

/**
 * Loads stations from Postgres and keeps them in memory: there are only a few
 * hundred and they change when PeMS publishes new metadata.
 */
export class PgStationSource implements StationSource {
  private readonly cache: TtlCache<PemsStation[]>;

  constructor(
    private readonly db: Queryable,
    ttlMs = 60 * 60_000,
    now: () => number = Date.now,
  ) {
    this.cache = new TtlCache(ttlMs, now);
  }

  getStations(): Promise<PemsStation[]> {
    return this.cache.get('stations', () => this.load());
  }

  private async load(): Promise<PemsStation[]> {
    const { rows } = await this.db.query<{
      id: number;
      freeway: string;
      direction: string;
      length_miles: number;
      latitude: number;
      longitude: number;
    }>(
      `SELECT id, freeway, direction, length_miles::float8 AS length_miles,
              latitude, longitude
         FROM pems_stations`,
    );
    return rows.map(r => ({
      id: r.id,
      freeway: r.freeway,
      direction: r.direction,
      lengthMiles: r.length_miles,
      latitude: r.latitude,
      longitude: r.longitude,
    }));
  }
}
