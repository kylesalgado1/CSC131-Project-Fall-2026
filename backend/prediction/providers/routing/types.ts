import { PemsStation } from '../pems/types';
import { LatLng, Route } from '../../types';

export interface RoutePath {
  /** The driving path, start to end. */
  points: LatLng[];
  /** Distance of the path in miles. */
  distanceMiles: number;
  /** Travel time with no traffic, when the service reports one. */
  freeFlowMinutes?: number;
  /** Which routing service drew the path. Absent when it does not say. */
  source?: 'tomtom' | 'osrm' | 'fixture';
  /** True when the primary service failed and the fallback answered. */
  fallback?: boolean;
}

/** A routing service that returns the path a driver would take. */
export interface RoutePathProvider {
  getPath(route: Route): Promise<RoutePath>;
}

export interface StationSource {
  getStations(): Promise<PemsStation[]>;
}

/** The routing service failed or found no route for the trip. */
export class RoutingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RoutingError';
  }
}
