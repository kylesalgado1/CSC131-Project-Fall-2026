// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// PGlite, the in-memory Postgres these tests use, cannot load inside Jest.
//
// How the monitor is run: its limits on provider use, the heartbeat clients
// are told about, and its housekeeping.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Database } from '../../db/db';
import { TripMonitor } from '../monitor';
import {
  addMinutes,
  GYM,
  migratedDatabase,
  resetDatabase,
  t,
  tripInput,
  World,
  WorldOptions,
} from './harness';

const iso = (clock: string): string => t(clock).toISOString();

let db: Database;

// One database for the whole file, emptied before each test.
before(async () => {
  db = await migratedDatabase();
});

after(async () => {
  await db.close();
});

beforeEach(async () => {
  await resetDatabase(db);
});

const world = (now: Date, options: Partial<WorldOptions> = {}): World =>
  new World(db, { now, ...options });

const budgetRow = async () => {
  const { rows } = await db.query<{ day: string | null; used: number }>(
    'SELECT budget_day::text AS day, budget_used AS used FROM monitor_state',
  );
  return rows[0];
};

/** Five trips arriving a quarter of an hour apart, none evaluated yet. */
const fiveTrips = async (options: Partial<WorldOptions> = {}) => {
  const w = world(t('05:00'), {
    ...options,
    // The sync itself evaluates nothing, so the ticks have it all to do.
    config: { inlineEvaluations: 0, ...options.config },
  });
  const token = await w.device();
  const ids = ['E@1', 'D@1', 'C@1', 'B@1', 'A@1'];
  await w.sync(
    token,
    ids.map((id, i) =>
      tripInput({
        id,
        title: `Trip ${id}`,
        arriveBy: addMinutes(t('08:00'), i * 15).toISOString(),
      }),
    ),
  );
  return { w, token, ids };
};

const planned = async (w: World, token: string): Promise<string[]> =>
  (await w.list(token)).trips
    .filter(trip => trip.recommendation !== null)
    .map(trip => trip.id);

