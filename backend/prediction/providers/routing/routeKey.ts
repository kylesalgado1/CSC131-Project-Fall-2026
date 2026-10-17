import { Route } from '../../types';

/**
 * A cache key for a trip. About 100 m of precision, so a phone's position
 * wandering a few metres between reads still finds the same cached answer.
 */
export const routeKey = ({ origin, destination }: Route): string =>
  [origin, destination]
    .map(p => `${p.lat.toFixed(3)},${p.lng.toFixed(3)}`)
    .join('>');
