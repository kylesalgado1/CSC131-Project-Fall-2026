// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// PGlite, the in-memory Postgres these tests use, cannot load inside Jest.
//
// Every test drives the real monitor against a real schema, with a clock
// that only moves when the test says, traffic the test sets, and a push
// sender that records. "runUntil" ticks once a minute, as the server does.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Database } from '../../db/db';
import { NoBaselineCoverageError } from '../../prediction/providers/pems/provider';
import { RoutingError } from '../../prediction/providers/routing/types';
import { Route } from '../../prediction/types';
import { MAX_LEAD_MINUTES } from '../config';
import { applySnapshot } from '../store';
import {
  addMinutes,
  GYM,
  LAB,
  migratedDatabase,
  MINUTE,
  OTHER_TOKEN,
  resetDatabase,
  t,
  TOKEN,
  tripInput,
  World,
  WorldOptions,
} from './harness';

/** A time on Thursday 19 November 2026, the evening before. */
const eve = (clock: string): Date => new Date(`2026-11-19T${clock}:00-08:00`);
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

const HEADS_UP = {
  title: 'Heads up: Chem lab',
  body: "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
};
const LEAVE = {
  title: 'Time to leave for Chem lab',
  body: 'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
};

/** What was sent, when, and what it said. */
const sentBy = (w: World) =>
  w.push.sent.map(({ at, kind, title, body }) => ({
    at: at.toISOString(),
    kind,
    title,
    body,
  }));

const clocks = (dates: Date[]): string[] =>
  dates.map(date =>
    date.toLocaleTimeString('en-GB', {
      hour: '2-digit',
      minute: '2-digit',
      timeZone: 'America/Los_Angeles',
    }),
  );

describe('the example from the product brief', () => {
  it('monitors from 5:30, sends one heads-up at 6:00 and "time to leave" at 7:30, and ends at 8:00', async () => {
    const w = world(t('05:00'));
    const token = await w.device();

    // The app syncs a trip to arrive by 8:00; the drive takes 20 minutes.
    const synced = await w.sync(token, [tripInput()]);
    const [trip] = synced.trips;
    assert.equal(trip.phase, 'planned');
    assert.equal(trip.recommendation?.action, 'leave_later');
    assert.equal(trip.recommendation?.departAt, iso('07:30'));
    assert.equal(trip.recommendation?.arriveAt, iso('07:50'));
    assert.equal(trip.recommendation?.evaluatedAt, iso('05:00'));
    assert.deepEqual(trip.recommendation?.source, {
      baseline: 'fixture',
      fallback: false,
      live: false,
    });
    assert.deepEqual(trip.monitoring, {
      startsAt: iso('05:30'),
      startedAt: null,
      headsUpAt: iso('06:00'),
      headsUpSentAt: null,
      leaveAlertSentAt: null,
      endsAt: iso('08:00'),
      nextCheckAt: iso('05:30'),
      lastAlert: null,
    });

    // 5:29: not yet. 5:30: monitoring begins.
    await w.runUntil(t('05:29'));
    assert.equal((await w.state(token)).phase, 'planned');
    assert.equal(w.traffic.asks, 1);
    await w.runUntil(t('05:30'));
    let state = await w.state(token);
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.monitoring.startedAt, iso('05:30'));
    assert.equal(state.monitoring.nextCheckAt, iso('05:45'));

    // 5:59: no heads-up. 6:00: exactly one.
    await w.runUntil(t('05:59'));
    assert.deepEqual(sentBy(w), []);
    await w.runUntil(t('06:00'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
    ]);
    state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, iso('06:00'));
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'sent',
      at: iso('06:00'),
    });

    // Nothing more until 7:30, when it is time to leave.
    await w.runUntil(t('07:29'));
    assert.equal(w.push.sent.length, 1);
    await w.runUntil(t('07:30'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      { at: iso('07:30'), kind: 'leave_now', ...LEAVE },
    ]);
    state = await w.state(token);
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.monitoring.leaveAlertSentAt, iso('07:30'));
    assert.equal(state.monitoring.headsUpSentAt, iso('06:00'));
    assert.equal(state.monitoring.nextCheckAt, iso('08:00'));
    assert.equal(state.recommendation?.action, 'leave_now');

    // Monitoring ends at the arrival target, and not before.
    await w.runUntil(t('07:59'));
    assert.equal((await w.row()).status, 'active');
    await w.runUntil(t('08:00'));
    const row = await w.row();
    assert.equal(row.status, 'ended');
    assert.deepEqual(row.endedAt, t('08:00'));
    assert.equal(row.departAt, null);
    state = await w.state(token);
    assert.equal(state.phase, 'ended');
    assert.equal(state.recommendation, null);
    assert.deepEqual(await w.outbox(), []);

    // Nothing else, ever: no other alert, and no provider asked after 7:30.
    await w.runUntil(t('08:30'));
    assert.equal(w.push.sent.length, 2);
    assert.equal(w.push.attempts.length, 2);
    assert.deepEqual(clocks(w.traffic.askedAbout), [
      '05:00',
      '05:30',
      '05:45',
      '06:00',
      '06:15',
      '06:30',
      '06:45',
      '07:00',
      '07:15',
      '07:30',
    ]);
    assert.deepEqual(w.logs, []);
  });

  it('sends each alert as the wire contract describes it', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('07:30'));
    const row = await w.row();
    const [headsUp, leave] = w.push.sent.map(sent => sent.message);

    assert.match(
      headsUp.id,
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    assert.notEqual(headsUp.id, leave.id);
    assert.equal(headsUp.deviceToken, TOKEN);
    assert.equal(headsUp.environment, 'sandbox');
    // One alert per trip stays on the lock screen.
    assert.equal(headsUp.collapseId, row.id);
    assert.equal(leave.collapseId, row.id);
    // A heads-up is no use after the departure; "time to leave" a little longer.
    assert.deepEqual(headsUp.expiresAt, t('07:30'));
    assert.deepEqual(leave.expiresAt, t('08:00'));
    assert.equal(headsUp.atLeastOnce, false);
    assert.equal(leave.atLeastOnce, true);
    assert.deepEqual(headsUp.payload, {
      aps: {
        alert: HEADS_UP,
        sound: 'default',
        'thread-id': `trip-${LAB}`,
        category: 'WAIT_IT_OUT_TRIP',
      },
      tripId: LAB,
      kind: 'heads_up',
      departAt: iso('07:30'),
      arriveBy: iso('08:00'),
    });
    assert.deepEqual(leave.payload, {
      aps: {
        alert: LEAVE,
        sound: 'default',
        'thread-id': `trip-${LAB}`,
        category: 'WAIT_IT_OUT_TRIP',
      },
      tripId: LAB,
      kind: 'leave_now',
      departAt: iso('07:30'),
      arriveBy: iso('08:00'),
    });
  });
});

