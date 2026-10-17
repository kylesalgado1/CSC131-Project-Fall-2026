/**
 * A worked example of what the app is for: a UCLA student is done with class
 * at 2:00 PM on a Friday and has a concert at SoFi Stadium at 8:30 PM. Is
 * leaving now the only way to get there, or is there time to study, work out
 * or get coffee first?
 *
 * The drive times are a stand-in shaped like TomTom's typical Friday traffic
 * for UCLA to SoFi (about 13.6 miles, 23 minutes with no traffic), rounded to
 * the nearest 5 minutes: light after lunch, heaviest from 4 to 5 PM, easing
 * through the evening. They are an illustration, not measured data.
 *
 * To read the answer as the app would give it:
 *
 *   SHOW_SCENARIO=1 npx jest backend/prediction/__tests__/concertScenario
 */
import { decide } from '../decide';
import { slotTimesFor } from '../predict';
import {
  DEFAULT_PREFERENCES,
  Preferences,
  SlotPrediction,
  TripRequest,
  Verdict,
} from '../types';
import { addMinutes, minutesBetween } from '../../util/time';

const UCLA = { lat: 34.0689, lng: -118.4452 };
const SOFI = { lat: 33.9535, lng: -118.3392 };

// Friday 2026-10-23, Pacific daylight time (UTC-7).
const NOW = new Date('2026-10-23T21:00:00Z'); // 2:00 PM
const CONCERT = new Date('2026-10-24T03:30:00Z'); // 8:30 PM

/** [hour on the local clock, drive minutes], joined by straight lines. */
const FRIDAY_TYPICAL: Array<[number, number]> = [
  [14, 35],
  [15, 45],
  [16, 50],
  [17, 50],
  [18, 45],
  [19, 35],
  [20, 30],
  [21, 25],
];

function typicalDrive(departAt: Date, surge: (hour: number) => number): number {
  const hour = 14 + minutesBetween(NOW, departAt) / 60;
  const after = FRIDAY_TYPICAL.findIndex(([h]) => h >= hour);
  const [h1, d1] = FRIDAY_TYPICAL[Math.max(after, 1) - 1];
  const [h2, d2] = FRIDAY_TYPICAL[Math.max(after, 1)];
  const base = d1 + ((d2 - d1) * (hour - h1)) / (h2 - h1);
  return Math.round(base + surge(hour));
}

function request(prefs: Partial<Preferences> = {}): TripRequest {
  return {
    route: { origin: UCLA, destination: SOFI },
    now: NOW,
    preferences: { ...DEFAULT_PREFERENCES, arriveBy: CONCERT, ...prefs },
  };
}

/** The slots the server would build for this request. */
function slotsFor(
  req: TripRequest,
  surge: (hour: number) => number = () => 0,
): SlotPrediction[] {
  return slotTimesFor(req).map(departAt => {
    const driveMinutes = typicalDrive(departAt, surge);
    return {
      departAt,
      driveMinutes,
      arriveAt: addMinutes(departAt, driveMinutes),
      confidence: 'High',
      confidenceReason: 'Based on typical Friday traffic.',
    };
  });
}

const clock = (date: Date): string =>
  date
    .toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      timeZone: 'America/Los_Angeles',
    })
    .replace(' ', ' ');

const hm = (minutes: number): string =>
  minutes < 60
    ? `${minutes} min`
    : `${Math.floor(minutes / 60)} hr${
        minutes % 60 ? ` ${minutes % 60} min` : ''
      }`;

/** A sample evening, to show the free time is room for real plans. */
const SAMPLE_PLAN: Array<[string, number]> = [
  ['Gym', 75],
  ['Study at the library', 120],
  ['Coffee', 30],
  ['Shower and get ready', 30],
];

function printAnswer(title: string, slots: SlotPrediction[], verdict: Verdict) {
  const out: string[] = ['', `=== ${title} ===`, ''];
  const spare = (slot: SlotPrediction) =>
    minutesBetween(slot.arriveAt, CONCERT);
  out.push(
    'UCLA to SoFi Stadium. Class ends 2:00 PM. Concert at 8:30 PM.',
    '',
    `Verdict: ${
      verdict.action === 'leave_later'
        ? `Leave at ${clock(verdict.recommended.departAt)}`
        : verdict.action === 'no_rush'
        ? 'No need to leave yet'
        : verdict.action
    }`,
    verdict.reason,
    '',
    'Every departure and when it gets you there:',
    '  Leave      Drive    Arrive     Spare before 8:30 PM',
  );
  for (const slot of slots.filter(
    s =>
      minutesBetween(NOW, s.departAt) % 60 === 0 ||
      s.departAt.getTime() === verdict.recommended.departAt.getTime(),
  )) {
    const room = spare(slot);
    const mark =
      verdict.action !== 'no_rush' &&
      slot.departAt.getTime() === verdict.recommended.departAt.getTime()
        ? '  <-- recommended'
        : '';
    out.push(
      `  ${clock(slot.departAt).padEnd(9)}  ${`${slot.driveMinutes} min`.padEnd(
        7,
      )}  ${clock(slot.arriveAt).padEnd(9)}  ${
        room >= 0 ? hm(room) : `${hm(-room)} LATE`
      }${mark}`,
    );
  }
  const leaveNow = verdict.leaveNow;
  const latest = verdict.deadline?.latestDeparture;
  out.push(
    '',
    `Leaving now (${clock(NOW)}) gets you to SoFi at ${clock(
      leaveNow.arriveAt,
    )}, ${hm(minutesBetween(leaveNow.arriveAt, CONCERT))} before the concert.`,
  );
  if (latest) {
    out.push(
      `The latest you can leave and still make it: ${clock(latest.departAt)}.`,
    );
  }
  // With no departure recommended, the time to spend runs to the latest one.
  const free =
    verdict.action === 'no_rush' && latest
      ? minutesBetween(NOW, latest.departAt)
      : verdict.waitMinutes;
  if (free > 0) {
    const planned = SAMPLE_PLAN.reduce((sum, [, m]) => sum + m, 0);
    out.push(
      '',
      `Time to spend before you need to go: ${hm(free)}.`,
      'A sample afternoon:',
      ...SAMPLE_PLAN.map(([what, m]) => `  - ${what}: ${hm(m)}`),
      free >= planned
        ? `  ${hm(planned)} planned, ${hm(free - planned)} to spare.`
        : `  ${hm(planned)} planned: ${hm(planned - free)} too much for ${hm(
            free,
          )}, so something would have to go.`,
    );
  }
  out.push('');
  process.stdout.write(out.join('\n'));
}

