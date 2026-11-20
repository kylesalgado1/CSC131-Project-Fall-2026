import {
  FAR_SLOT_INTERVAL_MINUTES,
  HORIZON_MINUTES,
  MAX_PLAN_MINUTES,
  SLOT_INTERVAL_MINUTES,
} from '../prediction/predict';

/**
 * How far ahead of its arrival target a trip can be given a departure.
 *
 * Not configurable: it follows from how the prediction lays out its slots.
 * Past three hours they sit on the half hour, and they stop MAX_PLAN_MINUTES
 * after "now". Exactly that far ahead, a target off the half hour (say 8:50)
 * still lies beyond the last slot, so the answer can be "no rush" instead of
 * a departure. One far slot closer the slots always reach the target, and
 * the first evaluation of a trip yields a plan.
 */
export const PLANNING_HORIZON_MINUTES =
  MAX_PLAN_MINUTES - FAR_SLOT_INTERVAL_MINUTES;

/**
 * How often a monitored trip is checked again. Not configurable either: a
 * recommended departure is always one of the prediction's slots, which sit
 * this far apart, so checking more often could not move it and would only
 * spend the traffic provider's quota.
 */
export const MONITOR_POLL_MINUTES = SLOT_INTERVAL_MINUTES;

/** A trip is accepted until its arrival time is this far in the past. */
export const MAX_PAST_ARRIVAL_HOURS = 24;

/** A trip is accepted once its arrival time is less than this far ahead. */
export const MAX_AHEAD_ARRIVAL_DAYS = 8;

/**
 * A trip's start time, which is only a label, is accepted when it is no
 * farther than this from its arrival time.
 */
export const MAX_START_OFFSET_HOURS = 24;

/** A device with nothing to monitor is forgotten after this long unseen. */
export const DEVICE_RETENTION_DAYS = 30;

/** The thresholds the trip endpoints and the monitor share. */
export interface MonitorConfig {
  /** Active monitoring starts this long before the recommended departure. */
  monitorLeadMinutes: number;
  /** The heads-up goes out this long before the recommended departure. */
  headsUpLeadMinutes: number;
  /**
   * A recommended departure that moved by at least this much is worth an
   * update. Checks land on the 15-minute slots, so a shift is always zero or
   * a multiple of 15 minutes and the default of 5 means "one slot" in
   * practice. What stops an update flapping at a slot boundary is that a
   * later departure must be seen twice in a row before it is announced.
   */
  meaningfulShiftMinutes: number;
  /** The least time between two updates for one trip. */
  updateMinIntervalMinutes: number;
  /** The most updates one trip gets. */
  maxUpdatesPerTrip: number;
  /** A check that runs more than this after it was due counts as late. */
  maxLagSeconds: number;
  /** A recommendation that could not be refreshed for this long is stale. */
  staleAfterMinutes: number;
  /** How long a trip's row is kept after the trip is over. */
  retentionHours: number;
  /** The most trips one device can have monitored. */
  maxTrips: number;
  /** How many of a device's trips are evaluated while its sync waits. */
  inlineEvaluations: number;
}

/** The thresholds in use unless the environment overrides them. */
export const DEFAULT_MONITOR_CONFIG: MonitorConfig = {
  monitorLeadMinutes: 120,
  headsUpLeadMinutes: 90,
  meaningfulShiftMinutes: 5,
  updateMinIntervalMinutes: 10,
  maxUpdatesPerTrip: 3,
  maxLagSeconds: 120,
  staleAfterMinutes: 30,
  retentionHours: 24,
  maxTrips: 50,
  inlineEvaluations: 3,
};

interface EnvSetting {
  key: keyof MonitorConfig;
  variable: string;
  min: number;
  max: number;
  /** Set when the value must sit on the prediction's slots. */
  multipleOf?: number;
}

/**
 * The longest lead time the environment may set, for monitoring and for the
 * heads-up alike: one slot short of the prediction's slot horizon.
 *
 * Only within that horizon are departures a slot apart, which is what lets
 * one check be compared with the next. And exactly at the horizon the
 * 15-minute slots end at the departure itself: asked three hours before a
 * departure, the prediction may not yet be able to offer the slot after it,
 * only one on the half hour beyond. So a lead of the whole horizon could
 * name a departure that the very next check moves a slot later with traffic
 * unchanged, and the user would get an "updated plan" for nothing.
 */
export const MAX_LEAD_MINUTES = HORIZON_MINUTES - SLOT_INTERVAL_MINUTES;

const ENV_SETTINGS: EnvSetting[] = [
  {
    key: 'monitorLeadMinutes',
    variable: 'MONITOR_LEAD_MINUTES',
    min: SLOT_INTERVAL_MINUTES,
    max: MAX_LEAD_MINUTES,
    multipleOf: SLOT_INTERVAL_MINUTES,
  },
  {
    key: 'headsUpLeadMinutes',
    variable: 'HEADS_UP_LEAD_MINUTES',
    min: SLOT_INTERVAL_MINUTES,
    max: MAX_LEAD_MINUTES,
    multipleOf: SLOT_INTERVAL_MINUTES,
  },
  {
    key: 'meaningfulShiftMinutes',
    variable: 'MEANINGFUL_SHIFT_MINUTES',
    min: 1,
    max: 60,
  },
  {
    key: 'updateMinIntervalMinutes',
    variable: 'UPDATE_MIN_INTERVAL_MINUTES',
    min: 0,
    max: 240,
  },
  {
    key: 'maxUpdatesPerTrip',
    variable: 'MAX_UPDATES_PER_TRIP',
    min: 0,
    max: 20,
  },
  {
    key: 'maxLagSeconds',
    variable: 'MONITOR_MAX_LAG_SECONDS',
    min: 30,
    max: 600,
  },
  {
    key: 'retentionHours',
    variable: 'TRIP_RETENTION_HOURS',
    // No shorter than a trip stays acceptable after its arrival time, so a
    // trip a device still lists is never purged from under it.
    min: MAX_PAST_ARRIVAL_HOURS,
    max: 720,
  },
];

