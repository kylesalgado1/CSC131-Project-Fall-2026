import { getVerdict } from '../index';
import { LIVE_DECAY_MINUTES, predictSlots } from '../predict';
import { FakeBaselineProvider, FakeLiveProvider } from '../providers/fake';
import { LiveConditionsProvider, NoLiveConditions } from '../providers/live';
import { DEFAULT_PREFERENCES, TripRequest } from '../types';

const NOW = new Date('2026-10-13T17:00:00Z');
const request: TripRequest = {
  route: {
    origin: { lat: 38.56, lng: -121.42 },
    destination: { lat: 38.54, lng: -121.74 },
  },
  now: NOW,
  preferences: DEFAULT_PREFERENCES,
};

const flat = (minutes: number, samples?: number) =>
  new FakeBaselineProvider(() => minutes, samples);

describe('predictSlots', () => {
  it('returns 15-minute slots covering at least 3 hours, starting now', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30),
      live: new NoLiveConditions(),
    });
    expect(slots).toHaveLength(13);
    expect(slots[0].departAt).toEqual(NOW);
    const gaps = slots
      .slice(1)
      .map(
        (s, i) => (s.departAt.getTime() - slots[i].departAt.getTime()) / 60_000,
      );
    expect(new Set(gaps)).toEqual(new Set([15]));
    const span = slots[12].departAt.getTime() - NOW.getTime();
    expect(span).toBeGreaterThanOrEqual(3 * 60 * 60_000);
  });

  it('adds live congestion and fades it out', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30),
      live: new FakeLiveProvider({
        available: true,
        extraMinutes: 20,
        incidents: [],
      }),
    });
    expect(slots[0].driveMinutes).toBe(50);
    expect(slots[2].driveMinutes).toBe(40);
    expect(slots[LIVE_DECAY_MINUTES / 15].driveMinutes).toBe(30);
    expect(slots[12].driveMinutes).toBe(30);
  });

  it('falls back to the baseline when the live feed is unavailable', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30),
      live: new NoLiveConditions(),
    });
    expect(slots.every(s => s.driveMinutes === 30)).toBe(true);
    expect(slots[0].confidence).toBe('Medium');
  });

  it('falls back to the baseline when the live feed throws', async () => {
    const failing: LiveConditionsProvider = {
      getAdjustment: () => Promise.reject(new Error('feed down')),
    };
    const slots = await predictSlots(request, {
      baseline: flat(30),
      live: failing,
    });
    expect(slots.every(s => s.driveMinutes === 30)).toBe(true);
  });

  it('marks confidence Low for an incident or sparse history', async () => {
    const incident = await predictSlots(request, {
      baseline: flat(30),
      live: new FakeLiveProvider({
        available: true,
        extraMinutes: 5,
        incidents: [{ description: 'Collision on I-80' }],
      }),
    });
    expect(incident[0].confidence).toBe('Low');

    const sparse = await predictSlots(request, {
      baseline: flat(30, 3),
      live: new FakeLiveProvider({
        available: true,
        extraMinutes: 0,
        incidents: [],
      }),
    });
    expect(sparse[0].confidence).toBe('Low');
  });

  it('marks confidence High with plenty of data and a live feed', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30, 200),
      live: new FakeLiveProvider({
        available: true,
        extraMinutes: 0,
        incidents: [],
      }),
    });
    expect(slots[0].confidence).toBe('High');
  });

  it('lowers confidence when the history is mostly estimated', async () => {
    const live = new FakeLiveProvider({
      available: true,
      extraMinutes: 0,
      incidents: [],
    });
    const confidenceAt = async (observedShare?: number) =>
      (
        await predictSlots(request, {
          baseline: new FakeBaselineProvider(() => 30, 200, observedShare),
          live,
        })
      )[0];

    expect((await confidenceAt(0.1)).confidence).toBe('Low');
    expect((await confidenceAt(0.4)).confidence).toBe('Medium');
    expect((await confidenceAt(0.9)).confidence).toBe('High');
    // A source that does not report the share is not penalized.
    expect((await confidenceAt(undefined)).confidence).toBe('High');
    expect((await confidenceAt(0.1)).confidenceReason).toMatch(/estimated/);
  });

  it('rounds drive time to whole minutes', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30.4),
      live: new NoLiveConditions(),
    });
    expect(slots[0].driveMinutes).toBe(30);
  });
});

