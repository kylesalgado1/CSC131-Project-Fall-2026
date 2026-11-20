// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory. The timers are driven by hand: nothing
// here waits for real time.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  availabilityNotice,
  FIRST_TICK_DELAY_MS,
  shutDown,
  SHUTDOWN_WAIT_MS,
  startTicker,
  tickOnce,
  Timers,
} from '../ticker';
import { TickReport } from '../types';

/** Timers that fire when the test says so. */
class ManualTimers implements Timers {
  timeouts: Array<{ run: () => void; ms: number; cleared: boolean }> = [];
  intervals: Array<{ run: () => void; ms: number; cleared: boolean }> = [];

  setTimeout(run: () => void, ms: number) {
    const timer = { run, ms, cleared: false };
    this.timeouts.push(timer);
    return timer;
  }

  setInterval(run: () => void, ms: number) {
    const timer = { run, ms, cleared: false };
    this.intervals.push(timer);
    return timer;
  }

  clearTimeout(handle: unknown) {
    (handle as { cleared: boolean }).cleared = true;
  }

  clearInterval(handle: unknown) {
    (handle as { cleared: boolean }).cleared = true;
  }

  /** Lets the boot delay pass. */
  boot() {
    for (const timer of this.timeouts) {
      if (!timer.cleared) {
        timer.run();
      }
    }
  }

  /** Lets one interval pass. */
  interval() {
    for (const timer of this.intervals) {
      if (!timer.cleared) {
        timer.run();
      }
    }
  }
}

/** Lets promise callbacks that are ready run. */
const settle = async () => {
  for (let i = 0; i < 5; i++) {
    await Promise.resolve();
  }
};

const REPORT: TickReport = {
  evaluated: 2,
  queued: 1,
  delivered: 1,
  failed: 0,
  dropped: 3,
};

describe('startTicker', () => {
  it('ticks first 30 seconds after the start, then at every interval', async () => {
    const timers = new ManualTimers();
    let ticks = 0;
    startTicker({
      tick: async () => {
        ticks += 1;
      },
      intervalMs: 60_000,
      timers,
    });
    assert.equal(FIRST_TICK_DELAY_MS, 30_000);
    assert.deepEqual(
      timers.timeouts.map(timer => timer.ms),
      [30_000],
    );
    assert.equal(timers.intervals.length, 0);
    assert.equal(ticks, 0);

    timers.boot();
    await settle();
    assert.equal(ticks, 1);
    assert.deepEqual(
      timers.intervals.map(timer => timer.ms),
      [60_000],
    );
    timers.interval();
    await settle();
    timers.interval();
    await settle();
    assert.equal(ticks, 3);
  });

  it('never runs two ticks at once: one that falls due during another is skipped', async () => {
    const timers = new ManualTimers();
    let started = 0;
    let finish: () => void = () => undefined;
    startTicker({
      tick: () => {
        started += 1;
        return new Promise<void>(resolve => {
          finish = resolve;
        });
      },
      intervalMs: 60_000,
      timers,
    });
    timers.boot();
    await settle();
    assert.equal(started, 1);
    // Two intervals pass while the first tick is still running.
    timers.interval();
    timers.interval();
    await settle();
    assert.equal(started, 1);

    finish();
    await settle();
    timers.interval();
    await settle();
    assert.equal(started, 2);
  });

  it('carries on after a tick that fails, logging only the kind of failure', async () => {
    const timers = new ManualTimers();
    const logs: string[] = [];
    let ticks = 0;
    startTicker({
      tick: async () => {
        ticks += 1;
        if (ticks === 1) {
          throw new RangeError('postgres://user:secret@host/db is down');
        }
      },
      intervalMs: 60_000,
      timers,
      log: line => logs.push(line),
    });
    timers.boot();
    await settle();
    assert.deepEqual(logs, ['Monitoring tick failed: RangeError']);
    timers.interval();
    await settle();
    assert.equal(ticks, 2);
    assert.equal(logs.length, 1);
  });

  it('carries on after a tick that throws before it returns', async () => {
    const timers = new ManualTimers();
    const logs: string[] = [];
    let ticks = 0;
    startTicker({
      tick: () => {
        ticks += 1;
        throw new TypeError('not even a promise');
      },
      intervalMs: 60_000,
      timers,
      log: line => logs.push(line),
    });
    timers.boot();
    await settle();
    timers.interval();
    await settle();
    assert.equal(ticks, 2);
    assert.deepEqual(logs, [
      'Monitoring tick failed: TypeError',
      'Monitoring tick failed: TypeError',
    ]);
  });

  it('stops: no more ticks, and its timers are cleared', async () => {
    const timers = new ManualTimers();
    let ticks = 0;
    const ticker = startTicker({
      tick: async () => {
        ticks += 1;
      },
      intervalMs: 60_000,
      timers,
    });
    timers.boot();
    await settle();
    ticker.stop();
    assert.ok(timers.timeouts.every(timer => timer.cleared));
    assert.ok(timers.intervals.every(timer => timer.cleared));
    // Even if a cleared timer were to fire.
    timers.intervals[0].run();
    await settle();
    assert.equal(ticks, 1);
  });

  it('never ticks when stopped before the first tick', async () => {
    const timers = new ManualTimers();
    let ticks = 0;
    const ticker = startTicker({
      tick: async () => {
        ticks += 1;
      },
      intervalMs: 60_000,
      timers,
    });
    ticker.stop();
    assert.ok(timers.timeouts[0].cleared);
    timers.timeouts[0].run();
    await settle();
    assert.equal(ticks, 0);
    assert.equal(timers.intervals.length, 0);
  });

  it('says when a tick under way at the stop has finished', async () => {
    const timers = new ManualTimers();
    let finish: () => void = () => undefined;
    const ticker = startTicker({
      tick: () =>
        new Promise<void>(resolve => {
          finish = resolve;
        }),
      intervalMs: 60_000,
      timers,
    });
    timers.boot();
    await settle();
    let stopped = false;
    const stopping = ticker.stop().then(() => {
      stopped = true;
    });
    await settle();
    // The tick is still running: it is not safe to close anything yet.
    assert.equal(stopped, false);
    finish();
    await stopping;
    assert.equal(stopped, true);
  });

  it('is stopped at once when no tick is under way, and after one that failed', async () => {
    const timers = new ManualTimers();
    const idle = startTicker({
      tick: async () => undefined,
      intervalMs: 60_000,
      timers,
    });
    await idle.stop();

    const failing = startTicker({
      tick: async () => {
        throw new Error('down');
      },
      intervalMs: 60_000,
      timers,
      log: () => undefined,
    });
    timers.boot();
    // Resolves, and does not reject, whatever became of the tick.
    await failing.stop();
  });

  it('names the work it runs when a round of it fails', async () => {
    const timers = new ManualTimers();
    const logs: string[] = [];
    startTicker({
      name: 'Trip purge',
      tick: async () => {
        throw new RangeError('no');
      },
      intervalMs: 3_600_000,
      firstDelayMs: 60_000,
      timers,
      log: line => logs.push(line),
    });
    timers.boot();
    await settle();
    assert.deepEqual(logs, ['Trip purge failed: RangeError']);
  });

  it('uses the first delay it is given', () => {
    const timers = new ManualTimers();
    const ticker = startTicker({
      tick: async () => undefined,
      intervalMs: 5000,
      firstDelayMs: 100,
      timers,
    });
    assert.deepEqual(
      timers.timeouts.map(timer => timer.ms),
      [100],
    );
    ticker.stop();
  });
});

