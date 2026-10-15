export const METERS_PER_MILE = 1609.344;

export const metersToMiles = (meters: number): number =>
  meters / METERS_PER_MILE;

export const milesToMeters = (miles: number): number => miles * METERS_PER_MILE;
