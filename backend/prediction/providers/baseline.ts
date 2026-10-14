import { BaselineResult, Route } from '../types';

/** Historical drive-time source. PeMS is the first real implementation. */
export interface BaselineProvider {
  getBaseline(route: Route, departAt: Date): Promise<BaselineResult>;
}
