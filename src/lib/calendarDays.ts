/**
 * Calendar days, as local "YYYY-MM-DD" keys: naming them, laying out a month.
 * Nothing here knows about times of day.
 */
import { pad2 } from './format';

/** How many months ahead the calendar can reach, counting this one. */
export const MAX_MONTHS_AHEAD = 12;

/** Local "YYYY-MM-DD". Not toISOString, which is UTC and can be off by a day. */
export function dateKey(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(
    date.getDate(),
  )}`;
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
