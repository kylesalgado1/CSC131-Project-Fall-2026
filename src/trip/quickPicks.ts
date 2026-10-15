import { Place } from '../api/types';

/**
 * A few well-known places to start from. TomTom's search is weak on
 * abbreviations like "csus", and these make the demo work with one tap. They
 * are public landmarks, not addresses.
 */
export const QUICK_PICKS: Place[] = [
  {
    id: 'quick-sac-state',
    name: 'Sacramento State',
    address: '6000 J Street, Sacramento, CA 95819',
    lat: 38.5593,
    lng: -121.4237,
  },
  {
    id: 'quick-sfsu',
    name: 'San Francisco State',
    address: '1600 Holloway Avenue, San Francisco, CA 94132',
    lat: 37.7241,
    lng: -122.4799,
  },
  {
    id: 'quick-suisun',
    name: 'Suisun City',
    address: 'Suisun City, CA',
    lat: 38.2383,
    lng: -122.0402,
  },
];
