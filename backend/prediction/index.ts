import { decide } from './decide';
import { PredictionProviders, predictSlots } from './predict';
import { SlotPrediction, TripRequest, Verdict } from './types';

export * from './types';
export type { BaselineProvider } from './providers/baseline';
export type { LiveConditionsProvider } from './providers/live';
export { NoLiveConditions } from './providers/live';
export type { PredictionProviders } from './predict';

export interface PredictionResult {
  slots: SlotPrediction[];
  verdict: Verdict;
}

/** Entry point for the backend: predict every slot, then decide. */
export async function getVerdict(
  request: TripRequest,
  providers: PredictionProviders,
): Promise<PredictionResult> {
  const slots = await predictSlots(request, providers);
  return { slots, verdict: decide(slots, request) };
}