describe('how many trips one tick asks about', () => {
  it('is at most ten, earliest arrival first, and the rest wait for the next tick', async () => {
    const w = world(t('05:00'), {
      config: { inlineEvaluations: 0, maxTrips: 50 },
    });
    const token = await w.device();
    await w.sync(
      token,
      Array.from({ length: 12 }, (_, i) =>
        tripInput({
          id: `T${String(i).padStart(2, '0')}@1`,
          // Listed latest first, to show the order is by arrival time.
          arriveBy: addMinutes(t('08:00'), (11 - i) * 5).toISOString(),
        }),
      ),
    );
    assert.equal(w.traffic.asks, 0);

    const first = await w.tickAt(t('05:01'));
    assert.equal(first.evaluated, 10);
    assert.equal(w.traffic.asks, 10);
    // The two latest arrivals are the ones left.
    assert.deepEqual(
      (await w.list(token)).trips
        .filter(trip => trip.recommendation === null)
        .map(trip => trip.id),
      ['T01@1', 'T00@1'],
    );
    const second = await w.tickAt(t('05:02'));
    assert.equal(second.evaluated, 2);
    assert.equal((await w.tickAt(t('05:03'))).evaluated, 0);
  });

  it('follows the limit it is given', async () => {
    const { w, token } = await fiveTrips({ budget: { evaluationsPerTick: 2 } });
    assert.equal((await w.tickAt(t('05:01'))).evaluated, 2);
    assert.deepEqual(await planned(w, token), ['E@1', 'D@1']);
    assert.equal((await w.tickAt(t('05:02'))).evaluated, 2);
    assert.equal((await w.tickAt(t('05:03'))).evaluated, 1);
    assert.equal((await w.tickAt(t('05:04'))).evaluated, 0);
    assert.equal(w.traffic.asks, 5);
  });

  it('asks about one trip at a time, never several at once', async () => {
    const { w } = await fiveTrips();
    let asking = 0;
    let most = 0;
    w.traffic.onAsk = async () => {
      asking += 1;
      most = Math.max(most, asking);
      await new Promise(resolve => setImmediate(resolve));
      asking -= 1;
    };
    assert.equal((await w.tickAt(t('05:01'))).evaluated, 5);
    assert.equal(most, 1);
  });

  it('shares one queue between the ticker, the tick route and a sync’s first evaluation', async () => {
    const { w, token } = await fiveTrips({ budget: { evaluationsPerTick: 2 } });
    const device = await w.authenticate(token);
    let asking = 0;
    let most = 0;
    w.traffic.onAsk = async () => {
      asking += 1;
      most = Math.max(most, asking);
      await new Promise(resolve => setImmediate(resolve));
      asking -= 1;
    };
    w.clock = t('05:01');
    assert.ok(w.externalTick);
    await Promise.all([
      w.monitor.tick(),
      w.externalTick(),
      w.monitor.evaluateDue({ deviceId: device.id, limit: 1 }),
    ]);
    assert.equal(most, 1);
    assert.equal(w.traffic.asks, 5);
  });

  it('does not count trips that need no asking against the limit', async () => {
    const { w, token } = await fiveTrips({ budget: { evaluationsPerTick: 1 } });
    // By 8:35 three of the five are past their arrival time. Ending them
    // asks nobody, so the one evaluation the tick may make is still made.
    const report = await w.tickAt(t('08:35'));
    assert.equal(report.evaluated, 1);
    assert.deepEqual(
      (await w.list(token)).trips.map(trip => [trip.id, trip.phase]),
      [
        ['E@1', 'ended'],
        ['D@1', 'ended'],
        ['C@1', 'ended'],
        ['B@1', 'monitoring'],
        ['A@1', 'planning'],
      ],
    );
  });

  it('carries on with the other trips when one cannot be checked', async () => {
    const { w, token } = await fiveTrips();
    // A row the monitor cannot write back: a drive time the column refuses.
    let asked = 0;
    w.traffic.onAsk = async () => {
      asked += 1;
      w.traffic.driveMinutes = asked === 1 ? 4e9 : 20;
    };
    const report = await w.tickAt(t('05:01'));
    assert.equal(report.evaluated, 4);
    assert.equal(w.logs.length, 1);
    assert.match(w.logs[0], /^Trip check failed: \w+$/);
    assert.deepEqual(await planned(w, token), ['D@1', 'C@1', 'B@1', 'A@1']);
  });
});