describe('shutting down', () => {
  /** The steps of a shutdown, each noting when it ran. */
  const steps = (work: Promise<unknown>) => {
    const done: string[] = [];
    const note = (step: string, wait?: Promise<unknown>) => async () => {
      done.push(step);
      await wait;
      done.push(`${step} done`);
    };
    return {
      done,
      steps: {
        stopTimers: note('timers stopped', work),
        closeServer: note('server closing'),
        idle: note('monitor asked', work),
        closeConnections: note('connections closing'),
      },
    };
  };

  it('stops the ticker first, and closes the push sender and the database only once the tick under way has finished', async () => {
    let finish: () => void = () => undefined;
    const tick = new Promise<void>(resolve => {
      finish = resolve;
    });
    const timers = new ManualTimers();
    const { done, steps: shutdown } = steps(tick);
    const stopping = shutDown({ ...shutdown, timers });
    await settle();
    assert.deepEqual(done, [
      'timers stopped',
      'server closing',
      'server closing done',
      'monitor asked',
    ]);
    // Ten seconds are allowed for the tick.
    assert.equal(SHUTDOWN_WAIT_MS, 10_000);
    assert.deepEqual(
      timers.timeouts.map(timer => timer.ms),
      [10_000],
    );

    finish();
    assert.equal(await stopping, true);
    assert.deepEqual(done.slice(-2), [
      'connections closing',
      'connections closing done',
    ]);
    assert.ok(
      done.indexOf('timers stopped done') < done.indexOf('connections closing'),
    );
    assert.ok(
      done.indexOf('monitor asked done') < done.indexOf('connections closing'),
    );
    assert.ok(timers.timeouts[0].cleared);
  });

  it('closes anyway when a tick does not finish in time, and says so', async () => {
    const timers = new ManualTimers();
    const logs: string[] = [];
    const { done, steps: shutdown } = steps(new Promise(() => undefined));
    const stopping = shutDown({
      ...shutdown,
      waitMs: 250,
      timers,
      log: line => logs.push(line),
    });
    await settle();
    assert.ok(!done.includes('connections closing'));
    assert.deepEqual(
      timers.timeouts.map(timer => timer.ms),
      [250],
    );
    // The time runs out.
    timers.boot();
    assert.equal(await stopping, false);
    assert.equal(done[done.length - 1], 'connections closing done');
    assert.deepEqual(logs, [
      'Shutting down while a monitoring tick is still running.',
    ]);
  });

  it('does not mind work that ended badly', async () => {
    const timers = new ManualTimers();
    const { done, steps: shutdown } = steps(Promise.resolve());
    const finished = await shutDown({
      ...shutdown,
      idle: async () => {
        throw new Error('the last tick failed');
      },
      timers,
    });
    assert.equal(finished, true);
    assert.equal(done[done.length - 1], 'connections closing done');
  });
});