describe('slots for a far-off deadline', () => {
  const withDeadline = (minutesAway: number): TripRequest => ({
    ...request,
    preferences: {
      ...DEFAULT_PREFERENCES,
      arriveBy: new Date(NOW.getTime() + minutesAway * 60_000),
    },
  });
  const offsetsOf = async (req: TripRequest) =>
    (
      await predictSlots(req, {
        baseline: flat(30),
        live: new NoLiveConditions(),
      })
    ).map(slot => (slot.departAt.getTime() - NOW.getTime()) / 60_000);

  it('keeps the usual slots when the deadline is within 3 hours', async () => {
    expect(await offsetsOf(withDeadline(120))).toHaveLength(13);
    expect(await offsetsOf(withDeadline(180))).toHaveLength(13);
  });

  it('adds 30-minute slots until the deadline, never past it by more than one', async () => {
    const offsets = await offsetsOf(withDeadline(300));
    expect(offsets.slice(12, 17)).toEqual([180, 210, 240, 270, 300]);
    expect(offsets).toHaveLength(17);
  });

  it('rounds up to cover a deadline between slots', async () => {
    const offsets = await offsetsOf(withDeadline(305));
    expect(offsets[offsets.length - 1]).toBe(330);
  });

  it('stops at 12 hours however far off the deadline is', async () => {
    const offsets = await offsetsOf(withDeadline(30 * 60));
    expect(offsets[offsets.length - 1]).toBe(720);
  });

  it('puts the far slots on the half hour, so they hold still as "now" moves', async () => {
    const later = new Date(NOW.getTime() + 7 * 60_000); // 17:07
    const slotsFor = async (now: Date) =>
      (
        await predictSlots(
          {
            ...request,
            now,
            preferences: {
              ...DEFAULT_PREFERENCES,
              arriveBy: new Date(NOW.getTime() + 300 * 60_000),
            },
          },
          { baseline: flat(30), live: new NoLiveConditions() },
        )
      ).map(slot => slot.departAt.toISOString());
    const far = (times: string[]) =>
      times.filter(t => t.endsWith(':00:00.000Z') || t.endsWith(':30:00.000Z'));
    const first = await slotsFor(NOW);
    const second = await slotsFor(later);
    expect(second.slice(13)).toEqual(
      first.slice(13).filter(t => t > second[12]),
    );
    expect(far(second.slice(13)).length).toBe(second.length - 13);
    expect(second[13]).toBe('2026-10-13T20:30:00.000Z');
  });

  it('uses the baseline for the far slots', async () => {
    const slots = await predictSlots(withDeadline(300), {
      baseline: new FakeBaselineProvider(at =>
        at.getTime() > NOW.getTime() + 200 * 60_000 ? 20 : 30,
      ),
      live: new NoLiveConditions(),
    });
    expect(slots[slots.length - 1].driveMinutes).toBe(20);
  });
});

