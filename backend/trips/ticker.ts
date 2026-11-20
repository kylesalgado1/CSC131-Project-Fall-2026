import { errorName } from '../util/errorName';
import { TickReport } from './types';

/** The first tick comes this long after the server starts. */
export const FIRST_TICK_DELAY_MS = 30_000;

/** The timers the ticker uses, so tests can drive them by hand. */
export interface Timers {
  setTimeout(run: () => void, ms: number): unknown;
  setInterval(run: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  clearInterval(handle: unknown): void;
}

const systemTimers: Timers = {
  setTimeout: (run, ms) => setTimeout(run, ms),
  setInterval: (run, ms) => setInterval(run, ms),
  clearTimeout: handle => clearTimeout(handle as NodeJS.Timeout),
  clearInterval: handle => clearInterval(handle as NodeJS.Timeout),
};

/** What a ticker is started with. */
export interface TickerOptions {
  /** One round of the work: of monitoring, unless `name` says otherwise. */
  tick: () => Promise<unknown>;
  /** How long between the start of one tick and the start of the next. */
  intervalMs: number;
  firstDelayMs?: number;
  /** What the work is called when a round of it fails. */
  name?: string;
  /** Where a failed tick is noted: its kind only. */
  log?: (line: string) => void;
  timers?: Timers;
}

/** A running ticker. */
export interface Ticker {
  /**
   * Stops it: no tick starts after this. A tick already under way finishes,
   * and the promise resolves once it has, so whatever that tick uses can be
   * closed afterwards and not under it.
   */
  stop(): Promise<void>;
}

/**
 * Runs a tick every so often inside the server, starting a little after it
 * boots. Ticks never overlap: when one is still running as the next falls
 * due, that next one is skipped. A tick that fails is logged and the ticker
 * carries on.
 *
 * This only works while the process is awake. A host that puts an idle
 * server to sleep stops the ticker with it, which is why such a host also
 * needs something outside to call the tick route.
 */
export function startTicker({
  tick,
  intervalMs,
  firstDelayMs = FIRST_TICK_DELAY_MS,
  name = 'Monitoring tick',
  log = line => console.error(line),
  timers = systemTimers,
}: TickerOptions): Ticker {
  let running = false;
  let stopped = false;
  let interval: unknown;
  // The tick under way, or the last one: it never rejects.
  let current: Promise<void> = Promise.resolve();
  const run = (): void => {
    if (running || stopped) {
      return;
    }
    running = true;
    current = Promise.resolve()
      .then(tick)
      .then(
        () => undefined,
        error => log(`${name} failed: ${errorName(error)}`),
      )
      .finally(() => {
        running = false;
      });
  };
  const first = timers.setTimeout(() => {
    if (stopped) {
      return;
    }
    interval = timers.setInterval(run, intervalMs);
    run();
  }, firstDelayMs);
  return {
    stop() {
      stopped = true;
      timers.clearTimeout(first);
      if (interval !== undefined) {
        timers.clearInterval(interval);
      }
      return current;
    },
  };
}

/** How long shutting down waits for work under way before closing anyway. */
export const SHUTDOWN_WAIT_MS = 10_000;

/** What shutting the server down is made of. */
export interface ShutdownSteps {
  /**
   * Stops whatever starts work by itself (the tickers), and resolves once
   * what they had started has finished.
   */
  stopTimers: () => Promise<unknown>;
  /** Stops taking requests; resolves once those under way are answered. */
  closeServer: () => Promise<unknown>;
  /** Resolves once the monitor has nothing under way. */
  idle: () => Promise<unknown>;
  /** Closes what the work needs: the push sender and the database. */
  closeConnections: () => Promise<unknown>;
  /** The longest to wait for work under way. */
  waitMs?: number;
  timers?: Pick<Timers, 'setTimeout' | 'clearTimeout'>;
  log?: (line: string) => void;
}

/**
 * Shuts the server down without pulling the connections out from under a
 * tick: nothing new is started, the requests under way are answered, and a
 * tick or an evaluation still running gets up to `waitMs` to finish before
 * the push sender and the database are closed. A tick cut short loses
 * nothing: its leases run out and the next process takes over. Answers
 * whether the work finished in time.
 */
export async function shutDown({
  stopTimers,
  closeServer,
  idle,
  closeConnections,
  waitMs = SHUTDOWN_WAIT_MS,
  timers = systemTimers,
  log = line => console.error(line),
}: ShutdownSteps): Promise<boolean> {
  const stopped = stopTimers();
  await closeServer();
  // Asked only now: a request may have left work behind its answer.
  const work = Promise.all([stopped, idle()]);
  const finished = await new Promise<boolean>(resolve => {
    const timer = timers.setTimeout(() => resolve(false), waitMs);
    const done = (): void => {
      timers.clearTimeout(timer);
      resolve(true);
    };
    work.then(done, done);
  });
  if (!finished) {
    log('Shutting down while a monitoring tick is still running.');
  }
  await closeConnections();
  return finished;
}

/** What is said when the trip tables are not there. */
export const TABLES_MISSING_NOTICE =
  'Trip monitoring is off: run npm run migrate to create its tables.';

/**
 * What to say at start-up about the trip tables, if anything. That they are
 * missing is one thing: the migration has to be run, and until then the
 * device and trip routes answer 503 monitoring_unavailable. That the
 * database could not be asked is another: nothing is known about the
 * tables, the routes answer 503 temporarily_unavailable, and they look
 * again at the next request, so they work by themselves once the database
 * can be reached. Only the kind of failure is named: a message can carry
 * the database's address.
 */
export async function availabilityNotice(
  available: () => Promise<boolean>,
): Promise<string | undefined> {
  try {
    return (await available()) ? undefined : TABLES_MISSING_NOTICE;
  } catch (error) {
    return `Trip monitoring could not be checked: the database could not be reached (${errorName(
      error,
    )}). That is not a missing migration: there is nothing to run.`;
  }
}

/** What a single tick from the command line needs. */
export interface TickOnceDeps {
  /** Whether this deployment runs the worker (MONITOR=on). */
  enabled: boolean;
  /** Whether the trip tables exist. */
  available: () => Promise<boolean>;
  tick: () => Promise<TickReport>;
  /** Releases the connections. Runs however the tick ends. */
  close: () => Promise<void>;
  print?: (line: string) => void;
}

/**
 * Runs one tick for a scheduler that starts a process per tick, and answers
 * the exit code: 0 when the tick ran, 1 when this deployment does not run
 * the worker, its tables are missing or the database could not be asked
 * about them. The connections are closed whatever happens, so the process
 * can end.
 */
export async function tickOnce({
  enabled,
  available,
  tick,
  close,
  print = line => console.log(line),
}: TickOnceDeps): Promise<number> {
  try {
    if (!enabled) {
      print(
        'Trip monitoring is off here: set MONITOR=on on the one deployment that runs it.',
      );
      return 1;
    }
    const notice = await availabilityNotice(available);
    if (notice !== undefined) {
      print(notice);
      return 1;
    }
    const report = await tick();
    print(
      `Monitoring tick: ${report.evaluated} evaluated, ${report.queued} queued, ${report.delivered} delivered, ${report.failed} failed, ${report.dropped} dropped`,
    );
    return 0;
  } finally {
    await close();
  }
}
