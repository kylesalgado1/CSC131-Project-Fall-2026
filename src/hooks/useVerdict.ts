import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';
import { fetchVerdict } from '../api/client';
import { Verdict, VerdictResponse } from '../api/types';
import { buildRequest, VerdictSettings } from '../lib/request';
import { departureChange } from '../lib/verdictView';
import { sampleResponse, SampleKind } from '../samples';
import { Trip } from '../trips';

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
  /** Set when the latest request failed. */
  error?: Error;
  /** When the answer on screen was fetched. */
  updatedAt?: Date;
  /** Set when a refresh changed the advice noticeably. */
  change?: string;
}

/**
 * Fetches the stay-or-go answer, and keeps it fresh: it asks again when the
 * trip or settings change, every five minutes while the app is open, and when
 * the app returns to the foreground after being away.
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
  const [state, setState] = useState<VerdictState>({
    loading: true,
    refreshing: true,
  });

  const load = useCallback(async (reason: 'change' | 'refresh') => {
    const id = ++requestId.current;
    const { baseUrl, fetchFn, now = () => new Date() } = latest.current;
    const current = latest.current;
    setState(s => ({ ...s, refreshing: true }));
    try {
      const asked = now();
      const response =
        current.source === 'live'
          ? await fetchVerdict(
              baseUrl,
              buildRequest(current.trip, current.settings, asked),
              { fetchFn },
            )
          : sampleResponse(current.source, asked);
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
        error: error instanceof Error ? error : new Error(String(error)),
      }));
    }
  }, []);

  // A new trip, source or setting starts over, so the old answer and the
  // "advice changed" comparison do not carry across.
  const settingsKey = JSON.stringify([source, trip.id, settings]);
  const firstRun = useRef(true);
  useEffect(() => {
    const delay = firstRun.current ? 0 : SETTINGS_DEBOUNCE_MS;
    firstRun.current = false;
    previous.current = undefined;
    setState({ loading: true, refreshing: true });
    const timer = setTimeout(() => load('change'), delay);
    return () => clearTimeout(timer);
  }, [settingsKey, load]);

  useEffect(() => {
    if (source !== 'live') {
      return undefined;
    }
    const timer = setInterval(() => load('refresh'), refreshMs);
    return () => clearInterval(timer);
  }, [source, refreshMs, load]);

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
