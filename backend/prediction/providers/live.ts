import { LiveAdjustment, Route } from '../types';

/** Live traffic and incident source. TomTom is the planned implementation. */
export interface LiveConditionsProvider {
  getAdjustment(route: Route, now: Date): Promise<LiveAdjustment>;
}

/** What to use when there is no live data: no adjustment, flagged unavailable. */
export const liveUnavailable = (): LiveAdjustment => ({
  available: false,
  extraMinutes: 0,
  incidents: [],
});

/** Used until a live feed exists. */
export class NoLiveConditions implements LiveConditionsProvider {
  async getAdjustment(): Promise<LiveAdjustment> {
    return liveUnavailable();
  }
}
