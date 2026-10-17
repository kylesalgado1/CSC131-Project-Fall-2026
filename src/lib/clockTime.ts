import { dayName, parseDateKey } from './calendarDays';
import { pad2 } from './format';

/** A time of day on a 24-hour clock, with a calendar day when one is chosen. */
export interface ClockTime {
  /** 0 to 23 */
  hour: number;
  /** 0 to 59 */
  minute: number;
  /**
   * The day, as local "YYYY-MM-DD". Absent means the next time the clock shows
   * this time. A day that has already passed also falls back to that.
   */
  date?: string;
}

/** The minute wheel moves in steps of this many minutes. */
export const MINUTE_STEP = 5;

/** "8:30 AM". Written out here so it reads the same on every phone. */
export function formatClockTime({ hour, minute }: ClockTime): string {
  return `${hour % 12 || 12}:${pad2(minute)} ${hour < 12 ? 'AM' : 'PM'}`;
}

/** The three wheels' view of a time: hour 1 to 12, minute, and AM or PM. */
export interface WheelTime {
  hour12: number;
  minute: number;
  pm: boolean;
}

export const toWheels = ({ hour, minute }: ClockTime): WheelTime => ({
  hour12: hour % 12 || 12,
  minute,
  pm: hour >= 12,
});

export const fromWheels = ({ hour12, minute, pm }: WheelTime): ClockTime => ({
  hour: (hour12 % 12) + (pm ? 12 : 0),
  minute,
});

/**
 * The next moment the clock shows this time: later today, or tomorrow if it
 * has already passed. A time that is exactly now counts as passed.
 */
export function nextOccurrence({ hour, minute }: ClockTime, now: Date): Date {
  const date = new Date(now);
  date.setHours(hour, minute, 0, 0);
  if (date.getTime() <= now.getTime()) {
    date.setDate(date.getDate() + 1);
  }
  return date;
}

/** The moment a time means: its chosen day, or the next occurrence. */
export function resolveTime(time: ClockTime, now: Date): Date {
  if (time.date) {
    const chosen = parseDateKey(time.date);
    chosen.setHours(time.hour, time.minute, 0, 0);
    if (chosen.getTime() > now.getTime()) {
      return chosen;
    }
  }
  return nextOccurrence(time, now);
}

/** Which day a time falls on, in words. */
export const dayOf = (time: ClockTime, now: Date): string =>
  dayName(resolveTime(time, now), now);

/**
 * A starting point for the wheels: the time a while from now, rounded up to
 * the next step, so most people have little to scroll.
 */
export function suggestedTime(now: Date, minutesAhead: number): ClockTime {
  const target = new Date(now.getTime() + minutesAhead * 60_000);
  const minutes = target.getHours() * 60 + target.getMinutes();
  const rounded = Math.ceil(minutes / MINUTE_STEP) * MINUTE_STEP;
  const wrapped = rounded % (24 * 60);
  return { hour: Math.floor(wrapped / 60), minute: wrapped % 60 };
}
