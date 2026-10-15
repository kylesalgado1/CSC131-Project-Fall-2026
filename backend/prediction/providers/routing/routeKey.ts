import { Route } from '../../types';

/** A cache key for a trip. About 10 m of precision: nearby starts share it. */
export const routeKey = ({ origin, destination }: Route): string =>
  [origin, destination]
    .map(p => `${p.lat.toFixed(4)},${p.lng.toFixed(4)}`)
    .join('>');
