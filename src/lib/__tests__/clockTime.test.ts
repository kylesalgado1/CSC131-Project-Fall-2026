import {
  dayOf,
  formatClockTime,
  fromWheels,
  nextOccurrence,
  suggestedTime,
  toWheels,
} from '../clockTime';

// Built in local time, so the tests do not depend on the machine's zone.
const at = (hours: number, minutes = 0, day = 21) =>
  new Date(2026, 9, day, hours, minutes, 0, 0);

describe('formatClockTime', () => {
  it.each([
    [{ hour: 0, minute: 0 }, '12:00 AM'],
    [{ hour: 0, minute: 5 }, '12:05 AM'],
    [{ hour: 7, minute: 5 }, '7:05 AM'],
    [{ hour: 11, minute: 59 }, '11:59 AM'],
    [{ hour: 12, minute: 0 }, '12:00 PM'],
    [{ hour: 12, minute: 30 }, '12:30 PM'],
    [{ hour: 17, minute: 45 }, '5:45 PM'],
    [{ hour: 23, minute: 55 }, '11:55 PM'],
  ])('shows %j as %s', (time, text) => {
    expect(formatClockTime(time)).toBe(text);
  });
});

describe('wheels', () => {
  it('splits a time into hour 1 to 12, minute and AM or PM', () => {
    expect(toWheels({ hour: 0, minute: 0 })).toEqual({
      hour12: 12,
      minute: 0,
      pm: false,
    });
    expect(toWheels({ hour: 9, minute: 15 })).toEqual({
      hour12: 9,
      minute: 15,
      pm: false,
    });
    expect(toWheels({ hour: 12, minute: 30 })).toEqual({
      hour12: 12,
      minute: 30,
      pm: true,
    });
    expect(toWheels({ hour: 23, minute: 5 })).toEqual({
      hour12: 11,
      minute: 5,
      pm: true,
    });
  });

  it('puts the wheels back together', () => {
    expect(fromWheels({ hour12: 12, minute: 0, pm: false })).toEqual({
      hour: 0,
      minute: 0,
    });
    expect(fromWheels({ hour12: 12, minute: 0, pm: true })).toEqual({
      hour: 12,
      minute: 0,
    });
    expect(fromWheels({ hour12: 8, minute: 30, pm: true })).toEqual({
      hour: 20,
      minute: 30,
    });
    expect(fromWheels({ hour12: 1, minute: 5, pm: false })).toEqual({
      hour: 1,
      minute: 5,
    });
  });

  it('round-trips every time of day', () => {
    for (let hour = 0; hour < 24; hour++) {
      for (const minute of [0, 5, 30, 55]) {
        expect(fromWheels(toWheels({ hour, minute }))).toEqual({
          hour,
          minute,
        });
      }
    }
  });
});

describe('nextOccurrence', () => {
  it('is later today when the time has not come', () => {
    expect(nextOccurrence({ hour: 17, minute: 30 }, at(7, 0))).toEqual(
      at(17, 30),
    );
  });

  it('is tomorrow when the time has passed, or is exactly now', () => {
    expect(nextOccurrence({ hour: 6, minute: 0 }, at(7, 0))).toEqual(
      at(6, 0, 22),
    );
    expect(nextOccurrence({ hour: 7, minute: 0 }, at(7, 0))).toEqual(
      at(7, 0, 22),
    );
  });

  it('counts a minute from now as today', () => {
    expect(nextOccurrence({ hour: 7, minute: 1 }, at(7, 0))).toEqual(at(7, 1));
  });

  it('crosses a month end', () => {
    const lateOnThe31st = new Date(2026, 9, 31, 23, 0, 0, 0);
    expect(nextOccurrence({ hour: 6, minute: 0 }, lateOnThe31st)).toEqual(
      new Date(2026, 10, 1, 6, 0, 0, 0),
    );
  });

  it('does not change the date it was given', () => {
    const now = at(7, 0);
    nextOccurrence({ hour: 6, minute: 0 }, now);
    expect(now).toEqual(at(7, 0));
  });
});

describe('dayOf', () => {
  it('says today or tomorrow', () => {
    expect(dayOf({ hour: 17, minute: 0 }, at(7, 0))).toBe('today');
    expect(dayOf({ hour: 6, minute: 0 }, at(7, 0))).toBe('tomorrow');
  });
});

describe('suggestedTime', () => {
  it('is a while from now, rounded up to the next five minutes', () => {
    expect(suggestedTime(at(7, 2), 30)).toEqual({ hour: 7, minute: 35 });
    expect(suggestedTime(at(7, 0), 30)).toEqual({ hour: 7, minute: 30 });
    expect(suggestedTime(at(7, 51), 30)).toEqual({ hour: 8, minute: 25 });
  });

  it('wraps past midnight', () => {
    expect(suggestedTime(at(23, 50), 30)).toEqual({ hour: 0, minute: 20 });
    expect(suggestedTime(at(23, 58), 0)).toEqual({ hour: 0, minute: 0 });
  });
});