describe('slots from the earliest time the user can leave', () => {
  const LATER = new Date(NOW.getTime() + 2 * 60 * 60_000);
  const after = (leaveAfter?: Date): TripRequest => ({
    ...request,
    preferences: { ...DEFAULT_PREFERENCES, leaveAfter },
  });
  const providers = {
    baseline: flat(30),
    live: new FakeLiveProvider({
      available: true,
      extraMinutes: 20,
      incidents: [],
    }),
  };

  it('start there instead of now', async () => {
    const slots = await predictSlots(after(LATER), providers);
    expect(slots).toHaveLength(13);
    expect(slots[0].departAt).toEqual(LATER);
    expect(slots[12].departAt.getTime() - LATER.getTime()).toBe(
      3 * 60 * 60_000,
    );
  });

  it('ignore a time that has passed, or is now', async () => {
    for (const leaveAfter of [new Date(NOW.getTime() - 60_000), NOW]) {
      const slots = await predictSlots(after(leaveAfter), providers);
      expect(slots[0].departAt).toEqual(NOW);
    }
  });

  it('leave live congestion behind, since it fades within the hour', async () => {
    const slots = await predictSlots(after(LATER), providers);
    expect(slots.every(slot => slot.driveMinutes === 30)).toBe(true);
  });

  it('reach a far deadline from the earliest time, not from now', async () => {
    const deadline = new Date(LATER.getTime() + 8 * 60 * 60_000);
    const slots = await predictSlots(
      {
        ...request,
        preferences: {
          ...DEFAULT_PREFERENCES,
          leaveAfter: LATER,
          arriveBy: deadline,
        },
      },
      providers,
    );
    expect(slots[0].departAt).toEqual(LATER);
    expect(slots[slots.length - 1].departAt.getTime()).toBeGreaterThanOrEqual(
      deadline.getTime(),
    );
  });
});

describe('class ends at 2:00 PM, pick-up by 5:00 PM', () => {
  // 9:00 AM Pacific now. A 30 minute drive that grows to 40 after 3:30 PM.
  const morning = new Date('2026-10-29T16:00:00Z');
  const twoPm = new Date('2026-10-29T21:00:00Z');
  const fivePm = new Date('2026-10-30T00:00:00Z');
  const threeThirty = new Date('2026-10-29T22:30:00Z');
  const providers = {
    baseline: new FakeBaselineProvider(at => (at < threeThirty ? 30 : 40)),
    live: new NoLiveConditions(),
  };
  const ask = (preferences = {}) =>
    getVerdict(
      {
        ...request,
        now: morning,
        preferences: {
          ...DEFAULT_PREFERENCES,
          goal: 'arrive_by',
          arriveBy: fivePm,
          leaveAfter: twoPm,
          ...preferences,
        },
      },
      providers,
    );

  it('recommends the latest safe departure, not 2:00 PM', async () => {
    const { verdict } = await ask();
    expect(verdict.action).toBe('leave_later');
    expect(verdict.recommended.departAt).toEqual(
      new Date('2026-10-29T23:00:00Z'), // 4:00 PM
    );
    expect(verdict.recommended.arriveAt).toEqual(
      new Date('2026-10-29T23:40:00Z'), // 4:40 PM, 20 minutes to spare
    );
    expect(verdict.deadline?.marginMinutes).toBe(20);
  });

  it('never plans a departure before the earliest time', async () => {
    const { slots } = await ask();
    expect(slots[0].departAt).toEqual(twoPm);
    expect(slots.every(s => s.departAt >= twoPm)).toBe(true);
  });

  it('is the same without a leave-after, since 4:00 PM is later anyway', async () => {
    const { verdict } = await ask({ leaveAfter: undefined });
    expect(verdict.recommended.departAt).toEqual(
      new Date('2026-10-29T23:00:00Z'),
    );
  });
});

describe('getVerdict', () => {
  it('goes end to end from providers to a stay-or-go answer', async () => {
    // Congested for the first hour, then normal.
    const baseline = new FakeBaselineProvider(departAt => {
      const offset = (departAt.getTime() - NOW.getTime()) / 60_000;
      return offset < 60 ? 70 - offset / 2 : 35;
    });
    const { slots, verdict } = await getVerdict(
      {
        ...request,
        preferences: { ...DEFAULT_PREFERENCES, goal: 'minimize_time' },
      },
      { baseline, live: new NoLiveConditions() },
    );
    expect(slots).toHaveLength(13);
    expect(verdict.action).toBe('wait');
    expect(verdict.waitMinutes).toBe(60);
    expect(verdict.minutesSaved).toBe(35);
  });
});
