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

const pad = (n: number): string => String(n).padStart(2, '0');

/** How many months ahead the calendar can reach, counting this one. */
export const MAX_MONTHS_AHEAD = 12;

/** Local "YYYY-MM-DD". Not toISOString, which is UTC and can be off by a day. */
export function dateKey(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(
    date.getDate(),
  )}`;
}

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

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const sameDay = (a: Date, b: Date): boolean => dateKey(a) === dateKey(b);

/** "today", "tomorrow", or "Fri, Oct 23": the day a moment falls on. */
export function dayName(moment: Date, now: Date): string {
  if (sameDay(moment, now)) {
    return 'today';
  }
  const tomorrow = new Date(now);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (sameDay(moment, tomorrow)) {
    return 'tomorrow';
  }
  return `${WEEKDAYS[moment.getDay()]}, ${
    MONTHS[moment.getMonth()]
  } ${moment.getDate()}`;
}

/** Which day a time falls on, in words. */
export const dayOf = (time: ClockTime, now: Date): string =>
  dayName(resolveTime(time, now), now);

/** The local midnight that starts a "YYYY-MM-DD" day. */
export function parseDateKey(key: string): Date {
  const [year, month, day] = key.split('-').map(Number);
  return new Date(year, month - 1, day);
}

/** "Fri, Oct 23". */
export const longDay = (date: Date): string =>
  `${WEEKDAYS[date.getDay()]}, ${MONTHS[date.getMonth()]} ${date.getDate()}`;

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/** "October 2026". `month` counts from 0. */
export const monthTitle = (year: number, month: number): string =>
  `${MONTH_NAMES[month]} ${year}`;

/** The weekday letters across the top of a calendar, Sunday first. */
export const WEEKDAY_INITIALS = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

/**
 * A month as rows of seven, Sunday first. Each cell is the day's
 * "YYYY-MM-DD" and number, or undefined for the blanks around the month.
 * `month` counts from 0.
 */
export function calendarWeeks(
  year: number,
  month: number,
): ({ key: string; day: number } | undefined)[][] {
  const lead = new Date(year, month, 1).getDay();
  const length = new Date(year, month + 1, 0).getDate();
  const cells = Array.from(
    { length: Math.ceil((lead + length) / 7) * 7 },
    (_, i) => {
      const day = i - lead + 1;
      return day >= 1 && day <= length
        ? { key: dateKey(new Date(year, month, day)), day }
        : undefined;
    },
  );
  return Array.from({ length: cells.length / 7 }, (_, w) =>
    cells.slice(w * 7, w * 7 + 7),
  );
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