describe('a trip beyond the planning horizon', () => {
  it('waits, asking nobody, until it enters the horizon, then gets its plan', async () => {
    const w = world(eve('19:00'));
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].phase, 'scheduled');
    assert.equal(synced.trips[0].planAvailableAt, eve('20:30').toISOString());
    assert.equal(synced.trips[0].recommendation, null);
    assert.equal(w.traffic.asks, 0);

    await w.runUntil(eve('20:29'));
    assert.equal(w.traffic.asks, 0);
    assert.equal((await w.state(token)).phase, 'scheduled');

    // The first plan, and with it the time monitoring will start: neither
    // waits for the other.
    await w.runUntil(eve('20:30'));
    assert.deepEqual(w.traffic.askedAbout, [eve('20:30')]);
    const state = await w.state(token);
    assert.equal(state.phase, 'planned');
    assert.equal(state.planAvailableAt, null);
    assert.equal(state.recommendation?.departAt, iso('07:30'));
    assert.equal(state.monitoring.startsAt, iso('05:30'));
    assert.equal(state.monitoring.nextCheckAt, iso('05:30'));

    // Nothing is asked again until monitoring starts.
    await w.runUntil(t('05:29'));
    assert.equal(w.traffic.asks, 1);
    await w.runUntil(t('05:30'));
    assert.equal(w.traffic.asks, 2);
    assert.equal((await w.state(token)).phase, 'monitoring');
    assert.deepEqual(sentBy(w), []);
  });

  it('is put off again if it comes up early', async () => {
    const w = world(eve('19:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await db.query('UPDATE trips SET next_check_at = $1::timestamptz', [
      eve('19:00').toISOString(),
    ]);
    const report = await w.tickAt(eve('19:01'));
    assert.equal(report.evaluated, 0);
    assert.equal(w.traffic.asks, 0);
    const row = await w.row();
    assert.equal(row.phase, 'scheduled');
    assert.deepEqual(row.nextCheckAt, eve('20:30'));
    assert.equal(row.leaseToken, null);
  });

  it('gets a plan at its first evaluation even with a target off the half hour', async () => {
    // Arrive by 8:50 with an 18-minute drive. Asked 12 hours ahead, the
    // backend would say "no rush"; at the horizon it gives a departure.
    const w = world(eve('21:00'));
    w.traffic.driveMinutes = 18;
    const token = await w.device();
    const synced = await w.sync(token, [tripInput({ arriveBy: iso('08:50') })]);
    assert.equal(synced.trips[0].phase, 'scheduled');
    assert.equal(synced.trips[0].planAvailableAt, eve('21:20').toISOString());

    await w.runUntil(eve('21:20'));
    let state = await w.state(token);
    assert.equal(state.phase, 'planned');
    assert.equal(state.noPlanReason, null);
    assert.equal(state.recommendation?.action, 'leave_later');
    // On the half-hour slots a far-off plan is made of.
    assert.equal(state.recommendation?.departAt, iso('08:00'));
    assert.equal(state.monitoring.nextCheckAt, iso('06:00'));

    // Within three hours the slots are 15 minutes apart and a later one
    // fits; monitoring starts two hours before that.
    await w.runUntil(t('06:00'));
    state = await w.state(token);
    assert.equal(state.phase, 'planned');
    assert.equal(state.recommendation?.departAt, iso('08:15'));
    await w.runUntil(t('06:15'));
    assert.equal((await w.state(token)).phase, 'monitoring');

    await w.runUntil(t('08:50'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:45'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 8:15 AM to arrive by 8:50 AM. We'll keep checking traffic.",
      },
      {
        at: iso('08:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 8:15 AM to arrive around 8:33 AM. Your target is 8:50 AM.',
      },
    ]);
    assert.equal((await w.row()).status, 'ended');
  });
});

describe('the longest lead the settings allow', () => {
  it('names a departure in the heads-up that the next check does not move while traffic is steady', async () => {
    // Arrive by 8:50 with an 18-minute drive, and a heads-up as early as
    // the settings take: 2 hours 45 minutes before the departure. Planned
    // far ahead on the half-hour slots, the departure is 8:00; on the
    // 15-minute slots it is 8:15. One slot short of the slot horizon the
    // first monitored check already sees 8:15, so the heads-up names it.
    // At the whole horizon it would name 8:00 and then "update" to 8:15.
    assert.equal(MAX_LEAD_MINUTES, 165);
    const w = world(eve('21:00'), {
      config: {
        monitorLeadMinutes: MAX_LEAD_MINUTES,
        headsUpLeadMinutes: MAX_LEAD_MINUTES,
      },
    });
    w.traffic.driveMinutes = 18;
    const token = await w.device();
    await w.sync(token, [tripInput({ arriveBy: iso('08:50') })]);
    await w.runUntil(t('08:50'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('05:30'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 8:15 AM to arrive by 8:50 AM. We'll keep checking traffic.",
      },
      {
        at: iso('08:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 8:15 AM to arrive around 8:33 AM. Your target is 8:50 AM.',
      },
    ]);
    assert.equal((await w.row()).updateCount, 0);
  });
});

describe('a check that takes a while', () => {
  it('ends a trip whose arrival time passes while it is being checked, and queues nothing', async () => {
    // Synced ten minutes before the target, with nothing evaluated yet.
    const w = world(t('07:50'), { config: { inlineEvaluations: 0 } });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    assert.equal(w.traffic.asks, 0);
    // The prediction comes back after the arrival time. It would have said
    // "running late".
    w.traffic.onAsk = async () => {
      w.clock = t('08:00');
    };
    const report = await w.tickAt(t('07:51'));
    assert.deepEqual(report, {
      evaluated: 1,
      queued: 0,
      delivered: 0,
      failed: 0,
      dropped: 0,
    });
    const row = await w.row();
    assert.equal(row.status, 'ended');
    assert.deepEqual(row.endedAt, t('08:00'));
    assert.equal(row.lateSentAt, null);
    assert.deepEqual(await w.outbox(), []);
    assert.deepEqual(w.push.attempts, []);
  });

  it('discards the result of a worker whose claim ran out and was taken over meanwhile', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('05:59'));
    const other = w.secondMonitor();
    w.clock = t('06:00');
    w.traffic.onAsk = async () => {
      w.traffic.onAsk = undefined;
      // Past this line the first worker's own figures are in: a 20-minute
      // drive, for a departure at 7:30.
      await Promise.resolve();
      // Its prediction then takes three minutes, longer than its claim on
      // the trip holds. Traffic worsens, and a second worker checks the
      // trip: leave at 7:15.
      w.clock = t('06:03');
      w.traffic.driveMinutes = 35;
      const taken = await other.tick();
      assert.equal(taken.evaluated, 1);
      assert.equal(taken.queued, 1);
    };
    const report = await w.monitor.tick();
    // The first worker asked, and what it was told was thrown away.
    assert.equal(report.evaluated, 1);
    assert.equal(report.queued, 0);
    assert.equal(w.traffic.asks, 5);
    const row = await w.row();
    assert.deepEqual(row.departAt, t('07:15'));
    assert.deepEqual(row.notifiedDepartAt, t('07:15'));
    assert.equal(row.leaseToken, null);
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'sent',
        last_error: null,
        attempts: 0,
        content_version: 1,
      },
    ]);
    assert.deepEqual(
      sentBy(w).map(sent => sent.body),
      [
        "Plan to leave around 7:15 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      ],
    );
    assert.equal((await w.state(token)).recommendation?.departAt, iso('07:15'));
  });
});

describe('traffic that depends on when one leaves', () => {
  it('follows a rush hour: "wait" while leaving now would be late, then "time to leave" as it clears', async () => {
    const w = world(t('05:00'));
    // Leaving before 7:15 takes 70 minutes; from 7:15 on, 30.
    w.traffic.driveMinutesAt = departAt => (departAt < t('07:15') ? 70 : 30);
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].recommendation?.action, 'leave_later');
    assert.equal(synced.trips[0].recommendation?.departAt, iso('07:15'));
    assert.equal(synced.trips[0].recommendation?.arriveAt, iso('07:45'));

    // 6:45: leaving now would still just make it, so the plan is unchanged.
    await w.runUntil(t('06:59'));
    assert.equal((await w.state(token)).recommendation?.action, 'leave_later');

    // 7:00: leaving now arrives at 8:10. The backend says to wait.
    await w.runUntil(t('07:00'));
    const state = await w.state(token);
    assert.equal(state.recommendation?.action, 'wait');
    assert.equal(state.recommendation?.departAt, iso('07:15'));
    assert.equal(
      state.recommendation?.reason,
      'Leaving now would make you late. Waiting 15 minutes gets you there on time.',
    );
    assert.equal(state.recommendation?.evaluatedAt, iso('07:00'));
    assert.equal(state.recommendation?.marginMinutes, 15);
    assert.equal(state.monitoring.nextCheckAt, iso('07:15'));

    await w.runUntil(t('08:00'));
    // The departure never moved, so there was nothing to update.
    assert.deepEqual(sentBy(w), [
      {
        at: iso('05:45'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:15 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      },
      {
        at: iso('07:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:15 AM to arrive around 7:45 AM. Your target is 8:00 AM.',
      },
    ]);
    assert.equal((await w.row()).status, 'ended');
  });
});

