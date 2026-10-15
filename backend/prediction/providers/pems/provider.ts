import { BaselineProvider } from '../baseline';
import {
  bucketOf,
  CampusBreak,
  dayTypeOf,
  localTime,
  LOCAL_TIME_ZONE,
} from '../../calendar';
import { MIN_SAMPLES } from '../../predict';
import { BaselineResult, Route } from '../../types';
import { ProfileStore } from './store';

/** A stretch of road covered by one PeMS station. */
export interface RouteSegment {
  stationId: number;
  lengthMiles: number;
}

/**
 * Maps a trip to the PeMS stations it passes, in order. This needs route
 * geometry (from a routing service) matched to station locations.
 */
export interface RouteResolver {
  resolve(route: Route): Promise<RouteSegment[]>;
}

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
}

const median = (values: number[]): number => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

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
    const {
      campusBreaks = [],
      timeZone = LOCAL_TIME_ZONE,
      minSpeedMph = 5,
      maxSpeedMph = 80,
    } = this.options;

    const segments = await this.resolver.resolve(route);
    if (segments.length === 0) {
      throw new NoBaselineCoverageError();
    }

    const { date, minuteOfDay } = localTime(departAt, timeZone);
    const bucket = bucketOf(minuteOfDay);
    const ids = segments.map(s => s.stationId);
    const dayType = dayTypeOf(date, campusBreaks);

    let rows = await this.store.getProfiles(ids, dayType, bucket);
    let usedFallback = false;
    if (dayType === 'holiday' && rows.length === 0) {
      rows = await this.store.getProfiles(ids, 'weekend', bucket);
      usedFallback = true;
    }

    const byStation = new Map(rows.map(r => [r.stationId, r]));
    const clamp = (mph: number) =>
      Math.min(maxSpeedMph, Math.max(minSpeedMph, mph));

    let knownMiles = 0;
    let knownHours = 0;
    for (const s of segments) {
      const row = byStation.get(s.stationId);
      if (row) {
        knownMiles += s.lengthMiles;
        knownHours += s.lengthMiles / clamp(row.avgSpeedMph);
      }
    }
    if (knownMiles === 0) {
      throw new NoBaselineCoverageError('No PeMS data for this time of day');
    }
    // Stations with no data take the typical speed of the ones that do.
    const fillSpeed = knownMiles / knownHours;

    let hours = 0;
    for (const s of segments) {
      const row = byStation.get(s.stationId);
      hours += s.lengthMiles / (row ? clamp(row.avgSpeedMph) : fillSpeed);
    }

    // The median keeps one sparse station from sinking confidence for a long
    // route, while a route that is mostly uncovered still reads as sparse.
    let sampleCount = median(
      segments.map(s => byStation.get(s.stationId)?.sampleCount ?? 0),
    );
    if (usedFallback) {
      // Holiday traffic estimated from weekends is a guess, so never trust it.
      sampleCount = Math.min(sampleCount, MIN_SAMPLES - 1);
    }

    // How much of the route's length rests on measured readings. A station
    // with no data counts as fully estimated.
    const totalMiles = segments.reduce((sum, s) => sum + s.lengthMiles, 0);
    const measuredMiles = segments.reduce(
      (sum, s) =>
        sum + s.lengthMiles * (byStation.get(s.stationId)?.observedShare ?? 0),
      0,
    );

    return {
      minutes: hours * 60,
      sampleCount,
      observedShare: measuredMiles / totalMiles,
    };
  }
}
