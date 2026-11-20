import { BaselineResult, Route } from '../types';
import { BaselineProvider } from './baseline';
import { RoutePath, RoutePathProvider } from './routing/types';

/**
 * Tries the primary source and, if it fails for any reason, the fallback. If
 * both fail the primary's error is thrown, since that is the one to fix.
 */
async function withFallback<T>(
  primary: () => Promise<T>,
  fallback: () => Promise<T>,
  onFallback?: (error: unknown) => void,
): Promise<T> {
  try {
    return await primary();
  } catch (primaryError) {
    onFallback?.(primaryError);
    try {
      return await fallback();
    } catch {
      throw primaryError;
    }
  }
}

/** A copy of a result that says the fallback source produced it. */
const viaFallback = <T extends object>(result: T): T & { fallback: true } => ({
  ...result,
  fallback: true,
});

/**
 * Baselines from the primary source, or from the fallback when it fails.
 * Every result the fallback produced is marked `fallback: true`.
 */
export class FallbackBaselineProvider implements BaselineProvider {
  constructor(
    private readonly primary: BaselineProvider,
    private readonly fallback: BaselineProvider,
    private readonly onFallback?: (error: unknown) => void,
  ) {}

  getBaseline(route: Route, departAt: Date): Promise<BaselineResult> {
    return withFallback(
      () => this.primary.getBaseline(route, departAt),
      async () => viaFallback(await this.fallback.getBaseline(route, departAt)),
      this.onFallback,
    );
  }

  getBaselines(route: Route, departAts: Date[]): Promise<BaselineResult[]> {
    const all = (source: BaselineProvider) =>
      source.getBaselines
        ? source.getBaselines(route, departAts)
        : Promise.all(departAts.map(at => source.getBaseline(route, at)));
    return withFallback(
      () => all(this.primary),
      async () => (await all(this.fallback)).map(viaFallback),
      this.onFallback,
    );
  }
}

/**
 * Paths from the primary service, or from the fallback when it fails. A path
 * the fallback produced is marked `fallback: true`.
 */
export class FallbackPathProvider implements RoutePathProvider {
  constructor(
    private readonly primary: RoutePathProvider,
    private readonly fallback: RoutePathProvider,
    private readonly onFallback?: (error: unknown) => void,
  ) {}

  getPath(route: Route): Promise<RoutePath> {
    return withFallback(
      () => this.primary.getPath(route),
      async () => viaFallback(await this.fallback.getPath(route)),
      this.onFallback,
    );
  }
}
