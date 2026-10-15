import { formatDuration, formatTime, plural } from '../format';

describe('plural', () => {
  it('adds an s except for one', () => {
    expect(plural(1, 'minute')).toBe('1 minute');
    expect(plural(0, 'minute')).toBe('0 minutes');
    expect(plural(75, 'minute')).toBe('75 minutes');
  });
});

describe('formatDuration', () => {
  it.each([
    [0, '0 min'],
    [45, '45 min'],
    [59.6, '1 hr'],
    [60, '1 hr'],
    [75, '1 hr 15 min'],
    [180, '3 hr'],
  ])('%s minutes is %s', (minutes, text) => {
    expect(formatDuration(minutes)).toBe(text);
  });
});

describe('formatTime', () => {
  const options = { locale: 'en-US', timeZone: 'America/Los_Angeles' };

  it('shows the time of day on the given clock', () => {
    expect(formatTime('2026-10-21T14:05:00Z', options)).toBe('7:05 AM');
    expect(formatTime('2026-10-22T01:30:00Z', options)).toBe('6:30 PM');
  });

  it('follows daylight saving', () => {
    expect(formatTime('2026-11-04T15:00:00Z', options)).toBe('7:00 AM');
  });

  it('accepts a Date', () => {
    expect(formatTime(new Date('2026-10-21T14:05:00Z'), options)).toBe(
      '7:05 AM',
    );
  });
});