describe('the daily evaluation budget', () => {
  it('stops asking once it is used up, and says so, while the clock still decides the alerts', async () => {
    const w = world(t('05:00'), { budget: { dailyEvaluations: 3 } });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // Used: the sync, 5:30 and 5:45.
    await w.runUntil(t('05:59'));
    assert.equal(w.traffic.asks, 3);
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 3 });
    assert.equal((await w.state(token)).lastError, null);

    const report = await w.tickAt(t('06:00'));
    assert.equal(report.evaluated, 0);
    assert.equal(w.traffic.asks, 3);
    let state = await w.state(token);
    assert.deepEqual(state.lastError, {
      code: 'budget_exhausted',
      at: iso('06:00'),
    });
    assert.equal(state.recommendation?.departAt, iso('07:30'));
    assert.equal(state.recommendation?.evaluatedAt, iso('05:45'));
    // Looked at again in half an hour, or when something is due.
    assert.equal(state.monitoring.nextCheckAt, iso('06:30'));
    // The heads-up still went out, from the plan made at 5:45.
    assert.deepEqual(w.push.kinds(), ['heads_up']);

    await w.runUntil(t('08:00'));
    assert.equal(w.traffic.asks, 3);
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 3 });
    assert.deepEqual(
      w.push.sent.map(({ at, kind, body }) => ({
        at: at.toISOString(),
        kind,
        body,
      })),
      [
        {
          at: iso('06:00'),
          kind: 'heads_up',
          body: "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
        },
        {
          at: iso('07:30'),
          kind: 'leave_now',
          body: 'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM. Traffic could not be re-checked since 5:45 AM.',
        },
      ],
    );
    state = await w.state(token);
    assert.equal(state.phase, 'ended');
  });

  it('starts again at midnight UTC', async () => {
    // 4:00 PM Pacific is midnight UTC. Arrive by 6:00 PM, one evaluation a day.
    const w = world(t('15:00'), { budget: { dailyEvaluations: 1 } });
    const token = await w.device();
    await w.sync(token, [tripInput({ arriveBy: iso('18:00') })]);
    assert.equal(w.traffic.asks, 1);
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 1 });

    await w.runUntil(t('15:59'));
    assert.equal(w.traffic.asks, 1);
    assert.equal((await w.state(token)).lastError?.code, 'budget_exhausted');

    await w.runUntil(t('16:00'));
    assert.equal(w.traffic.asks, 2);
    assert.deepEqual(await budgetRow(), { day: '2026-11-21', used: 1 });
    assert.equal((await w.state(token)).lastError, null);
    await w.runUntil(t('16:20'));
    assert.equal(w.traffic.asks, 2);
    assert.equal((await w.state(token)).lastError?.code, 'budget_exhausted');
  });

  it('is shared by every worker on the database, and by the first evaluation of a sync', async () => {
    const { w } = await fiveTrips({ budget: { dailyEvaluations: 3 } });
    const other = w.secondMonitor();
    w.clock = t('05:01');
    const reports = await Promise.all([w.monitor.tick(), other.tick()]);
    assert.equal(reports[0].evaluated + reports[1].evaluated, 3);
    assert.equal(w.traffic.asks, 3);
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 3 });
  });

  it('of zero asks nobody at all', async () => {
    const w = world(t('05:00'), { budget: { dailyEvaluations: 0 } });
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(w.traffic.asks, 0);
    assert.equal(synced.trips[0].phase, 'planning');
    assert.equal(synced.trips[0].lastError?.code, 'budget_exhausted');
    await w.runUntil(t('08:00'));
    assert.equal(w.traffic.asks, 0);
    assert.deepEqual(w.push.attempts, []);
    assert.equal((await w.row()).status, 'ended');
  });

  it('counts the second question of a late check without refusing it', async () => {
    const w = world(t('05:00'), { budget: { dailyEvaluations: 9 } });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // The sync, 5:30, 5:45 ... 7:15 make nine. Then the server sleeps past
    // 7:30.
    await w.runUntil(t('07:15'));
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 9 });
    await w.tickAt(t('07:37'));
    // Out of budget: nothing is asked, and the stored plan sends the alert.
    // Seven minutes after its departure, it does not promise its arrival.
    assert.equal(w.traffic.asks, 9);
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal(
      w.push.sent[1].body,
      'You planned to leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be re-checked since 7:15 AM.',
    );

    await resetDatabase(db);
    const roomy = world(t('05:00'), { budget: { dailyEvaluations: 10 } });
    const second = await roomy.device();
    await roomy.sync(second, [tripInput()]);
    await roomy.runUntil(t('07:15'));
    await roomy.tickAt(t('07:37'));
    // One left: the lattice instant uses it, and the catch-up question is
    // asked and counted all the same.
    assert.equal(roomy.traffic.asks, 11);
    assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 11 });
    assert.equal(
      roomy.push.sent[1].body,
      'Leave at 7:37 AM to arrive around 7:57 AM. Your target is 8:00 AM.',
    );
  });
});

