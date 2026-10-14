import { LiveAdjustment, Route } from '../types';

/** Live traffic and incident source. TomTom is the planned implementation. */
export interface LiveConditionsProvider {
  getAdjustment(route: Route, now: Date): Promise<LiveAdjustment>;
}

/** Used until a live feed exists, and as the "feed is down" fallback. */
export class NoLiveConditions implements LiveConditionsProvider {
  async getAdjustment(): Promise<LiveAdjustment> {
    return { available: false, extraMinutes: 0, incidents: [] };
  }
}
