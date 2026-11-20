import {
  bucketOf,
  CampusBreak,
  dayTypeOf,
  localTime,
  LOCAL_TIME_ZONE,
} from '../../calendar';
import { BaselineResult, Route } from '../../types';
import { BaselineProvider } from '../baseline';
import { ProfileKey, ProfileStore } from './store';
import { ProfileRow, ResolvedRoute, RouteResolver } from './types';

export type { ResolvedRoute, RouteResolver, RouteSegment } from './types';

/** Thrown when PeMS has no usable data for the route, e.g. surface streets. */
export class NoBaselineCoverageError extends Error {
  constructor(message = 'No PeMS coverage for this route') {
    super(message);
    this.name = 'NoBaselineCoverageError';
  }
}

export interface PemsBaselineOptions {
  campusBreaks?: CampusBreak[];
  timeZone?: string;
  /** Speeds are clamped to this range so one bad reading cannot dominate. */
  minSpeedMph?: number;
  maxSpeedMph?: number;
  /** Assumed speed over route length that has no station. */
  uncoveredSpeedMph?: number;
}

type StationProfiles = Map<number, ProfileRow>;

const median = (values: number[]): number => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

const keyId = (k: ProfileKey) => `${k.dayType}|${k.bucket}`;

/** Groups profile rows by day type and bucket, then by station. */
function indexProfiles(rows: ProfileRow[]): Map<string, StationProfiles> {
  const index = new Map<string, StationProfiles>();
  for (const row of rows) {
    const key = keyId(row);
    const stations = index.get(key) ?? new Map();
    stations.set(row.stationId, row);
    index.set(key, stations);
  }
  return index;
}

/**
 * Baseline drive time from historical PeMS speeds: for each station on the
 * route, length divided by the typical speed for that day type and time.
 */
export class PemsBaselineProvider implements BaselineProvider {
  constructor(
    private readonly store: ProfileStore,
    private readonly resolver: RouteResolver,
    private readonly options: PemsBaselineOptions = {},
  ) {}

  async getBaseline(route: Route, departAt: Date): Promise<BaselineResult> {
    return (await this.getBaselines(route, [departAt]))[0];
  }

  /**
   * Resolves the route once and reads all the needed profiles in a single
   * query, however many departure times are asked for.
   */
  async getBaselines(
    route: Route,
    departAts: Date[],
  ): Promise<BaselineResult[]> {
    const { campusBreaks = [], timeZone = LOCAL_TIME_ZONE } = this.options;

    const resolved = await this.resolver.resolve(route);
    if (resolved.segments.length === 0) {
      throw new NoBaselineCoverageError();
    }
    const stationIds = resolved.segments.map(s => s.stationId);

    const keys = departAts.map<ProfileKey>(at => {
      const { date, minuteOfDay } = localTime(at, timeZone);
      return {
        dayType: dayTypeOf(date, campusBreaks),
        bucket: bucketOf(minuteOfDay),
      };
    });
    const { profiles, estimatedFromWeekends } = await this.loadProfiles(
      stationIds,
      keys,
    );

    return keys.map(key => {
      const id = keyId(key);
      return this.combine(
        resolved,
        profiles.get(id) ?? new Map(),
        estimatedFromWeekends.has(id),
      );
    });
  }

  /**
   * Reads the profiles for every distinct key in one query. A holiday with
   * no history of its own is estimated from the same time on weekends.
   */
  private async loadProfiles(stationIds: number[], keys: ProfileKey[]) {
    const distinct = [...new Map(keys.map(k => [keyId(k), k])).values()];
    const profiles = indexProfiles(
      await this.store.getProfiles(stationIds, distinct),
    );

    const estimatedFromWeekends = new Set<string>();
    const holidaysWithoutData = distinct.filter(
      k => k.dayType === 'holiday' && !profiles.has(keyId(k)),
    );
    if (holidaysWithoutData.length > 0) {
      const weekend = await this.store.getProfiles(
        stationIds,
        holidaysWithoutData.map(k => ({ ...k, dayType: 'weekend' as const })),
      );
      const asHoliday = weekend.map(r => ({
        ...r,
        dayType: 'holiday' as const,
      }));
      for (const [key, stations] of indexProfiles(asHoliday)) {
        profiles.set(key, stations);
        estimatedFromWeekends.add(key);
      }
    }
    return { profiles, estimatedFromWeekends };
  }

