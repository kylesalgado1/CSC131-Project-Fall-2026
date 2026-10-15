import { bucketOf, CampusBreak, dayTypeOf, parseIso } from '../../calendar';
import { PemsObservation, ProfileRow } from './types';

/** Readings measured less than this much of the time are ignored. */
export const MIN_PCT_OBSERVED = 50;

/** A reading counts as measured, not estimated, at or above this coverage. */
export const MEASURED_PCT_OBSERVED = 50;

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
  dayType: ProfileRow['dayType'];
  bucket: number;
  weight: number;
  weightedInverseSpeed: number;
  days: Set<string>;
  readings: number;
  measured: number;
}

/**
 * Builds baseline profiles from raw readings. Speeds are combined with a
 * flow-weighted harmonic mean, which is the right average when the result
 * feeds a travel-time calculation: a few slow readings count for more than
 * the same number of fast ones, as they do for a driver.
 */
export function aggregateProfiles(
  observations: PemsObservation[],
  options: AggregateOptions = {},
): ProfileRow[] {
  const { campusBreaks = [], minPctObserved = MIN_PCT_OBSERVED } = options;
  const groups = new Map<string, Group>();

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
  }

  return [...groups.values()].map(g => ({
    stationId: g.stationId,
    dayType: g.dayType,
    bucket: g.bucket,
    avgSpeedMph: g.weight / g.weightedInverseSpeed,
    sampleCount: g.days.size,
    observedShare: g.measured / g.readings,
  }));
}
