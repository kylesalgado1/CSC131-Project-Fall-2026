import { metersToMiles, milesToMeters } from '../../../util/geo';
import { LatLng } from '../../types';
import { PemsStation, ResolvedRoute } from '../pems/types';

const METERS_PER_DEG_LAT = 110_574;
const METERS_PER_DEG_LNG_AT_EQUATOR = 111_320;

export interface MatchOptions {
  /** A station further than this from the route path is not on it. */
  maxDistanceMeters?: number;
  /** Station direction and driving direction may differ by this much. */
  headingToleranceDegrees?: number;
  /** A gap between stations on different roads is filled up to this much. */
  maxGapMiles?: number;
  /**
   * A gap between two stations on the same freeway and direction is filled
   * from their speeds up to this much. Stations are missing mid-freeway far
   * more often than the freeway's speed changes, so this is generous.
   */
  maxFreewayGapMiles?: number;
}

/** Compass bearing in degrees of each direction of travel PeMS uses. */
const BEARING: Record<string, number> = { N: 0, E: 90, S: 180, W: 270 };

interface Point {
  x: number;
  y: number;
}

export interface Hit {
  station: PemsStation;
  /** Meters along the route path to the closest point. */
  progress: number;
}

const angleDiff = (a: number, b: number): number => {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
};

/**
 * Flat-earth projection to meters around a starting point: accurate to well
 * under 1% over a 100 mile trip, and cheap.
 */
function projectorAround(origin: LatLng): (p: LatLng) => Point {
  const metersPerDegLng =
    METERS_PER_DEG_LNG_AT_EQUATOR * Math.cos((origin.lat * Math.PI) / 180);
  return p => ({
    x: (p.lng - origin.lng) * metersPerDegLng,
    y: (p.lat - origin.lat) * METERS_PER_DEG_LAT,
  });
}

/** Distance in meters from the start of the path to each of its points. */
function cumulativeDistances(points: Point[]): number[] {
  const distances = [0];
  for (let i = 1; i < points.length; i++) {
    distances.push(
      distances[i - 1] +
        Math.hypot(
          points[i].x - points[i - 1].x,
          points[i].y - points[i - 1].y,
        ),
    );
  }
  return distances;
}

/** The box around the points, grown by a margin. */
function boundsOf(points: Point[], margin: number) {
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  for (const { x, y } of points) {
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);
  }
  return {
    contains: (p: Point) =>
      p.x >= minX - margin &&
      p.x <= maxX + margin &&
      p.y >= minY - margin &&
      p.y <= maxY + margin,
  };
}

/** Where the path comes closest to a point, and which way it is heading. */
function closestApproach(point: Point, path: Point[], along: number[]) {
  let best: { dist: number; progress: number; heading: number } | undefined;
  for (let i = 0; i < path.length - 1; i++) {
    const a = path[i];
    const dx = path[i + 1].x - a.x;
    const dy = path[i + 1].y - a.y;
    const lengthSq = dx * dx + dy * dy;
    if (lengthSq === 0) {
      continue;
    }
    const t = Math.max(
      0,
      Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSq),
    );
    const dist = Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy));
    if (!best || dist < best.dist) {
      best = {
        dist,
        progress: along[i] + t * Math.sqrt(lengthSq),
        heading: ((Math.atan2(dx, dy) * 180) / Math.PI + 360) % 360,
      };
    }
  }
  return best;
}

/** Compass bearing in degrees of each direction of travel PeMS and TomTom use. */
export const COMPASS_BEARING: Record<string, number> = BEARING;

/** Straight-line distance in meters between two points. */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const project = projectorAround(a);
  const { x, y } = project(b);
  return Math.hypot(x, y);
}

/** The compass bearing in degrees (0 is north, 90 east) from one point to another. */
export function bearingDegrees(from: LatLng, to: LatLng): number {
  const { x, y } = projectorAround(from)(to);
  return ((Math.atan2(x, y) * 180) / Math.PI + 360) % 360;
}

/**
 * A test for whether a set of points (an incident, say) lies within a given
 * distance of a route path. Sets the path up once for many tests. When the
 * direction the points travel in is known, only points where the route runs
 * the same way count, so the other side of a freeway does not.
 */
