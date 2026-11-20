import { Database } from '../db/db';
import { CachedPlaceSearch } from '../places/cachedPlaces';
import { CompositePlaceSearch } from '../places/compositePlaces';
import { PhotonPlaces } from '../places/photonPlaces';
import { TomTomPlaces } from '../places/tomtomPlaces';
import { PlaceSearch } from '../places/types';
import { CampusBreak } from '../prediction/calendar';
import { PredictionProviders } from '../prediction/predict';
import {
  FallbackBaselineProvider,
  FallbackPathProvider,
} from '../prediction/providers/fallback';
import { NoLiveConditions } from '../prediction/providers/live';
import { OpenMeteoWeatherProvider } from '../prediction/providers/openMeteo';
import { PgProfileStore } from '../prediction/providers/pems/pgStore';
import { PemsBaselineProvider } from '../prediction/providers/pems/provider';
import {
  CachedPathProvider,
  OsrmPathProvider,
} from '../prediction/providers/routing/osrm';
import {
  PathRouteResolver,
  PgStationSource,
} from '../prediction/providers/routing/pathResolver';
import { TomTomClient } from '../prediction/providers/routing/tomtom';
import { TomTomTraffic } from '../prediction/providers/routing/tomtomTraffic';
import { RoutePathProvider } from '../prediction/providers/routing/types';
import { CachedWeatherProvider } from '../prediction/providers/weather';
import { FetchLike } from '../util/http';

/** The data sources the API and the background workers share. */
export interface ProviderWiring {
  providers: PredictionProviders;
  places: PlaceSearch;
  /** Route geometry, from the same source and cache the predictions use. */
  paths: RoutePathProvider;
  /** One line saying which traffic source is in use, for the start-up log. */
  description: string;
}

/** Where warnings go unless the caller says otherwise: the server's log. */
const defaultWarn = (message: string): void => console.warn(message);

/** How long one TomTom request may take before it is given up on. */
export const TOMTOM_TIMEOUT_MS = 15_000;

/**
 * `fetch` that gives up after TOMTOM_TIMEOUT_MS. The TomTom client sends its
 * requests one after another, so a single request that never answers would
 * hold up every one behind it, and with them every trip the monitor checks.
 * A request that times out fails like any other, and PeMS and OSRM answer.
 */
const fetchWithTimeout: FetchLike = url =>
  fetch(url, { signal: AbortSignal.timeout(TOMTOM_TIMEOUT_MS) });

/**
 * Wires up the data sources from the environment.
 *
 * With TOMTOM_API_KEY set, TomTom is the main traffic source: its route, its
 * typical drive time for each departure, and live delay and incidents. PeMS
 * and OSRM take over if TomTom fails, and `warn` is told each time they do.
 * TRAFFIC_SOURCE=pems skips TomTom entirely. A TomTom request that takes
 * longer than TOMTOM_TIMEOUT_MS counts as failed. Place search needs no key:
 * Photon is always on unless PLACE_SEARCH_PHOTON=off, and TomTom joins it
 * when there is a key. Rain comes from Open-Meteo. Nothing is fetched here.
 */
export function buildProviders(
  db: Database,
  campusBreaks: CampusBreak[],
  env = process.env,
  warn = defaultWarn,
): ProviderWiring {
  const warnFallback = (error: unknown) =>
    // TomTom errors never include the request URL, so the key cannot leak here.
    warn(
      `TomTom failed, using PeMS: ${
        error instanceof Error ? error.message : error
      }`,
    );
  const osrm = new CachedPathProvider(new OsrmPathProvider());
  const apiKey = env.TOMTOM_API_KEY;
  const useTomTom = Boolean(apiKey) && env.TRAFFIC_SOURCE !== 'pems';

  const client = useTomTom
    ? new TomTomClient(apiKey!, fetchWithTimeout)
    : undefined;
  const tomtom = client
    ? new TomTomTraffic(client, { campusBreaks })
    : undefined;
  // Place search needs no key: Photon (OpenStreetMap) is always on unless
  // PLACE_SEARCH_PHOTON=off, and TomTom joins it when there is a key.
  const placeSources: PlaceSearch[] = [
    ...(client ? [new TomTomPlaces(client)] : []),
    ...(env.PLACE_SEARCH_PHOTON === 'off'
      ? []
      : [new PhotonPlaces(env.PHOTON_URL)]),
  ];
  const places = new CachedPlaceSearch(new CompositePlaceSearch(placeSources));
  const paths: RoutePathProvider = tomtom
    ? new FallbackPathProvider(tomtom, osrm, warnFallback)
    : osrm;
  const pems = new PemsBaselineProvider(
    new PgProfileStore(db),
    new PathRouteResolver(new PgStationSource(db), paths),
    { campusBreaks },
  );
  const providers: PredictionProviders = {
    baseline: tomtom
      ? new FallbackBaselineProvider(tomtom, pems, warnFallback)
      : pems,
    live: tomtom ?? new NoLiveConditions(),
    weather: new CachedWeatherProvider(new OpenMeteoWeatherProvider()),
    campusBreaks,
  };
  return {
    providers,
    places,
    paths,
    description: tomtom
      ? 'Traffic source: TomTom, with PeMS as the fallback'
      : apiKey
      ? 'Traffic source: PeMS only (TRAFFIC_SOURCE=pems)'
      : 'Traffic source: PeMS only (TOMTOM_API_KEY is not set)',
  };
}
