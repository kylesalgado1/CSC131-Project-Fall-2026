export const MINUTE_MS = 60_000;
export const HOUR_MS = 60 * MINUTE_MS;

export const addMinutes = (date: Date, minutes: number): Date =>
  new Date(date.getTime() + minutes * MINUTE_MS);

/** Whole minutes from `a` to `b`, negative if `b` is earlier. */
export const minutesBetween = (a: Date, b: Date): number =>
  Math.round((b.getTime() - a.getTime()) / MINUTE_MS);

/** The start of the hour containing the given time, in epoch milliseconds. */
export const startOfHourMs = (ms: number): number =>
  Math.floor(ms / HOUR_MS) * HOUR_MS;
