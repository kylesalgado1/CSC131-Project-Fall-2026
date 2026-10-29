import { Verdict } from '../../api/types';
import { sampleResponse } from '../../samples';
import {
  deadlineLines,
  departureChange,
  headline,
  optionViews,
  startsLater,
  toneOf,
  tradeoffLines,
} from '../verdictView';

const NOW = new Date('2026-10-21T14:00:00Z'); // 7:00 AM Pacific
const time = { locale: 'en-US', timeZone: 'America/Los_Angeles' };
const wait = sampleResponse('wait', NOW).verdict;
const leaveNow = sampleResponse('leave_now', NOW).verdict;
const late = sampleResponse('late', NOW).verdict;

describe('headline', () => {
  it('is one of the two answers', () => {
    expect(headline(leaveNow)).toBe('Leave now');
    expect(headline(wait)).toBe('Wait 60 minutes');
    expect(headline({ ...wait, waitMinutes: 1 })).toBe('Wait 1 minute');
  });
});

const noRush: Verdict = {
  ...leaveNow,
  action: 'no_rush',
  reason: 'Your deadline is 20 hours away. There is no need to leave yet.',
};

describe('when there is no rush', () => {
  it('says so, in the calm tone, with no options to compare', () => {
    expect(headline(noRush)).toBe('No need to leave yet');
    expect(toneOf(noRush)).toBe('wait');
    expect(optionViews(noRush, time)).toEqual([]);
    expect(tradeoffLines(noRush)).toEqual([]);
    expect(deadlineLines(noRush, time)).toEqual([]);
  });

  it('announces the change once, not on every refresh', () => {
    expect(departureChange(leaveNow, noRush, time)).toBe(
      'Update: your deadline is far off, so there is no need to leave yet.',
    );
    const later = {
      ...noRush,
      recommended: { ...noRush.recommended, departAt: '2026-10-21T14:05:00Z' },
    };
    expect(departureChange(noRush, later, time)).toBeUndefined();
  });
});

describe('toneOf', () => {
  it('tells go, wait and late apart', () => {
    expect(toneOf(leaveNow)).toBe('go');
    expect(toneOf(wait)).toBe('wait');
    expect(toneOf(late)).toBe('late');
  });
});

describe('optionViews', () => {
  it('shows just leaving now when that is the answer', () => {
    const [only, ...rest] = optionViews(leaveNow, time);
    expect(rest).toEqual([]);
    expect(only).toEqual({
      title: 'Leave now',
      leave: 'Leave 7:00 AM',
      arrive: 'Arrive 7:56 AM',
      drive: '56 min drive',
      recommended: true,
    });
  });

  it('shows both choices, local times and the recommended one, for a wait', () => {
    const [now, later] = optionViews(wait, time);
    expect(now).toMatchObject({
      title: 'Leave now',
      leave: 'Leave 7:00 AM',
      arrive: 'Arrive 8:10 AM',
      recommended: false,
    });
    expect(later).toMatchObject({
      title: 'Wait 60 minutes',
      leave: 'Leave 8:00 AM',
      arrive: 'Arrive 8:38 AM',
      drive: '38 min drive',
      recommended: true,
    });
  });
});

describe('tradeoffLines', () => {
  it('says what a wait saves and how much later you arrive', () => {
    expect(tradeoffLines(wait)).toEqual([
      'Save 32 minutes in the car',
      'Arrive 28 minutes later',
    ]);
  });

  it('handles arriving earlier or at the same time', () => {
    expect(tradeoffLines({ ...wait, arrivalDelayMinutes: -4 })[1]).toBe(
      'Arrive 4 minutes earlier',
    );
    expect(tradeoffLines({ ...wait, arrivalDelayMinutes: 0 })[1]).toBe(
      'Arrive at the same time',
    );
  });

  it('is empty when leaving now', () => {
    expect(tradeoffLines(leaveNow)).toEqual([]);
  });
});

describe('departureChange', () => {
  const moved = (minutes: number, over: Partial<Verdict> = {}): Verdict => ({
    ...wait,
    ...over,
    recommended: {
      ...wait.recommended,
      departAt: new Date(
        Date.parse(wait.recommended.departAt) + minutes * 60_000,
      ).toISOString(),
    },
  });

  it('has nothing to say the first time', () => {
    expect(departureChange(undefined, wait, time)).toBeUndefined();
  });

  it('ignores a shift under 5 minutes', () => {
    expect(departureChange(wait, moved(4), time)).toBeUndefined();
    expect(departureChange(wait, moved(-4), time)).toBeUndefined();
  });

  it('notices a shift of 5 minutes or more, either way', () => {
    expect(departureChange(wait, moved(5), time)).toMatch(
      /moved later, to 8:05 AM/,
    );
    expect(departureChange(wait, moved(-10), time)).toMatch(
      /now 7:50 AM, earlier/,
    );
  });

  it('notices a flip between waiting and leaving now', () => {
    expect(departureChange(wait, leaveNow, time)).toBe(
      'Update: traffic changed, so you should leave now.',
    );
    expect(departureChange(leaveNow, wait, time)).toMatch(/Update:/);
  });

  it('ignores identical advice', () => {
    expect(departureChange(wait, wait, time)).toBeUndefined();
  });
});

