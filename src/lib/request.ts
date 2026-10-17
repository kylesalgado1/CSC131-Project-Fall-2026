import { Goal, LatLng, VerdictRequest } from '../api/types';
import { ClockTime, resolveTime } from './clockTime';

export interface VerdictSettings {
  goal: Goal;
  /** Longest wait the user will accept. Absent for no limit. */
  maxWaitMinutes?: number;
  /** Waiting must save at least this much to be recommended. */
  minSavingsMinutes: number;
  /** The latest time to be there. Absent for no deadline. */
  arriveBy?: ClockTime;
  /** The latest time to be on the road. Absent for no limit. */
  leaveBy?: ClockTime;
}

export const DEFAULT_SETTINGS: VerdictSettings = {
  goal: 'balance',
  minSavingsMinutes: 10,
};

/**
 * The request for a trip. A time with a chosen day means that moment. A time
 * without one means the next time the clock shows it, worked out fresh each
 * time, so "8:30" keeps meaning the next 8:30.
 */
export function buildRequest(
  origin: LatLng,
  destination: LatLng,
  settings: VerdictSettings,
  now: Date,
): VerdictRequest {
  const { arriveBy, leaveBy } = settings;
  return {
    origin: { lat: origin.lat, lng: origin.lng },
    destination: { lat: destination.lat, lng: destination.lng },
    ...(arriveBy ? { arriveBy: resolveTime(arriveBy, now).toISOString() } : {}),
    ...(leaveBy ? { leaveBy: resolveTime(leaveBy, now).toISOString() } : {}),
    preferences: {
      goal: settings.goal,
      ...(settings.maxWaitMinutes !== undefined
        ? { maxWaitMinutes: settings.maxWaitMinutes }
        : {}),
      minSavingsMinutes: settings.minSavingsMinutes,
    },
  };
}
