import {
  addDays,
  formatWithOffset,
  instantAt,
  parseIso,
  toIso,
  weekdayOf,
} from '../calendar';

describe('instantAt', () => {
  it('finds the instant for a local time in daylight saving time', () => {
    expect(instantAt(parseIso('2026-10-21'), 7 * 60).toISOString()).toBe(
      '2026-10-21T14:00:00.000Z',
    );
  });

  it('finds the instant in standard time, an hour later in UTC', () => {
    expect(instantAt(parseIso('2026-11-04'), 7 * 60).toISOString()).toBe(
      '2026-11-04T15:00:00.000Z',
    );
  });

  it('handles the days daylight saving starts and ends', () => {
    // Clocks went forward on 2026-03-08 and back on 2026-11-01.
    expect(instantAt(parseIso('2026-03-08'), 12 * 60).toISOString()).toBe(
      '2026-03-08T19:00:00.000Z',
    );
    expect(instantAt(parseIso('2026-11-01'), 12 * 60).toISOString()).toBe(
      '2026-11-01T20:00:00.000Z',
    );
  });

  it('handles late evening crossing into the next UTC day', () => {
    expect(instantAt(parseIso('2026-10-21'), 18 * 60 + 30).toISOString()).toBe(
      '2026-10-22T01:30:00.000Z',
    );
  });
});

describe('formatWithOffset', () => {
  it('writes the local clock with the UTC offset', () => {
    expect(formatWithOffset(new Date('2026-10-21T14:00:00Z'))).toBe(
      '2026-10-21T07:00:00-07:00',
    );
    expect(formatWithOffset(new Date('2026-11-04T15:00:00Z'))).toBe(
      '2026-11-04T07:00:00-08:00',
    );
  });

  it('rolls into the previous local day when UTC is already tomorrow', () => {
    expect(formatWithOffset(new Date('2026-10-22T01:30:00Z'))).toBe(
      '2026-10-21T18:30:00-07:00',
    );
  });

  it('round-trips with instantAt', () => {
    const at = instantAt(parseIso('2026-12-24'), 8 * 60 + 15);
    expect(formatWithOffset(at)).toBe('2026-12-24T08:15:00-08:00');
  });
});

describe('addDays and weekdayOf', () => {
  it('moves across month and year ends', () => {
    expect(toIso(addDays(parseIso('2026-10-30'), 3))).toBe('2026-11-02');
    expect(toIso(addDays(parseIso('2026-12-30'), 3))).toBe('2027-01-02');
    expect(toIso(addDays(parseIso('2026-03-01'), -1))).toBe('2026-02-28');
  });

  it('knows the day of the week', () => {
    expect(weekdayOf(parseIso('2026-10-21'))).toBe(3); // Wednesday
  });
});
