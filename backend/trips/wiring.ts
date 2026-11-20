import { Database } from '../db/db';
import { PredictionProviders } from '../prediction/predict';
import { PushSender } from '../push/apns';
import {
  DEFAULT_MONITOR_BUDGET,
  DEFAULT_MONITOR_CONFIG,
  MonitorBudget,
  MonitorConfig,
} from './config';
import { TripMonitor } from './monitor';
import { TripService } from './service';
import { TickReport } from './types';

/** What trip monitoring is put together from. */
export interface MonitoringDeps {
  db: Database;
  providers: PredictionProviders;
  push: PushSender;
  config?: MonitorConfig;
  budget?: MonitorBudget;
  /** Whether this server runs the worker (MONITOR=on). */
  enabled?: boolean;
  /** Whether this server is declared never to sleep. */
  alwaysOn?: boolean;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
  log?: (line: string) => void;
  /** How long one prediction may take. */
  evaluationTimeoutMs?: number;
  /** How long a sync waits for its trips' first plan. */
  inlineEvaluationTimeoutMs?: number;
}

/** The monitor and the trip service, wired to each other. */
export interface Monitoring {
  monitor: TripMonitor;
  trips: TripService;
  /**
   * One tick on a scheduler's behalf, for the tick route. Absent when this
   * server does not run the worker, which makes the route answer 503.
   */
  externalTick?: () => Promise<TickReport>;
}

/**
 * Wires the monitor and the trip service together, the one way the server,
 * the tick script, the fixture server and the tests all use:
 *
 * - On a server that runs the worker, a sync gets its trips' first plan at
 *   once from the monitor. On one that does not, the trip service plans
 *   nothing: a plan nobody refreshes would make the trip look monitored.
 * - Clients are told what the monitor says about itself.
 * - A tick started through the tick route counts as coming from outside.
 */
export function wireMonitoring({
  db,
  providers,
  push,
  config = DEFAULT_MONITOR_CONFIG,
  budget = DEFAULT_MONITOR_BUDGET,
  enabled = false,
  alwaysOn = false,
  now,
  log,
  evaluationTimeoutMs,
  inlineEvaluationTimeoutMs,
}: MonitoringDeps): Monitoring {
  const monitor = new TripMonitor({
    db,
    providers,
    push,
    now,
    config,
    budget,
    enabled,
    alwaysOn,
    evaluationTimeoutMs,
    log,
  });
  const trips = new TripService({
    db,
    now,
    config,
    push,
    evaluateNow: async deviceId => {
      await monitor.evaluateDue({ deviceId, limit: config.inlineEvaluations });
    },
    monitorStatus: () => monitor.status(),
    inlineEvaluationTimeoutMs,
    log,
  });
  return {
    monitor,
    trips,
    ...(enabled
      ? { externalTick: () => monitor.tick({ external: true }) }
      : {}),
  };
}
