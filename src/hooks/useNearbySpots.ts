import { useEffect, useRef, useState } from 'react';
import { isAbort, searchPlaces } from '../api/places';
import { LatLng, Place } from '../api/types';
import { getCurrentLocation } from '../location/currentLocation';
import { distanceMiles } from '../lib/waitPlan';

/** The kinds of place offered for a wait, each found by one search. */
export const SPOT_CATEGORIES = [
  { id: 'cafe', label: 'Cafes', noun: 'Cafe', query: 'cafe' },
  { id: 'food', label: 'Food', noun: 'Food', query: 'restaurant' },
  { id: 'park', label: 'Parks', noun: 'Park', query: 'park' },
  { id: 'books', label: 'Bookstores', noun: 'Bookstore', query: 'bookstore' },
] as const;

export type SpotCategory = (typeof SPOT_CATEGORIES)[number]['id'];

/** Search results further away than this are not somewhere to wait. */
export const MAX_SPOT_MILES = 5;

export interface Spot extends Place {
  miles: number;
  category: SpotCategory;
}

export interface NearbySpotsState {
  spots: Spot[];
  loading: boolean;
  error?: Error;
}

interface Options {
  /** Look only while this is true, which is while the advice is to wait. */
  active: boolean;
  baseUrl: string;
  /** The last position the app knows; the phone is asked if there is none. */
  located?: LatLng;
  locate?: () => Promise<LatLng>;
  fetchFn?: typeof fetch;
}

type Found = PromiseSettledResult<{ id: SpotCategory; places: Place[] }>;

/** Every result within reach, once each, closest first. */
function nearest(here: LatLng, found: Found[]): Spot[] {
  const seen = new Set<string>();
  return found
    .flatMap(result =>
      result.status === 'fulfilled'
        ? result.value.places.map(place => ({
            ...place,
            category: result.value.id,
            miles: distanceMiles(here, place),
          }))
        : [],
    )
    .filter(spot => {
      if (spot.miles > MAX_SPOT_MILES || seen.has(spot.id)) {
        return false;
      }
      seen.add(spot.id);
      return true;
    })
    .sort((a, b) => a.miles - b.miles);
}

/**
 * Places close to where the phone is, to spend a wait at, nearest first, from
 * every category at once. Looks once each time `active` turns on, not on
 * every refresh of the advice.
 */
export function useNearbySpots({
  active,
  baseUrl,
  located,
  locate = getCurrentLocation,
  fetchFn,
}: Options): NearbySpotsState {
  const [state, setState] = useState<NearbySpotsState>({
    spots: [],
    loading: false,
  });
  const locatedRef = useRef(located);
  locatedRef.current = located;

  useEffect(() => {
    if (!active) {
      setState({ spots: [], loading: false });
      return undefined;
    }
    const controller = new AbortController();
    setState({ spots: [], loading: true });
    (async () => {
      try {
        const here = locatedRef.current ?? (await locate());
        const found = await Promise.allSettled(
          SPOT_CATEGORIES.map(({ id, query }) =>
            searchPlaces(baseUrl, query, here, {
              fetchFn,
              signal: controller.signal,
            }).then(places => ({ id, places })),
          ),
        );
        if (controller.signal.aborted) {
          return;
        }
        const failed = found.filter(r => r.status === 'rejected');
        if (failed.length === found.length) {
          throw (failed[0] as PromiseRejectedResult).reason;
        }
        setState({ spots: nearest(here, found), loading: false });
      } catch (error) {
        if (!controller.signal.aborted && !isAbort(error)) {
          setState({
            spots: [],
            loading: false,
            error: error instanceof Error ? error : new Error(String(error)),
          });
        }
      }
    })();
    return () => controller.abort();
    // `locate` and `fetchFn` are fixed for the life of the screen.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, baseUrl]);

  return state;
}
