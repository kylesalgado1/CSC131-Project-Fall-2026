import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';
import { fetchVerdict } from '../api/client';
import { LatLng, Verdict, VerdictResponse } from '../api/types';
import { getCurrentLocation } from '../location/currentLocation';
import { buildRequest, VerdictSettings } from '../lib/request';
import { departureChange } from '../lib/verdictView';
import { sampleResponse, SampleKind } from '../samples';
import { Trip } from '../trip/types';

/** Story 2-6: recalculate at least this often while the app is open. */
export const REFRESH_MS = 5 * 60_000;
/** Wait for typing to settle before asking the server again. */
const SETTINGS_DEBOUNCE_MS = 500;

export type VerdictSource = 'live' | SampleKind;

export interface UseVerdictInput {
  source: VerdictSource;
  trip: Trip;
  settings: VerdictSettings;
  baseUrl: string;
  fetchFn?: typeof fetch;
  /** Where the phone is. Defaults to the phone's location services. */
  locate?: () => Promise<LatLng>;
  /** Told each position found, for example to rank place search results. */
  onLocated?: (position: LatLng) => void;
  refreshMs?: number;
  now?: () => Date;
}

export interface VerdictState {
  /** The latest answer. Kept on screen if a later refresh fails. */
  response?: VerdictResponse;
  /** True until the first answer for the current trip arrives. */
  loading: boolean;
  /** True while any request is in flight. */
  refreshing: boolean;
  /** True while waiting for the phone to say where it is. */
  locating: boolean;
  /** Set when the latest request failed. */
  error?: Error;
  /** When the answer on screen was fetched. */
  updatedAt?: Date;
  /** Set when a refresh changed the advice noticeably. */
  change?: string;
}

const IDLE: VerdictState = {
  loading: false,
  refreshing: false,
  locating: false,
};
const STARTING: VerdictState = {
  loading: true,
  refreshing: true,
  locating: false,
};

/**
 * Fetches the stay-or-go answer, and keeps it fresh: it asks again when the
 * trip or settings change, every five minutes while the app is open, and when
 * the app returns to the foreground after being away. A trip that starts at
 * the current location asks the phone where it is each time, so the answer
 * follows the user while the app is open. Nothing is tracked in the
 * background.
 */
export function useVerdict(input: UseVerdictInput): VerdictState & {
  refresh: () => void;
} {
  const { source, trip, settings, refreshMs = REFRESH_MS } = input;
  const latest = useRef(input);
  latest.current = input;
  const requestId = useRef(0);
  const previous = useRef<Verdict | undefined>(undefined);
  const updatedAt = useRef<Date | undefined>(undefined);
  const [state, setState] = useState<VerdictState>(STARTING);

  const load = useCallback(async (reason: 'change' | 'refresh') => {
    const current = latest.current;
    const { baseUrl, fetchFn, locate = getCurrentLocation } = current;
    const { now = () => new Date() } = current;
    const to = current.trip.to;
    if (current.source === 'live' && !to) {
      return; // nothing to ask until a destination is chosen
    }
    const id = ++requestId.current;
    setState(s => ({ ...s, refreshing: true }));
    try {
      const asked = now();
      let response: VerdictResponse;
      if (current.source === 'live') {
        const { from } = current.trip;
        let origin: LatLng;
        if (from.kind === 'current') {
          setState(s => ({ ...s, locating: true }));
          origin = await locate();
          current.onLocated?.(origin);
          if (id !== requestId.current) {
            return;
          }
          setState(s => ({ ...s, locating: false }));
        } else {
          origin = from.place;
        }
        response = await fetchVerdict(
          baseUrl,
          buildRequest(origin, to!, current.settings, asked),
          { fetchFn },
        );
      } else {
        response = sampleResponse(current.source, asked);
      }
      if (id !== requestId.current) {
        return;
      }
      const change =
        reason === 'refresh'
          ? departureChange(previous.current, response.verdict)
          : undefined;
      previous.current = response.verdict;
      updatedAt.current = asked;
      setState({
        response,
        loading: false,
        refreshing: false,
        locating: false,
        updatedAt: asked,
        change,
      });
    } catch (error) {
      if (id !== requestId.current) {
        return;
      }
      setState(s => ({
        ...s,
        loading: s.response === undefined,
        refreshing: false,
        locating: false,
        error: error instanceof Error ? error : new Error(String(error)),
      }));
    }
  }, []);

  // A new trip, source or setting starts over, so the old answer and the
  // "advice changed" comparison do not carry across.
  const hasDestination = Boolean(trip.to);
  const waiting = source === 'live' && !hasDestination;
  const tripKey = trip.from.kind === 'current' ? 'current' : trip.from.place.id;
  const settingsKey = JSON.stringify([source, tripKey, trip.to?.id, settings]);
  // Picking a place or a source is a single tap and should answer at once.
  // Only edits to the settings wait, so typing an "arrive by" time does not
  // ask the server after every character.
  const choiceKey = JSON.stringify([source, tripKey, trip.to?.id]);
  const lastChoice = useRef<string | undefined>(undefined);
  useEffect(() => {
    const delay = lastChoice.current === choiceKey ? SETTINGS_DEBOUNCE_MS : 0;
    lastChoice.current = choiceKey;
    previous.current = undefined;
    updatedAt.current = undefined;
    requestId.current += 1; // forget anything still on its way
    if (waiting) {
      setState(IDLE);
      return undefined;
    }
    setState(STARTING);
    const timer = setTimeout(() => load('change'), delay);
    return () => clearTimeout(timer);
  }, [settingsKey, choiceKey, waiting, load]);

  useEffect(() => {
    if (source !== 'live' || !hasDestination) {
      return undefined;
    }
    const timer = setInterval(() => load('refresh'), refreshMs);
    return () => clearInterval(timer);
  }, [source, hasDestination, refreshMs, load]);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', status => {
      const stale =
        !updatedAt.current ||
        Date.now() - updatedAt.current.getTime() >= refreshMs;
      if (status === 'active' && latest.current.source === 'live' && stale) {
        load('refresh');
      }
    });
    return () => subscription.remove();
  }, [refreshMs, load]);

  return { ...state, refresh: useCallback(() => load('refresh'), [load]) };
}
