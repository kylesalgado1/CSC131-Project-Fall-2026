import { DepartureOption, LatLng, Verdict } from '../api/types';
import { formatDuration } from './format';
import { startsLater } from './verdictView';

/** How long before the departure time the reminder goes off. */
export const REMINDER_LEAD_MINUTES = 5;
/** For a latest departure, which is no margin at all, remind sooner. */
export const LATEST_REMINDER_LEAD_MINUTES = 15;

const MINUTE = 60_000;
const EARTH_RADIUS_MILES = 3958.8;

/** Whole minutes until a time, rounded up so "0 min" never shows early. */
export function minutesUntil(at: string | Date, now: Date): number {
  return Math.ceil((new Date(at).getTime() - now.getTime()) / MINUTE);
}

/**
 * "Leave in 1 hr 42 min", or "Time to leave" once the time has come. For a
 * latest departure it is "Leave within 1 hr 42 min", since any time before
 * it will do.
 */
export function countdownLabel(
  departAt: string | Date,
  now: Date,
  latest = false,
): string {
  const left = minutesUntil(departAt, now);
  if (left <= 0) {
    return 'Time to leave';
  }
  return `Leave ${latest ? 'within' : 'in'} ${formatDuration(left)}`;
}

/**
 * What the answer leaves the user to spend: a wait for a set departure, or a
 * window of time for "no need to leave yet". Nothing for the other answers.
 */
export function planKind(verdict: Verdict): 'wait' | 'window' | undefined {
  switch (verdict.action) {
    case 'wait':
    case 'leave_later':
      return 'wait';
    // The user cannot leave until later: there is a wait until then.
    case 'leave_now':
      return startsLater(verdict) ? 'wait' : undefined;
    case 'no_rush':
      return 'window';
    default:
      return undefined;
  }
}

/**
 * The departure to count down to: the recommended one for a wait, the latest
 * one that still arrives in time for a window. A deadline too far off to plan
 * has none.
 */
export function departureTarget(verdict: Verdict): DepartureOption | undefined {
  switch (planKind(verdict)) {
    case 'wait':
      return verdict.recommended;
    case 'window':
      return verdict.deadline?.latestDeparture;
    default:
      return undefined;
  }
}

/**
 * When to remind: a few minutes before the departure, or in a few seconds if
 * that moment has passed. Undefined once the departure itself has passed.
 */
export function reminderTime(
  departAt: string | Date,
  now: Date,
  leadMinutes = REMINDER_LEAD_MINUTES,
): Date | undefined {
  const depart = new Date(departAt).getTime();
  if (depart <= now.getTime()) {
    return undefined;
  }
  return new Date(
    Math.max(depart - leadMinutes * MINUTE, now.getTime() + 5_000),
  );
}

const radians = (degrees: number) => (degrees * Math.PI) / 180;

/** Straight-line miles between two points. */
export function distanceMiles(a: LatLng, b: LatLng): number {
  const dLat = radians(b.lat - a.lat);
  const dLng = radians(b.lng - a.lng);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(radians(a.lat)) *
      Math.cos(radians(b.lat)) *
      Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_MILES * Math.asin(Math.sqrt(h));
}

/** "300 ft" up close, "0.4 mi" further out. */
export function formatDistance(miles: number): string {
  if (miles < 0.1) {
    return `${Math.round((miles * 5280) / 50) * 50} ft`;
  }
  return `${miles.toFixed(1)} mi`;
}

/** A link that opens walking directions in the phone's maps app. */
export function mapsUrl(
  place: LatLng & { name: string },
  os: 'ios' | 'android' | string,
): string {
  const name = encodeURIComponent(place.name);
  return os === 'ios'
    ? `http://maps.apple.com/?daddr=${place.lat},${place.lng}&dirflg=w&q=${name}`
    : `geo:${place.lat},${place.lng}?q=${place.lat},${place.lng}(${name})`;
}

/** How many places to suggest. */
export const SPOTS_SHOWN = 3;

/** The closest few of a list sorted nearest first, optionally of one kind. */
export function closest<T extends { category: string }>(
  spots: T[],
  category?: string,
  count = SPOTS_SHOWN,
): T[] {
  return spots
    .filter(spot => category === undefined || spot.category === category)
    .slice(0, count);
}
