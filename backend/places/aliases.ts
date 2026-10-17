import { Place } from './types';

/**
 * Places people call by a short or informal name. Search engines handle
 * "csus" and "ucla" badly, so these are matched first, before any search.
 * Public landmarks only, not private addresses. Coordinates were checked
 * against TomTom's own results for each official name.
 */
interface Alias {
  /** What people type, lower case. The first is the usual short name. */
  names: string[];
  place: Place;
}

const ALIASES: Alias[] = [
  {
    names: [
      'sac state',
      'csus',
      'cal state sac',
      'sacramento state',
      'sacramento state university',
      'csu sacramento',
      'cal state sacramento',
      'california state university sacramento',
    ],
    place: {
      id: 'alias-sac-state',
      name: 'Sacramento State',
      address: '6000 J Street, Sacramento, CA 95819',
      lat: 38.5593,
      lng: -121.4237,
    },
  },
  {
    names: [
      'sfsu',
      'sf state',
      'san francisco state',
      'san francisco state university',
    ],
    place: {
      id: 'alias-sfsu',
      name: 'San Francisco State',
      address: '1600 Holloway Avenue, San Francisco, CA 94132',
      lat: 37.7241,
      lng: -122.4799,
    },
  },
  {
    names: ['ucla', 'uc los angeles', 'university of california los angeles'],
    place: {
      id: 'alias-ucla',
      name: 'UCLA',
      address: 'University of California, Los Angeles, CA 90095',
      lat: 34.07,
      lng: -118.444,
    },
  },
  {
    names: ['usc', 'university of southern california'],
    place: {
      id: 'alias-usc',
      name: 'University of Southern California',
      address: '3620 South Vermont Avenue, Los Angeles, CA 90007',
      lat: 34.0222,
      lng: -118.2904,
    },
  },
  {
    names: ['uc davis', 'university of california davis'],
    place: {
      id: 'alias-uc-davis',
      name: 'UC Davis',
      address: '1 Shields Avenue, Davis, CA 95616',
      lat: 38.5382,
      lng: -121.7617,
    },
  },
  {
    names: ['uc berkeley', 'ucb', 'university of california berkeley'],
    place: {
      id: 'alias-uc-berkeley',
      name: 'UC Berkeley',
      address: 'University of California, Berkeley, CA 94720',
      lat: 37.8717,
      lng: -122.2547,
    },
  },
  {
    names: ['sofi', 'sofi stadium', 'sofi stadium inglewood'],
    place: {
      id: 'alias-sofi-stadium',
      name: 'SoFi Stadium',
      address: '1001 South Stadium Drive, Inglewood, CA 90305',
      lat: 33.9534,
      lng: -118.3391,
    },
  },
  {
    names: ['sfo', 'sf airport', 'san francisco airport'],
    place: {
      id: 'alias-sfo',
      name: 'San Francisco International Airport (SFO)',
      address: 'San Francisco International Airport, San Francisco, CA 94128',
      lat: 37.6213,
      lng: -122.379,
    },
  },
  {
    names: ['smf', 'sacramento airport', 'sacramento international airport'],
    place: {
      id: 'alias-smf',
      name: 'Sacramento International Airport (SMF)',
      address: '6900 Airport Boulevard, Sacramento, CA 95837',
      lat: 38.6953,
      lng: -121.5927,
    },
  },
  {
    names: ['lax', 'la airport', 'los angeles airport'],
    place: {
      id: 'alias-lax',
      name: 'Los Angeles International Airport (LAX)',
      address: '1 World Way, Los Angeles, CA 90045',
      lat: 33.9435,
      lng: -118.4086,
    },
  },
];

/** Lower case, letters and digits only, single spaces. */
export const normalize = (text: string): string =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

/** Typing a few letters is enough, but not so few that anything matches. */
const MIN_PREFIX_LENGTH = 3;

/**
 * The aliased places that typed text is heading towards: it is a name, or
 * the start of one ("sac st" for "sac state"). Each place appears once.
 */
export function matchAliases(
  query: string,
  aliases: Alias[] = ALIASES,
): Place[] {
  const typed = normalize(query);
  if (
    typed.length < MIN_PREFIX_LENGTH &&
    !aliases.some(a => a.names.includes(typed))
  ) {
    return [];
  }
  return aliases
    .filter(({ names }) =>
      names.some(
        name =>
          name === typed ||
          (typed.length >= MIN_PREFIX_LENGTH && name.startsWith(typed)),
      ),
    )
    .map(({ place }) => place);
}