  private combine(
    resolved: ResolvedRoute,
    byStation: StationProfiles,
    estimatedFromWeekends: boolean,
  ): BaselineResult {
    const { segments, uncoveredMiles } = resolved;
    const limits = {
      minSpeedMph: this.options.minSpeedMph ?? 5,
      maxSpeedMph: this.options.maxSpeedMph ?? 80,
      uncoveredSpeedMph: this.options.uncoveredSpeedMph ?? 25,
    };
    const minutes =
      freeFlowPlusDelayMinutes(resolved, byStation, limits) ??
      sumOfSpeedsMinutes(resolved, byStation, limits);
    if (minutes === undefined) {
      throw new NoBaselineCoverageError('No PeMS data for this time of day');
    }

    // The median keeps one sparse station from sinking confidence for a long
    // route, while a route that is mostly uncovered still reads as sparse.
    const sampleCount = median(
      segments.map(s => byStation.get(s.stationId)?.sampleCount ?? 0),
    );

    // How much of the route's length rests on measured readings. A station
    // with no data, and any length without a station, counts as estimated.
    const coveredMiles = segments.reduce((sum, s) => sum + s.lengthMiles, 0);
    const measuredMiles = segments.reduce(
      (sum, s) =>
        sum + s.lengthMiles * (byStation.get(s.stationId)?.observedShare ?? 0),
      0,
    );

    return {
      minutes,
      sampleCount,
      observedShare: measuredMiles / (coveredMiles + uncoveredMiles),
      // Holiday traffic estimated from weekends is a guess, and says so.
      basis: estimatedFromWeekends ? 'holiday_estimate' : undefined,
      source: 'pems',
    };
  }
}

interface SpeedLimits {
  /** Speeds are clamped to this range so one bad reading cannot dominate. */
  minSpeedMph: number;
  maxSpeedMph: number;
  /** Assumed speed over route length that has no station. */
  uncoveredSpeedMph: number;
}

const clampSpeed = (mph: number, { minSpeedMph, maxSpeedMph }: SpeedLimits) =>
  Math.min(maxSpeedMph, Math.max(minSpeedMph, mph));

/**
 * The routing service's no-traffic time for the route, plus the delay PeMS
 * shows beyond each station's free-flow speed. The routing service already
 * knows about signals, ramps and surface streets, so PeMS only has to say how
 * much slower than usual traffic is. Stations with no data take the average
 * delay per mile of the ones that have it. Undefined when the routing time or
 * the free-flow speeds are not known.
 */
function freeFlowPlusDelayMinutes(
  { segments, freeFlowMinutes }: ResolvedRoute,
  byStation: StationProfiles,
  limits: SpeedLimits,
): number | undefined {
  if (freeFlowMinutes === undefined) {
    return undefined;
  }
  let knownMiles = 0;
  let knownDelayHours = 0;
  const delays = segments.map(({ stationId, lengthMiles }) => {
    const row = byStation.get(stationId);
    if (!row?.freeFlowMph) {
      return undefined;
    }
    const hours =
      lengthMiles / clampSpeed(row.avgSpeedMph, limits) -
      lengthMiles / clampSpeed(row.freeFlowMph, limits);
    knownMiles += lengthMiles;
    knownDelayHours += Math.max(0, hours);
    return Math.max(0, hours);
  });
  if (knownMiles === 0) {
    return undefined;
  }
  const delayHoursPerMile = knownDelayHours / knownMiles;
  const delayHours = delays.reduce(
    (sum: number, delay, i) =>
      sum + (delay ?? segments[i].lengthMiles * delayHoursPerMile),
    0,
  );
  return freeFlowMinutes + delayHours * 60;
}

/**
 * Drive time from PeMS speeds alone: each station's length over its speed,
 * plus the road with no station at an assumed surface speed. The fallback for
 * when there is no routing time. Stations with no data take the typical speed
 * of the ones that have it. Undefined when no station has data.
 */
function sumOfSpeedsMinutes(
  { segments, uncoveredMiles }: ResolvedRoute,
  byStation: StationProfiles,
  limits: SpeedLimits,
): number | undefined {
  const speedAt = (stationId: number): number | undefined => {
    const row = byStation.get(stationId);
    return row && clampSpeed(row.avgSpeedMph, limits);
  };

  let knownMiles = 0;
  let knownHours = 0;
  for (const { stationId, lengthMiles } of segments) {
    const speed = speedAt(stationId);
    if (speed !== undefined) {
      knownMiles += lengthMiles;
      knownHours += lengthMiles / speed;
    }
  }
  if (knownMiles === 0) {
    return undefined;
  }
  const fillSpeed = knownMiles / knownHours;

  let hours = uncoveredMiles / limits.uncoveredSpeedMph;
  for (const { stationId, lengthMiles } of segments) {
    hours += lengthMiles / (speedAt(stationId) ?? fillSpeed);
  }
  return hours * 60;
}