const show = process.env.SHOW_SCENARIO === '1';
const at = (hour: number, minute = 0): Date =>
  addMinutes(NOW, (hour - 14) * 60 + minute);

/** Runs a scenario, printing it when asked, and returns what it found. */
function run(
  title: string,
  prefs: Partial<Preferences> = {},
  surge?: (hour: number) => number,
) {
  const req = request(prefs);
  const slots = slotsFor(req, surge);
  const verdict = decide(slots, req);
  if (show) {
    printAnswer(title, slots, verdict);
  }
  return { slots, verdict };
}

describe('a UCLA student with a concert at SoFi', () => {
  describe('on a typical Friday', () => {
    const { slots, verdict } = run('Typical Friday traffic');

    it('is planned as a departure time, since the concert is hours away', () => {
      expect(verdict.action).toBe('leave_later');
    });

    it('does not say to leave now: nearly six hours of waiting is fine', () => {
      expect(verdict.leaveNow.arriveAt).toEqual(at(14, 35));
      expect(minutesBetween(verdict.leaveNow.arriveAt, CONCERT)).toBe(355);
      expect(verdict.recommended.departAt).not.toEqual(
        verdict.leaveNow.departAt,
      );
    });

    it('recommends leaving at 7:30 PM, 27 minutes to spare', () => {
      expect(verdict.recommended.departAt).toEqual(at(19, 30));
      expect(verdict.recommended.arriveAt).toEqual(at(20, 3));
      expect(verdict.waitMinutes).toBe(330); // 5 hr 30 min to spend first
      expect(verdict.deadline?.marginMinutes).toBe(27);
    });

    it('shows 8:00 PM as the latest departure that still makes it', () => {
      expect(verdict.deadline?.latestDeparture?.departAt).toEqual(at(20));
    });

    it('finds that every departure from now to 8:00 PM arrives in time', () => {
      const onTime = slots.filter(s => s.arriveAt <= CONCERT);
      expect(onTime[0].departAt).toEqual(NOW);
      expect(onTime[onTime.length - 1].departAt).toEqual(at(20));
      expect(
        slots.some(s => s.departAt > at(20) && s.arriveAt <= CONCERT),
      ).toBe(false);
    });

    it('leaves room for a gym session, studying, coffee and getting ready', () => {
      const planned = SAMPLE_PLAN.reduce((sum, [, m]) => sum + m, 0);
      expect(planned).toBeLessThan(verdict.waitMinutes);
    });
  });

  it('with concert traffic building after 6 PM, leaves earlier', () => {
    // Fans heading to the stadium add about half an hour from 6 PM on.
    const { verdict } = run(
      'Concert traffic adds 30 minutes after 6 PM',
      {},
      hour => (hour >= 18 ? 30 : 0),
    );
    expect(verdict.action).toBe('leave_later');
    expect(verdict.recommended.departAt).toEqual(at(19));
    expect(verdict.deadline?.latestDeparture?.departAt).toEqual(at(19));
    expect(verdict.recommended.departAt.getTime()).toBeLessThan(
      at(19, 30).getTime(),
    );
  });

  it('respects a leave-by time: a student who has to go by 5 PM', () => {
    const { verdict } = run('Has to be on the road by 5:00 PM', {
      leaveBy: at(17),
    });
    expect(verdict.action).toBe('leave_later');
    expect(verdict.recommended.departAt).toEqual(at(17));
    expect(verdict.reason).toMatch(/as late as your leave-by time allows\.$/);
  });

  describe('with the least-driving goal', () => {
    const { verdict } = run('Least driving goal', { goal: 'minimize_time' });

    it('says there is no rush, not "leave now": waiting saves too little', () => {
      // The quietest road that still arrives with time to spare (7:30 PM, 33
      // minutes) saves 2 minutes over leaving now (35), under the 10 minute
      // minimum, so no departure is worth recommending.
      expect(verdict.action).toBe('no_rush');
      expect(verdict.reason).toMatch(/^Waiting would save at most 2 minutes/);
      expect(verdict.minutesSaved).toBe(0);
    });

    it('still gives the window: the latest departure that makes it', () => {
      expect(verdict.deadline?.latestDeparture?.departAt).toEqual(at(20));
    });
  });
});
