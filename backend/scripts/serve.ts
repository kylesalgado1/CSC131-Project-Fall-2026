/**
 * Starts the API. Needs DATABASE_URL (see .env.example).
 *
 *   npm run serve
 *
 * ROUTING=osrm (default) uses the public OSRM demo server, which is for
 * development only. Rain comes from Open-Meteo. PORT defaults to 3000.
 */
import { buildServer } from '../api/server';
import { databaseFromEnv } from '../db/pool';
import { NoLiveConditions } from '../prediction/providers/live';
import { OpenMeteoWeatherProvider } from '../prediction/providers/openMeteo';
import { CachedWeatherProvider } from '../prediction/providers/weather';
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

async function main() {
  const routing = process.env.ROUTING ?? 'osrm';
  if (routing !== 'osrm') {
    throw new Error(`Unknown ROUTING "${routing}". Only "osrm" exists so far.`);
  }
  const db = databaseFromEnv();
  const paths = new CachedPathProvider(new OsrmPathProvider());
  const resolver = new PathRouteResolver(new PgStationSource(db), paths);
  const app = buildServer({
    providers: {
      baseline: new PemsBaselineProvider(new PgProfileStore(db), resolver),
      live: new NoLiveConditions(),
      weather: new CachedWeatherProvider(new OpenMeteoWeatherProvider()),
    },
  });

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
