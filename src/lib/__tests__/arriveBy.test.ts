import { parseArriveBy } from '../arriveBy';

// Local time, so the test does not depend on the machine's time zone.
const at = (hours: number, minutes = 0, day = 21) =>
  new Date(2026, 9, day, hours, minutes, 0, 0);

const parsed = (text: string, now = at(7, 0)) => {
  const result = parseArriveBy(text, now);
  return result.kind === 'ok' ? result.date : result.kind;
};

describe('parseArriveBy', () => {
  it('means no deadline when empty', () => {
    expect(parsed('')).toBe('none');
    expect(parsed('   ')).toBe('none');
  });

  it.each([
    ['8:30 AM', at(8, 30)],
    ['8:30am', at(8, 30)],
    ['8:30 a.m.', at(8, 30)],
    ['5:45 PM', at(17, 45)],
    ['5pm', at(17, 0)],
    ['17:45', at(17, 45)],
    ['9', at(9, 0)],
    ['12 AM', at(0, 0, 22)], // midnight has passed today, so it is tomorrow
    ['12 PM', at(12, 0)],
    ['12:15 pm', at(12, 15)],
  ])('reads %p', (text, expected) => {
    expect(parsed(text)).toEqual(expected);
  });

  it('means tomorrow when the time has already passed', () => {
    expect(parsed('6:00 AM')).toEqual(at(6, 0, 22));
    expect(parsed('7:00 AM')).toEqual(at(7, 0, 22)); // exactly now has passed
  });

  it.each(['noon', '25:00', '8:75', '13 PM', '0 AM', '8:3', 'abc', '8:30 xm'])(
    'rejects %p',
    text => {
      expect(parsed(text)).toBe('invalid');
    },
  );

  it('does not change the clock it was given', () => {
    const now = at(7, 0);
    parseArriveBy('9:00', now);
    expect(now).toEqual(at(7, 0));
  });
});
