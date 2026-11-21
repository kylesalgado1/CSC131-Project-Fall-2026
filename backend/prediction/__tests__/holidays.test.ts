import { assessConfidence } from '../confidence';
import { predictSlots } from '../predict';
import { FakeBaselineProvider } from '../providers/fake';
import { NoLiveConditions } from '../providers/live';
import {
  BaselineResult,
  DEFAULT_PREFERENCES,
  LiveAdjustment,
  TripRequest,
} from '../types';

const route = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
};
const request = (now: string): TripRequest => ({
  route,
  now: new Date(now),
  preferences: DEFAULT_PREFERENCES,
});
const flat = new FakeBaselineProvider(() => 30);
const providers = { baseline: flat, live: new NoLiveConditions() };

describe('holidays on predicted slots', () => {
  it('flags nothing on an ordinary day', async () => {
    const slots = await predictSlots(
      request('2026-10-21T14:00:00Z'),
      providers,
    );
    expect(slots.every(s => s.holiday === undefined)).toBe(true);
  });

  it('flags a holiday by name', async () => {
    // Veterans Day, 7 AM Pacific.
    const slots = await predictSlots(
      request('2026-11-11T15:00:00Z'),
      providers,
    );
    expect(slots.every(s => s.holiday === 'Veterans Day')).toBe(true);
  });

  it('flags the slots by the day they depart, not the day it is now', async () => {
    // 11:30 PM the night before Veterans Day: the first two slots are still the 10th.
    const slots = await predictSlots(
      request('2026-11-11T07:30:00Z'),
      providers,
    );
    expect(slots.slice(0, 2).map(s => s.holiday)).toEqual([
      undefined,
      undefined,
    ]);
    expect(slots.slice(2).every(s => s.holiday === 'Veterans Day')).toBe(true);
  });

  it('flags a campus break by its name', async () => {
    const slots = await predictSlots(request('2026-10-21T14:00:00Z'), {
      ...providers,
      campusBreaks: [
        { name: 'Fall break', start: '2026-10-21', end: '2026-10-23' },
      ],
    });
    expect(slots.every(s => s.holiday === 'Fall break')).toBe(true);
  });

  it('ignores a campus break on other days', async () => {
    const slots = await predictSlots(request('2026-10-21T14:00:00Z'), {
      ...providers,
      campusBreaks: [
        { name: 'Fall break', start: '2026-12-01', end: '2026-12-05' },
      ],
    });
    expect(slots.every(s => s.holiday === undefined)).toBe(true);
  });

  it('lowers confidence when the baseline is a holiday estimate', async () => {
    const estimate: FakeBaselineProvider = Object.assign(
      new FakeBaselineProvider(() => 30),
      {
        getBaseline: async (): Promise<BaselineResult> => ({
          minutes: 30,
          sampleCount: 100,
          observedShare: 1,
          basis: 'holiday_estimate',
        }),
      },
    );
    const [first] = await predictSlots(request('2026-11-11T15:00:00Z'), {
      baseline: estimate,
      live: {
        getAdjustment: async () => ({
          available: true,
          extraMinutes: 0,
          incidents: [],
        }),
      },
    });
    expect(first.confidence).toBe('Low');
    expect(first.confidenceReason).toMatch(/holiday or campus break/);
  });
});

describe('assessConfidence, rule by rule', () => {
  const live: LiveAdjustment = {
    available: true,
    extraMinutes: 0,
    incidents: [],
  };
  const rich: BaselineResult = {
    minutes: 30,
    sampleCount: 100,
    observedShare: 1,
  };
  const verdict = (
    base: Partial<BaselineResult>,
    l: Partial<LiveAdjustment> = {},
  ) => assessConfidence({ ...rich, ...base }, { ...live, ...l });

  it('is High with plenty of measured history and live data', () => {
    expect(verdict({}).confidence).toBe('High');
  });

  it('is Low with an incident, before anything else', () => {
    const result = verdict(
      { basis: 'holiday_estimate' },
      { incidents: [{ description: 'Crash' }] },
    );
    expect(result.confidence).toBe('Low');
    expect(result.reason).toMatch(/incident/);
  });

  it('is Low for a holiday estimate, whatever else is true', () => {
    const result = verdict({ basis: 'holiday_estimate' });
    expect(result.confidence).toBe('Low');
    expect(result.reason).toMatch(/holiday/);
  });

  it('is Low with little history, Low or Medium with mostly estimated history', () => {
    expect(verdict({ sampleCount: 5 }).confidence).toBe('Low');
    expect(verdict({ observedShare: 0.1 }).confidence).toBe('Low');
    expect(verdict({ observedShare: 0.4 }).confidence).toBe('Medium');
  });

  it('is Medium without live data or with limited history', () => {
    expect(verdict({}, { available: false }).confidence).toBe('Medium');
    expect(verdict({ sampleCount: 30 }).confidence).toBe('Medium');
  });

  it('does not penalize a source that does not report its measured share', () => {
    expect(verdict({ observedShare: undefined }).confidence).toBe('High');
  });
});
