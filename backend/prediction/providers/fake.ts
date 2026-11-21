import { BaselineProvider } from './baseline';
import { LiveConditionsProvider } from './live';
import { BaselineResult, LiveAdjustment, Route } from '../types';

/** Test and demo provider: drive time is computed by a function you supply. */
export class FakeBaselineProvider implements BaselineProvider {
  constructor(
    private readonly minutesAt: (departAt: Date) => number,
    private readonly sampleCount = 100,
    private readonly observedShare?: number,
    /** The source the figures claim to be from. Absent leaves it unsaid. */
    private readonly source?: BaselineResult['source'],
  ) {}

  async getBaseline(_route: Route, departAt: Date): Promise<BaselineResult> {
    return {
      minutes: this.minutesAt(departAt),
      sampleCount: this.sampleCount,
      observedShare: this.observedShare,
      source: this.source,
    };
  }
}

export class FakeLiveProvider implements LiveConditionsProvider {
  constructor(private readonly adjustment: LiveAdjustment) {}

  async getAdjustment(): Promise<LiveAdjustment> {
    return this.adjustment;
  }
}
