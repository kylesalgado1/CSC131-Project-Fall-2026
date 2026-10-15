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