// Leaving at 11:00 AM Pacific for a 1:30 PM deadline, 60-minute drive.
const planned: Verdict = {
  ...leaveNow,
  action: 'leave_later',
  waitMinutes: 240,
  recommended: {
    departAt: '2026-10-21T18:00:00.000Z',
    arriveAt: '2026-10-21T19:00:00.000Z',
    driveMinutes: 60,
  },
  deadline: {
    arriveBy: '2026-10-21T20:30:00.000Z',
    marginMinutes: 90,
    latestDeparture: {
      departAt: '2026-10-21T19:15:00.000Z',
      arriveAt: '2026-10-21T20:15:00.000Z',
      driveMinutes: 60,
    },
  },
};

describe('a planned departure', () => {
  it('has the time to leave as its headline', () => {
    expect(headline(planned, time)).toBe('Leave at 11:00 AM');
    expect(toneOf(planned)).toBe('wait');
  });

  it('shows leaving now beside leaving later, with no wait-style tradeoff', () => {
    const options = optionViews(planned, time);
    expect(options.map(o => [o.title, o.recommended])).toEqual([
      ['Leave now', false],
      ['Leave later', true],
    ]);
    expect(options[1].leave).toBe('Leave 11:00 AM');
    expect(tradeoffLines(planned)).toEqual([]);
  });

  it('notices when the plan first appears, or moves', () => {
    expect(departureChange(leaveNow, planned, time)).toBe(
      'Update: the plan changed, so the best time to leave is 11:00 AM.',
    );
    const later = {
      ...planned,
      recommended: {
        ...planned.recommended,
        departAt: '2026-10-21T18:30:00.000Z',
      },
    };
    expect(departureChange(planned, later, time)).toBe(
      'Update: the best time to leave moved later, to 11:30 AM.',
    );
    expect(departureChange(planned, planned, time)).toBeUndefined();
  });
});

describe('deadlineLines', () => {
  it('says when you would arrive, how much room that leaves, and the latest to leave', () => {
    expect(deadlineLines(planned, time)).toEqual([
      'You would arrive 12:00 PM, 1 hr 30 min before your 1:30 PM deadline.',
      'Latest you can leave and still make it: 12:15 PM.',
    ]);
  });

  it('is empty without a deadline', () => {
    expect(deadlineLines(leaveNow, time)).toEqual([]);
  });

  it('leaves out the latest time when it is the time already recommended, or not known', () => {
    const same = {
      ...planned,
      deadline: {
        ...planned.deadline!,
        latestDeparture: { ...planned.recommended },
      },
    };
    expect(deadlineLines(same, time)).toHaveLength(1);
    const unknown = {
      ...planned,
      deadline: { ...planned.deadline!, latestDeparture: undefined },
    };
    expect(deadlineLines(unknown, time)).toHaveLength(1);
    const close = {
      ...planned,
      deadline: {
        ...planned.deadline!,
        latestDeparture: {
          ...planned.recommended,
          departAt: '2026-10-21T18:04:00.000Z',
        },
      },
    };
    expect(deadlineLines(close, time)).toHaveLength(1);
  });

  it('handles no room at all', () => {
    const tight = {
      ...planned,
      deadline: {
        ...planned.deadline!,
        marginMinutes: 0,
        latestDeparture: undefined,
      },
    };
    expect(deadlineLines(tight, time)[0]).toBe(
      'You would arrive 12:00 PM, right at your 1:30 PM deadline.',
    );
  });
});

describe('a plan that starts later, because the user cannot leave yet', () => {
  const at = (minutes: number) =>
    new Date(NOW.getTime() + minutes * 60_000).toISOString();
  // Class ends in two hours, so the earliest departure is then.
  const later = (verdict: Verdict): Verdict => {
    const earliest = {
      ...verdict.leaveNow,
      departAt: at(120),
      arriveAt: at(190),
    };
    return {
      ...verdict,
      generatedAt: at(0),
      leaveNow: earliest,
      // Leaving at the earliest time is its own recommendation.
      ...(verdict.action === 'leave_now' ? { recommended: earliest } : {}),
    };
  };

  it('is detected from the earliest departure, not the action', () => {
    expect(startsLater(leaveNow)).toBe(false);
    expect(startsLater(wait)).toBe(false);
    expect(startsLater(later(leaveNow))).toBe(true);
    // Under a minute of lead is just now.
    expect(
      startsLater({
        ...leaveNow,
        generatedAt: at(0),
        leaveNow: { ...leaveNow.leaveNow, departAt: at(0.5) },
      }),
    ).toBe(false);
  });

  it('gives a time instead of "now"', () => {
    expect(headline(later(leaveNow), time)).toBe('Leave at 9:00 AM');
  });

  it('gives the time to wait until instead of a number of minutes', () => {
    const verdict = {
      ...later(wait),
      recommended: { ...wait.recommended, departAt: at(180) },
    };
    expect(headline(verdict, time)).toBe('Wait until 10:00 AM');
    expect(optionViews(verdict, time).map(o => o.title)).toEqual([
      'Earliest',
      'Wait until 10:00 AM',
    ]);
  });

  it('says leave at that time when traffic changes', () => {
    expect(departureChange(later(wait), later(leaveNow), time)).toBe(
      'Update: traffic changed, so you should leave at 9:00 AM.',
    );
  });
});
