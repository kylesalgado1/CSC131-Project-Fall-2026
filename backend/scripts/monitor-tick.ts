/**
 * Runs one monitoring tick and exits: checks the trips that are due, sends
 * the alerts that are queued, and enforces retention. For a scheduler that
 * starts a process on a timer (cron). Needs DATABASE_URL and MONITOR=on, and
 * the APNS_* variables for alerts to be sent (see .env.example).
 *
 *   npm run monitor:tick
 *
 * A process started for one tick has nothing cached: every trip it checks
 * costs fresh requests to the traffic provider, where the long-running
 * server reuses what it fetched minutes ago. So when the web service is
 * running, calling POST /internal/monitor/tick on it is the cheaper way to
 * drive ticks, and it keeps a host that sleeps when idle awake too.
 *
 * What the app is told about the monitor comes from the web service, which
 * only says monitoring is running when it has MONITOR=on itself. So a web
 * service left at MONITOR=off beside this script tells the app that nothing
 * is watching its trips, although this script is.
 */
import { loadCampusBreaks } from '../config/campusBreaks';
import { buildProviders } from '../config/providers';
import { databaseFromEnv } from '../db/pool';
import { pushSenderFromEnv } from '../push/apns';
import {
  monitorBudgetFromEnv,
  monitorConfigFromEnv,
  monitorSwitchesFromEnv,
} from '../trips/config';
import { tickOnce } from '../trips/ticker';
import { wireMonitoring } from '../trips/wiring';

async function main(): Promise<number> {
  const db = databaseFromEnv();
  const push = pushSenderFromEnv();
  let closed = false;
  // Safe to call twice: once by the tick, once on the way out.
  const close = async () => {
    if (closed) {
      return;
    }
    closed = true;
    try {
      await push.close?.();
    } finally {
      await db.close();
    }
  };
  try {
    const campusBreaks = await loadCampusBreaks(process.env.CAMPUS_BREAKS_FILE);
    const { providers } = buildProviders(db, campusBreaks);
    const { enabled, alwaysOn } = monitorSwitchesFromEnv();
    const { monitor, trips } = wireMonitoring({
      db,
      providers,
      push,
      config: monitorConfigFromEnv(),
      budget: monitorBudgetFromEnv(),
      enabled,
      alwaysOn,
    });
    return await tickOnce({
      enabled,
      available: () => trips.isAvailable(),
      // Started by a scheduler, which is what makes monitoring dependable.
      tick: () => monitor.tick({ external: true }),
      close,
    });
  } finally {
    // Also when the set-up above failed before any tick could run.
    await close();
  }
}

main()
  .then(code => process.exit(code))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
