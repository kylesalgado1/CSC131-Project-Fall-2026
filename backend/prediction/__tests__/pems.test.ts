import { NoLiveConditions } from '../providers/live';
import { getVerdict } from '../index';
import { aggregateProfiles } from '../providers/pems/aggregate';
import { parsePemsFile, parsePemsLine } from '../providers/pems/parse';
import {
  NoBaselineCoverageError,
  PemsBaselineProvider,
  RouteResolver,
} from '../providers/pems/provider';
import { InMemoryProfileStore } from '../providers/pems/store';
import { PemsObservation, ProfileRow } from '../providers/pems/types';
import { DEFAULT_PREFERENCES, Route } from '../types';

const ROUTE: Route = {
  origin: { lat: 38.56, lng: -121.42 },
  destination: { lat: 38.54, lng: -121.74 },
};

const obs = (over: Partial<PemsObservation> = {}): PemsObservation => ({
  stationId: 101,
  localDate: '2026-10-14', // Wednesday
  minuteOfDay: 8 * 60,
  avgSpeedMph: 60,
  totalFlow: 100,
  pctObserved: 100,
  ...over,
});

describe('parsePemsLine', () => {
  const line =
    '10/14/2026 08:05:00,312345,3,80,E,ML,0.5,12,100,120,0.12,58.3,1,40,0.1,60';

  it('reads station, local time, speed, flow and coverage', () => {
    expect(parsePemsLine(line)).toEqual({
      stationId: 312345,
      localDate: '2026-10-14',
      minuteOfDay: 8 * 60 + 5,
      avgSpeedMph: 58.3,
      totalFlow: 120,
      pctObserved: 100,
    });
  });

  describe('lines from a real District 4 file (2026-10-12)', () => {
    // 52 columns: station summary, then five lanes with blank unused lanes.
    const measured =
      '10/12/2026 00:00:00,400000,4,101,S,ML,.415,40,100,35,.0067,68.1,10,3,.0017,74.8,1,10,10,.0066,71,1,10,15,.0125,67.4,1,10,7,.0059,62.8,1,,,,,0,,,,,0,,,,,0,,,,,0';
    // Observed 0%: PeMS filled this reading in, but it still carries values.
    const imputed =
      '10/12/2026 00:00:00,400001,4,101,N,ML,.265,50,0,107,.0191,67.3,10,14,.015,74.1,0,10,29,.0242,70.7,0,10,24,.0184,67.8,0,10,14,.0068,67.3,0,10,26,.0312,59.6,0,,,,,0,,,,,0,,,,,0';

    it('parses a measured reading', () => {
      expect(parsePemsLine(measured)).toEqual({
        stationId: 400000,
        localDate: '2026-10-12',
        minuteOfDay: 0,
        avgSpeedMph: 68.1,
        totalFlow: 35,
        pctObserved: 100,
      });
    });

    it('parses an imputed reading with its 0% observed flag', () => {
      expect(parsePemsLine(imputed)).toMatchObject({
        stationId: 400001,
        avgSpeedMph: 67.3,
        totalFlow: 107,
        pctObserved: 0,
      });
    });
  });

  it('skips blank speeds, bad timestamps and short lines', () => {
    expect(
      parsePemsLine(
        '10/14/2026 08:05:00,312345,3,80,E,ML,0.5,12,100,120,0.12,',
      ),
    ).toBeNull();
    expect(
      parsePemsLine('2026-10-14,312345,3,80,E,ML,0.5,12,100,120,0.12,58.3'),
    ).toBeNull();
    expect(parsePemsLine('10/14/2026 08:05:00,312345')).toBeNull();
    expect(parsePemsLine('')).toBeNull();
  });

  it('parses a whole file and drops unusable lines', () => {
    const text = [line, 'garbage', line.replace('58.3', '45.0'), ''].join('\n');
    expect(parsePemsFile(text)).toHaveLength(2);
  });
});

