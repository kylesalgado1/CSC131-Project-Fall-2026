import { errorFor, ApiError } from './client';
import { LatLng, Place } from './types';

export interface SearchPlacesOptions {
  fetchFn?: typeof fetch;
  /** Lets a newer search cancel an older one. */
  signal?: AbortSignal;
  timeoutMs?: number;
}

/**
 * Places matching text being typed, closest to `near` first. The backend
 * asks TomTom, so the key never reaches the phone.
 */
export async function searchPlaces(
  baseUrl: string,
  query: string,
  near?: LatLng,
  { fetchFn = fetch, signal, timeoutMs = 10_000 }: SearchPlacesOptions = {},
): Promise<Place[]> {
  const params = new URLSearchParams({ q: query });
  if (near) {
    params.set('lat', String(near.lat));
    params.set('lng', String(near.lng));
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  signal?.addEventListener('abort', () => controller.abort());
  let response: Response;
  try {
    response = await fetchFn(`${baseUrl}/places?${params}`, {
      signal: controller.signal,
    });
  } catch (error) {
    if (signal?.aborted) {
      throw error; // replaced by a newer search: the caller drops it
    }
    throw errorFor('network');
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    // 503 and 502 both mean search is not working; 400 means a bad request.
    throw errorFor(
      response.status === 400
        ? 'bad_request'
        : response.status === 503 || response.status === 502
        ? 'search_unavailable'
        : 'server',
    );
  }
  return ((await response.json()) as { places: Place[] }).places;
}

export const isAbort = (error: unknown): boolean =>
  error instanceof Error && error.name === 'AbortError';

export type { ApiError };