describe('a trip created close to its departure', () => {
  it('is monitored at once, and gets its heads-up at its time', async () => {
    // Created at 5:40. The slots from then put the departure at 7:25.
    const w = world(t('05:40'));
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    const [trip] = synced.trips;
    assert.equal(trip.phase, 'monitoring');
    assert.equal(trip.recommendation?.departAt, iso('07:25'));
    assert.equal(trip.monitoring.startedAt, iso('05:40'));
    assert.equal(trip.monitoring.headsUpAt, iso('05:55'));
    assert.equal(trip.monitoring.lastAlert, null);

    await w.runUntil(t('05:54'));
    assert.deepEqual(sentBy(w), []);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('05:55'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:25 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      },
      {
        at: iso('07:25'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:25 AM to arrive around 7:45 AM. Your target is 8:00 AM.',
      },
    ]);
  });

  it('gets exactly one catch-up heads-up when created after its time', async () => {
    const w = world(t('06:40'));
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    const [trip] = synced.trips;
    assert.equal(trip.phase, 'monitoring');
    assert.equal(trip.recommendation?.departAt, iso('07:25'));
    // Queued by the sync itself; the next tick sends it.
    assert.deepEqual(trip.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:40'),
    });
    assert.equal(trip.monitoring.headsUpSentAt, null);

    await w.runUntil(t('07:24'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:41'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:25 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      },
    ]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
  });

  it('gets exactly one "time to leave", and no heads-up, when the departure is already due', async () => {
    const w = world(t('07:35'));
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].phase, 'monitoring');
    assert.equal(synced.trips[0].recommendation?.action, 'leave_now');
    assert.equal(synced.trips[0].monitoring.lastAlert?.kind, 'leave_now');

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('07:36'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:35 AM to arrive around 7:55 AM. Your target is 8:00 AM.',
      },
    ]);
    // Asked once, by the sync, and never again.
    assert.equal(w.traffic.asks, 1);
  });

  it('gets exactly one "running late" when the target is already out of reach', async () => {
    const w = world(t('07:50'));
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].recommendation?.lateByMinutes, 10);

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('07:51'),
        kind: 'late',
        title: 'Running late for Chem lab',
        body: 'Leaving at 7:50 AM, you may arrive about 10 minutes after 8:00 AM.',
      },
    ]);
    const row = await w.row();
    assert.equal(row.status, 'ended');
    assert.equal(row.headsUpState, 'skipped');
    assert.equal(row.leaveSentAt, null);
  });
});