/** Where warnings go unless the caller says otherwise: the server's log. */
const defaultWarn = (message: string): void => console.warn(message);

/**
 * What bounds the monitor's use of the traffic provider. Kept apart from the
 * thresholds above: clients are told those, and these are only the worker's.
 */
export interface MonitorBudget {
  /**
   * The most trips one tick asks the prediction about. The rest wait for the
   * next tick, so one busy minute cannot run into the provider's rate limit.
   */
  evaluationsPerTick: number;
  /**
   * The most evaluations in one UTC day, counted in the database so every
   * worker shares it. Once it is used up no provider is asked until
   * midnight UTC; alerts that only depend on the clock still go out from
   * the stored plans.
   */
  dailyEvaluations: number;
}

/** The limits in use unless the environment overrides them. */
export const DEFAULT_MONITOR_BUDGET: MonitorBudget = {
  evaluationsPerTick: 10,
  dailyEvaluations: 150,
};

/** How often the in-process ticker runs unless the environment says. */
export const DEFAULT_TICK_SECONDS = 60;

const wholeNumber = (
  env: Record<string, string | undefined>,
  variable: string,
  min: number,
  max: number,
  fallback: number,
  warn: (message: string) => void,
): number => {
  const raw = env[variable]?.trim();
  if (!raw) {
    return fallback;
  }
  const value = /^\d{1,9}$/.test(raw) ? Number(raw) : NaN;
  if (value >= min && value <= max) {
    return value;
  }
  warn(`${variable} is not a usable value; using the default.`);
  return fallback;
};

/**
 * The monitor's limits, with MONITOR_DAILY_EVALUATION_BUDGET if it is set
 * to a whole number (0 stops every provider call). Anything else is ignored
 * with one warning that names the variable and never the value.
 */
export function monitorBudgetFromEnv(
  env: Record<string, string | undefined> = process.env,
  warn: (message: string) => void = defaultWarn,
): MonitorBudget {
  return {
    ...DEFAULT_MONITOR_BUDGET,
    dailyEvaluations: wholeNumber(
      env,
      'MONITOR_DAILY_EVALUATION_BUDGET',
      0,
      100_000,
      DEFAULT_MONITOR_BUDGET.dailyEvaluations,
      warn,
    ),
  };
}

/**
 * How often the in-process ticker runs, from MONITOR_TICK_SECONDS (10 to
 * 900). More often than a trip's 15-minute checks need, so that a check and
 * the alert it queues go out within about that long of being due.
 */
export function tickSecondsFromEnv(
  env: Record<string, string | undefined> = process.env,
  warn: (message: string) => void = defaultWarn,
): number {
  return wholeNumber(
    env,
    'MONITOR_TICK_SECONDS',
    10,
    900,
    DEFAULT_TICK_SECONDS,
    warn,
  );
}

/** Whether this server runs the monitoring worker, and can be counted on. */
export interface MonitorSwitches {
  /** MONITOR=on. Off unless said, so two deployments never both run it. */
  enabled: boolean;
  /** MONITOR_ALWAYS_ON=true: this server is declared never to sleep. */
  alwaysOn: boolean;
}

/**
 * Reads MONITOR and MONITOR_ALWAYS_ON. The worker is opt-in: a server only
 * checks trips and sends alerts with MONITOR=on, which belongs on the one
 * deployment meant to do it. Everything else leaves it off.
 */
export function monitorSwitchesFromEnv(
  env: Record<string, string | undefined> = process.env,
): MonitorSwitches {
  return {
    enabled: env.MONITOR?.trim().toLowerCase() === 'on',
    alwaysOn: env.MONITOR_ALWAYS_ON?.trim().toLowerCase() === 'true',
  };
}

/**
 * The monitoring thresholds, with any the environment overrides. A value
 * that is not a whole number in range is ignored with one warning that names
 * the variable and never the value. The two lead times must be whole slots
 * and no longer than MAX_LEAD_MINUTES, and the heads-up cannot come before
 * monitoring starts.
 */
export function monitorConfigFromEnv(
  env: Record<string, string | undefined> = process.env,
  warn: (message: string) => void = defaultWarn,
): MonitorConfig {
  const config = { ...DEFAULT_MONITOR_CONFIG };
  for (const { key, variable, min, max, multipleOf = 1 } of ENV_SETTINGS) {
    const raw = env[variable]?.trim();
    if (!raw) {
      continue;
    }
    const value = /^\d{1,9}$/.test(raw) ? Number(raw) : NaN;
    if (value >= min && value <= max && value % multipleOf === 0) {
      config[key] = value;
    } else {
      warn(`${variable} is not a usable value; using the default.`);
    }
  }
  if (config.headsUpLeadMinutes > config.monitorLeadMinutes) {
    warn(
      'HEADS_UP_LEAD_MINUTES is longer than MONITOR_LEAD_MINUTES; using the defaults for both.',
    );
    config.monitorLeadMinutes = DEFAULT_MONITOR_CONFIG.monitorLeadMinutes;
    config.headsUpLeadMinutes = DEFAULT_MONITOR_CONFIG.headsUpLeadMinutes;
  }
  return config;
}
