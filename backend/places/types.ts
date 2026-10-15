import { LatLng } from '../prediction/types';

/** A place a user can pick as a start or a destination. */
export interface Place extends LatLng {
  id: string;
  /** Short name to show: a business, a campus, or the street address. */
  name: string;
  /** The full address, to show beneath the name. */
  address: string;
}

export interface PlaceSearch {
  /** Places matching text being typed, closest to `near` first. */
  search(query: string, near?: LatLng): Promise<Place[]>;
}

/** The place search failed or could not be reached. */
export class SearchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SearchError';
  }
}
