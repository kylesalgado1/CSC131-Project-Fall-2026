import { TtlCache } from '../util/ttlCache';
import { LatLng } from '../prediction/types';
import { RoutingError } from '../prediction/providers/routing/types';
import {
  TomTomClient,
  TomTomPlace,
} from '../prediction/providers/routing/tomtom';
import { Place, PlaceSearch, SearchError } from './types';

const MAX_RESULTS = 5;

/** The name to show: the business or campus, else the first part of the address. */
const displayName = (place: TomTomPlace): string =>
  place.poiName ?? place.address.split(',')[0];

/** About 10 m of precision, enough to tell two spots in a town apart. */
const spot = (p: LatLng) => `${p.lat.toFixed(4)},${p.lng.toFixed(4)}`;

/** Place search from TomTom. */
export class TomTomPlaces implements PlaceSearch {
  constructor(private readonly client: TomTomClient) {}

  async search(query: string, near?: LatLng): Promise<Place[]> {
    let found: TomTomPlace[];
    try {
      // Ask for a few extra: some are dropped as duplicates.
      found = await this.client.search(query, near, MAX_RESULTS + 3);
    } catch (error) {
      if (error instanceof RoutingError) {
        throw new SearchError(error.message);
      }
      throw error;
    }

    const seen = new Set<string>();
    const places: Place[] = [];
    for (const result of found) {
      const key = `${displayName(result)}|${spot(result.position)}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      places.push({
        id: result.id ?? key,
        name: displayName(result),
        address: result.address,
        ...result.position,
      });
      if (places.length === MAX_RESULTS) {
        break;
      }
    }
    return places;
  }
}

/**
 * Remembers recent searches so retyping, or backing up a letter, does not use
 * another request. Kept in memory for minutes only: TomTom's terms on storing
 * results are not clear for free plans.
 */
export class CachedPlaceSearch implements PlaceSearch {
  private readonly cache: TtlCache<Place[]>;

  constructor(
    private readonly inner: PlaceSearch,
    ttlMs = 10 * 60_000,
    now: () => number = Date.now,
  ) {
    this.cache = new TtlCache(ttlMs, now);
  }

  search(query: string, near?: LatLng): Promise<Place[]> {
    // Nearby phones share results; a different town does not. About 1 km.
    const where = near ? `${near.lat.toFixed(2)},${near.lng.toFixed(2)}` : '-';
    const key = `${query.trim().toLowerCase()}|${where}`;
    return this.cache.get(key, () => this.inner.search(query.trim(), near));
  }
}
