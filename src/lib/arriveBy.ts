export type ArriveByResult =
  | { kind: 'none' }
  | { kind: 'ok'; date: Date }
  | { kind: 'invalid' };

/**
 * Reads a time the user typed, such as "8:30 am", "8:30" or "17:45", as the
 * next time the clock shows that: later today, or tomorrow if it has passed.
 */
export function parseArriveBy(text: string, now: Date): ArriveByResult {
  const trimmed = text.trim();
  if (trimmed === '') {
    return { kind: 'none' };
  }
  const match = /^(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?$/i.exec(trimmed);
  if (!match) {
    return { kind: 'invalid' };
  }
  let hours = Number(match[1]);
  const minutes = Number(match[2] ?? '0');
  const meridiem = match[3]?.[0].toLowerCase();
  if (meridiem) {
    if (hours < 1 || hours > 12) {
      return { kind: 'invalid' };
    }
    hours = (hours % 12) + (meridiem === 'p' ? 12 : 0);
  }
  if (hours > 23 || minutes > 59) {
    return { kind: 'invalid' };
  }
  const date = new Date(now);
  date.setHours(hours, minutes, 0, 0);
  if (date.getTime() <= now.getTime()) {
    date.setDate(date.getDate() + 1);
  }
  return { kind: 'ok', date };
}
