import { toIso } from '../../prediction/calendar';
import {
  formatClock,
  nextWednesday,
  parseCoordinate,
  parseTimes,
} from '../checkTrip';

describe('parseCoordinate', () => {
  it('reads latitude and longitude', () => {
    expect(parseCoordinate('38.5593, -121.4237', '--to')).toEqual({
      lat: 38.5593,
      lng: -121.4237,
    });
  });

  it.each([
    '',
    'abc',
    '12.34',
    '12.34,56.78,9',
    '91,0',
    '0,181',
    '12.34,',
    ',56.78',
    ' , ',
  ])('rejects %p without repeating it', text => {
    let message = '';
    try {
      parseCoordinate(text, '--from');
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toContain('--from must look like');
    if (text) {
      expect(message).not.toContain(text);
    }
  });
});

describe('parseTimes', () => {
  it('reads times into minutes after midnight', () => {
    expect(parseTimes('07:00,18:30, 6:05')).toEqual([420, 1110, 365]);
  });

  it.each(['7', '24:00', '12:60', 'noon', ''])('rejects %p', text => {
    expect(() => parseTimes(text)).toThrow('--times must look like');
  });

  it('formats minutes back into a clock', () => {
    expect(formatClock(420)).toBe('07:00');
    expect(formatClock(1110)).toBe('18:30');
  });
});

describe('nextWednesday', () => {
  // 2026-10-21 is a Wednesday.
  it('is the following week when today is Wednesday', () => {
    expect(toIso(nextWednesday(new Date('2026-10-21T19:00:00Z')))).toBe(
      '2026-10-28',
    );
  });

  it.each([
    ['2026-10-19T19:00:00Z', '2026-10-21'], // Monday
    ['2026-10-22T19:00:00Z', '2026-10-28'], // Thursday
    ['2026-10-25T19:00:00Z', '2026-10-28'], // Sunday
  ])('from %s is %s', (now, expected) => {
    expect(toIso(nextWednesday(new Date(now)))).toBe(expected);
  });

  it('uses the local date, not the UTC date', () => {
    // 02:00 UTC on Thursday 10/22 is still Wednesday evening in California.
    expect(toIso(nextWednesday(new Date('2026-10-22T02:00:00Z')))).toBe(
      '2026-10-28',
    );
  });
});