describe('what clients are told about the monitor', () => {
  it('is that nothing has ticked yet, on a new server', async () => {
    const w = world(t('05:00'));
    assert.deepEqual(await w.monitor.status(), {
      enabled: true,
      dependable: false,
      lastTickAt: null,
    });
    const token = await w.device();
    assert.deepEqual((await w.list(token)).monitor, {
      enabled: true,
      dependable: false,
      lastTickAt: null,
    });
  });

  it('is not dependable on the in-process ticker alone, which stops when the server sleeps', async () => {
    const w = world(t('05:00'));
    await w.tickAt(t('05:01'));
    assert.deepEqual(await w.monitor.status(), {
      enabled: true,
      dependable: false,
      lastTickAt: t('05:01'),
    });
  });

  it('is dependable for three minutes after a tick started from outside', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    assert.ok(w.externalTick);
    w.clock = t('05:01');
    await w.externalTick();
    assert.deepEqual(await w.monitor.status(), {
      enabled: true,
      dependable: true,
      lastTickAt: t('05:01'),
    });
    assert.deepEqual((await w.list(token)).monitor, {
      enabled: true,
      dependable: true,
      lastTickAt: iso('05:01'),
    });

    // In-process ticks do not extend it.
    await w.tickAt(t('05:04'));
    assert.equal((await w.monitor.status()).dependable, true);
    w.clock = new Date(t('05:04').getTime() + 1000);
    assert.deepEqual(await w.monitor.status(), {
      enabled: true,
      dependable: false,
      lastTickAt: t('05:04'),
    });
    // The next outside tick makes it dependable again.
    w.clock = t('05:10');
    await w.externalTick();
    assert.equal((await w.monitor.status()).dependable, true);
  });

  it('is dependable without outside ticks on a server declared always on', async () => {
    const w = world(t('05:00'), { alwaysOn: true });
    assert.deepEqual(await w.monitor.status(), {
      enabled: true,
      dependable: true,
      lastTickAt: null,
    });
  });

  it('is neither enabled nor dependable where the worker is off, whatever else is said', async () => {
    const w = world(t('05:00'), { enabled: false, alwaysOn: true });
    // No tick route can start a tick here.
    assert.equal(w.externalTick, undefined);
    const token = await w.device();
    // Another deployment on the same database ticked a moment ago.
    await world(t('05:00')).monitor.tick({ external: true });
    assert.deepEqual((await w.list(token)).monitor, {
      enabled: false,
      dependable: false,
      lastTickAt: iso('05:00'),
    });
  });

  it('plans nothing and queues nothing for a trip where the worker is off, and says so', async () => {
    const w = world(t('05:00'), { enabled: false });
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    // Stored, and no more: a plan nobody refreshes would look monitored.
    assert.equal(synced.applied, true);
    assert.equal(synced.monitor.enabled, false);
    assert.equal(synced.trips[0].phase, 'planning');
    assert.equal(synced.trips[0].recommendation, null);
    assert.equal(synced.trips[0].lastError, null);
    assert.equal(synced.trips[0].monitoring.lastAlert, null);
    assert.equal(w.traffic.asks, 0);
    assert.deepEqual(await budgetRow(), { day: null, used: 0 });

    // A trip beyond the horizon waits there, as anywhere.
    const far = await w.sync(token, [
      tripInput(),
      tripInput({
        id: GYM,
        arriveBy: addMinutes(t('08:00'), 24 * 60).toISOString(),
      }),
    ]);
    assert.deepEqual(
      far.trips.map(trip => trip.phase),
      ['planning', 'scheduled'],
    );

    // Hours later nothing has happened to it here.
    w.clock = t('07:45');
    const listed = await w.list(token);
    assert.equal(listed.trips[0].phase, 'planning');
    assert.equal(listed.trips[0].recommendation, null);
    assert.equal(w.traffic.asks, 0);
    assert.deepEqual(await w.outbox(), []);
    assert.deepEqual(w.push.attempts, []);
  });

  it('gives a sync its first plan where the worker is on', async () => {
    const w = world(t('05:00'), { enabled: true });
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.monitor.enabled, true);
    assert.equal(synced.trips[0].phase, 'planned');
    assert.equal(synced.trips[0].recommendation?.departAt, iso('07:30'));
    assert.equal(w.traffic.asks, 1);
  });

  it('still says whether it runs the worker when the heartbeat cannot be read', async () => {
    class ConnectionLost extends Error {}
    for (const enabled of [true, false]) {
      const w = world(t('05:00'), { enabled });
      const broken = {
        ...db,
        query: async () => {
          throw new ConnectionLost('db.example.com went away');
        },
      };
      const logs: string[] = [];
      const monitor = new TripMonitor({
        db: broken,
        providers: w.traffic.providers(),
        push: w.push,
        now: () => w.clock,
        enabled,
        log: line => logs.push(line),
      });
      // Not "off" because of a hiccup: a sync on this server would then
      // plan nothing, and the app would say nobody is watching.
      assert.deepEqual(await monitor.status(), {
        enabled,
        dependable: false,
        lastTickAt: null,
      });
      assert.deepEqual(logs, [
        'Monitor heartbeat could not be read: ConnectionLost',
      ]);
    }
  });

  it('survives a monitor_state table that lost its row', async () => {
    const w = world(t('05:00'));
    await db.exec('DELETE FROM monitor_state');
    try {
      assert.deepEqual(await w.monitor.status(), {
        enabled: true,
        dependable: false,
        lastTickAt: null,
      });
      const token = await w.device();
      await w.sync(token, [tripInput()]);
      assert.equal(w.traffic.asks, 1);
      await w.monitor.tick({ external: true });
      assert.equal((await w.monitor.status()).dependable, true);
      assert.deepEqual(await budgetRow(), { day: '2026-11-20', used: 1 });
    } finally {
      await db.exec(
        'INSERT INTO monitor_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING',
      );
    }
  });
});

