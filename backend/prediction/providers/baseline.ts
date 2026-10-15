import { BaselineResult, Route } from '../types';

/** Historical drive-time source. PeMS is the first real implementation. */
export interface BaselineProvider {
  getBaseline(route: Route, departAt: Date): Promise<BaselineResult>;
  /**
   * Baselines for several departure times at once, in the same order.
   * Optional: a provider that can resolve the route and read its data once
   * for all of them should implement it, because a verdict needs a dozen.
   */
  getBaselines?(route: Route, departAts: Date[]): Promise<BaselineResult[]>;
}