describe('aggregateProfiles', () => {
  it('averages speeds as a harmonic mean, so slow readings weigh more', () => {
    // 60 mph and 30 mph with equal flow: 2 / (1/60 + 1/30) = 40.
    const rows = aggregateProfiles([
      obs({ avgSpeedMph: 60 }),
      obs({ avgSpeedMph: 30, minuteOfDay: 8 * 60 + 5 }),
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0].avgSpeedMph).toBeCloseTo(40);
    expect(rows[0].bucket).toBe(32);
  });

  it('weights readings by flow', () => {
    const rows = aggregateProfiles([
      obs({ avgSpeedMph: 60, totalFlow: 300 }),
      obs({ avgSpeedMph: 30, totalFlow: 100, minuteOfDay: 8 * 60 + 5 }),
    ]);
    // 400 / (300/60 + 100/30) = 48
    expect(rows[0].avgSpeedMph).toBeCloseTo(48);
  });

  it('counts distinct days, not readings', () => {
    const rows = aggregateProfiles([
      obs(),
      obs({ minuteOfDay: 8 * 60 + 5 }),
      obs({ minuteOfDay: 8 * 60 + 10 }),
      obs({ localDate: '2026-10-15' }),
    ]);
    expect(rows[0].sampleCount).toBe(2);
  });

  it('ignores readings that were mostly unobserved', () => {
    const rows = aggregateProfiles([
      obs({ pctObserved: 30, avgSpeedMph: 5 }),
      obs({ avgSpeedMph: 60 }),
    ]);
    expect(rows[0].avgSpeedMph).toBeCloseTo(60);
  });

  it('takes free-flow speed from the overnight readings only', () => {
    const rows = aggregateProfiles([
      obs({ minuteOfDay: 2 * 60, avgSpeedMph: 70 }),
      obs({ minuteOfDay: 3 * 60, avgSpeedMph: 68 }),
      obs({ minuteOfDay: 4 * 60 + 55, avgSpeedMph: 66 }),
      obs({ minuteOfDay: 5 * 60, avgSpeedMph: 20 }), // 05:00 is not overnight
      obs({ minuteOfDay: 8 * 60, avgSpeedMph: 30 }),
    ]);
    expect(rows).toHaveLength(5);
    for (const row of rows) {
      expect(row.freeFlowMph).toBe(68);
    }
  });

  it('has no free-flow speed without overnight readings', () => {
    expect(aggregateProfiles([obs()])[0].freeFlowMph).toBeUndefined();
  });

  it('reports what share of readings were measured', () => {
    const rows = aggregateProfiles(
      [
        obs({ pctObserved: 100 }),
        obs({ pctObserved: 60, minuteOfDay: 8 * 60 + 5 }),
        obs({ pctObserved: 0, minuteOfDay: 8 * 60 + 10 }),
        obs({ pctObserved: 20, minuteOfDay: 8 * 60 + 14 }),
      ],
      { minPctObserved: 0 },
    );
    expect(rows[0].observedShare).toBe(0.5);
  });

  it('is fully measured when only measured readings pass the filter', () => {
    const rows = aggregateProfiles([
      obs({ pctObserved: 80 }),
      obs({ pctObserved: 0, minuteOfDay: 8 * 60 + 5 }),
    ]);
    expect(rows[0].observedShare).toBe(1);
  });

  it('keeps weekday, weekend and holiday data separate', () => {
    const rows = aggregateProfiles([
      obs({ localDate: '2026-10-14' }), // Wednesday
      obs({ localDate: '2026-10-17' }), // Saturday
      obs({ localDate: '2026-11-26' }), // Thanksgiving
    ]);
    expect(rows.map(r => r.dayType).sort()).toEqual([
      'holiday',
      'weekday',
      'weekend',
    ]);
  });

  it('treats campus breaks as holidays', () => {
    const rows = aggregateProfiles([obs({ localDate: '2026-10-14' })], {
      campusBreaks: [{ name: 'Break', start: '2026-10-14', end: '2026-10-14' }],
    });
    expect(rows[0].dayType).toBe('holiday');
  });

  it('accepts imputed readings when the threshold is lowered to 0', () => {
    const imputed = obs({ pctObserved: 0, avgSpeedMph: 45 });
    expect(aggregateProfiles([imputed])).toEqual([]);
    const rows = aggregateProfiles([imputed], { minPctObserved: 0 });
    expect(rows).toHaveLength(1);
    expect(rows[0].avgSpeedMph).toBeCloseTo(45);
  });

  it('separates stations and buckets', () => {
    const rows = aggregateProfiles([
      obs({ stationId: 101 }),
      obs({ stationId: 102 }),
      obs({ minuteOfDay: 9 * 60 }),
    ]);
    expect(rows).toHaveLength(3);
  });
});

