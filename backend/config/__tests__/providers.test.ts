import { Database } from '../../db/db';
import { CachedPlaceSearch } from '../../places/cachedPlaces';
import { CampusBreak } from '../../prediction/calendar';
import {
  FallbackBaselineProvider,
  FallbackPathProvider,
} from '../../prediction/providers/fallback';
import { NoLiveConditions } from '../../prediction/providers/live';
import { PemsBaselineProvider } from '../../prediction/providers/pems/provider';
import { CachedPathProvider } from '../../prediction/providers/routing/osrm';
import { TomTomTraffic } from '../../prediction/providers/routing/tomtomTraffic';
import { CachedWeatherProvider } from '../../prediction/providers/weather';
import { Route } from '../../prediction/types';
import { buildProviders } from '../providers';

const KEY = 'SECRETKEY123';
const route: Route = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
};
const campusBreaks: CampusBreak[] = [
  { name: 'Spring break', start: '2027-03-22', end: '2027-03-26' },
];

/** Wiring must not read the database, so every call here is a failure. */
const unused = (): never => {
  throw new Error('The database was used while wiring the providers.');
};
const db: Database = {
  query: unused,
  exec: unused,
  transaction: unused,
  close: unused,
};

describe('buildProviders', () => {
  const realFetch = global.fetch;
  // Every service is down, and nothing here may reach the network.
  const fetchMock = jest.fn(async () => ({
    ok: false,
    status: 503,
    json: async () => ({}),
  }));

  beforeEach(() => {
    fetchMock.mockClear();
    global.fetch = fetchMock as unknown as typeof fetch;
  });

  afterEach(() => {
    global.fetch = realFetch;
  });

  it('uses PeMS alone when there is no TomTom key', () => {
    const wiring = buildProviders(db, campusBreaks, {});
    expect(wiring.providers.baseline).toBeInstanceOf(PemsBaselineProvider);
    expect(wiring.providers.live).toBeInstanceOf(NoLiveConditions);
    expect(wiring.providers.weather).toBeInstanceOf(CachedWeatherProvider);
    expect(wiring.providers.campusBreaks).toBe(campusBreaks);
    expect(wiring.paths).toBeInstanceOf(CachedPathProvider);
    expect(wiring.places).toBeInstanceOf(CachedPlaceSearch);
    expect(wiring.description).toBe(
      'Traffic source: PeMS only (TOMTOM_API_KEY is not set)',
    );
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('puts TomTom first, with PeMS and OSRM behind it, when there is a key', () => {
    const wiring = buildProviders(db, campusBreaks, { TOMTOM_API_KEY: KEY });
    expect(wiring.providers.baseline).toBeInstanceOf(FallbackBaselineProvider);
    expect(wiring.providers.live).toBeInstanceOf(TomTomTraffic);
    expect(wiring.providers.weather).toBeInstanceOf(CachedWeatherProvider);
    expect(wiring.providers.campusBreaks).toBe(campusBreaks);
    expect(wiring.paths).toBeInstanceOf(FallbackPathProvider);
    expect(wiring.description).toBe(
      'Traffic source: TomTom, with PeMS as the fallback',
    );
    expect(wiring.description).not.toContain(KEY);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('skips TomTom when TRAFFIC_SOURCE=pems, even with a key', () => {
    const wiring = buildProviders(db, campusBreaks, {
      TOMTOM_API_KEY: KEY,
      TRAFFIC_SOURCE: 'pems',
    });
    expect(wiring.providers.baseline).toBeInstanceOf(PemsBaselineProvider);
    expect(wiring.providers.live).toBeInstanceOf(NoLiveConditions);
    expect(wiring.paths).toBeInstanceOf(CachedPathProvider);
    expect(wiring.description).toBe(
      'Traffic source: PeMS only (TRAFFIC_SOURCE=pems)',
    );
  });

  it('warns, without the key, each time TomTom fails and a fallback is tried', async () => {
    const warnings: string[] = [];
    const { paths } = buildProviders(
      db,
      campusBreaks,
      { TOMTOM_API_KEY: KEY },
      message => warnings.push(message),
    );
    // OSRM is down as well, so the error to fix is TomTom's.
    await expect(paths.getPath(route)).rejects.toThrow(
      'TomTom request failed: HTTP 503',
    );
    expect(warnings).toEqual([
      'TomTom failed, using PeMS: TomTom request failed: HTTP 503',
    ]);
    expect(warnings.join()).not.toContain(KEY);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('draws paths with OSRM, tagged as such, when PeMS is the only source', async () => {
    fetchMock.mockImplementationOnce(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        code: 'Ok',
        routes: [
          {
            distance: 16093.44,
            duration: 600,
            geometry: {
              coordinates: [
                [-122.0402, 38.2383],
                [-121.4237, 38.5593],
              ],
            },
          },
        ],
      }),
    }));
    const { paths } = buildProviders(db, campusBreaks, {});
    const path = await paths.getPath(route);
    expect(path.source).toBe('osrm');
    expect(path.fallback).toBeUndefined();
    expect(path.points).toEqual([route.origin, route.destination]);
  });

  it('searches no service when Photon is off and there is no key', async () => {
    const { places } = buildProviders(db, campusBreaks, {
      PLACE_SEARCH_PHOTON: 'off',
    });
    expect(await places.search('zzzz qqqq')).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