describe('traffic that changes after the heads-up', () => {
  /** A monitored trip whose 6:00 heads-up for 7:30 has gone out. */
  const afterHeadsUp = async (options: Partial<WorldOptions> = {}) => {
    const w = world(t('05:00'), options);
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:15'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    return { w, token };
  };

  it('sends one update when the departure moves 15 minutes earlier', async () => {
    const { w, token } = await afterHeadsUp();
    w.traffic.driveMinutes = 35;
    await w.runUntil(t('06:29'));
    assert.equal(w.push.sent.length, 1);
    await w.runUntil(t('07:14'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('06:30'),
        kind: 'update',
        title: 'Leave earlier for Chem lab',
        body: 'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
      },
    ]);
    const state = await w.state(token);
    assert.equal(state.recommendation?.departAt, iso('07:15'));
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'update',
      status: 'sent',
      at: iso('06:30'),
    });

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w).slice(2), [
      {
        at: iso('07:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:15 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
      },
    ]);
  });

  it('sends one update when traffic eases, once two checks agree', async () => {
    const { w, token } = await afterHeadsUp();
    w.traffic.driveMinutes = 5;
    // 6:30 sees the later departure for the first time: stored, not said.
    await w.runUntil(t('06:44'));
    assert.equal(w.push.sent.length, 1);
    assert.equal((await w.state(token)).recommendation?.departAt, iso('07:45'));
    assert.deepEqual((await w.row()).candidateDepartAt, t('07:45'));

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('06:45'),
        kind: 'update',
        title: 'Updated plan for Chem lab',
        body: 'Leave at 7:45 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
      },
      {
        at: iso('07:45'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:45 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
      },
    ]);
  });

  it('sends nothing for a shift below the threshold', async () => {
    const { w, token } = await afterHeadsUp({
      config: { meaningfulShiftMinutes: 20 },
    });
    w.traffic.driveMinutes = 35;
    await w.runUntil(t('07:14'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    // The app still shows the new plan.
    assert.equal((await w.state(token)).recommendation?.departAt, iso('07:15'));
    await w.runUntil(t('08:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal(w.push.sent[1].at.toISOString(), iso('07:15'));
  });

  for (const [name, config] of [
    ['with the default limits', {}],
    [
      'with updates at least 40 minutes apart',
      { updateMinIntervalMinutes: 40 },
    ],
    ['with one update allowed', { maxUpdatesPerTrip: 1 }],
    ['with none allowed', { maxUpdatesPerTrip: 0 }],
  ] as const) {
    it(`never sends more updates than allowed, or two too close, ${name}`, async () => {
      // A three-hour heads-up, so there is time for traffic to go back and
      // forth: half an hour heavy, half an hour light, all morning.
      const w = world(t('04:00'), {
        config: {
          monitorLeadMinutes: 180,
          headsUpLeadMinutes: 180,
          ...config,
        },
      });
      const token = await w.device();
      await w.sync(token, [tripInput({ arriveBy: iso('09:00') })]);
      for (let at = t('04:01'); at <= t('09:00'); at = addMinutes(at, 1)) {
        const halfHours = Math.floor(
          (at.getTime() - t('04:00').getTime()) / (30 * MINUTE),
        );
        w.traffic.driveMinutes = halfHours % 2 === 0 ? 20 : 35;
        await w.tickAt(at);
      }
      const limits = { ...w.config };
      const count = (kind: string) =>
        w.push.kinds().filter(one => one === kind).length;
      // The heads-up and the updates are what the limits are about; "time
      // to leave" and "running late" are never held back.
      const said = w.push.sent.filter(
        sent => sent.kind === 'heads_up' || sent.kind === 'update',
      );
      assert.equal(count('heads_up'), 1);
      assert.ok(count('update') <= limits.maxUpdatesPerTrip);
      for (let i = 1; i < said.length; i++) {
        const gap = (said[i].at.getTime() - said[i - 1].at.getTime()) / MINUTE;
        assert.ok(gap >= limits.updateMinIntervalMinutes, `gap of ${gap}`);
      }
      assert.ok(count('leave_now') + count('late') === 1);
      assert.equal(w.push.sent.length, said.length + 1);
      if (limits.maxUpdatesPerTrip >= 3) {
        // Traffic did go back and forth, and the limit was reached.
        assert.equal(count('update'), 3);
      }
    });
  }

  it('says "time to leave" at once when traffic makes the departure due, a minute after an update', async () => {
    const { w } = await afterHeadsUp();
    // The server sleeps from 6:15 to 6:44 while traffic gets worse, and
    // wakes to say "leave earlier". A minute later it gets much worse.
    w.traffic.driveMinutes = 35;
    await w.tickAt(t('06:44'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('06:44'),
        kind: 'update',
        title: 'Leave earlier for Chem lab',
        body: 'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
      },
    ]);
    w.traffic.driveMinutes = 60;
    await w.tickAt(t('06:45'));
    assert.deepEqual(sentBy(w).slice(2), [
      {
        at: iso('06:45'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 6:45 AM to arrive around 7:45 AM. Your target is 8:00 AM.',
      },
    ]);
    await w.runUntil(t('08:00'));
    assert.equal(w.push.sent.length, 3);
  });

  it('says "running late" once when the target can no longer be met', async () => {
    const { w, token } = await afterHeadsUp();
    await w.runUntil(t('06:50'));
    w.traffic.driveMinutes = 100;
    await w.runUntil(t('07:59'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('07:00'),
        kind: 'late',
        title: 'Running late for Chem lab',
        body: 'Leaving at 7:00 AM, you may arrive about 40 minutes after 8:00 AM.',
      },
    ]);
    const state = await w.state(token);
    // Asked last at 7:45, when the 100-minute drive would end at 9:25.
    assert.equal(state.recommendation?.lateByMinutes, 85);
    assert.equal(state.monitoring.leaveAlertSentAt, null);
    assert.equal(state.monitoring.lastAlert?.kind, 'late');
    // It kept asking, in case traffic cleared, and said nothing more.
    assert.deepEqual(clocks(w.traffic.askedAbout).slice(-4), [
      '07:00',
      '07:15',
      '07:30',
      '07:45',
    ]);
    await w.runUntil(t('08:10'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'late']);
    assert.equal((await w.row()).status, 'ended');
  });

  it('follows "running late" with one update and "time to leave" when the plan recovers', async () => {
    const w = world(t('06:00'));
    const token = await w.device();
    // Arrive by 9:00, with a two-and-a-half-hour drive: late from the start.
    w.traffic.driveMinutes = 200;
    await w.sync(token, [tripInput({ arriveBy: iso('09:00') })]);
    await w.runUntil(t('06:10'));
    assert.deepEqual(w.push.kinds(), ['late']);
    // The road clears.
    w.traffic.driveMinutes = 20;
    await w.runUntil(t('09:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:01'),
        kind: 'late',
        title: 'Running late for Chem lab',
        body: 'Leaving at 6:00 AM, you may arrive about 20 minutes after 9:00 AM.',
      },
      {
        at: iso('06:30'),
        kind: 'update',
        title: 'Updated plan for Chem lab',
        body: 'Leave at 8:30 AM instead of 6:00 AM. Predicted arrival 8:50 AM; your target is 9:00 AM.',
      },
      {
        at: iso('08:30'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 8:30 AM to arrive around 8:50 AM. Your target is 9:00 AM.',
      },
    ]);
  });

  it('still says "time to leave" at the departure it announced when the live feed then drops out', async () => {
    // A 15-minute live delay. It fades out over an hour, so it only moves
    // the plan as the departure comes near: at 6:45, to 7:15.
    const w = world(t('05:00'));
    w.traffic.live = { available: true, extraMinutes: 15, incidents: [] };
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:59'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      {
        at: iso('06:45'),
        kind: 'update',
        title: 'Leave earlier for Chem lab',
        body: 'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:43 AM; your target is 8:00 AM.',
      },
    ]);

    // The live feed drops out. Without it the plan is 7:30 again: stored,
    // for the app to show with its source, and not announced.
    w.traffic.live = undefined;
    await w.runUntil(t('07:14'));
    let state = await w.state(token);
    assert.equal(state.recommendation?.departAt, iso('07:30'));
    assert.equal(state.recommendation?.source.live, false);
    assert.equal(state.monitoring.nextCheckAt, iso('07:15'));
    assert.equal(w.push.sent.length, 2);

    // 7:15 is still when the user was told to leave, and the delay that
    // moved it there may well still be on the road.
    await w.runUntil(t('07:15'));
    assert.deepEqual(sentBy(w).slice(2), [
      {
        at: iso('07:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:15 AM. Your target is 8:00 AM. Traffic could not be fully re-checked.',
      },
    ]);
    assert.deepEqual(
      (w.push.sent[2].message.payload as { departAt: string }).departAt,
      iso('07:15'),
    );
    state = await w.state(token);
    assert.equal(state.monitoring.leaveAlertSentAt, iso('07:15'));
    assert.equal(state.monitoring.nextCheckAt, iso('08:00'));

    // And that is the last of it.
    const asked = w.traffic.asks;
    await w.runUntil(t('08:00'));
    assert.equal(w.push.sent.length, 3);
    assert.equal(w.traffic.asks, asked);
  });

  it('sends at most one update for a drive time that sits on a slot boundary', async () => {
    // Arrive by 8:00. A 50-minute drive fits the 7:00 departure exactly; a
    // 51-minute one needs 6:45. The drive alternates at every check.
    const w = world(t('04:00'));
    w.traffic.driveMinutes = 50;
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    let checks = 0;
    w.traffic.onAsk = async () => {
      checks += 1;
    };
    for (let at = t('04:01'); at <= t('08:00'); at = addMinutes(at, 1)) {
      // After the heads-up at 5:30: 50 at 5:45, 51 at 6:00, 50 at 6:15, ...
      if (at > t('05:30')) {
        w.traffic.driveMinutes = checks % 2 === 0 ? 51 : 50;
      }
      await w.tickAt(at);
    }
    const kinds = w.push.kinds();
    assert.equal(kinds.filter(kind => kind === 'update').length, 1);
    assert.deepEqual(kinds, ['heads_up', 'update', 'leave_now']);
    assert.deepEqual(
      sentBy(w).map(sent => sent.body),
      [
        "Plan to leave around 7:00 AM to arrive by 8:00 AM. We'll keep checking traffic.",
        'Leave at 6:45 AM instead of 7:00 AM. Predicted arrival 7:36 AM; your target is 8:00 AM.',
        'Leave at 7:00 AM to arrive around 7:51 AM. Your target is 8:00 AM.',
      ],
    );
  });

  it('stays in active monitoring when the departure moves beyond the two-hour lead', async () => {
    // Arrive by 9:00 with a 50-minute drive: leave at 8:00, monitored from 6:00.
    const w = world(t('05:00'));
    w.traffic.driveMinutes = 50;
    const token = await w.device();
    await w.sync(token, [tripInput({ arriveBy: iso('09:00') })]);
    await w.runUntil(t('06:00'));
    assert.equal((await w.state(token)).phase, 'monitoring');

    // Traffic eases: leave at 8:45, which is more than two hours off.
    w.traffic.driveMinutes = 5;
    await w.runUntil(t('06:15'));
    const state = await w.state(token);
    assert.equal(state.recommendation?.departAt, iso('08:45'));
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.monitoring.startedAt, iso('06:00'));
    // Still checked every slot, not put off until 6:45.
    assert.equal(state.monitoring.nextCheckAt, iso('06:30'));

    await w.runUntil(t('09:00'));
    assert.deepEqual(
      sentBy(w).map(({ at, kind }) => ({ at, kind })),
      [
        { at: iso('07:15'), kind: 'heads_up' },
        { at: iso('08:45'), kind: 'leave_now' },
      ],
    );
  });
});