describe('PemsBaselineProvider', () => {
  // Wednesday 08:00 Pacific daylight time.
  const MORNING = new Date('2026-10-14T15:00:00Z');
  const resolver: RouteResolver = {
    resolve: async () => ({
      segments: [
        { stationId: 101, lengthMiles: 2 },
        { stationId: 102, lengthMiles: 3 },
      ],
      uncoveredMiles: 0,
    }),
  };
  const row = (over: Partial<ProfileRow>): ProfileRow => ({
    stationId: 101,
    dayType: 'weekday',
    bucket: 32,
    avgSpeedMph: 60,
    sampleCount: 40,
    observedShare: 1,
    ...over,
  });
  const providerFor = (rows: ProfileRow[], r: RouteResolver = resolver) =>
    new PemsBaselineProvider(new InMemoryProfileStore(rows), r);

  it('sums length over speed for each segment', async () => {
    const result = await providerFor([
      row({ stationId: 101, avgSpeedMph: 60 }),
      row({ stationId: 102, avgSpeedMph: 30 }),
    ]).getBaseline(ROUTE, MORNING);
    // 2 miles at 60 = 2 min, 3 miles at 30 = 6 min.
    expect(result.minutes).toBeCloseTo(8);
    expect(result.sampleCount).toBe(40);
  });

  it('uses the local clock, not UTC, to pick the time bucket', async () => {
    // Bucket 32 is 08:00 local. 15:00 UTC would be bucket 60.
    const result = await providerFor([
      row({ stationId: 101 }),
      row({ stationId: 102 }),
    ]).getBaseline(ROUTE, MORNING);
    expect(result.minutes).toBeCloseTo(5);
  });

  it('fills a station with no data using the speed of the others', async () => {
    const result = await providerFor([
      row({ stationId: 101, avgSpeedMph: 40, sampleCount: 40 }),
    ]).getBaseline(ROUTE, MORNING);
    // 5 miles at 40 mph = 7.5 minutes. One of two stations is missing, so the
    // median sample count is (40 + 0) / 2.
    expect(result.minutes).toBeCloseTo(7.5);
    expect(result.sampleCount).toBe(20);
  });

  it('reports the length-weighted share of measured history', async () => {
    // Station 101 (2 miles) is fully measured; station 102 (3 miles) is
    // 20% measured. (2 * 1 + 3 * 0.2) / 5 = 0.52.
    const result = await providerFor([
      row({ stationId: 101, observedShare: 1 }),
      row({ stationId: 102, observedShare: 0.2 }),
    ]).getBaseline(ROUTE, MORNING);
    expect(result.observedShare).toBeCloseTo(0.52);
  });

  it('counts a station with no data as fully estimated', async () => {
    const result = await providerFor([
      row({ stationId: 101, observedShare: 1 }),
    ]).getBaseline(ROUTE, MORNING);
    // Only 2 of the 5 miles have data.
    expect(result.observedShare).toBeCloseTo(0.4);
  });

  it('adds time for road with no station, at the surface speed', async () => {
    const withGap: RouteResolver = {
      resolve: async () => ({
        segments: [{ stationId: 101, lengthMiles: 5 }],
        uncoveredMiles: 5,
      }),
    };
    const provider = providerFor(
      [row({ stationId: 101, avgSpeedMph: 60 })],
      withGap,
    );
    const result = await provider.getBaseline(ROUTE, MORNING);
    // 5 miles at 60 mph = 5 min, plus 5 miles at the 25 mph default = 12 min.
    expect(result.minutes).toBeCloseTo(17);
    // Only half the route's length rests on measured data.
    expect(result.observedShare).toBeCloseTo(0.5);
  });

  it('resolves the route once and reads the data once for many times', async () => {
    let resolves = 0;
    const counting: RouteResolver = {
      resolve: async r => {
        resolves += 1;
        return resolver.resolve(r);
      },
    };
    const reads: number[] = [];
    const store = new InMemoryProfileStore([
      row({ stationId: 101, bucket: 32 }),
      row({ stationId: 101, bucket: 33, avgSpeedMph: 30 }),
      row({ stationId: 102, bucket: 32 }),
      row({ stationId: 102, bucket: 33, avgSpeedMph: 30 }),
    ]);
    const original = store.getProfiles.bind(store);
    store.getProfiles = async (ids, keys) => {
      reads.push(keys.length);
      return original(ids, keys);
    };
    const provider = new PemsBaselineProvider(store, counting);
    const results = await provider.getBaselines(ROUTE, [
      MORNING,
      new Date(MORNING.getTime() + 15 * 60_000),
      MORNING,
    ]);
    expect(resolves).toBe(1);
    expect(reads).toEqual([2]); // two distinct buckets, one query
    expect(results[0].minutes).toBeCloseTo(5);
    expect(results[1].minutes).toBeCloseTo(10);
    expect(results[2].minutes).toBeCloseTo(5);
  });

  describe("with the routing service's free-flow time", () => {
    const withFreeFlow = (
      freeFlowMinutes: number | undefined,
      segments = [
        { stationId: 101, lengthMiles: 2 },
        { stationId: 102, lengthMiles: 3 },
      ],
      uncoveredMiles = 0,
    ): RouteResolver => ({
      resolve: async () => ({ segments, uncoveredMiles, freeFlowMinutes }),
    });
    const at = (rows: ProfileRow[], custom: RouteResolver) =>
      providerFor(rows, custom).getBaseline(ROUTE, MORNING);

    it('adds the delay beyond free-flow to the routing time', async () => {
      // 5 miles at 30 mph is 10 min; at 60 mph it is 5 min: 5 min of delay.
      const result = await at(
        [
          row({ stationId: 101, avgSpeedMph: 30, freeFlowMph: 60 }),
          row({ stationId: 102, avgSpeedMph: 30, freeFlowMph: 60 }),
        ],
        withFreeFlow(65),
      );
      expect(result.minutes).toBeCloseTo(70);
    });

    it('adds nothing when traffic moves at or above free-flow', async () => {
      const result = await at(
        [
          row({ stationId: 101, avgSpeedMph: 70, freeFlowMph: 60 }),
          row({ stationId: 102, avgSpeedMph: 60, freeFlowMph: 60 }),
        ],
        withFreeFlow(65),
      );
      expect(result.minutes).toBeCloseTo(65);
    });

    it('gives a station with no data the average delay per mile', async () => {
      // Station 101: 2 miles, 2 min of delay (1 min per mile). Station 102
      // has no profile, so its 3 miles get 3 min.
      const result = await at(
        [row({ stationId: 101, avgSpeedMph: 30, freeFlowMph: 60 })],
        withFreeFlow(60),
      );
      // 2 miles: 4 min at 30 mph vs 2 min at 60 mph = 2 min delay.
      expect(result.minutes).toBeCloseTo(60 + 2 + 3);
    });

    it('does not double count road with no station', async () => {
      // The routing time already covers the uncovered miles.
      const result = await at(
        [row({ stationId: 101, avgSpeedMph: 60, freeFlowMph: 60 })],
        withFreeFlow(60, [{ stationId: 101, lengthMiles: 5 }], 10),
      );
      expect(result.minutes).toBeCloseTo(60);
      // But they still count as unmeasured.
      expect(result.observedShare).toBeCloseTo(5 / 15);
    });

    it('falls back to summing PeMS speeds without a routing time', async () => {
      const result = await at(
        [
          row({ stationId: 101, avgSpeedMph: 60, freeFlowMph: 60 }),
          row({ stationId: 102, avgSpeedMph: 60, freeFlowMph: 60 }),
        ],
        withFreeFlow(undefined),
      );
      expect(result.minutes).toBeCloseTo(5);
    });

    it('falls back to summing speeds when free-flow speeds are unknown', async () => {
      const result = await at(
        [row({ stationId: 101 }), row({ stationId: 102 })], // no freeFlowMph
        withFreeFlow(65),
      );
      expect(result.minutes).toBeCloseTo(5);
    });
  });

  it('clamps unrealistic speeds', async () => {
    const result = await providerFor([
      row({ stationId: 101, avgSpeedMph: 0.5 }),
      row({ stationId: 102, avgSpeedMph: 300 }),
    ]).getBaseline(ROUTE, MORNING);
    // 2 miles at the 5 mph floor = 24 min, 3 miles at the 80 mph cap = 2.25.
    expect(result.minutes).toBeCloseTo(26.25);
  });

  it('throws when the route has no stations', async () => {
    const empty: RouteResolver = {
      resolve: async () => ({ segments: [], uncoveredMiles: 5 }),
    };
    await expect(
      providerFor([row({})], empty).getBaseline(ROUTE, MORNING),
    ).rejects.toThrow(NoBaselineCoverageError);
  });

  it('throws when no station has data for that time', async () => {
    await expect(
      providerFor([row({ bucket: 10 })]).getBaseline(ROUTE, MORNING),
    ).rejects.toThrow(NoBaselineCoverageError);
  });

  describe('holidays', () => {
    // Thanksgiving 2026, 08:00 Pacific standard time.
    const THANKSGIVING = new Date('2026-11-26T16:00:00Z');

    it('uses holiday profiles when they exist', async () => {
      const result = await providerFor([
        row({ stationId: 101, dayType: 'holiday', avgSpeedMph: 70 }),
        row({ stationId: 102, dayType: 'holiday', avgSpeedMph: 70 }),
        row({ stationId: 101, dayType: 'weekday', avgSpeedMph: 20 }),
        row({ stationId: 102, dayType: 'weekday', avgSpeedMph: 20 }),
      ]).getBaseline(ROUTE, THANKSGIVING);
      expect(result.minutes).toBeCloseTo((5 / 70) * 60);
      expect(result.sampleCount).toBe(40);
    });

    it('falls back to weekend data with low confidence', async () => {
      const result = await providerFor([
        row({ stationId: 101, dayType: 'weekend', avgSpeedMph: 60 }),
        row({ stationId: 102, dayType: 'weekend', avgSpeedMph: 60 }),
      ]).getBaseline(ROUTE, THANKSGIVING);
      expect(result.minutes).toBeCloseTo(5);
      expect(result.basis).toBe('holiday_estimate');
    });

    it('does not mark an ordinary day as an estimate', async () => {
      const result = await providerFor([
        row({ stationId: 101 }),
        row({ stationId: 102 }),
      ]).getBaseline(ROUTE, MORNING);
      expect(result.basis).toBeUndefined();
    });

    it('does not mark a holiday with its own history as an estimate', async () => {
      const result = await providerFor([
        row({ stationId: 101, dayType: 'holiday' }),
        row({ stationId: 102, dayType: 'holiday' }),
      ]).getBaseline(ROUTE, THANKSGIVING);
      expect(result.basis).toBeUndefined();
    });

    it('does not use weekday data for a holiday', async () => {
      await expect(
        providerFor([
          row({ stationId: 101 }),
          row({ stationId: 102 }),
        ]).getBaseline(ROUTE, THANKSGIVING),
      ).rejects.toThrow(NoBaselineCoverageError);
    });
  });

  it('feeds the stay-or-go decision end to end', async () => {
    // Rush hour: 15 mph at 08:00 easing to 60 mph by 09:00. Rows cover the
    // buckets from 08:00 (32) through 11:00 (44) at 15-minute steps.
    const speeds = [15, 20, 30, 45, 60, 60, 60, 60, 60, 60, 60, 60, 60];
    const rows = speeds.flatMap((mph, i) => [
      row({ stationId: 101, bucket: 32 + i, avgSpeedMph: mph }),
      row({ stationId: 102, bucket: 32 + i, avgSpeedMph: mph }),
    ]);
    const { slots, verdict } = await getVerdict(
      {
        route: ROUTE,
        now: MORNING,
        preferences: { ...DEFAULT_PREFERENCES, goal: 'minimize_time' },
      },
      { baseline: providerFor(rows), live: new NoLiveConditions() },
    );
    expect(slots[0].driveMinutes).toBe(20); // 5 miles at 15 mph
    expect(slots[4].driveMinutes).toBe(5); // 5 miles at 60 mph
    expect(verdict.action).toBe('wait');
    expect(verdict.waitMinutes).toBe(60);
    expect(verdict.minutesSaved).toBe(15);
  });
});
