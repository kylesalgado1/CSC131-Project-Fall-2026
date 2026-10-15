import { Goal, VerdictRequest } from '../api/types';
import { Trip } from '../trips';
import { parseArriveBy } from './arriveBy';

export interface VerdictSettings {
  goal: Goal;
  /** Longest wait the user will accept. */
  maxWaitMinutes: number;
  /** Waiting must save at least this much to be recommended. */
  minSavingsMinutes: number;
  /** What the user typed for the arrival deadline. Empty for none. */
  arriveByText: string;
}

export const DEFAULT_SETTINGS: VerdictSettings = {
  goal: 'balance',
  maxWaitMinutes: 90,
  minSavingsMinutes: 10,
  arriveByText: '',
};

/** The request for a trip. A deadline is re-read each time, so "8:30" keeps meaning the next 8:30. */
export function buildRequest(
  trip: Trip,
  settings: VerdictSettings,
  now: Date,
): VerdictRequest {
  const arriveBy = parseArriveBy(settings.arriveByText, now);
  return {
    origin: trip.origin,
    destination: trip.destination,
    ...(arriveBy.kind === 'ok'
      ? { arriveBy: arriveBy.date.toISOString() }
      : {}),
    preferences: {
      goal: settings.goal,
      maxWaitMinutes: settings.maxWaitMinutes,
      minSavingsMinutes: settings.minSavingsMinutes,
    },
  };
}