describe('duplicate suppression', () => {
  const beforeHeadsUp = async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('05:59'));
    return { w, token };
  };

  it('sends an alert once when the same tick runs twice', async () => {
    const { w } = await beforeHeadsUp();
    const first = await w.tickAt(t('06:00'));
    const second = await w.tickAt(t('06:00'));
    assert.deepEqual(first, {
      evaluated: 1,
      queued: 1,
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(second, {
      evaluated: 0,
      queued: 0,
      delivered: 0,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    assert.equal(w.push.attempts.length, 1);
  });

  it('sends an alert once when two ticks run at the same time', async () => {
    const { w } = await beforeHeadsUp();
    w.clock = t('06:00');
    const reports = await Promise.all([w.monitor.tick(), w.monitor.tick()]);
    assert.equal(reports[0].queued + reports[1].queued, 1);
    assert.equal(reports[0].delivered + reports[1].delivered, 1);
    assert.equal(w.push.attempts.length, 1);
    assert.equal((await w.outbox()).length, 1);
  });

  it('sends an alert once when two workers tick at the same time', async () => {
    const { w } = await beforeHeadsUp();
    const other = w.secondMonitor();
    w.clock = t('06:00');
    const reports = await Promise.all([
      w.monitor.tick(),
      other.tick(),
      w.monitor.tick(),
      other.tick(),
    ]);
    const total = (key: 'evaluated' | 'queued' | 'delivered') =>
      reports.reduce((sum, report) => sum + report[key], 0);
    assert.equal(total('evaluated'), 1);
    assert.equal(total('queued'), 1);
    assert.equal(total('delivered'), 1);
    assert.equal(w.push.attempts.length, 1);
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'sent',
        last_error: null,
        attempts: 0,
        content_version: 1,
      },
    ]);

    // And the same at the leave alert.
    await w.runUntil(t('07:29'));
    w.clock = t('07:30');
    await Promise.all([other.tick(), w.monitor.tick()]);
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal(w.push.attempts.length, 2);
  });

  it('does not let a second worker take a trip that is being checked', async () => {
    const { w } = await beforeHeadsUp();
    const other = w.secondMonitor();
    w.clock = t('06:00');
    let inside: Promise<unknown> | undefined;
    w.traffic.onAsk = async () => {
      // While the first worker waits for its prediction, a second ticks.
      w.traffic.onAsk = undefined;
      inside = other.tick();
      await inside;
    };
    const report = await w.monitor.tick();
    assert.ok(inside);
    assert.deepEqual(await inside, {
      evaluated: 0,
      queued: 0,
      delivered: 0,
      failed: 0,
      dropped: 0,
    });
    assert.equal(report.queued, 1);
    // The sync and the checks at 5:30, 5:45 and 6:00: the second worker
    // asked nothing.
    assert.equal(w.traffic.asks, 4);
    assert.deepEqual(w.push.kinds(), ['heads_up']);
  });

  it('never sends an update while traffic is constant, ticking every minute', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    for (let at = t('05:01'); at < t('08:00'); at = addMinutes(at, 1)) {
      await w.tickAt(at);
      // The recommended departure never moves.
      assert.deepEqual((await w.row()).departAt, t('07:30'));
    }
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal(w.push.kinds().includes('update'), false);
  });

  it('asks only about instants on the trip’s lattice, however unevenly it ticks', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    // Ticks 37 seconds past the minute, with every seventh one skipped.
    for (let minute = 1; minute < 180; minute++) {
      if (minute % 7 !== 0) {
        await w.tickAt(
          new Date(t('05:00').getTime() + minute * MINUTE + 37_000),
        );
      }
    }
    for (const at of w.traffic.askedAbout) {
      assert.equal((t('07:30').getTime() - at.getTime()) % (15 * MINUTE), 0);
    }
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal((await w.row()).updateCount, 0);
  });

  it('may move the plan earlier as the departure nears when a live delay holds', async () => {
    // A constant 12-minute live delay. The backend fades live conditions out
    // over the next hour, so a departure two hours off is planned without
    // it, and the delay only shows as the departure comes within the hour.
    // The update is the prediction changing, not the lattice jittering.
    const w = world(t('05:00'));
    w.traffic.live = { available: true, extraMinutes: 12, incidents: [] };
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      {
        at: iso('06:45'),
        kind: 'update',
        title: 'Leave earlier for Chem lab',
        body: 'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:41 AM; your target is 8:00 AM.',
      },
      {
        at: iso('07:15'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:15 AM to arrive around 7:47 AM. Your target is 8:00 AM.',
      },
    ]);
  });
});

describe('a tick that comes late', () => {
  const upTo = async (clock: string) => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t(clock));
    return { w, token };
  };

  it('keeps to the lattice and sends one catch-up message after 40 minutes asleep', async () => {
    const { w } = await upTo('06:00');
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    // Asleep from 6:00 to 6:40, while traffic got worse.
    w.traffic.driveMinutes = 35;
    const report = await w.tickAt(t('06:40'));
    assert.deepEqual(report, {
      evaluated: 1,
      queued: 1,
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    // Asked about 6:30, the lattice instant, not about 6:40.
    assert.deepEqual(clocks(w.traffic.askedAbout).slice(-1), ['06:30']);
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('06:40'),
        kind: 'update',
        title: 'Leave earlier for Chem lab',
        body: 'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
      },
    ]);
    const row = await w.row();
    assert.deepEqual(row.anchorAt, t('07:15'));
    assert.deepEqual(row.nextCheckAt, t('06:45'));
    // As of the instant it was asked about: its sentences count from 6:30.
    assert.deepEqual(row.evaluatedAt, t('06:30'));

    await w.runUntil(t('08:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'update', 'leave_now']);
    assert.deepEqual(clocks(w.traffic.askedAbout).slice(-3), [
      '06:45',
      '07:00',
      '07:15',
    ]);
  });

  it('sends the one heads-up when it slept through its time', async () => {
    const { w } = await upTo('05:45');
    await w.tickAt(t('06:25'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:25'), kind: 'heads_up', ...HEADS_UP },
    ]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
  });

  it('says "time to leave" with times that are still true when it slept through the departure', async () => {
    const { w, token } = await upTo('07:15');
    const report = await w.tickAt(t('07:37'));
    assert.equal(report.evaluated, 1);
    // Asked about the lattice instant, told "leave now", and so asked again
    // about this minute.
    assert.deepEqual(clocks(w.traffic.askedAbout).slice(-2), [
      '07:30',
      '07:37',
    ]);
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('07:37'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:37 AM to arrive around 7:57 AM. Your target is 8:00 AM.',
      },
    ]);
    const state = await w.state(token);
    assert.equal(state.recommendation?.departAt, iso('07:37'));
    assert.equal(state.recommendation?.arriveAt, iso('07:57'));
    assert.deepEqual((await w.row()).anchorAt, t('07:37'));
    await w.runUntil(t('08:00'));
    assert.equal(w.push.sent.length, 2);
  });

  it('says only "running late" when it slept until the target was out of reach', async () => {
    const { w } = await upTo('07:15');
    await w.tickAt(t('07:50'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('07:50'),
        kind: 'late',
        title: 'Running late for Chem lab',
        body: 'Leaving at 7:50 AM, you may arrive about 10 minutes after 8:00 AM.',
      },
    ]);
    await w.runUntil(t('08:10'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'late']);
  });

  it('sends nothing at all when it slept through the whole trip', async () => {
    const { w, token } = await upTo('05:00');
    const report = await w.tickAt(t('08:10'));
    assert.deepEqual(report, {
      evaluated: 0,
      queued: 0,
      delivered: 0,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(w.push.attempts, []);
    assert.equal(w.traffic.asks, 1);
    const row = await w.row();
    assert.equal(row.status, 'ended');
    // Ended when it was due to end, not when somebody noticed.
    assert.deepEqual(row.endedAt, t('08:00'));
    assert.equal((await w.state(token)).phase, 'ended');
  });

  it('never sends a burst after a long sleep: one message per trip at most', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [
      tripInput(),
      tripInput({ id: GYM, title: 'Gym', arriveBy: iso('08:15') }),
    ]);
    // Asleep from 5:00 until 7:20: past both monitoring starts and both
    // heads-ups.
    const report = await w.tickAt(t('07:20'));
    assert.equal(report.delivered, 2);
    assert.deepEqual(w.push.kinds(), ['heads_up', 'heads_up']);
    assert.deepEqual(w.push.sent.map(sent => sent.title).sort(), [
      'Heads up: Chem lab',
      'Heads up: Gym',
    ]);
  });
});

