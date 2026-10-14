import { decide } from '../decide';
import { addMinutes } from '../predict';
import {
  Confidence,
  DEFAULT_PREFERENCES,
  Preferences,
  SlotPrediction,
  TripRequest,
} from '../types';

const NOW = new Date('2026-10-13T17:00:00Z');
const ROUTE = {
  origin: { lat: 38.56, lng: -121.42 },
  destination: { lat: 38.54, lng: -121.74 },
};

/** Drive minutes for the slots at +0, +15, +30, ... */
function slotsOf(drives: number[], confidence: Confidence = 'High') {
  return drives.map<SlotPrediction>((driveMinutes, i) => {
    const departAt = addMinutes(NOW, i * 15);
    return {
      departAt,
      driveMinutes,
      arriveAt: addMinutes(departAt, driveMinutes),
      confidence,
      confidenceReason: `${confidence} reason`,
    };
  });
}

const requestWith = (prefs: Partial<Preferences> = {}): TripRequest => ({
  route: ROUTE,
  now: NOW,
  preferences: { ...DEFAULT_PREFERENCES, ...prefs },
});

// Leaving now takes 60 min. It clears to 32 min by +75 and stays there.
const CLEARING = [60, 55, 50, 44, 38, 32, 32, 32, 32, 32, 32, 32, 32];

