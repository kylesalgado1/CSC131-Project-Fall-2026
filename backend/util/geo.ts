export const METERS_PER_MILE = 1609.344;

export const metersToMiles = (meters: number): number =>
  meters / METERS_PER_MILE;

export const milesToMeters = (miles: number): number => miles * METERS_PER_MILE;

/** A place on the earth. Structurally the same as the backend's `LatLng`. */
export interface GeoPoint {
  lat: number;
  lng: number;
}

/** A point on a flat map, in meters. */
export interface Point {
  x: number;
  y: number;
}

const METERS_PER_DEG_LAT = 110_574;
const METERS_PER_DEG_LNG_AT_EQUATOR = 111_320;

/**
 * Flat-earth projection to meters around a starting point: accurate to well
 * under 1% over a 100 mile trip, and cheap.
 */
export function projectorAround(origin: GeoPoint): (p: GeoPoint) => Point {
  const metersPerDegLng =
    METERS_PER_DEG_LNG_AT_EQUATOR * Math.cos((origin.lat * Math.PI) / 180);
  return p => ({
    x: (p.lng - origin.lng) * metersPerDegLng,
    y: (p.lat - origin.lat) * METERS_PER_DEG_LAT,
  });
}

/** Straight-line distance in meters between two points. */
export function distanceMeters(a: GeoPoint, b: GeoPoint): number {
  const { x, y } = projectorAround(a)(b);
  return Math.hypot(x, y);
}

/** The compass bearing in degrees (0 is north, 90 east) from one point to another. */
export function bearingDegrees(from: GeoPoint, to: GeoPoint): number {
  const { x, y } = projectorAround(from)(to);
  return ((Math.atan2(x, y) * 180) / Math.PI + 360) % 360;
}
