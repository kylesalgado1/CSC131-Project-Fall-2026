import { FetchLike } from '../util/http';
import { LatLng } from '../prediction/types';
import { Place, PlaceSearch, SearchError } from './types';

interface PhotonResponse {
  features?: Array<{
    geometry?: { coordinates?: [number, number] };
    properties?: {
      osm_id?: number;
      osm_type?: string;
      name?: string;
      housenumber?: string;
      street?: string;
      city?: string;
      state?: string;
      postcode?: string;
      countrycode?: string;
    };
  }>;
}

const MAX_RESULTS = 5;
const TIMEOUT_MS = 4000;

/** What to call this request: Photon asks its users to identify themselves. */
const USER_AGENT = 'WaitItOut/0.0.1 (student project; place search)';

const defaultFetch: FetchLike = url =>
  fetch(url, {
    headers: { 'user-agent': USER_AGENT },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });

/** "Sacramento, CA 95819" style address lines from Photon's parts. */
function addressOf(
  p: NonNullable<PhotonResponse['features']>[number]['properties'],
): string {
  const street = [p?.housenumber, p?.street].filter(Boolean).join(' ');
  const region = [p?.state, p?.postcode].filter(Boolean).join(' ');
  return [street, p?.city, region].filter(Boolean).join(', ');
}

/**
 * Place search from Photon, an open search engine over OpenStreetMap data,
 * which needs no key. The public server asks for fair use, so searches are
 * cached by the caller and typed only after a pause. Results are credited to
 * OpenStreetMap contributors in the app. Set PHOTON_URL to use another
 * server, such as one you host yourself.
 */
export class PhotonPlaces implements PlaceSearch {
  constructor(
    private readonly baseUrl = 'https://photon.komoot.io',
    private readonly fetchFn: FetchLike = defaultFetch,
  ) {}

  async search(query: string, near?: LatLng): Promise<Place[]> {
    const params = new URLSearchParams({
      q: query,
      limit: String(MAX_RESULTS + 5),
      lang: 'en',
    });
    if (near) {
      params.set('lat', String(near.lat));
      params.set('lon', String(near.lng));
    }
    let body: PhotonResponse;
    try {
      const res = await this.fetchFn(`${this.baseUrl}/api/?${params}`);
      if (!res.ok) {
        throw new SearchError(`Photon request failed: HTTP ${res.status}`);
      }
      body = (await res.json()) as PhotonResponse;
    } catch (error) {
      throw error instanceof SearchError
        ? error
        : new SearchError('Photon could not be reached');
    }

    const places: Place[] = [];
    for (const feature of body.features ?? []) {
      const p = feature.properties;
      const [lng, lat] = feature.geometry?.coordinates ?? [];
      if (typeof lat !== 'number' || typeof lng !== 'number') {
        continue;
      }
      const name =
        p?.name ?? [p?.housenumber, p?.street].filter(Boolean).join(' ');
      // The app is for the US, and Photon's ranking sometimes crosses oceans.
      if (
        !p ||
        p.countrycode !== 'US' ||
        !name ||
        !Number.isFinite(lat) ||
        !Number.isFinite(lng)
      ) {
        continue;
      }
      places.push({
        id: `photon-${p.osm_type ?? 'x'}${p.osm_id ?? `${lat},${lng}`}`,
        name,
        address: addressOf(p) || name,
        lat,
        lng,
      });
      if (places.length === MAX_RESULTS) {
        break;
      }
    }
    return places;
  }
}
