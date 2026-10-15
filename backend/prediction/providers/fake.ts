import { BaselineProvider } from './baseline';
import { LiveConditionsProvider } from './live';
import { BaselineResult, LiveAdjustment, Route } from '../types';

/** Test and demo provider: drive time is computed by a function you supply. */
export class FakeBaselineProvider implements BaselineProvider {
  constructor(
    private readonly minutesAt: (departAt: Date) => number,
    private readonly sampleCount = 100,
    private readonly observedShare?: number,
  ) {}

  async getBaseline(_route: Route, departAt: Date): Promise<BaselineResult> {
    return {
      minutes: this.minutesAt(departAt),
      sampleCount: this.sampleCount,
      observedShare: this.observedShare,
    };
  }
}

export class FakeLiveProvider implements LiveConditionsProvider {
  constructor(private readonly adjustment: LiveAdjustment) {}

  async getAdjustment(): Promise<LiveAdjustment> {
    return this.adjustment;
  }
}
