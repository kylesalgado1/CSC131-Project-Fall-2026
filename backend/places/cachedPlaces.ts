import { TtlCache } from '../util/ttlCache';
import { LatLng } from '../prediction/types';
import { Place, PlaceSearch } from './types';

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
