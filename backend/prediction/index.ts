import { decide } from './decide';
import { predict, PredictionProviders } from './predict';
import {
  PredictionSource,
  SlotPrediction,
  TripRequest,
  Verdict,
} from './types';

// Includes PredictionSource, along with every other shared type.
export * from './types';
export type { BaselineProvider } from './providers/baseline';
export type { LiveConditionsProvider } from './providers/live';
export { NoLiveConditions } from './providers/live';
export type { PredictionProviders } from './predict';

export interface PredictionResult {
  slots: SlotPrediction[];
  verdict: Verdict;
  /** Where the figures came from, and whether live conditions were used. */
  source: PredictionSource;
}

/** Entry point for the backend: predict every slot, then decide. */
export async function getVerdict(
  request: TripRequest,
  providers: PredictionProviders,
): Promise<PredictionResult> {
  const { slots, source } = await predict(request, providers);
  return { slots, verdict: decide(slots, request), source };
}
