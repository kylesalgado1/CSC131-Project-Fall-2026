import { useEffect, useRef, useState } from 'react';
import { isAbort, searchPlaces } from '../api/places';
import { LatLng, Place } from '../api/types';

/** Story 3-1: suggestions start at three characters. */
export const MIN_QUERY_LENGTH = 3;

interface Options {
  baseUrl: string;
  /** Ranks closer places first. */
  near?: LatLng;
  fetchFn?: typeof fetch;
  debounceMs?: number;
}

export interface PlaceSearchState {
  places: Place[];
  /** True from the first keystroke until the answer arrives. */
  loading: boolean;
  error?: Error;
  /** The text the places and error belong to. */
  forQuery: string;
}

const EMPTY: PlaceSearchState = { places: [], loading: false, forQuery: '' };

/**
 * Search suggestions for text being typed. Waits for typing to pause, asks
 * only once there are enough characters, and drops an answer that a newer
 * search has replaced.
 */
export function usePlaceSearch(
  query: string,
  { baseUrl, near, fetchFn, debounceMs = 350 }: Options,
): PlaceSearchState {
  const [state, setState] = useState<PlaceSearchState>(EMPTY);
  const nearRef = useRef(near);
  nearRef.current = near;

  useEffect(() => {
    const text = query.trim();
    if (text.length < MIN_QUERY_LENGTH) {
      setState(EMPTY);
      return undefined;
    }
    setState(s => ({ ...s, loading: true, error: undefined }));
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const places = await searchPlaces(baseUrl, text, nearRef.current, {
          fetchFn,
          signal: controller.signal,
        });
        if (!controller.signal.aborted) {
          setState({ places, loading: false, forQuery: text });
        }
      } catch (error) {
        if (controller.signal.aborted || isAbort(error)) {
          return;
        }
        setState({
          places: [],
          loading: false,
          forQuery: text,
          error: error instanceof Error ? error : new Error(String(error)),
        });
      }
    }, debounceMs);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [query, baseUrl, fetchFn, debounceMs]);

  return state;
}
