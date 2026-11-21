import {
  addDays,
  CivilDate,
  localTime,
  weekdayOf,
} from '../prediction/calendar';
import { LatLng } from '../prediction/types';

/**
 * Parses "lat,lng". The error does not repeat the value, so a pasted
 * terminal session does not leak a home address.
 */
export function parseCoordinate(text: string, flag: string): LatLng {
  const parts = text.split(',').map(part => part.trim());
  // An empty part would read as 0 and quietly point somewhere wrong.
  const [lat, lng] = parts.map(part => (part === '' ? NaN : Number(part)));
  const valid =
    parts.length === 2 &&
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    Math.abs(lat) <= 90 &&
    Math.abs(lng) <= 180;
  if (!valid) {
    throw new Error(
      `${flag} must look like 38.5593,-121.4237 (latitude,longitude)`,
    );
  }
  return { lat, lng };
}

/** Parses "07:00,18:00" into minutes after midnight. */
export function parseTimes(text: string): number[] {
  return text.split(',').map(part => {
    const match = /^(\d{1,2}):(\d{2})$/.exec(part.trim());
    const minutes = match ? Number(match[1]) * 60 + Number(match[2]) : NaN;
    if (!(minutes >= 0 && minutes < 24 * 60) || Number(match?.[2]) > 59) {
      throw new Error('--times must look like 07:00,18:00 (24-hour clock)');
    }
    return minutes;
  });
}

const WEDNESDAY = 3;

/** The next Wednesday after today on the local clock. */
export function nextWednesday(now: Date): CivilDate {
  const today = localTime(now).date;
  const daysAhead = (WEDNESDAY - weekdayOf(today) + 7) % 7 || 7;
  return addDays(today, daysAhead);
}

export const formatClock = (minuteOfDay: number): string =>
  `${String(Math.floor(minuteOfDay / 60)).padStart(2, '0')}:${String(
    minuteOfDay % 60,
  ).padStart(2, '0')}`;