export function pathProximity(
  path: LatLng[],
  maxMeters: number,
  toleranceDegrees = 60,
): (points: LatLng[], travelBearing?: number) => boolean {
  if (path.length < 2) {
    return () => false;
  }
  const project = projectorAround(path[0]);
  const points = path.map(project);
  const along = cumulativeDistances(points);
  const nearPath = boundsOf(points, maxMeters);
  return (candidates, travelBearing) =>
    candidates.some(candidate => {
      const at = project(candidate);
      if (!nearPath.contains(at)) {
        return false;
      }
      const near = closestApproach(at, points, along);
      return (
        near !== undefined &&
        near.dist <= maxMeters &&
        (travelBearing === undefined ||
          angleDiff(travelBearing, near.heading) <= toleranceDegrees)
      );
    });
}

/**
 * The stations on a route path with how far along the path each one is,
 * nearest the start first. A station is on the path when it is close to it
 * and its direction of travel agrees with the path there.
 */
export function locateStations(
  path: LatLng[],
  stations: PemsStation[],
  options: MatchOptions = {},
): { hits: Hit[]; totalMeters: number } {
  const { maxDistanceMeters = 150, headingToleranceDegrees = 60 } = options;
  if (path.length < 2) {
    return { hits: [], totalMeters: 0 };
  }

  const project = projectorAround(path[0]);
  const points = path.map(project);
  const along = cumulativeDistances(points);
  const nearPath = boundsOf(points, maxDistanceMeters);

  const hits: Hit[] = [];
  for (const station of stations) {
    const bearing = BEARING[station.direction];
    const at = project({ lat: station.latitude, lng: station.longitude });
    if (bearing === undefined || !nearPath.contains(at)) {
      continue;
    }
    const near = closestApproach(at, points, along);
    if (
      near &&
      near.dist <= maxDistanceMeters &&
      angleDiff(bearing, near.heading) <= headingToleranceDegrees
    ) {
      hits.push({ station, progress: near.progress });
    }
  }

  hits.sort((a, b) => a.progress - b.progress);
  return { hits, totalMeters: along[along.length - 1] };
}

/**
 * Finds the PeMS stations a driving route passes, in order, and the stretch
 * of road each one stands for. Excludes the opposite carriageway and freeways
 * that merely cross, since their direction of travel disagrees with the route.
 */
export function matchStations(
  path: LatLng[],
  stations: PemsStation[],
  options: MatchOptions = {},
): ResolvedRoute {
  const { maxGapMiles = 2, maxFreewayGapMiles = 8 } = options;
  const { hits, totalMeters } = locateStations(path, stations, options);
  if (hits.length === 0) {
    return { segments: [], uncoveredMiles: metersToMiles(totalMeters) };
  }

  // Each station stands for the road from halfway to the previous station to
  // halfway to the next, so lengths add up to the stretch actually driven.
  const maxHalfGap = milesToMeters(maxGapMiles) / 2;
  const maxFreewayHalfGap = milesToMeters(maxFreewayGapMiles) / 2;
  const halfGapBetween = (a: Hit, b: Hit): number => {
    const sameRoad =
      a.station.freeway === b.station.freeway &&
      a.station.direction === b.station.direction;
    return Math.min(
      (b.progress - a.progress) / 2,
      sameRoad ? maxFreewayHalfGap : maxHalfGap,
    );
  };

  let coveredMeters = 0;
  const segments = hits.map((hit, i) => {
    const ownHalf = Math.min(
      milesToMeters(hit.station.lengthMiles) / 2,
      maxHalfGap,
    );
    const before = i === 0 ? ownHalf : halfGapBetween(hits[i - 1], hit);
    const after =
      i === hits.length - 1 ? ownHalf : halfGapBetween(hit, hits[i + 1]);
    // Never extend past either end of the path.
    const start = Math.max(0, hit.progress - before);
    const end = Math.min(totalMeters, hit.progress + after);
    const meters = Math.max(0, end - start);
    coveredMeters += meters;
    return { stationId: hit.station.id, lengthMiles: metersToMiles(meters) };
  });

  return {
    segments,
    uncoveredMiles: metersToMiles(Math.max(0, totalMeters - coveredMeters)),
  };
}
