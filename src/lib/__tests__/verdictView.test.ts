import { Verdict } from '../../api/types';
import { sampleResponse } from '../../samples';
import {
  departureChange,
  headline,
  optionViews,
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
