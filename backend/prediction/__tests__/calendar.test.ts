import {
  bucketOf,
  dayTypeOf,
  holidayName,
  localTime,
  parseIso,
  toIso,
} from '../calendar';

const day = (iso: string) => parseIso(iso);

describe('holidayName', () => {
  it.each([
    ['2026-01-01', "New Year's Day"],
    ['2026-01-19', 'Martin Luther King Jr. Day'],
    ['2026-02-16', "Presidents' Day"],
    ['2026-05-25', 'Memorial Day'],
    ['2026-06-19', 'Juneteenth'],
    ['2026-09-07', 'Labor Day'],
    ['2026-03-31', 'Cesar Chavez Day'],
    ['2026-11-11', 'Veterans Day'],
    ['2026-11-26', 'Thanksgiving'],
    ['2026-11-27', 'Day after Thanksgiving'],
    ['2026-12-25', 'Christmas Day'],
  ])('%s is %s', (iso, name) => {
    expect(holidayName(day(iso))).toBe(name);
  });

  it('observes a Saturday holiday on Friday', () => {
    // July 4, 2026 is a Saturday.
    expect(holidayName(day('2026-07-04'))).toBe('Independence Day');
    expect(holidayName(day('2026-07-03'))).toBe('Independence Day (observed)');
  });

  it('observes a Sunday holiday on Monday', () => {
    // Christmas 2022 was a Sunday.
    expect(holidayName(day('2022-12-26'))).toBe('Christmas Day (observed)');
  });

  it("observes New Year's Day in the previous year when it is a Saturday", () => {
    // Jan 1, 2028 is a Saturday.
    expect(holidayName(day('2027-12-31'))).toBe("New Year's Day (observed)");
  });

  it('does not treat Columbus / Indigenous Peoples Day as a holiday', () => {
    expect(holidayName(day('2026-10-12'))).toBeUndefined();
    expect(dayTypeOf(day('2026-10-12'))).toBe('weekday');
  });

  it('is undefined on ordinary days', () => {
    expect(holidayName(day('2026-10-14'))).toBeUndefined();
    expect(holidayName(day('2026-10-19'))).toBeUndefined();
  });
});

describe('dayTypeOf', () => {
  it('separates weekdays and weekends', () => {
    expect(dayTypeOf(day('2026-10-14'))).toBe('weekday'); // Wednesday
    expect(dayTypeOf(day('2026-10-17'))).toBe('weekend'); // Saturday
    expect(dayTypeOf(day('2026-10-18'))).toBe('weekend'); // Sunday
  });

  it('treats holidays as their own type, even on weekdays', () => {
    expect(dayTypeOf(day('2026-11-26'))).toBe('holiday');
    expect(dayTypeOf(day('2026-09-07'))).toBe('holiday');
  });

  it('treats campus breaks as holidays, inclusive of both ends', () => {
    const breaks = [
      { name: 'Spring break', start: '2026-03-23', end: '2026-03-27' },
    ];
    expect(dayTypeOf(day('2026-03-22'), breaks)).toBe('weekend');
    expect(dayTypeOf(day('2026-03-23'), breaks)).toBe('holiday');
    expect(dayTypeOf(day('2026-03-25'), breaks)).toBe('holiday');
    expect(dayTypeOf(day('2026-03-27'), breaks)).toBe('holiday');
    expect(dayTypeOf(day('2026-03-30'), breaks)).toBe('weekday');
  });
});

describe('localTime', () => {
  it('converts to Pacific daylight time', () => {
    const { date, minuteOfDay } = localTime(new Date('2026-10-14T00:30:00Z'));
    expect(toIso(date)).toBe('2026-10-13');
    expect(minuteOfDay).toBe(17 * 60 + 30);
  });

  it('converts to Pacific standard time', () => {
    const { date, minuteOfDay } = localTime(new Date('2026-12-01T08:00:00Z'));
    expect(toIso(date)).toBe('2026-12-01');
    expect(minuteOfDay).toBe(0);
  });
});

describe('bucketOf', () => {
  it('uses 15-minute buckets', () => {
    expect(bucketOf(0)).toBe(0);
    expect(bucketOf(14)).toBe(0);
    expect(bucketOf(15)).toBe(1);
    expect(bucketOf(8 * 60)).toBe(32);
    expect(bucketOf(1439)).toBe(95);
  });
});