describe('what is said about the trip tables at start-up', () => {
  it('is nothing when they are there', async () => {
    assert.equal(await availabilityNotice(async () => true), undefined);
  });

  it('is to run the migration when they are missing', async () => {
    assert.equal(
      await availabilityNotice(async () => false),
      'Trip monitoring is off: run npm run migrate to create its tables.',
    );
  });

  it('is that the database could not be reached, which is not a missing migration, naming only the kind of failure', async () => {
    class ConnectionRefused extends Error {}
    const notice = await availabilityNotice(async () => {
      throw new ConnectionRefused('connect ECONNREFUSED db.example.com:5432');
    });
    assert.equal(
      notice,
      'Trip monitoring could not be checked: the database could not be reached (ConnectionRefused). That is not a missing migration: there is nothing to run.',
    );
    assert.ok(!String(notice).includes('db.example.com'));
    assert.ok(!String(notice).includes('npm run migrate'));
  });
});

describe('tickOnce', () => {
  const run = async (over: {
    enabled?: boolean;
    available?: boolean | Error;
    tick?: () => Promise<TickReport>;
  }) => {
    const lines: string[] = [];
    let ticks = 0;
    let closes = 0;
    const result = tickOnce({
      enabled: over.enabled ?? true,
      available: async () => {
        if (over.available instanceof Error) {
          throw over.available;
        }
        return over.available ?? true;
      },
      tick:
        over.tick ??
        (async () => {
          ticks += 1;
          return REPORT;
        }),
      close: async () => {
        closes += 1;
      },
      print: line => lines.push(line),
    });
    const code = await result.catch((error: unknown) => error);
    return { code, lines, ticks: () => ticks, closes: () => closes };
  };

  it('runs one tick, prints what it did, and closes its connections', async () => {
    const { code, lines, ticks, closes } = await run({});
    assert.equal(code, 0);
    assert.equal(ticks(), 1);
    assert.equal(closes(), 1);
    assert.deepEqual(lines, [
      'Monitoring tick: 2 evaluated, 1 queued, 1 delivered, 0 failed, 3 dropped',
    ]);
  });

  it('refuses to run where the worker is not switched on', async () => {
    const { code, lines, ticks, closes } = await run({ enabled: false });
    assert.equal(code, 1);
    assert.equal(ticks(), 0);
    assert.equal(closes(), 1);
    assert.deepEqual(lines, [
      'Trip monitoring is off here: set MONITOR=on on the one deployment that runs it.',
    ]);
  });

  it('refuses to run when the trip tables are missing', async () => {
    const { code, lines, ticks, closes } = await run({ available: false });
    assert.equal(code, 1);
    assert.equal(ticks(), 0);
    assert.equal(closes(), 1);
    assert.deepEqual(lines, [
      'Trip monitoring is off: run npm run migrate to create its tables.',
    ]);
  });

  it('refuses to run, without blaming the migration, when the database cannot be reached', async () => {
    const { code, lines, ticks, closes } = await run({
      available: new TypeError('getaddrinfo ENOTFOUND db.example.com'),
    });
    assert.equal(code, 1);
    assert.equal(ticks(), 0);
    assert.equal(closes(), 1);
    assert.deepEqual(lines, [
      'Trip monitoring could not be checked: the database could not be reached (TypeError). That is not a missing migration: there is nothing to run.',
    ]);
  });

  it('closes its connections when the tick fails, and passes the failure on', async () => {
    const failure = new Error('the database went away');
    const { code, lines, closes } = await run({
      tick: async () => {
        throw failure;
      },
    });
    assert.equal(code, failure);
    assert.equal(closes(), 1);
    assert.deepEqual(lines, []);
  });
});
