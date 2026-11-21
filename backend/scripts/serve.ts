/**
 * Starts the API. Needs DATABASE_URL (see .env.example).
 *
 *   npm run serve
 *
 * With TOMTOM_API_KEY set, TomTom is the main traffic source: its route,
 * its typical drive time for each departure, and live delay and incidents.
 * PeMS and OSRM take over if TomTom fails. Campus breaks come from
 * config/campus-breaks.json (or CAMPUS_BREAKS_FILE) and are treated like
 * holidays. TRAFFIC_SOURCE=pems skips TomTom
 * entirely, which is handy for comparing the two. OSRM is the public demo
 * server and is for development only. Rain comes from Open-Meteo. PORT
 * defaults to 3000.
 *
 * The device and trip routes for the iOS client need the tables of migration
 * 005 (npm run migrate) and answer 503 until they exist. Behind a host's
 * proxy, set TRUST_PROXY so new devices are limited per client and not per
 * proxy.
 *
 * Trip monitoring (checking trips and sending alerts while the app is
 * closed) is opt-in: set MONITOR=on on the one deployment that should do it.
 * It then ticks every MONITOR_TICK_SECONDS inside this process, and also
 * whenever POST /internal/monitor/tick is called with MONITOR_TICK_SECRET.
 * Alerts need the APNS_* variables; without them trips are still planned
 * and monitored, and the app is told that alerts cannot be sent. Without
 * MONITOR=on the trip routes store what the app sends and plan nothing: the
 * app is told the monitor is off.
 *
 * Retention (ending trips past their arrival time, deleting what is over)
 * runs on its own timer whether or not MONITOR is on.
 */
import { buildServer, trustProxyFromEnv } from '../api/server';
import { loadCampusBreaks } from '../config/campusBreaks';
import { buildProviders } from '../config/providers';
import { databaseFromEnv } from '../db/pool';
import { pushSenderFromEnv } from '../push/apns';
import {
  monitorBudgetFromEnv,
  monitorConfigFromEnv,
  monitorSwitchesFromEnv,
  tickSecondsFromEnv,
} from '../trips/config';
import {
  availabilityNotice,
  shutDown,
  startTicker,
  Ticker,
} from '../trips/ticker';
import { wireMonitoring } from '../trips/wiring';
import { HOUR_MS, MINUTE_MS } from '../util/time';

/** Retention is first enforced this long after the server starts. */
const FIRST_PURGE_DELAY_MS = MINUTE_MS;

/** And then this often, for as long as the server runs. */
const PURGE_INTERVAL_MS = HOUR_MS;

async function main() {
  const db = databaseFromEnv();
  const campusBreaks = await loadCampusBreaks(process.env.CAMPUS_BREAKS_FILE);
  const { providers, places, paths, description } = buildProviders(
    db,
    campusBreaks,
  );
  console.log(description);

  console.log(`Campus breaks loaded: ${campusBreaks.length}`);

  const push = pushSenderFromEnv();
  const { enabled, alwaysOn } = monitorSwitchesFromEnv();
  const { monitor, trips, externalTick } = wireMonitoring({
    db,
    providers,
    push,
    config: monitorConfigFromEnv(),
    budget: monitorBudgetFromEnv(),
    enabled,
    alwaysOn,
  });
  const app = buildServer({
    providers,
    places,
    paths,
    trips,
    tickSecret: process.env.MONITOR_TICK_SECRET,
    tick: externalTick,
    trustProxy: trustProxyFromEnv(),
  });
  const port = Number(process.env.PORT ?? 3000);
  await app.listen({ port, host: '0.0.0.0' });
  console.log(`Listening on port ${port}`);
  // After listening, so a slow database cannot hold the server back. A
  // database that cannot be reached is said to be that, not a missing
  // migration, and does not stop the server: the routes try again.
  const notice = await availabilityNotice(() => trips.isAvailable());
  if (notice !== undefined) {
    console.log(notice);
  }
  // Whether or not this server runs the monitor: what it stores must not
  // outlive its retention because nobody happens to be syncing.
  const retention = startTicker({
    name: 'Trip purge',
    intervalMs: PURGE_INTERVAL_MS,
    firstDelayMs: FIRST_PURGE_DELAY_MS,
    tick: () => trips.enforceRetention(),
  });
  let ticker: Ticker | undefined;
  if (enabled) {
    const seconds = tickSecondsFromEnv();
    ticker = startTicker({
      intervalMs: seconds * 1000,
      // Looked up at every tick, so the tables can be created later
      // without a restart.
      tick: async () => {
        if (await trips.isAvailable()) {
          await monitor.tick();
        }
      },
    });
    console.log(
      `Trip monitoring: on, every ${seconds}s, push ${
        push.configured ? 'configured' : 'not configured'
      }`,
    );
  } else {
    console.log(
      'Trip monitoring: off (set MONITOR=on on the one deployment that runs it)',
    );
  }
  let stopping = false;
  const stop = async () => {
    if (stopping) {
      return;
    }
    stopping = true;
    // The ticker first, and a tick under way is given time to finish
    // before the push sender and the pool are closed under it.
    await shutDown({
      stopTimers: () => Promise.all([ticker?.stop(), retention.stop()]),
      closeServer: () => app.close(),
      idle: () => monitor.idle(),
      closeConnections: async () => {
        await push.close?.();
        await db.close();
      },
    });
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
