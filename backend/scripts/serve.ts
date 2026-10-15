/**
 * Starts the API. Needs DATABASE_URL (see .env.example).
 *
 *   npm run serve
 *
 * With TOMTOM_API_KEY set, TomTom is the main traffic source: its route,
 * its typical drive time for each departure, and live delay and incidents.
 * PeMS and OSRM take over if TomTom fails. TRAFFIC_SOURCE=pems skips TomTom
 * entirely, which is handy for comparing the two. OSRM is the public demo
 * server and is for development only. Rain comes from Open-Meteo. PORT
 * defaults to 3000.
 */
import { buildServer } from '../api/server';
import { databaseFromEnv } from '../db/pool';
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
import { TomTomRoutingClient } from '../prediction/providers/routing/tomtom';
import { TomTomTraffic } from '../prediction/providers/routing/tomtomTraffic';
import { CachedWeatherProvider } from '../prediction/providers/weather';

function warnFallback(error: unknown) {
  // TomTom errors never include the request URL, so the key cannot leak here.
  console.warn(
    `TomTom failed, using PeMS: ${
      error instanceof Error ? error.message : error
    }`,
  );
}

async function main() {
  const db = databaseFromEnv();
  const osrm = new CachedPathProvider(new OsrmPathProvider());
  const apiKey = process.env.TOMTOM_API_KEY;
  const useTomTom = Boolean(apiKey) && process.env.TRAFFIC_SOURCE !== 'pems';

  const tomtom = useTomTom
    ? new TomTomTraffic(new TomTomRoutingClient(apiKey!))
    : undefined;
  const pems = new PemsBaselineProvider(
    new PgProfileStore(db),
    new PathRouteResolver(
      new PgStationSource(db),
      tomtom ? new FallbackPathProvider(tomtom, osrm, warnFallback) : osrm,
    ),
  );
  const providers: PredictionProviders = {
    baseline: tomtom
      ? new FallbackBaselineProvider(tomtom, pems, warnFallback)
      : pems,
    live: tomtom ?? new NoLiveConditions(),
    weather: new CachedWeatherProvider(new OpenMeteoWeatherProvider()),
  };
  console.log(
    tomtom
      ? 'Traffic source: TomTom, with PeMS as the fallback'
      : apiKey
      ? 'Traffic source: PeMS only (TRAFFIC_SOURCE=pems)'
      : 'Traffic source: PeMS only (TOMTOM_API_KEY is not set)',
  );

  const app = buildServer({ providers });
  const port = Number(process.env.PORT ?? 3000);
  await app.listen({ port, host: '0.0.0.0' });
  console.log(`Listening on port ${port}`);
  const stop = async () => {
    await app.close();
    await db.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
