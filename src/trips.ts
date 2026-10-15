import { LatLng } from './api/types';

export interface Trip {
  id: string;
  label: string;
  origin: LatLng;
  destination: LatLng;
}

const SUISUN_CITY: LatLng = { lat: 38.2383, lng: -122.0402 };
const SAC_STATE: LatLng = { lat: 38.5593, lng: -121.4237 };
const SFSU: LatLng = { lat: 37.7241, lng: -122.4799 };

/**
 * Fixed trips for the demo. Setting up a trip is Epic 3's job; until it
 * exists, these stand in for it. They are public landmarks, not addresses.
 */
export const DEMO_TRIPS: Trip[] = [
  {
    id: 'suisun-sac',
    label: 'Suisun City to Sac State',
    origin: SUISUN_CITY,
    destination: SAC_STATE,
  },
  {
    id: 'sac-suisun',
    label: 'Sac State to Suisun City',
    origin: SAC_STATE,
    destination: SUISUN_CITY,
  },
  {
    id: 'sac-sfsu',
    label: 'Sac State to SFSU',
    origin: SAC_STATE,
    destination: SFSU,
  },
];
