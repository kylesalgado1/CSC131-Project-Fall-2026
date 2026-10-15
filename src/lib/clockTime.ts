/** A time of day on a 24-hour clock, without a date. */
export interface ClockTime {
  /** 0 to 23 */
  hour: number;
  /** 0 to 59 */
  minute: number;
}

/** The minute wheel moves in steps of this many minutes. */
export const MINUTE_STEP = 5;

const pad = (n: number): string => String(n).padStart(2, '0');

/** "8:30 AM". Written out here so it reads the same on every phone. */
export function formatClockTime({ hour, minute }: ClockTime): string {
  return `${hour % 12 || 12}:${pad(minute)} ${hour < 12 ? 'AM' : 'PM'}`;
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

/** "today" or "tomorrow": which day the next occurrence of a time falls on. */
export function dayOf(time: ClockTime, now: Date): 'today' | 'tomorrow' {
  return nextOccurrence(time, now).getDate() === now.getDate()
    ? 'today'
    : 'tomorrow';
}

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
