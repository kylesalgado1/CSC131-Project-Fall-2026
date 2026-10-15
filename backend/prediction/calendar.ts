/**
 * Local-time and day-type helpers. Traffic follows the local clock and
 * calendar, so everything here works on civil (year, month, day) dates in the
 * app's time zone rather than UTC instants.
 */

export const LOCAL_TIME_ZONE = 'America/Los_Angeles';
export const BUCKET_MINUTES = 15;
export const BUCKETS_PER_DAY = (24 * 60) / BUCKET_MINUTES;

export interface CivilDate {
  year: number;
  /** 1-12 */
  month: number;
  day: number;
}

export type DayType = 'weekday' | 'weekend' | 'holiday';

/** A closed date range, such as spring break. Dates are YYYY-MM-DD. */
export interface CampusBreak {
  name: string;
  start: string;
  end: string;
}

export const toIso = ({ year, month, day }: CivilDate): string =>
  `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;

export function parseIso(iso: string): CivilDate {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) {
    throw new Error(`Invalid date: ${iso}`);
  }
  return { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]) };
}

/** The date and minute of day on the local clock at the given instant. */
export function localTime(
  at: Date,
  timeZone: string = LOCAL_TIME_ZONE,
): { date: CivilDate; minuteOfDay: number } {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    minute: 'numeric',
  }).formatToParts(at);
  const get = (type: string) => Number(parts.find(p => p.type === type)?.value);
  return {
    date: { year: get('year'), month: get('month'), day: get('day') },
    minuteOfDay: get('hour') * 60 + get('minute'),
  };
}

export const bucketOf = (minuteOfDay: number): number =>
  Math.floor(minuteOfDay / BUCKET_MINUTES);

/** 0 = Sunday ... 6 = Saturday */
const weekdayOf = ({ year, month, day }: CivilDate): number =>
  new Date(Date.UTC(year, month - 1, day)).getUTCDay();

/** Day of month of the nth (1-based) given weekday in a month. */
function nthWeekday(
  year: number,
  month: number,
  weekday: number,
  n: number,
): number {
  const first = weekdayOf({ year, month, day: 1 });
  return 1 + ((weekday - first + 7) % 7) + (n - 1) * 7;
}

function lastWeekday(year: number, month: number, weekday: number): number {
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const last = weekdayOf({ year, month, day: lastDay });
  return lastDay - ((last - weekday + 7) % 7);
}

const SUNDAY = 0;
const MON = 1;
const THU = 4;
const SATURDAY = 6;

/** Fixed-date holidays: [month, day, name]. */
const FIXED: Array<[number, number, string]> = [
  [1, 1, "New Year's Day"],
  [3, 31, 'Cesar Chavez Day'],
  [6, 19, 'Juneteenth'],
  [7, 4, 'Independence Day'],
  [11, 11, 'Veterans Day'],
  [12, 25, 'Christmas Day'],
];

/** The day a fixed-date holiday is observed: Saturday -> Friday, Sunday -> Monday. */
function observed(date: CivilDate): CivilDate {
  const weekday = weekdayOf(date);
  let shift = 0;
  if (weekday === SATURDAY) {
    shift = -1;
  } else if (weekday === SUNDAY) {
    shift = 1;
  }
  const d = new Date(Date.UTC(date.year, date.month - 1, date.day + shift));
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
  };
}

/**
 * Name of the California holiday on this date, counting observed days.
 * Columbus / Indigenous Peoples Day is not one: California does not close
 * for it.
 */
export function holidayName(date: CivilDate): string | undefined {
  const { year, month, day } = date;
  const same = (m: number, d: number) => month === m && day === d;

  for (const [m, d, name] of FIXED) {
    if (same(m, d)) {
      return name;
    }
  }
  // An observed day can land in the neighboring year (Jan 1 on a Saturday).
  for (const y of [year, year + 1]) {
    for (const [m, d, name] of FIXED) {
      const obs = observed({ year: y, month: m, day: d });
      if (obs.year === year && obs.month === month && obs.day === day) {
        return `${name} (observed)`;
      }
    }
  }

  if (same(1, nthWeekday(year, 1, MON, 3))) {
    return 'Martin Luther King Jr. Day';
  }
  if (same(2, nthWeekday(year, 2, MON, 3))) {
    return "Presidents' Day";
  }
  if (same(5, lastWeekday(year, 5, MON))) {
    return 'Memorial Day';
  }
  if (same(9, nthWeekday(year, 9, MON, 1))) {
    return 'Labor Day';
  }
  const thanksgiving = nthWeekday(year, 11, THU, 4);
  if (same(11, thanksgiving)) {
    return 'Thanksgiving';
  }
  if (same(11, thanksgiving + 1)) {
    return 'Day after Thanksgiving';
  }
  return undefined;
}

export function campusBreakName(
  date: CivilDate,
  breaks: CampusBreak[],
): string | undefined {
  const iso = toIso(date);
  return breaks.find(b => b.start <= iso && iso <= b.end)?.name;
}

/**
 * Holidays and campus breaks get their own day type so predictions use
 * matching historical days instead of ordinary weekday traffic.
 */
export function dayTypeOf(
  date: CivilDate,
  breaks: CampusBreak[] = [],
): DayType {
  if (holidayName(date) || campusBreakName(date, breaks)) {
    return 'holiday';
  }
  const weekday = weekdayOf(date);
  return weekday === 0 || weekday === 6 ? 'weekend' : 'weekday';
}
