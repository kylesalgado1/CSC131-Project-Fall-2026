import {
  bucketOf,
  CampusBreak,
  DayType,
  dayTypeOf,
  parseIso,
} from '../../calendar';
import { PemsObservation, ProfileRow } from './types';

/** Readings measured less than this much of the time are ignored. */
export const MIN_PCT_OBSERVED = 50;

/** A reading counts as measured, not estimated, at or above this coverage. */
export const MEASURED_PCT_OBSERVED = 50;

/** Overnight, when roads are empty: 02:00 up to 05:00 local time. */
const NIGHT_START_MINUTE = 2 * 60;
const NIGHT_END_MINUTE = 5 * 60;

export interface AggregateOptions {
  campusBreaks?: CampusBreak[];
  /**
   * Readings observed less than this share of the time are dropped. Set to 0
   * to accept readings PeMS filled in, which some districts report as 0%
   * observed even when the values look real.
   */
  minPctObserved?: number;
}

interface Group {
  stationId: number;
  dayType: DayType;
  bucket: number;
  weight: number;
  weightedInverseSpeed: number;
  days: Set<string>;
  readings: number;
  measured: number;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/**
 * Builds baseline profiles from raw readings. Speeds are combined with a
 * flow-weighted harmonic mean, which is the right average when the result
 * feeds a travel-time calculation: a few slow readings count for more than
 * the same number of fast ones, as they do for a driver.
 *
 * Each station's free-flow speed is the median of its overnight readings,
 * across all days. Delay at any other hour is measured against it.
 */
export function aggregateProfiles(
  observations: PemsObservation[],
  options: AggregateOptions = {},
): ProfileRow[] {
  const { campusBreaks = [], minPctObserved = MIN_PCT_OBSERVED } = options;
  const groups = new Map<string, Group>();
  const overnight = new Map<number, number[]>();

  for (const obs of observations) {
    if (obs.avgSpeedMph <= 0) {
      continue;
    }
    if (obs.pctObserved !== null && obs.pctObserved < minPctObserved) {
      continue;
    }
    const dayType = dayTypeOf(parseIso(obs.localDate), campusBreaks);
    const bucket = bucketOf(obs.minuteOfDay);
    const key = `${obs.stationId}|${dayType}|${bucket}`;
    let g = groups.get(key);
    if (!g) {
      g = {
        stationId: obs.stationId,
        dayType,
        bucket,
        weight: 0,
        weightedInverseSpeed: 0,
        days: new Set(),
        readings: 0,
        measured: 0,
      };
      groups.set(key, g);
    }
    const w = Math.max(obs.totalFlow ?? 0, 1);
    g.weight += w;
    g.weightedInverseSpeed += w / obs.avgSpeedMph;
    g.days.add(obs.localDate);
    g.readings += 1;
    if (obs.pctObserved !== null && obs.pctObserved >= MEASURED_PCT_OBSERVED) {
      g.measured += 1;
    }

    if (
      obs.minuteOfDay >= NIGHT_START_MINUTE &&
      obs.minuteOfDay < NIGHT_END_MINUTE
    ) {
      const speeds = overnight.get(obs.stationId) ?? [];
      speeds.push(obs.avgSpeedMph);
      overnight.set(obs.stationId, speeds);
    }
  }

  const freeFlow = new Map(
    [...overnight].map(([stationId, speeds]) => [stationId, median(speeds)]),
  );
  return [...groups.values()].map(g => ({
    stationId: g.stationId,
    dayType: g.dayType,
    bucket: g.bucket,
    avgSpeedMph: g.weight / g.weightedInverseSpeed,
    sampleCount: g.days.size,
    observedShare: g.measured / g.readings,
    freeFlowMph: freeFlow.get(g.stationId),
  }));
}
