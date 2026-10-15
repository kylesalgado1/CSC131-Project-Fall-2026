import { BaselineProvider } from './providers/baseline';
import { LiveConditionsProvider } from './providers/live';
import {
  Confidence,
  LiveAdjustment,
  SlotPrediction,
  TripRequest,
} from './types';

export const SLOT_INTERVAL_MINUTES = 15;
export const HORIZON_MINUTES = 180;
/** Live congestion fades to zero this many minutes after "now". */
export const LIVE_DECAY_MINUTES = 60;
/** Fewer observations than this and the baseline is not trusted. */
export const MIN_SAMPLES = 20;
export const HIGH_CONFIDENCE_SAMPLES = 50;
/** Below this share of measured history, confidence is Low. */
export const LOW_OBSERVED_SHARE = 0.25;
/** Below this share, confidence is at most Medium. */
export const MEDIUM_OBSERVED_SHARE = 0.5;

export interface PredictionProviders {
  baseline: BaselineProvider;
  live: LiveConditionsProvider;
}

export function addMinutes(date: Date, minutes: number): Date {
  return new Date(date.getTime() + minutes * 60_000);
}

/**
 * Predicts drive time for every departure slot from now through the horizon,
 * slot 0 being "leave now". Live congestion is added on top of the baseline
 * and fades out linearly, since a current slowdown says little about traffic
 * an hour from now. A live feed that fails is treated as unavailable and the
 * baseline is used alone.
 */
export async function predictSlots(
  request: TripRequest,
  providers: PredictionProviders,
): Promise<SlotPrediction[]> {
  const { route, now } = request;
  const live = await providers.live
    .getAdjustment(route, now)
    .catch<LiveAdjustment>(() => ({
      available: false,
      extraMinutes: 0,
      incidents: [],
    }));

  const offsets: number[] = [];
  for (let m = 0; m <= HORIZON_MINUTES; m += SLOT_INTERVAL_MINUTES) {
    offsets.push(m);
  }

  return Promise.all(
    offsets.map(async offset => {
      const departAt = addMinutes(now, offset);
      const base = await providers.baseline.getBaseline(route, departAt);
      const fade = Math.max(0, 1 - offset / LIVE_DECAY_MINUTES);
      const driveMinutes = Math.max(
        1,
        Math.round(base.minutes + live.extraMinutes * fade),
      );
      const { confidence, reason } = assessConfidence(
        base.sampleCount,
        base.observedShare,
        live,
      );
      return {
        departAt,
        driveMinutes,
        arriveAt: addMinutes(departAt, driveMinutes),
        confidence,
        confidenceReason: reason,
      };
    }),
  );
}

function assessConfidence(
  sampleCount: number,
  observedShare: number | undefined,
  live: LiveAdjustment,
): { confidence: Confidence; reason: string } {
  if (live.incidents.length > 0) {
    return {
      confidence: 'Low',
      reason: 'An incident on your route could change this estimate.',
    };
  }
  if (sampleCount < MIN_SAMPLES) {
    return {
      confidence: 'Low',
      reason: 'There is little historical data for this route.',
    };
  }
  if (observedShare !== undefined && observedShare < LOW_OBSERVED_SHARE) {
    return {
      confidence: 'Low',
      reason: 'Most of the history for this route is estimated, not measured.',
    };
  }
  if (observedShare !== undefined && observedShare < MEDIUM_OBSERVED_SHARE) {
    return {
      confidence: 'Medium',
      reason: 'Part of the history for this route is estimated, not measured.',
    };
  }
  if (!live.available) {
    return {
      confidence: 'Medium',
      reason: 'Live traffic is unavailable, so this uses typical conditions.',
    };
  }
  if (sampleCount < HIGH_CONFIDENCE_SAMPLES) {
    return {
      confidence: 'Medium',
      reason: 'This route has a limited amount of historical data.',
    };
  }
  return {
    confidence: 'High',
    reason: 'Based on plenty of historical data and live traffic.',
  };
}
