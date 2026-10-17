import { decide } from '../decide';
import { addMinutes } from '../../util/time';
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

  it('has no wait limit unless one is given', () => {
    const v = decide(slotsOf(CLEARING), requestWith({ goal: 'minimize_time' }));
    expect(DEFAULT_PREFERENCES.maxWaitMinutes).toBeUndefined();
    expect(v.waitMinutes).toBe(75); // waits as long as it takes to clear
    expect(v.reason).not.toContain('maximum');
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

  describe('leave-by limit', () => {
    const min = (minutes: number) => addMinutes(NOW, minutes);
    const fastest = { goal: 'minimize_time' as const };

    it('stops a wait from going past it', () => {
      // Waiting 75 would save the most, but the user must be on the road by 45.
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ ...fastest, leaveBy: min(50) }),
      );
      expect(v.action).toBe('wait');
      expect(v.waitMinutes).toBe(45);
      expect(v.minutesSaved).toBe(16);
    });

    it('allows leaving at exactly the leave-by time, but not a minute later', () => {
      const at = (limit: number) =>
        decide(
          slotsOf(CLEARING),
          requestWith({ ...fastest, leaveBy: min(limit) }),
        ).waitMinutes;
      expect(at(45)).toBe(45);
      expect(at(44)).toBe(30);
    });

    it('says so when the leave-by time is what stops a better wait', () => {
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ ...fastest, leaveBy: min(10) }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.reason).toBe(
        'Waiting longer would save more, but that is past your leave-by time.',
      );
    });

    it('changes nothing when it is beyond everything the app looks at', () => {
      const without = decide(slotsOf(CLEARING), requestWith(fastest));
      const far = decide(
        slotsOf(CLEARING),
        requestWith({ ...fastest, leaveBy: min(600) }),
      );
      expect(far).toEqual(without);
    });

    it('still lets the user leave now when the time has already passed', () => {
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ ...fastest, leaveBy: min(-30) }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.waitMinutes).toBe(0);
    });

    it('does not blame it when waiting would not help anyway', () => {
      const flat = slotsOf([
        40, 38, 36, 35, 34, 33, 33, 33, 33, 33, 33, 33, 33,
      ]);
      const v = decide(flat, requestWith({ ...fastest, leaveBy: min(10) }));
      expect(v.reason).toBe("Traffic won't improve much in the next 3 hours.");
    });

    it('works with the maximum wait: the stricter of the two wins', () => {
      const wait = (maxWaitMinutes: number, leaveBy: Date) =>
        decide(
          slotsOf(CLEARING),
          requestWith({ ...fastest, maxWaitMinutes, leaveBy }),
        ).waitMinutes;
      expect(wait(60, min(30))).toBe(30);
      expect(wait(30, min(60))).toBe(30);
    });

    it('can leave a late arrival standing when the only on-time wait is too late', () => {
      // Waiting 15 minutes gets there at 65, in time for a 66 deadline. Leaving
      // now arrives at 70.
      const slots = slotsOf([
        70, 50, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
      ]);
      const deadline = min(66);
      const free = decide(slots, requestWith({ arriveBy: deadline }));
      expect(free.action).toBe('wait');
      expect(free.waitMinutes).toBe(15);
      const limited = decide(
        slots,
        requestWith({ arriveBy: deadline, leaveBy: min(10) }),
      );
      expect(limited.action).toBe('leave_now');
      expect(limited.lateByMinutes).toBe(4);
    });
  });

  describe('room to spare before the deadline', () => {
    const min = (minutes: number) => addMinutes(NOW, minutes);

    it('says how much room there is when leaving now is fine', () => {
      const v = decide(
        slotsOf(CLEARING.map(() => 40)),
        requestWith({ arriveBy: min(120) }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.deadline?.arriveBy).toEqual(min(120));
      expect(v.deadline?.marginMinutes).toBe(80);
    });

    it('finds the last departure that still makes it', () => {
      // 40-minute drives, deadline 120 minutes out: leave by +80.
      const v = decide(
        slotsOf(CLEARING.map(() => 40)),
        requestWith({ arriveBy: min(120) }),
      );
      expect(v.deadline?.latestDeparture?.departAt).toEqual(min(75));
      expect(v.deadline?.latestDeparture?.arriveAt).toEqual(min(115));
    });

    it('measures the room from the option it recommends', () => {
      const v = decide(
        slotsOf(CLEARING),
        requestWith({ goal: 'minimize_time', arriveBy: min(170) }),
      );
      expect(v.action).toBe('wait');
      expect(v.deadline?.marginMinutes).toBe(
        170 - v.waitMinutes - v.recommended.driveMinutes,
      );
    });

    it('leaves out the latest departure when the forecast ends before the deadline', () => {
      // Slots run 3 hours, every one arrives in time, and the deadline is later.
      const v = decide(
        slotsOf(CLEARING.map(() => 40)),
        requestWith({ goal: 'minimize_time', arriveBy: min(400) }),
      );
      expect(v.deadline?.latestDeparture).toBeUndefined();
      expect(v.deadline?.marginMinutes).toBe(360);
    });

    it('is absent without a deadline, and when the deadline cannot be met', () => {
      expect(decide(slotsOf(CLEARING), requestWith()).deadline).toBeUndefined();
      const late = decide(
        slotsOf(CLEARING),
        requestWith({ arriveBy: min(20) }),
      );
      expect(late.lateByMinutes).toBeDefined();
      expect(late.deadline).toBeUndefined();
    });
  });

  describe('a deadline far beyond the forecast', () => {
    const min = (minutes: number) => addMinutes(NOW, minutes);
    /** 15-minute slots to 3 hours, then every 30, out to `last` minutes. */
    function longSlots(driveAt: (offset: number) => number, last: number) {
      const offsets = [];
      for (let o = 0; o <= 180; o += 15) offsets.push(o);
      for (let o = 210; o <= last; o += 30) offsets.push(o);
      return offsets.map<SlotPrediction>(offset => {
        const driveMinutes = driveAt(offset);
        const departAt = min(offset);
        return {
          departAt,
          driveMinutes,
          arriveAt: addMinutes(departAt, driveMinutes),
          confidence: 'High',
          confidenceReason: 'High reason',
        };
      });
    }

    it('recommends the latest departure that arrives with 10 minutes to spare', () => {
      // Deadline at +300, 60-minute drives: leave at +230 to arrive at +290.
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ arriveBy: min(300) }),
      );
      expect(v.action).toBe('leave_later');
      expect(v.recommended.departAt).toEqual(min(210)); // slots are 30 apart: +240 would arrive at +300, with no spare
      expect(v.waitMinutes).toBe(210);
      expect(v.deadline?.marginMinutes).toBe(30);
      expect(v.deadline?.latestDeparture?.departAt).toEqual(min(240));
      expect(v.reason).toBe(
        'Your deadline is 5 hours away, so there is no rush. Leaving in 3 hr 30 min still gets you there with 30 minutes to spare.',
      );
    });

    it('ignores the longest-wait setting, which is for short waits', () => {
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ arriveBy: min(300), maxWaitMinutes: 30 }),
      );
      expect(v.action).toBe('leave_later');
      expect(v.waitMinutes).toBe(210);
    });

    it('stops at the leave-by time, and says so', () => {
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ arriveBy: min(300), leaveBy: min(200) }),
      );
      expect(v.action).toBe('leave_later');
      expect(v.recommended.departAt).toEqual(min(180)); // the last slot at or before +200
      expect(v.reason).toMatch(/as late as your leave-by time allows\.$/);
    });

    it('does not use the plan when leave-by has already passed', () => {
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ arriveBy: min(300), leaveBy: min(-5) }),
      );
      expect(v.action).toBe('leave_now');
    });

    it('for least driving, picks the quietest time, preferring the later of ties', () => {
      // Drives are 90 at +60..+120 and 60 otherwise; leaving now takes 90.
      const slots = longSlots(o => (o <= 120 ? 90 : 60), 330);
      const v = decide(
        slots,
        requestWith({ goal: 'minimize_time', arriveBy: min(300) }),
      );
      expect(v.action).toBe('leave_later');
      expect(v.recommended.driveMinutes).toBe(60);
      expect(v.recommended.departAt).toEqual(min(210));
      expect(v.reason).toBe(
        'Traffic is lightest if you leave in 3 hr 30 min: 60 minutes of driving instead of 90.',
      );
    });

    it('for least driving, leaves now when waiting would not save enough', () => {
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ goal: 'minimize_time', arriveBy: min(300) }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.deadline?.latestDeparture?.departAt).toEqual(min(240));
    });

    it('is not used when the deadline is within 3 hours', () => {
      const v = decide(
        longSlots(() => 60, 330),
        requestWith({ arriveBy: min(150) }),
      );
      expect(v.action).toBe('leave_now');
    });

    it('is not used when the forecast ends before the deadline does', () => {
      // 12 hours of slots, deadline 20 hours out: no way to tell the last time.
      const v = decide(
        longSlots(() => 60, 720),
        requestWith({ arriveBy: min(1200) }),
      );
      expect(v.action).toBe('leave_now');
      expect(v.deadline?.latestDeparture).toBeUndefined();
    });

    it('does not plan ahead when leaving now already misses the deadline', () => {
      const v = decide(
        longSlots(() => 400, 330),
        requestWith({ arriveBy: min(300) }),
      );
      expect(v.action).not.toBe('leave_later');
      expect(v.lateByMinutes).toBeGreaterThan(0);
    });
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