describe('a provider that fails', () => {
  const monitored = async (
    clock: string,
    options: Partial<WorldOptions> = {},
  ) => {
    const w = world(t('05:00'), options);
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t(clock));
    return { w, token };
  };

  it('sends no update or heads-up from stale data, but still says "time to leave", saying how old the plan is', async () => {
    const { w, token } = await monitored('06:10');
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    w.traffic.failure = new RoutingError('The routing service is down');
    // Even though the drive would now call for leaving earlier.
    w.traffic.driveMinutes = 35;

    await w.runUntil(t('06:30'));
    let state = await w.state(token);
    assert.deepEqual(state.lastError, {
      code: 'routing_unavailable',
      at: iso('06:23'),
    });
    assert.equal(state.recommendation?.departAt, iso('07:30'));
    assert.equal(state.recommendation?.evaluatedAt, iso('06:00'));
    assert.equal(state.recommendation?.stale, false);
    // Retried after 1, 2 and 5 minutes, about the same instant, and from
    // then on no more often than a monitored trip is checked anyway.
    assert.deepEqual(clocks(w.traffic.askedAbout.slice(-5)), [
      '06:00',
      '06:15',
      '06:15',
      '06:15',
      '06:15',
    ]);
    assert.deepEqual((await w.row()).nextCheckAt, t('06:38'));

    // A plan that could not be refreshed for over half an hour is stale.
    await w.runUntil(t('06:31'));
    state = await w.state(token);
    assert.equal(state.recommendation?.stale, true);

    await w.runUntil(t('07:29'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    // 6:38, 6:53, 7:08 and 7:23: a slot apart, each about its lattice instant.
    assert.deepEqual(clocks(w.traffic.askedAbout.slice(-4)), [
      '06:30',
      '06:45',
      '07:00',
      '07:15',
    ]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w).slice(1), [
      {
        at: iso('07:30'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM. Traffic could not be re-checked since 6:00 AM.',
      },
    ]);
    // Only what failed is logged, and nothing about the trip.
    assert.deepEqual(w.logs, []);
  });

  it('asks less and less often about a route that never answers, so other trips keep their plans and alerts', async () => {
    // The evening before, with a small budget for the day. One device's
    // trip is to a place no route can be planned to; another's is an
    // ordinary trip an hour later.
    const w = world(eve('20:00'), { budget: { dailyEvaluations: 60 } });
    const nowhere = { lat: 39.5, lng: -121 };
    const unroutable = (route: Route): boolean =>
      route.destination.lat === nowhere.lat;
    w.traffic.failureFor = route =>
      unroutable(route)
        ? new RoutingError('No route between these places')
        : undefined;
    const stuck = await w.device();
    const fine = await w.device({ apnsToken: OTHER_TOKEN, authorized: true });
    await w.sync(stuck, [tripInput({ destination: nowhere })]);
    await w.sync(fine, [
      tripInput({ id: GYM, title: 'Gym', arriveBy: iso('09:00') }),
    ]);

    await w.runUntil(t('09:00'));

    // From 8:30 PM, when it could first be planned, to 8:00 AM: after 1, 2,
    // 5 and 15 minutes, and then every half hour.
    const asks = w.traffic.askedRoutes.filter(unroutable).length;
    assert.equal(asks, 27);
    assert.ok(asks <= 30);
    assert.deepEqual(
      clocks(
        w.traffic.askedAbout.filter((_, i) =>
          unroutable(w.traffic.askedRoutes[i]),
        ),
      ).slice(0, 7),
      ['20:30', '20:31', '20:33', '20:38', '20:53', '21:23', '21:53'],
    );
    const { rows } = await db.query<{ used: number }>(
      'SELECT budget_used AS used FROM monitor_state',
    );
    // The other trip's ten checks, and nothing refused.
    assert.equal(rows[0].used, asks + 10);
    assert.equal((await w.row()).status, 'ended');
    assert.equal((await w.row()).departAt, null);

    // The other trip was planned and alerted as if it were alone: its
    // heads-up on time, and a leave alert from a plan checked that minute.
    assert.deepEqual(sentBy(w), [
      {
        at: iso('07:00'),
        kind: 'heads_up',
        title: 'Heads up: Gym',
        body: "Plan to leave around 8:30 AM to arrive by 9:00 AM. We'll keep checking traffic.",
      },
      {
        at: iso('08:30'),
        kind: 'leave_now',
        title: 'Time to leave for Gym',
        body: 'Leave at 8:30 AM to arrive around 8:50 AM. Your target is 9:00 AM.',
      },
    ]);
    assert.deepEqual(w.logs, []);
  });

  it('forgets the failure at the next success, which leaves the plan alone and queues nothing', async () => {
    const { w, token } = await monitored('06:10');
    w.traffic.failure = new RoutingError('The routing service is down');
    await w.runUntil(t('06:20'));
    assert.equal((await w.state(token)).lastError?.code, 'routing_unavailable');
    assert.equal((await w.row()).evalFailures, 3);

    w.traffic.failure = undefined;
    await w.runUntil(t('06:23'));
    const state = await w.state(token);
    assert.equal(state.lastError, null);
    assert.equal(state.recommendation?.departAt, iso('07:30'));
    // Asked at 6:23 about 6:15, which is what its sentences count from.
    assert.equal(state.recommendation?.evaluatedAt, iso('06:15'));
    assert.equal(state.recommendation?.stale, false);
    assert.equal(state.monitoring.nextCheckAt, iso('06:30'));
    const row = await w.row();
    assert.equal(row.evalFailures, 0);
    assert.deepEqual(row.notifiedDepartAt, t('07:30'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    assert.equal((await w.outbox()).length, 1);

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w).slice(1), [
      { at: iso('07:30'), kind: 'leave_now', ...LEAVE },
    ]);
  });

  it('still sends the heads-up during a short outage, from the stored plan', async () => {
    const { w, token } = await monitored('05:50');
    w.traffic.failure = new RoutingError('The routing service is down');
    await w.runUntil(t('06:05'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
    ]);
    assert.equal((await w.state(token)).lastError?.code, 'routing_unavailable');
  });

  it('starts monitoring on time but sends no heads-up from a plan gone stale', async () => {
    const { w, token } = await monitored('05:10');
    w.traffic.failure = new RoutingError('The routing service is down');
    await w.runUntil(t('05:30'));
    const state = await w.state(token);
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.monitoring.startedAt, iso('05:30'));

    await w.runUntil(t('07:29'));
    assert.deepEqual(w.push.attempts, []);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('07:30'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM. Traffic could not be re-checked since 5:00 AM.',
      },
    ]);
  });

  it('reports a route with no traffic data, and asks again in half an hour', async () => {
    const w = world(t('05:00'));
    w.traffic.failure = new NoBaselineCoverageError();
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].phase, 'planning');
    assert.equal(synced.trips[0].recommendation, null);
    assert.deepEqual(synced.trips[0].lastError, {
      code: 'no_coverage',
      at: iso('05:00'),
    });
    assert.equal(synced.trips[0].monitoring.nextCheckAt, iso('05:30'));
    await w.runUntil(t('05:29'));
    assert.equal(w.traffic.asks, 1);
    await w.runUntil(t('05:30'));
    assert.equal(w.traffic.asks, 2);
  });

  it('reports an unexpected failure as internal, logging only its kind', async () => {
    const w = world(t('05:00'));
    w.traffic.failure = new TypeError('secret detail at 38.2383,-122.0402');
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].lastError?.code, 'internal');
    assert.deepEqual(w.logs, ['Trip evaluation failed: TypeError']);
    assert.equal(synced.trips[0].monitoring.nextCheckAt, iso('05:01'));
  });

  it('counts a prediction that takes too long as a routing failure', async () => {
    const w = world(t('05:00'), { evaluationTimeoutMs: 5 });
    w.traffic.hangs = true;
    const token = await w.device();
    const synced = await w.sync(token, [tripInput()]);
    assert.deepEqual(synced.trips[0].lastError, {
      code: 'routing_unavailable',
      at: iso('05:00'),
    });
    assert.equal(synced.trips[0].phase, 'planning');
    // The trip is free again for the next check.
    assert.equal((await w.row()).leaseToken, null);
  });

  it('marks a recommendation stale when its check is overdue', async () => {
    const { w, token } = await monitored('06:00');
    // Nothing ticks after 6:00; the next check was due at 6:15.
    w.clock = t('06:20');
    assert.equal((await w.state(token)).recommendation?.stale, false);
    w.clock = t('06:21');
    assert.equal((await w.state(token)).recommendation?.stale, true);
  });
});

