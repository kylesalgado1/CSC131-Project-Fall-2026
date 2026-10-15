import { Confidence, LiveAdjustment } from './types';

/** Fewer days of history than this and the baseline is not trusted. */
export const MIN_SAMPLES = 20;
export const HIGH_CONFIDENCE_SAMPLES = 50;
/** Below this share of measured history, confidence is Low. */
export const LOW_OBSERVED_SHARE = 0.25;
/** Below this share, confidence is at most Medium. */
export const MEDIUM_OBSERVED_SHARE = 0.5;

/**
 * How far to trust a prediction, with a one-sentence reason to show. The
 * first rule that applies wins, from the strongest reason for doubt down.
 */
export function assessConfidence(
  sampleCount: number,
  observedShare: number | undefined,
  live: LiveAdjustment,
): { confidence: Confidence; reason: string } {
  const share = observedShare ?? 1; // a source that does not say is not penalized
  const rules: Array<{
    applies: boolean;
    confidence: Confidence;
    reason: string;
  }> = [
    {
      applies: live.incidents.length > 0,
      confidence: 'Low',
      reason: 'An incident on your route could change this estimate.',
    },
    {
      applies: sampleCount < MIN_SAMPLES,
      confidence: 'Low',
      reason: 'There is little historical data for this route.',
    },
    {
      applies: share < LOW_OBSERVED_SHARE,
      confidence: 'Low',
      reason: 'Most of the history for this route is estimated, not measured.',
    },
    {
      applies: share < MEDIUM_OBSERVED_SHARE,
      confidence: 'Medium',
      reason: 'Part of the history for this route is estimated, not measured.',
    },
    {
      applies: !live.available,
      confidence: 'Medium',
      reason: 'Live traffic is unavailable, so this uses typical conditions.',
    },
    {
      applies: sampleCount < HIGH_CONFIDENCE_SAMPLES,
      confidence: 'Medium',
      reason: 'This route has a limited amount of historical data.',
    },
    {
      applies: true,
      confidence: 'High',
      reason: 'Based on plenty of historical data and live traffic.',
    },
  ];
  const { confidence, reason } = rules.find(r => r.applies)!;
  return { confidence, reason };
}
