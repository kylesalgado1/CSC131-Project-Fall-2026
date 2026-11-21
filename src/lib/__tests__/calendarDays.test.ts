import {
  calendarWeeks,
  dateKey,
  longDay,
  monthTitle,
  parseDateKey,
} from '../calendarDays';

describe('calendar days', () => {
  it('dateKey uses local dates, padded', () => {
    expect(dateKey(new Date(2026, 0, 5, 23, 59))).toBe('2026-01-05');
  });

  it('lays a month out in weeks starting on Sunday', () => {
    const weeks = calendarWeeks(2026, 9); // October 2026 starts on a Thursday
    expect(weeks.every(week => week.length === 7)).toBe(true);
    expect(weeks).toHaveLength(5);
    expect(weeks[0].map(cell => cell?.day)).toEqual([
      undefined,
      undefined,
      undefined,
      undefined,
      1,
      2,
      3,
    ]);
    expect(weeks[0][4]?.key).toBe('2026-10-01');
    expect(weeks[4].map(cell => cell?.day)).toEqual([
      25, 26, 27, 28, 29, 30, 31,
    ]);
  });

  it('adds a row when a month needs six', () => {
    expect(calendarWeeks(2026, 7)).toHaveLength(6); // August 2026
  });

  it('handles February in a leap year and December', () => {
    const feb = calendarWeeks(2028, 1).flat().filter(Boolean);
    expect(feb).toHaveLength(29);
    expect(calendarWeeks(2026, 11).flat().filter(Boolean)).toHaveLength(31);
  });

  it('names months and days', () => {
    expect(monthTitle(2026, 9)).toBe('October 2026');
    expect(longDay(parseDateKey('2026-10-23'))).toBe('Fri, Oct 23');
  });
});