describe('a trip that changes while it is monitored', () => {
  it('discards a check whose trip was edited while it was being made', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    const device = await w.authenticate(token);
    await w.runUntil(t('05:29'));

    // While the 5:30 check waits for its prediction, the user moves the
    // trip to 9:00.
    w.traffic.onAsk = async () => {
      w.traffic.onAsk = undefined;
      await applySnapshot(
        db,
        device.id,
        99,
        [
          {
            id: LAB,
            title: 'Chem lab',
            origin: { lat: 38.2383, lng: -122.0402 },
            destination: { lat: 38.5593, lng: -121.4237 },
            destinationName: 'Sac State',
            arriveBy: t('09:00'),
            startsAt: null,
            timeZone: 'America/Los_Angeles',
          },
        ],
        w.clock,
      );
    };
    const report = await w.tickAt(t('05:30'));
    // The check for 8:00 would have started monitoring; it was thrown away,
    // and the trip as it now is was checked instead.
    assert.equal(report.evaluated, 2);
    const row = await w.row();
    assert.equal(row.contentVersion, 2);
    assert.deepEqual(row.arriveBy, t('09:00'));
    assert.deepEqual(row.departAt, t('08:30'));
    assert.equal(row.phase, 'planned');
    assert.equal(row.monitoringStartedAt, null);
    assert.deepEqual(row.nextCheckAt, t('06:30'));
    assert.deepEqual(await w.outbox(), []);
  });

  it('discards a check whose trip was cancelled or left while it was being made', async () => {
    for (const how of ['cancel', 'leave'] as const) {
      await resetDatabase(db);
      const w = world(t('05:00'));
      const token = await w.device();
      await w.sync(token, [tripInput()]);
      const device = await w.authenticate(token);
      await w.runUntil(t('05:59'));
      w.traffic.onAsk = async () => {
        w.traffic.onAsk = undefined;
        if (how === 'cancel') {
          await applySnapshot(db, device.id, 99, [], w.clock);
        } else {
          await w.service.departed(device, LAB, iso('08:00'));
        }
      };
      // The 6:00 check would have queued the heads-up.
      const report = await w.tickAt(t('06:00'));
      assert.equal(report.queued, 0);
      assert.deepEqual(await w.outbox(), []);
      assert.deepEqual(w.push.attempts, []);
      if (how === 'cancel') {
        // Nothing had been sent for it, so nothing of it is kept.
        const { rows } = await db.query('SELECT id FROM trips');
        assert.deepEqual(rows, []);
      } else {
        const row = await w.row();
        assert.equal(row.status, 'departed');
        assert.equal(row.headsUpState, 'pending');
      }
      await w.runUntil(t('08:00'));
      assert.deepEqual(w.push.attempts, []);
    }
  });

  it('sends nothing more after "I’ve left"', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:30'));
    const asked = w.traffic.asks;
    const { trip } = await w.service.departed(
      await w.authenticate(token),
      LAB,
      iso('08:00'),
    );
    assert.equal(trip.phase, 'departed');
    await w.runUntil(t('08:30'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    assert.equal(w.traffic.asks, asked);
  });

  it('drops the alerts queued for a trip that is cancelled or left', async () => {
    for (const how of ['cancel', 'leave'] as const) {
      await resetDatabase(db);
      const w = world(t('05:00'));
      // No token yet, so the heads-up waits in the outbox.
      const token = await w.device(null);
      await w.sync(token, [tripInput()]);
      await w.runUntil(t('06:05'));
      assert.deepEqual(
        (await w.outbox()).map(({ kind, status }) => ({ kind, status })),
        [{ kind: 'heads_up', status: 'pending' }],
      );
      if (how === 'cancel') {
        await w.sync(token, []);
      } else {
        await w.service.departed(
          await w.authenticate(token),
          LAB,
          iso('08:00'),
        );
      }
      assert.deepEqual(await w.outbox(), []);
      // The token arrives too late to matter.
      await w.setPush(token, TOKEN);
      await w.runUntil(t('08:00'));
      assert.deepEqual(w.push.attempts, []);
    }
  });

  it('drops a queued alert whose trip stopped being active under it', async () => {
    const w = world(t('05:00'));
    const token = await w.device(null);
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:05'));
    // As if the trip were cancelled between the alert being claimed and sent.
    await db.query(
      "UPDATE trips SET status = 'cancelled', next_check_at = NULL",
    );
    await w.setPush(token, TOKEN);
    const report = await w.tickAt(t('06:06'));
    assert.equal(report.dropped, 1);
    assert.deepEqual(w.push.attempts, []);
    assert.deepEqual(
      (await w.outbox()).map(({ status, last_error }) => ({
        status,
        last_error,
      })),
      [{ status: 'dropped', last_error: 'trip_inactive' }],
    );
  });

  it('sends a fresh heads-up for the new plan only, after a material reschedule', async () => {
    const w = world(t('05:00'));
    const token = await w.device(null);
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:05'));
    assert.equal((await w.state(token)).monitoring.lastAlert?.status, 'queued');

    // Moved to 8:30: a new version of the trip, planned from scratch.
    const synced = await w.sync(token, [tripInput({ arriveBy: iso('08:30') })]);
    // Planned from the minute of the change, 6:05, so on slots at :05, :20,
    // :35 and :50.
    assert.equal(synced.trips[0].recommendation?.departAt, iso('07:50'));
    assert.equal(synced.trips[0].monitoring.lastAlert, null);
    assert.equal(synced.trips[0].monitoring.headsUpAt, iso('06:20'));

    // The token arrives. The heads-up for the old time is not sent.
    await w.setPush(token, TOKEN);
    await w.runUntil(t('06:19'));
    assert.deepEqual(w.push.attempts, []);
    assert.deepEqual(
      (await w.outbox()).map(({ status, last_error, content_version }) => ({
        status,
        last_error,
        content_version,
      })),
      [{ status: 'dropped', last_error: 'superseded', content_version: 1 }],
    );

    await w.runUntil(t('08:30'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:20'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:50 AM to arrive by 8:30 AM. We'll keep checking traffic.",
      },
      {
        at: iso('07:50'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:50 AM to arrive around 8:10 AM. Your target is 8:30 AM.',
      },
    ]);
  });

  it('keeps its alerts when only its name changes, and uses the new name', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:10'));
    await w.sync(token, [tripInput({ title: 'Organic chem lab' })]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(
      sentBy(w).map(({ kind, title }) => ({ kind, title })),
      [
        { kind: 'heads_up', title: 'Heads up: Chem lab' },
        { kind: 'leave_now', title: 'Time to leave for Organic chem lab' },
      ],
    );
  });

  it('does not send a second heads-up to a trip cancelled and added back', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:10'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);

    await w.sync(token, []);
    assert.equal((await w.row()).status, 'cancelled');
    await w.runUntil(t('06:20'));

    // Back, unchanged: its plan is worked out again, its heads-up is not.
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].phase, 'monitoring');
    assert.equal(synced.trips[0].recommendation?.departAt, iso('07:30'));
    assert.equal(synced.trips[0].monitoring.lastAlert, null);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      { at: iso('07:30'), kind: 'leave_now', ...LEAVE },
    ]);
  });

  it('gives a trip added back after its leave alert a plan to show, and no more alerts', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('07:31'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    await w.sync(token, []);
    const asked = w.traffic.asks;

    const synced = await w.sync(token, [tripInput()]);
    assert.equal(w.traffic.asks, asked + 1);
    assert.equal(synced.trips[0].recommendation?.action, 'leave_now');
    assert.equal(synced.trips[0].monitoring.nextCheckAt, iso('08:00'));
    await w.runUntil(t('08:00'));
    assert.equal(w.traffic.asks, asked + 1);
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal((await w.row()).status, 'ended');
  });
});

