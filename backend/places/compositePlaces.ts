import { distanceMeters } from '../util/geo';
import { LatLng } from '../prediction/types';
import { matchAliases, normalize } from './aliases';
import { Place, PlaceSearch, SearchError } from './types';

const MAX_RESULTS = 5;
/** Two results this close with matching names are the same place. */
const SAME_PLACE_METERS = 150;
/** Names that share two words are one place if they are this close. */
const SHARED_WORDS_METERS = 500;

/** Names that say the same thing: one contains the other. */
const similarNames = (a: string, b: string): boolean => {
  const x = normalize(a);
  const y = normalize(b);
  return x === y || x.includes(y) || y.includes(x);
};

/** How many words two names have in common. */
const sharedWords = (a: string, b: string): number => {
  const words = new Set(normalize(a).split(' '));
  return new Set(
    normalize(b)
      .split(' ')
      .filter(w => words.has(w)),
  ).size;
};

/**
 * The same place under two names: right on top of each other; or close with
 * one name inside the other; or near with two words in common, as in
 * "Sacramento State" and "California State University, Sacramento". One shared
 * word is not enough, so "Sac State Library" stays a place of its own.
 */
const samePlace = (a: Place, b: Place): boolean => {
  const apart = distanceMeters(a, b);
  return (
    apart < 25 ||
    (apart < SAME_PLACE_METERS && similarNames(a.name, b.name)) ||
    (apart < SHARED_WORDS_METERS && sharedWords(a.name, b.name) >= 2)
  );
};

/**
 * Searches several sources at once and merges them: first the places people
 * call by a short name (aliases), then the sources' results taken in turn so
 * no one source crowds out the rest, without repeating a place. A source that
 * fails is skipped; the search only fails when every source does.
 */
export class CompositePlaceSearch implements PlaceSearch {
  constructor(private readonly sources: PlaceSearch[]) {}

  async search(query: string, near?: LatLng): Promise<Place[]> {
    const aliased = matchAliases(query);
    const settled = await Promise.allSettled(
      this.sources.map(source => source.search(query, near)),
    );
    const lists = settled.flatMap(r =>
      r.status === 'fulfilled' ? [r.value] : [],
    );
    if (lists.length === 0 && aliased.length === 0 && this.sources.length > 0) {
      const failure = settled.find(r => r.status === 'rejected') as
        | PromiseRejectedResult
        | undefined;
      throw failure?.reason instanceof Error
        ? failure.reason
        : new SearchError('Place search failed');
    }

    const merged: Place[] = [...aliased];
    const longest = Math.max(0, ...lists.map(list => list.length));
    for (let i = 0; i < longest && merged.length < MAX_RESULTS; i++) {
      for (const list of lists) {
        const place = list[i];
        if (
          place &&
          merged.length < MAX_RESULTS &&
          !merged.some(existing => samePlace(existing, place))
        ) {
          merged.push(place);
        }
      }
    }
    return merged;
  }
}