describe('housekeeping', () => {
  const count = async () =>
    (await db.query('SELECT 1 AS one FROM trips')).rows.length;

  it('purges a trip a day after it is over, at the end of a tick', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // Cancelled after its heads-up went out, so the row is kept to remember
    // that by.
    await w.runUntil(t('06:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    await w.sync(token, []);
    await w.tickAt(addMinutes(t('06:00'), 24 * 60));
    assert.equal(await count(), 1);
    await w.tickAt(addMinutes(t('06:00'), 24 * 60 + 1));
    assert.equal(await count(), 0);
  });

  it('keeps nothing of a cancelled trip that no alert was ever queued for', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    assert.equal(await count(), 1);
    await w.sync(token, []);
    assert.equal(await count(), 0);
  });

  it('enforces retention on a server that runs no monitor and gets no more syncs', async () => {
    const w = world(t('05:00'), { enabled: false });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // Nothing ticks here, and the app never syncs again. On its own timer
    // the server still ends the trip at its arrival time...
    w.clock = t('08:00');
    await w.service.enforceRetention();
    assert.equal((await w.row()).status, 'ended');
    // ...deletes it a day after that...
    w.clock = addMinutes(t('08:00'), 24 * 60);
    await w.service.enforceRetention();
    assert.equal(await count(), 1);
    w.clock = addMinutes(t('08:00'), 24 * 60 + 1);
    await w.service.enforceRetention();
    assert.equal(await count(), 0);
    // ...and forgets the installation after 30 days unseen.
    const devices = async () =>
      (await db.query('SELECT 1 AS one FROM devices')).rows.length;
    w.clock = addMinutes(t('05:00'), 30 * 24 * 60);
    await w.service.enforceRetention();
    assert.equal(await devices(), 1);
    w.clock = addMinutes(t('05:00'), 30 * 24 * 60 + 2);
    await w.service.enforceRetention();
    assert.equal(await devices(), 0);
    assert.deepEqual(w.logs, []);
  });

  it('notes a retention run that fails by its kind, and carries on', async () => {
    const w = world(t('05:00'), { config: { retentionHours: Number.NaN } });
    await w.service.enforceRetention();
    assert.equal(w.logs.length, 1);
    assert.match(w.logs[0], /^Trip purge failed: \w+$/);
  });

  it('keeps ticking when the purge fails, logging only the kind of failure', async () => {
    const w = world(t('05:00'), { config: { retentionHours: Number.NaN } });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // The sync tried its own hourly purge, and logged that.
    w.logs.length = 0;
    const report = await w.tickAt(t('05:30'));
    assert.equal(report.evaluated, 1);
    assert.equal(w.logs.length, 1);
    assert.match(w.logs[0], /^Trip purge failed: \w+$/);
  });
});