describe('a trip cancelled and added back', () => {
  const UNAVAILABLE = {
    ok: false,
    kind: 'retryable',
    reason: 'ServiceUnavailable',
    status: 503,
  } as const;

  it('gets its one heads-up when the first was still waiting to go out', async () => {
    const w = world(t('05:00'));
    // No token yet, so the 6:00 heads-up waits in the outbox.
    const token = await w.device(null);
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:05'));
    assert.deepEqual(
      (await w.outbox()).map(({ kind, status }) => ({ kind, status })),
      [{ kind: 'heads_up', status: 'pending' }],
    );

    // Dropped, which deletes the waiting heads-up, and listed again.
    await w.sync(token, []);
    assert.deepEqual(await w.outbox(), []);
    const synced = await w.sync(token, [tripInput()]);
    // Nothing had been sent for it, so it starts as a new trip, planned
    // from this minute, and is due its heads-up at once.
    assert.equal(synced.trips[0].recommendation?.departAt, iso('07:20'));
    assert.deepEqual(synced.trips[0].monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:05'),
    });

    await w.setPush(token, TOKEN);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:06'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:20 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      },
      {
        at: iso('07:20'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 7:20 AM to arrive around 7:40 AM. Your target is 8:00 AM.',
      },
    ]);
  });

  it('still gets "time to leave" when that alert was waiting for another try, and no second heads-up', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('07:29'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);
    // APNs does not take the leave alert at 7:30; it waits to be retried.
    w.push.results = [UNAVAILABLE];
    await w.runUntil(t('07:30'));
    assert.deepEqual(
      (await w.outbox()).map(({ kind, status }) => ({ kind, status })),
      [
        { kind: 'heads_up', status: 'sent' },
        { kind: 'leave_now', status: 'pending' },
      ],
    );

    // In that moment the trip is dropped and listed again.
    await w.sync(token, []);
    const kept = await w.row();
    assert.equal(kept.status, 'cancelled');
    // The heads-up went out and stays on record; the leave alert did not.
    assert.equal(kept.headsUpState, 'sent');
    assert.equal(kept.leaveSentAt, null);
    await w.sync(token, [tripInput()]);

    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      { at: iso('07:31'), kind: 'leave_now', ...LEAVE },
    ]);
    assert.equal(w.push.attempts.length, 3);
  });

  it('is asked about again after its leave alert when the one check fails, until it has a plan to show', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('07:31'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    await w.sync(token, []);
    const asked = w.traffic.asks;

    // Listed again while the provider is down for a moment.
    w.traffic.failure = new RoutingError('The routing service is down');
    const synced = await w.sync(token, [tripInput()]);
    assert.equal(synced.trips[0].phase, 'monitoring');
    assert.equal(synced.trips[0].recommendation, null);
    assert.equal(synced.trips[0].lastError?.code, 'routing_unavailable');
    // Not put off until the trip ends: asked again in a minute.
    assert.equal(synced.trips[0].monitoring.nextCheckAt, iso('07:32'));

    w.traffic.failure = undefined;
    await w.runUntil(t('07:32'));
    const state = await w.state(token);
    assert.equal(state.lastError, null);
    assert.equal(state.recommendation?.action, 'leave_now');
    assert.equal(state.monitoring.nextCheckAt, iso('08:00'));

    // And then left alone: nothing more is asked or sent.
    await w.runUntil(t('08:00'));
    assert.equal(w.traffic.asks, asked + 2);
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
    assert.equal((await w.row()).status, 'ended');
  });
});

describe('a server that restarts', () => {
  it('carries on mid-window: no second heads-up, and the leave alert still goes out', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('06:20'));
    assert.deepEqual(w.push.kinds(), ['heads_up']);

    // A new monitor and a new service on the same database.
    const { monitor: oldMonitor, service: oldService } = w;
    w.restart();
    assert.notEqual(w.monitor, oldMonitor);
    assert.notEqual(w.service, oldService);

    const state = await w.state(token);
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.monitoring.headsUpSentAt, iso('06:00'));
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:00'), kind: 'heads_up', ...HEADS_UP },
      { at: iso('07:30'), kind: 'leave_now', ...LEAVE },
    ]);
    assert.equal((await w.row()).status, 'ended');
  });

  it('picks a trip up again when the old process died in the middle of checking it', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('05:59'));
    // The old process claimed the trip for its 6:00 check and was killed
    // before it could finish: all that is left of it is its claim.
    await db.query(
      'UPDATE trips SET lease_token = $1::uuid, lease_until = $2::timestamptz',
      [randomUUID(), t('06:02').toISOString()],
    );
    w.restart();
    // The claim holds for two minutes, then anybody may take the trip.
    await w.tickAt(t('06:00'));
    await w.tickAt(t('06:01'));
    await w.tickAt(t('06:02'));
    assert.deepEqual(w.push.attempts, []);
    assert.equal(w.traffic.asks, 3);
    await w.tickAt(t('06:03'));
    assert.deepEqual(sentBy(w), [
      { at: iso('06:03'), kind: 'heads_up', ...HEADS_UP },
    ]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(w.push.kinds(), ['heads_up', 'leave_now']);
  });
});

describe('time zones and daylight saving', () => {
  it('shows a New York trip’s times on the Eastern clock', async () => {
    const w = world(t('05:00'));
    const token = await w.device();
    // 8:00 AM Pacific is 11:00 AM Eastern.
    await w.sync(token, [tripInput({ timeZone: 'America/New_York' })]);
    await w.runUntil(t('08:00'));
    assert.deepEqual(sentBy(w), [
      {
        at: iso('06:00'),
        kind: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 10:30 AM to arrive by 11:00 AM. We'll keep checking traffic.",
      },
      {
        at: iso('07:30'),
        kind: 'leave_now',
        title: 'Time to leave for Chem lab',
        body: 'Leave at 10:30 AM to arrive around 10:50 AM. Your target is 11:00 AM.',
      },
    ]);
  });

  it('plans and alerts at the right instants on the day the clocks go back', async () => {
    // Sunday 1 November 2026: 2:00 AM PDT becomes 1:00 AM PST. Arrive by
    // 8:00 AM PST, synced at 9:00 PM PDT the evening before, 12 hours ahead.
    const arriveBy = new Date('2026-11-01T08:00:00-08:00');
    const w = world(new Date('2026-10-31T21:00:00-07:00'));
    const token = await w.device();
    const synced = await w.sync(token, [
      tripInput({ id: 'A1B2C3@2026-11-01', arriveBy: arriveBy.toISOString() }),
    ]);
    assert.equal(synced.trips[0].phase, 'scheduled');
    assert.equal(
      synced.trips[0].planAvailableAt,
      new Date('2026-10-31T21:30:00-07:00').toISOString(),
    );

    await w.runUntil(arriveBy);
    assert.deepEqual(sentBy(w), [
      {
        at: new Date('2026-11-01T06:00:00-08:00').toISOString(),
        kind: 'heads_up',
        ...HEADS_UP,
      },
      {
        at: new Date('2026-11-01T07:30:00-08:00').toISOString(),
        kind: 'leave_now',
        ...LEAVE,
      },
    ]);
    assert.deepEqual(
      w.traffic.askedAbout.map(at => at.toISOString()),
      [
        // The first plan, as the trip enters the horizon, then every slot
        // from two hours before the departure.
        '2026-11-01T04:30:00.000Z',
        '2026-11-01T13:30:00.000Z',
        '2026-11-01T13:45:00.000Z',
        '2026-11-01T14:00:00.000Z',
        '2026-11-01T14:15:00.000Z',
        '2026-11-01T14:30:00.000Z',
        '2026-11-01T14:45:00.000Z',
        '2026-11-01T15:00:00.000Z',
        '2026-11-01T15:15:00.000Z',
        '2026-11-01T15:30:00.000Z',
      ],
    );
    assert.equal((await w.row('A1B2C3@2026-11-01')).status, 'ended');
  });

  it('plans and alerts at the right instants on the day the clocks go forward', async () => {
    // Sunday 14 March 2027: 2:00 AM PST becomes 3:00 AM PDT. Arrive by
    // 8:00 AM PDT, synced at 9:00 PM PST the evening before, 10 hours ahead.
    const arriveBy = new Date('2027-03-14T08:00:00-07:00');
    const w = world(new Date('2027-03-13T21:00:00-08:00'));
    const token = await w.device();
    const synced = await w.sync(token, [
      tripInput({ id: 'A1B2C3@2027-03-14', arriveBy: arriveBy.toISOString() }),
    ]);
    assert.equal(synced.trips[0].phase, 'planned');
    assert.equal(
      synced.trips[0].recommendation?.departAt,
      new Date('2027-03-14T07:30:00-07:00').toISOString(),
    );
    assert.equal(
      synced.trips[0].monitoring.startsAt,
      new Date('2027-03-14T05:30:00-07:00').toISOString(),
    );

    await w.runUntil(arriveBy);
    assert.deepEqual(sentBy(w), [
      {
        at: new Date('2027-03-14T06:00:00-07:00').toISOString(),
        kind: 'heads_up',
        ...HEADS_UP,
      },
      {
        at: new Date('2027-03-14T07:30:00-07:00').toISOString(),
        kind: 'leave_now',
        ...LEAVE,
      },
    ]);
    assert.equal(w.traffic.asks, 10);
    assert.equal((await w.row('A1B2C3@2027-03-14')).status, 'ended');
  });
});
