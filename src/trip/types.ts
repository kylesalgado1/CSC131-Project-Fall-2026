import { Place } from '../api/types';

/** Where a trip starts: wherever the phone is, or a chosen place. */
export type Start = { kind: 'current' } | { kind: 'place'; place: Place };

export interface Trip {
  from: Start;
  /** Not chosen yet on a fresh install. */
  to?: Place;
}

export const CURRENT_LOCATION = 'Current location';

export const startLabel = (start: Start): string =>
  start.kind === 'current' ? CURRENT_LOCATION : start.place.name;

/** Round trips are common, so swapping start and destination is one tap. */
export function swapped(trip: Trip): Trip | undefined {
  if (trip.from.kind !== 'place' || !trip.to) {
    return undefined; // a current location cannot become a destination
  }
  return { from: { kind: 'place', place: trip.to }, to: trip.from.place };
}