describe('decide', () => {
  it('recommends waiting when it saves enough', () => {
    const v = decide(slotsOf(CLEARING), requestWith({ goal: 'minimize_time' }));
    expect(v.action).toBe('wait');
    expect(v.waitMinutes).toBe(75);
    expect(v.minutesSaved).toBe(28);
    expect(v.arrivalDelayMinutes).toBe(47);
    expect(v.reason).toBe(
      "Wait 75 minutes: you'll save 28 minutes in traffic and you arrive 47 minutes later.",
    );
  });

  it('reports savings and delay as the difference from leaving now', () => {
    const v = decide(slotsOf(CLEARING), requestWith({ goal: 'minimize_time' }));
    expect(v.minutesSaved).toBe(
      v.leaveNow.driveMinutes - v.recommended.driveMinutes,
    );
    const nowArrival = v.leaveNow.arriveAt.getTime();
    const recArrival = v.recommended.arriveAt.getTime();
    expect(v.arrivalDelayMinutes).toBe(
      Math.round((recArrival - nowArrival) / 60_000),
    );
  });

  it('returns whole minutes', () => {
    const v = decide(slotsOf(CLEARING), requestWith());
    for (const n of [v.waitMinutes, v.minutesSaved, v.arrivalDelayMinutes]) {
      expect(Number.isInteger(n)).toBe(true);
    }
  });

  it('says leave now when no wait saves the minimum', () => {
    const v = decide(
      slotsOf([40, 38, 36, 35, 34, 33, 33, 33, 33, 33, 33, 33, 33]),
      requestWith(),
    );
    expect(v.action).toBe('leave_now');
    expect(v.waitMinutes).toBe(0);
    expect(v.minutesSaved).toBe(0);
    expect(v.reason).toBe("Traffic won't improve much in the next 3 hours.");
  });

  it('honors a custom minimum savings', () => {
    const slots = slotsOf([40, 36, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33]);
    expect(decide(slots, requestWith({ goal: 'minimize_time' })).action).toBe(
      'leave_now',
    );
    const v = decide(
      slots,
      requestWith({ goal: 'minimize_time', minSavingsMinutes: 5 }),
    );
    expect(v.action).toBe('wait');
    expect(v.minutesSaved).toBe(7);
  });

  it('never recommends a wait longer than the maximum', () => {
    const v = decide(
      slotsOf(CLEARING),
      requestWith({ goal: 'minimize_time', maxWaitMinutes: 45 }),
    );
    expect(v.waitMinutes).toBeLessThanOrEqual(45);
    expect(v.waitMinutes).toBe(45);
    expect(v.minutesSaved).toBe(16);
  });

  it('explains when only a longer wait would help', () => {
    const v = decide(
      slotsOf(CLEARING),
      requestWith({ goal: 'minimize_time', maxWaitMinutes: 15 }),
    );
    expect(v.action).toBe('leave_now');
    expect(v.reason).toContain('15 minutes maximum');
  });

  it('prefers a shorter wait in balance mode', () => {
    // Waiting 90 saves the most (28) but arrives 62 minutes later.
    // Waiting 15 saves 15 with no arrival delay.
    const slots = slotsOf([60, 45, 40, 38, 36, 34, 32, 32, 32, 32, 32, 32, 32]);
    const minimize = decide(slots, requestWith({ goal: 'minimize_time' }));
    const balance = decide(slots, requestWith({ goal: 'balance' }));
    expect(minimize.waitMinutes).toBe(90);
    expect(balance.action).toBe('wait');
    expect(balance.waitMinutes).toBe(15);
  });

  it('leaves now in balance mode when the delay outweighs the saving', () => {
    // Saves 10 minutes but only by waiting 60: delay 50, weighted 25 > 10.
    const v = decide(
      slotsOf([50, 50, 50, 50, 40, 40, 40, 40, 40, 40, 40, 40, 40]),
      requestWith({ goal: 'balance' }),
    );
    expect(v.action).toBe('leave_now');
  });

  describe('arrival deadline', () => {
    it('never recommends an arrival after the deadline', () => {
      // Leaving now arrives 18:00. Deadline 18:50 rules out waiting past +75.
      const deadline = new Date('2026-10-13T18:50:00Z');
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ goal: 'arrive_by', arriveBy: deadline }),
      );
      expect(v.recommended.arriveAt.getTime()).toBeLessThanOrEqual(
        deadline.getTime(),
      );
      expect(v.action).toBe('wait');
      expect(v.waitMinutes).toBe(75);
    });

    it('applies the deadline to every goal', () => {
      const deadline = new Date('2026-10-13T18:50:00Z');
      for (const goal of ['minimize_time', 'balance', 'arrive_by'] as const) {
        const v = decide(
          slotsOf(CLEARING),
          requestWith({ goal, arriveBy: deadline }),
        );
        expect(v.recommended.arriveAt.getTime()).toBeLessThanOrEqual(
          deadline.getTime(),
        );
      }
    });

    it('says leave now and how late when nothing meets the deadline', () => {
      const deadline = new Date('2026-10-13T17:45:00Z');
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ goal: 'arrive_by', arriveBy: deadline }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.lateByMinutes).toBe(15);
      expect(v.reason).toBe('Leave now, you may be late by about 15 minutes.');
    });

    it('recommends waiting when leaving now would be late but later is on time', () => {
      // Leaving now arrives 18:10, after the 18:05 deadline. Waiting 15
      // minutes and driving 50 arrives exactly 18:05.
      const slots = slotsOf([
        70, 50, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
      ]);
      const deadline = new Date('2026-10-13T18:05:00Z');
      const v = decide(
        slots,
        requestWith({ goal: 'arrive_by', arriveBy: deadline }),
      );
      expect(v.action).toBe('wait');
      expect(v.waitMinutes).toBe(15);
      expect(v.recommended.arriveAt.getTime()).toBeLessThanOrEqual(
        deadline.getTime(),
      );
    });
  });

  describe('confidence', () => {
    it('uses the lower of leave-now and recommended confidence', () => {
      const slots = slotsOf(CLEARING);
      slots[0].confidence = 'Medium';
      slots[0].confidenceReason = 'now is medium';
      const v = decide(slots, requestWith({ goal: 'minimize_time' }));
      expect(v.confidence).toBe('Medium');
      expect(v.confidenceReason).toBe('now is medium');
    });

    it('is Low when the recommended slot is Low', () => {
      const slots = slotsOf(CLEARING);
      slots[5].confidence = 'Low';
      const v = decide(slots, requestWith({ goal: 'minimize_time' }));
      expect(v.recommended.driveMinutes).toBe(32);
      expect(v.confidence).toBe('Low');
    });
  });
});
