// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// PGlite, the in-memory Postgres these tests use, cannot load inside Jest.
//
// The outbox: what happens to an alert between being queued and APNs
// accepting it. The push sender here records what it is asked to send and
// answers as the test tells it.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Database } from '../../db/db';
import { NoPushSender, PushResult } from '../../push/apns';
import { wireMonitoring } from '../wiring';
import {
  GYM,
  LAB,
  migratedDatabase,
  OTHER_TOKEN,
  resetDatabase,
  t,
  TOKEN,
  tripInput,
  World,
  WorldOptions,
} from './harness';

const iso = (clock: string): string => t(clock).toISOString();
/** A time to the second, such as 6:00:30. */
const at = (clock: string, seconds = 0): Date =>
  new Date(t(clock).getTime() + seconds * 1000);

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

const UNAVAILABLE: PushResult = {
  ok: false,
  kind: 'retryable',
  reason: 'ServiceUnavailable',
  status: 503,
};
const UNREGISTERED: PushResult = {
  ok: false,
  kind: 'invalid_token',
  reason: 'Unregistered',
  status: 410,
};
const BAD_TOKEN: PushResult = {
  ok: false,
  kind: 'invalid_token',
  reason: 'BadDeviceToken',
  status: 400,
};
const UNCONFIRMED: PushResult = {
  ok: false,
  kind: 'retryable',
  reason: 'timeout',
  unconfirmed: true,
};
const NOTHING = { delivered: 0, failed: 0, dropped: 0 };

type DevicePush = { apnsToken: string | null; authorized: boolean } | null;

/**
 * A trip to arrive by 8:00 whose heads-up for 7:30 was queued at 6:00 and
 * has not been sent: the checks ran, the deliveries did not.
 */
const queuedHeadsUp = async (
  options: Partial<WorldOptions> = {},
  push: DevicePush = { apnsToken: TOKEN, authorized: true },
) => {
  const w = new World(db, { now: t('05:00'), ...options });
  const token = await w.device(push);
  await w.sync(token, [tripInput()]);
  await checkAt(w, '05:30', '05:45', '06:00');
  assert.deepEqual(await statuses(w), [['heads_up', 'pending', null]]);
  return { w, token };
};

/** Runs the trip checks, and no deliveries, at each of the given times. */
const checkAt = async (w: World, ...times: string[]) => {
  for (const clock of times) {
    w.clock = t(clock);
    await w.monitor.evaluateDue();
  }
};

const deliverAt = (w: World, when: Date) => {
  w.clock = when;
  return w.monitor.deliverDue();
};

const statuses = async (w: World) =>
  (await w.outbox()).map(({ kind, status, last_error }) => [
    kind,
    status,
    last_error,
  ]);

const nextAttemptAt = async (): Promise<string> => {
  const { rows } = await db.query<{ at: number }>(
    `SELECT (extract(epoch FROM next_attempt_at) * 1000)::float8 AS at
       FROM trip_notifications ORDER BY created_at, id`,
  );
  return new Date(Math.round(rows[0].at)).toISOString();
};

const deviceRow = async () => {
  const { rows } = await db.query<{
    apns_token: string | null;
    apns_environment: string | null;
    push_failure_reason: string | null;
  }>('SELECT apns_token, apns_environment, push_failure_reason FROM devices');
  assert.equal(rows.length, 1);
  return rows[0];
};

describe('an alert APNs does not take at first', () => {
  it('is retried with a growing wait, under the same id, until it is accepted', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [UNAVAILABLE, UNAVAILABLE];

    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'pending',
        last_error: 'ServiceUnavailable',
        attempts: 1,
        content_version: 1,
      },
    ]);
    assert.equal(await nextAttemptAt(), at('06:00', 30).toISOString());
    assert.deepEqual((await w.state(token)).monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:00'),
      reason: 'ServiceUnavailable',
    });

    // Not before its time.
    assert.deepEqual(await deliverAt(w, at('06:00', 29)), NOTHING);
    assert.equal(w.push.attempts.length, 1);
    assert.deepEqual(await deliverAt(w, at('06:00', 30)), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.equal(await nextAttemptAt(), at('06:01', 30).toISOString());
    assert.deepEqual(await deliverAt(w, at('06:01', 29)), NOTHING);

    assert.deepEqual(await deliverAt(w, at('06:01', 30)), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'sent',
        last_error: null,
        attempts: 2,
        content_version: 1,
      },
    ]);
    // One alert, sent three times: APNs and the phone see a single id.
    assert.equal(w.push.attempts.length, 3);
    assert.equal(new Set(w.push.attempts.map(one => one.message.id)).size, 1);
    assert.equal(
      new Set(w.push.attempts.map(one => one.message.collapseId)).size,
      1,
    );
    const state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, at('06:01', 30).toISOString());
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'sent',
      at: at('06:01', 30).toISOString(),
    });
    // And never again.
    assert.deepEqual(await deliverAt(w, at('06:30')), NOTHING);
  });

  it('waits 30 seconds, 1, 2, 5 and 5 minutes, and gives up at the sixth failure', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = Array.from({ length: 6 }, () => UNAVAILABLE);
    const waits = [30, 60, 120, 300, 300];
    let when = at('06:00');
    for (const wait of waits) {
      assert.equal((await deliverAt(w, when)).failed, 1);
      when = new Date(when.getTime() + wait * 1000);
      assert.equal(await nextAttemptAt(), when.toISOString());
    }
    assert.deepEqual(await deliverAt(w, when), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'failed',
        last_error: 'ServiceUnavailable',
        attempts: 6,
        content_version: 1,
      },
    ]);
    const state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, null);
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'failed',
      at: iso('06:00'),
      reason: 'ServiceUnavailable',
    });
    assert.deepEqual(await deliverAt(w, at('07:00')), NOTHING);
    assert.equal(w.push.attempts.length, 6);
  });

  it('gives up when the next attempt would come after the alert is of any use', async () => {
    const { w } = await queuedHeadsUp();
    w.push.results = [UNAVAILABLE];
    // The heads-up is for a 7:30 departure. Fifteen seconds before it, a
    // retry in 30 seconds would be too late.
    assert.deepEqual(await deliverAt(w, at('07:29', 45)), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'failed', 'ServiceUnavailable'],
    ]);
  });

  it('is still sent at the last moment it is of use', async () => {
    const { w } = await queuedHeadsUp();
    assert.deepEqual(await deliverAt(w, at('07:30')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
  });

  it('is dropped, unsent, once it is of no use', async () => {
    const { w, token } = await queuedHeadsUp();
    assert.deepEqual(await deliverAt(w, at('07:30', 1)), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [['heads_up', 'dropped', 'expired']]);
    assert.deepEqual(w.push.attempts, []);
    assert.deepEqual((await w.state(token)).monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'dropped',
      at: iso('06:00'),
      reason: 'expired',
    });
  });

  it('stores a failure as a short code, whatever the sender says', async () => {
    const { w } = await queuedHeadsUp();
    w.push.results = [
      {
        ok: false,
        kind: 'retryable',
        reason: 'connect ECONNREFUSED 17.188.1.1:443 (token abc/def)',
      },
    ];
    await deliverAt(w, at('06:00'));
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'pending', 'connectECONNREFUSED1718811443tokenabcdef'],
    ]);
  });
});

describe('an alert that may or may not have reached APNs', () => {
  it('is not sent again when it is a heads-up: missing one beats getting two', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [UNCONFIRMED];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'failed', 'timeout_unconfirmed'],
    ]);
    assert.deepEqual(await deliverAt(w, at('06:05')), NOTHING);
    assert.equal(w.push.attempts.length, 1);
    const state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, null);
    assert.equal(state.monitoring.lastAlert?.status, 'failed');
    assert.equal(state.monitoring.lastAlert?.reason, 'timeout_unconfirmed');
  });

  it('is not sent again when it is an update', async () => {
    const { w } = await queuedHeadsUp();
    await deliverAt(w, at('06:00'));
    w.traffic.driveMinutes = 35;
    await checkAt(w, '06:15');
    w.push.results = [UNCONFIRMED];
    await deliverAt(w, at('06:15'));
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'sent', null],
      ['update', 'failed', 'timeout_unconfirmed'],
    ]);
  });

  it('is sent again when it is "time to leave": getting two beats missing it', async () => {
    const { w, token } = await queuedHeadsUp();
    await deliverAt(w, at('06:00'));
    await checkAt(w, '06:15', '06:30', '06:45', '07:00', '07:15', '07:30');
    w.push.results = [UNCONFIRMED];
    assert.deepEqual(await deliverAt(w, at('07:30')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'sent', null],
      ['leave_now', 'pending', 'timeout'],
    ]);
    assert.deepEqual(await deliverAt(w, at('07:30', 30)), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(
      (await w.state(token)).monitoring.leaveAlertSentAt,
      at('07:30', 30).toISOString(),
    );
    const [first, second] = w.push.attempts.slice(-2);
    assert.equal(first.message.id, second.message.id);
    assert.equal(first.message.atLeastOnce, true);
  });

  it('is sent again, heads-up or not, when APNs said outright that it did not process it', async () => {
    const { w, token } = await queuedHeadsUp();
    // What the sender reports for a refused stream: nothing unconfirmed.
    w.push.results = [
      { ok: false, kind: 'retryable', reason: 'connection_failed' },
    ];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'pending', 'connection_failed'],
    ]);
    assert.deepEqual(await deliverAt(w, at('06:00', 30)), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(
      (await w.state(token)).monitoring.headsUpSentAt,
      at('06:00', 30).toISOString(),
    );
  });
});

describe('a device token APNs rejects', () => {
  it('is forgotten and reported, and the alert waits for a new one', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [UNREGISTERED];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await deviceRow(), {
      apns_token: null,
      apns_environment: 'sandbox',
      push_failure_reason: 'Unregistered',
    });
    assert.deepEqual((await w.list(token)).push, {
      configured: true,
      registered: false,
      authorized: true,
      lastFailure: { reason: 'Unregistered', at: iso('06:00') },
    });
    // Not failed: a fresh token may arrive while the alert is still useful.
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'pending',
        last_error: 'Unregistered',
        attempts: 0,
        content_version: 1,
      },
    ]);
    assert.equal(await nextAttemptAt(), iso('06:01'));
    // With no token there is nothing to send to: the alert is left alone.
    assert.deepEqual(await deliverAt(w, at('06:01')), NOTHING);
    assert.equal(await nextAttemptAt(), iso('06:01'));
    assert.equal(w.push.attempts.length, 1);

    // The app registers again with a new token.
    await w.setPush(token, OTHER_TOKEN);
    assert.deepEqual(await deliverAt(w, at('06:02')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(w.push.sent[0].message.deviceToken, OTHER_TOKEN);
    // A successful send clears the failure.
    assert.deepEqual((await w.list(token)).push, {
      configured: true,
      registered: true,
      authorized: true,
    });
    assert.equal((await w.state(token)).monitoring.headsUpSentAt, iso('06:02'));
  });

  it('leaves the alert to be dropped when no new token comes in time', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [UNREGISTERED];
    await deliverAt(w, at('06:00'));
    assert.deepEqual(await deliverAt(w, at('07:31')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'no_device_token'],
    ]);
    assert.equal(
      (await w.state(token)).monitoring.lastAlert?.reason,
      'no_device_token',
    );
  });

  it('does not forget a token the device replaced while the send was under way', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [UNREGISTERED];
    w.push.onSend = async () => {
      w.push.onSend = undefined;
      await w.setPush(token, OTHER_TOKEN);
    };
    await deliverAt(w, at('06:00'));
    assert.deepEqual(await deviceRow(), {
      apns_token: OTHER_TOKEN,
      apns_environment: 'sandbox',
      push_failure_reason: null,
    });
    assert.deepEqual(await deliverAt(w, at('06:01')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(w.push.sent[0].message.deviceToken, OTHER_TOKEN);
  });

  it('is tried on the other APNs host before a "bad token" is believed', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [BAD_TOKEN];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(
      w.push.attempts.map(one => one.message.environment),
      ['sandbox', 'production'],
    );
    assert.equal(w.push.attempts[0].message.id, w.push.attempts[1].message.id);
    // The device said sandbox; it is a production token, and now stored so.
    assert.deepEqual(await deviceRow(), {
      apns_token: TOKEN,
      apns_environment: 'production',
      push_failure_reason: null,
    });
    assert.equal((await w.state(token)).monitoring.headsUpSentAt, iso('06:00'));

    // The next alert goes straight to the right host.
    await checkAt(w, '06:15', '06:30', '06:45', '07:00', '07:15', '07:30');
    await deliverAt(w, at('07:30'));
    assert.deepEqual(
      w.push.attempts.map(one => one.message.environment),
      ['sandbox', 'production', 'production'],
    );
  });

  it('is forgotten when both hosts reject it', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [BAD_TOKEN, BAD_TOKEN];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.equal(w.push.attempts.length, 2);
    assert.deepEqual(await deviceRow(), {
      apns_token: null,
      apns_environment: 'sandbox',
      push_failure_reason: 'BadDeviceToken',
    });
    assert.deepEqual((await w.list(token)).push.lastFailure, {
      reason: 'BadDeviceToken',
      at: iso('06:00'),
    });
  });

  it('is kept when the other host could not be asked', async () => {
    const { w } = await queuedHeadsUp();
    w.push.results = [BAD_TOKEN, UNAVAILABLE];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await deviceRow(), {
      apns_token: TOKEN,
      apns_environment: 'sandbox',
      push_failure_reason: null,
    });
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'pending',
        last_error: 'ServiceUnavailable',
        attempts: 1,
        content_version: 1,
      },
    ]);
  });
});

describe('a device that cannot be sent to', () => {
  it('keeps its alert waiting while it has no token, and gets it once it has', async () => {
    const { w, token } = await queuedHeadsUp({}, null);
    assert.deepEqual(await deliverAt(w, at('06:00')), NOTHING);
    assert.deepEqual(await w.outbox(), [
      {
        kind: 'heads_up',
        status: 'pending',
        last_error: null,
        attempts: 0,
        content_version: 1,
      },
    ]);
    // Not claimed and put back: it is due the moment the device reports.
    assert.equal(await nextAttemptAt(), iso('06:00'));
    assert.deepEqual(await deliverAt(w, at('06:05')), NOTHING);
    assert.deepEqual(w.push.attempts, []);
    assert.deepEqual((await w.state(token)).monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:00'),
    });

    await w.setPush(token, TOKEN);
    assert.deepEqual(await deliverAt(w, at('06:06')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(w.push.sent.length, 1);
    assert.equal((await w.state(token)).monitoring.headsUpSentAt, iso('06:06'));
  });

  it('has its alert dropped when it never gets a token in time', async () => {
    const { w } = await queuedHeadsUp({}, null);
    await deliverAt(w, at('06:00'));
    assert.deepEqual(await deliverAt(w, at('07:31')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'no_device_token'],
    ]);
  });

  it('has its alert dropped when it never says whether alerts are allowed', async () => {
    const { w } = await queuedHeadsUp();
    // A token on file, and no word on permission: not a state the app
    // leaves a device in, but one the table allows.
    await db.query('UPDATE devices SET notifications_authorized = NULL');
    assert.deepEqual(await deliverAt(w, at('07:30')), NOTHING);
    assert.deepEqual(await deliverAt(w, at('07:31')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [['heads_up', 'dropped', 'expired']]);
    assert.deepEqual(w.push.attempts, []);
  });

  it('has its alert dropped when the user turned notifications off', async () => {
    const { w, token } = await queuedHeadsUp(
      {},
      { apnsToken: TOKEN, authorized: false },
    );
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(w.push.attempts, []);
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'not_authorized'],
    ]);
    assert.deepEqual((await w.state(token)).monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'dropped',
      at: iso('06:00'),
      reason: 'not_authorized',
    });
    assert.equal((await w.list(token)).push.authorized, false);
  });
});

describe('a server with no push credentials', () => {
  it('says so, claims nothing, and reports the heads-up as queued, not sent', async () => {
    const { w, token } = await queuedHeadsUp({ push: false });
    assert.equal((await w.list(token)).push.configured, false);
    // A whole tick, a few minutes after the heads-up time.
    const report = await w.tickAt(t('06:05'));
    assert.deepEqual(report, {
      evaluated: 0,
      queued: 0,
      delivered: 0,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(w.push.attempts, []);
    const { rows } = await db.query<{
      status: string;
      attempts: number;
      lease_token: string | null;
    }>('SELECT status, attempts, lease_token FROM trip_notifications');
    assert.deepEqual(rows, [
      { status: 'pending', attempts: 0, lease_token: null },
    ]);
    const state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, null);
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:00'),
    });
  });

  it('behaves the same with the sender serve.ts uses when APNs is not set up', async () => {
    // Built by hand, with the real NoPushSender in place of the recorder.
    const w = new World(db, { now: t('05:00') });
    const { monitor, trips } = wireMonitoring({
      db,
      providers: w.traffic.providers(),
      push: new NoPushSender(),
      enabled: true,
      now: () => w.clock,
    });
    const { token } = await trips.register();
    const device = () => trips.authenticate(`Bearer ${token}`);
    await trips.setPush(await device(), {
      apnsToken: TOKEN,
      environment: 'sandbox',
      authorized: true,
    });
    await trips.sync(await device(), { revision: 1, trips: [tripInput()] });
    // Every minute until five past the heads-up time.
    for (let minute = 1; minute <= 65; minute++) {
      w.clock = new Date(t('05:00').getTime() + minute * 60_000);
      const report = await monitor.tick();
      assert.equal(report.delivered + report.failed + report.dropped, 0);
    }
    const listed = await trips.list(await device());
    assert.deepEqual(listed.push, {
      configured: false,
      registered: true,
      authorized: true,
    });
    assert.equal(listed.trips[0].phase, 'monitoring');
    assert.equal(listed.trips[0].monitoring.headsUpSentAt, null);
    assert.deepEqual(listed.trips[0].monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: iso('06:00'),
    });
  });

  it('drops an alert once it is of no use', async () => {
    const { w, token } = await queuedHeadsUp({ push: false });
    assert.deepEqual(await deliverAt(w, at('07:30')), NOTHING);
    assert.deepEqual(await deliverAt(w, at('07:30', 1)), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'push_not_configured'],
    ]);
    assert.deepEqual((await w.state(token)).monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'dropped',
      at: iso('06:00'),
      reason: 'push_not_configured',
    });
  });

  it('still plans and monitors, so the app has everything but the alerts', async () => {
    const w = new World(db, { now: t('05:00'), push: false });
    const token = await w.device();
    await w.sync(token, [tripInput()]);
    await w.runUntil(t('07:45'));
    const state = await w.state(token);
    assert.equal(state.phase, 'monitoring');
    assert.equal(state.recommendation?.action, 'leave_now');
    assert.equal(state.monitoring.headsUpSentAt, null);
    assert.equal(state.monitoring.leaveAlertSentAt, null);
    assert.deepEqual(state.monitoring.lastAlert, {
      kind: 'leave_now',
      status: 'queued',
      at: iso('07:30'),
    });
    assert.deepEqual(w.push.attempts, []);
  });
});

describe('a server whose push credentials are wrong', () => {
  it('fails the alert, reports why, and forgets it at the next success', async () => {
    const { w, token } = await queuedHeadsUp();
    w.push.results = [
      {
        ok: false,
        kind: 'config',
        reason: 'InvalidProviderToken',
        status: 403,
      },
    ];
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 1,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'failed', 'InvalidProviderToken'],
    ]);
    // The token is not at fault and is kept.
    assert.deepEqual((await w.list(token)).push, {
      configured: true,
      registered: true,
      authorized: true,
      lastFailure: { reason: 'InvalidProviderToken', at: iso('06:00') },
    });
    assert.deepEqual(await deliverAt(w, at('06:10')), NOTHING);

    await checkAt(w, '06:15', '06:30', '06:45', '07:00', '07:15', '07:30');
    assert.equal((await deliverAt(w, at('07:30'))).delivered, 1);
    assert.equal((await w.list(token)).push.lastFailure, undefined);
  });
});

describe('alerts that pile up', () => {
  it('sends only the newest when the token arrives after three were queued', async () => {
    const { w, token } = await queuedHeadsUp({}, null);
    // 6:00 heads-up for 7:30; traffic worsens, so 6:15 "leave at 7:15";
    // then 7:15 "time to leave". The device has no token all this while.
    w.traffic.driveMinutes = 35;
    await checkAt(w, '06:15', '06:30', '06:45', '07:00', '07:15');
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'superseded'],
      ['update', 'dropped', 'superseded'],
      ['leave_now', 'pending', null],
    ]);

    await w.setPush(token, TOKEN);
    assert.deepEqual(await deliverAt(w, at('07:16')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(
      w.push.attempts.map(({ kind, body }) => ({ kind, body })),
      [
        {
          kind: 'leave_now',
          body: 'Leave at 7:15 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
        },
      ],
    );
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'superseded'],
      ['update', 'dropped', 'superseded'],
      ['leave_now', 'sent', null],
    ]);
    const state = await w.state(token);
    assert.equal(state.monitoring.headsUpSentAt, null);
    assert.equal(state.monitoring.leaveAlertSentAt, iso('07:16'));
  });

  it('does not drop an alert that is being sent when a newer one is queued', async () => {
    const { w } = await queuedHeadsUp();
    // The heads-up is claimed, and its send is still under way when the
    // 6:15 check queues an update.
    w.traffic.driveMinutes = 35;
    w.push.onSend = async () => {
      w.push.onSend = undefined;
      w.clock = t('06:15');
      // A second worker, since this one is busy sending.
      await w.secondMonitor().evaluateDue();
      w.clock = t('06:00');
    };
    assert.equal((await deliverAt(w, at('06:00'))).delivered, 1);
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'sent', null],
      ['update', 'pending', null],
    ]);
  });

  it('still sends the one heads-up when the plan has moved to a later departure seen only once', async () => {
    const { w, token } = await queuedHeadsUp({}, null);
    // Traffic eases: the plan moves to 7:45, seen once so far, so no update
    // is queued yet. 7:30 is still what the user is to be told.
    w.traffic.driveMinutes = 5;
    await checkAt(w, '06:15');
    assert.equal((await w.state(token)).recommendation?.departAt, iso('07:45'));
    assert.deepEqual((await w.row()).notifiedDepartAt, t('07:30'));
    await w.setPush(token, TOKEN);
    assert.deepEqual(await deliverAt(w, at('06:16')), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(await statuses(w), [['heads_up', 'sent', null]]);
    assert.deepEqual(
      w.push.sent.map(sent => sent.body),
      [
        "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
      ],
    );

    // Traffic is back as it was by the next check: 7:30 again, and nothing
    // more to say until it is time to leave.
    w.traffic.driveMinutes = 20;
    await w.runUntil(t('08:00'));
    assert.deepEqual(
      w.push.sent.map(({ at: sentAt, kind }) => [sentAt.toISOString(), kind]),
      [
        [at('06:16').toISOString(), 'heads_up'],
        [iso('07:30'), 'leave_now'],
      ],
    );
  });

  it('follows that heads-up with an update when the later departure holds', async () => {
    const { w, token } = await queuedHeadsUp({}, null);
    w.traffic.driveMinutes = 5;
    await checkAt(w, '06:15');
    await w.setPush(token, TOKEN);
    await deliverAt(w, at('06:16'));
    await w.runUntil(t('06:30'));
    assert.deepEqual(
      w.push.sent.map(sent => sent.body),
      [
        "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
        'Leave at 7:45 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
      ],
    );
  });

  it('still sends the one heads-up when a poorer source gives a later departure, which is never announced', async () => {
    // Live conditions are there when the heads-up for 7:30 is queued.
    const w = new World(db, { now: t('05:00') });
    w.traffic.live = { available: true, extraMinutes: 0, incidents: [] };
    const token = await w.device(null);
    await w.sync(token, [tripInput()]);
    await checkAt(w, '05:30', '05:45', '06:00');
    assert.equal((await w.row()).notifiedDegraded, false);
    // Then the live feed drops out, and what is left says 7:45.
    w.traffic.live = undefined;
    w.traffic.driveMinutes = 5;
    await checkAt(w, '06:15', '06:30');
    assert.equal((await w.state(token)).recommendation?.departAt, iso('07:45'));
    assert.deepEqual(await statuses(w), [['heads_up', 'pending', null]]);

    await w.setPush(token, TOKEN);
    await w.runUntil(t('08:00'));
    // One heads-up, for the departure the leave alert then keeps to.
    assert.deepEqual(
      w.push.sent.map(({ at: sentAt, kind, body }) => ({
        at: sentAt.toISOString(),
        kind,
        body,
      })),
      [
        {
          at: iso('06:31'),
          kind: 'heads_up',
          body: "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
        },
        {
          at: iso('07:30'),
          kind: 'leave_now',
          body: 'Leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be fully re-checked.',
        },
      ],
    );
  });

  it('drops a heads-up left half sent once a newer alert has named another departure', async () => {
    const { w } = await queuedHeadsUp();
    // The process dies in the middle of sending the heads-up for 7:30.
    w.push.onSend = async () => {
      w.push.onSend = undefined;
      throw new Error('killed');
    };
    await deliverAt(w, at('06:00'));
    assert.deepEqual(await statuses(w), [['heads_up', 'sending', null]]);
    w.restart();
    // Traffic worsens: "leave at 7:15" is queued beside it.
    w.traffic.driveMinutes = 35;
    await checkAt(w, '06:15');
    assert.deepEqual(await deliverAt(w, at('06:15')), {
      delivered: 1,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'superseded'],
      ['update', 'sent', null],
    ]);
  });

  it('drops a heads-up once the leave alert has gone, and a leave alert once "running late" has', async () => {
    const { w } = await queuedHeadsUp();
    await db.query('UPDATE trips SET leave_sent_at = $1::timestamptz', [
      iso('06:00'),
    ]);
    assert.deepEqual(await deliverAt(w, at('06:01')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'superseded'],
    ]);

    await resetDatabase(db);
    const other = await queuedHeadsUp();
    await deliverAt(other.w, at('06:00'));
    await checkAt(
      other.w,
      '06:15',
      '06:30',
      '06:45',
      '07:00',
      '07:15',
      '07:30',
    );
    await db.query('UPDATE trips SET late_sent_at = $1::timestamptz', [
      iso('07:31'),
    ]);
    assert.deepEqual(await deliverAt(other.w, at('07:32')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await statuses(other.w), [
      ['heads_up', 'sent', null],
      ['leave_now', 'dropped', 'superseded'],
    ]);
  });
});

describe('a delivery that is interrupted', () => {
  it('is finished by the next process when the first died in the middle of a send', async () => {
    const { w, token } = await queuedHeadsUp();
    // The process is killed while APNs is being asked: the alert stays
    // claimed and nobody knows whether it was sent.
    w.push.onSend = async () => {
      w.push.onSend = undefined;
      throw new Error('killed');
    };
    assert.deepEqual(await deliverAt(w, at('06:00')), NOTHING);
    assert.deepEqual(w.logs, ['Alert delivery failed: Error']);
    assert.deepEqual(await statuses(w), [['heads_up', 'sending', null]]);

    w.restart();
    // The claim holds for two minutes.
    assert.deepEqual(await deliverAt(w, at('06:01')), NOTHING);
    assert.deepEqual(await deliverAt(w, at('06:02')), NOTHING);
    assert.deepEqual(await deliverAt(w, at('06:02', 1)), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.equal(w.push.attempts[0].message.id, w.push.attempts[1].message.id);
    assert.equal(
      (await w.state(token)).monitoring.headsUpSentAt,
      at('06:02', 1).toISOString(),
    );
  });

  it('does not mind an alert that vanishes while it is being sent', async () => {
    const { w, token } = await queuedHeadsUp();
    // The user says "I've left" during the send, which deletes the trip's
    // alerts.
    w.push.onSend = async () => {
      w.push.onSend = undefined;
      const device = await w.authenticate(token);
      await w.service.departed(device, LAB, iso('08:00'));
    };
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 0,
      failed: 0,
      dropped: 1,
    });
    assert.deepEqual(await w.outbox(), []);
    assert.deepEqual(w.logs, []);
  });
});

describe('a delivery pass', () => {
  const twoDevices = async () => {
    const w = new World(db, { now: t('05:00') });
    const first = await w.device();
    const second = await w.device({ apnsToken: OTHER_TOKEN, authorized: true });
    await w.sync(first, [tripInput()]);
    await w.sync(second, [tripInput({ id: GYM, title: 'Gym' })]);
    await checkAt(w, '05:30', '05:45', '06:00');
    assert.equal((await w.outbox()).length, 2);
    return { w, first, second };
  };

  it('sends one alert at a time, oldest first', async () => {
    const { w } = await twoDevices();
    let sending = 0;
    let most = 0;
    w.push.onSend = async () => {
      sending += 1;
      most = Math.max(most, sending);
      await new Promise(resolve => setImmediate(resolve));
      sending -= 1;
    };
    assert.deepEqual(await deliverAt(w, at('06:00')), {
      delivered: 2,
      failed: 0,
      dropped: 0,
    });
    assert.equal(most, 1);
    assert.deepEqual(
      w.push.sent.map(one => one.message.deviceToken).sort(),
      [TOKEN, OTHER_TOKEN].sort(),
    );
  });

  it('can be limited to one device, and to a number of alerts', async () => {
    const { w, second } = await twoDevices();
    const device = await w.authenticate(second);
    w.clock = at('06:00');
    assert.deepEqual(await w.monitor.deliverDue({ deviceId: device.id }), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(
      w.push.sent.map(one => one.message.deviceToken),
      [OTHER_TOKEN],
    );

    await resetDatabase(db);
    const again = await twoDevices();
    again.w.clock = at('06:00');
    assert.equal((await again.w.monitor.deliverDue({ limit: 1 })).delivered, 1);
    assert.equal((await again.w.monitor.deliverDue({ limit: 1 })).delivered, 1);
    assert.equal((await again.w.monitor.deliverDue({ limit: 1 })).delivered, 0);
  });

  it('does not let alerts that can only wait hold up the ones that can be sent', async () => {
    const w = new World(db, { now: t('05:00') });
    // One device never says where its alerts go; its three trips arrive at
    // 8:00. Another is ready, and its trip arrives a quarter of an hour on.
    const silent = await w.device(null);
    const ready = await w.device({ apnsToken: OTHER_TOKEN, authorized: true });
    await w.sync(silent, [
      tripInput(),
      tripInput({ id: 'B2@2026-11-20', title: 'Two' }),
      tripInput({ id: 'C3@2026-11-20', title: 'Three' }),
    ]);
    await w.sync(ready, [
      tripInput({ id: GYM, title: 'Gym', arriveBy: iso('08:15') }),
    ]);
    await checkAt(w, '05:30', '05:45', '06:00', '06:15');
    // Three heads-ups that can only wait, queued at 6:00, and one that can
    // go, queued after them.
    assert.deepEqual(
      (await w.outbox()).map(row => row.status),
      ['pending', 'pending', 'pending', 'pending'],
    );

    // Even a pass that may send a single alert reaches it.
    w.clock = at('06:15');
    assert.deepEqual(await w.monitor.deliverDue({ limit: 1 }), {
      delivered: 1,
      failed: 0,
      dropped: 0,
    });
    assert.deepEqual(
      w.push.sent.map(sent => [sent.title, sent.message.deviceToken]),
      [['Heads up: Gym', OTHER_TOKEN]],
    );
    // The waiting ones were not touched: not claimed, not put off.
    const { rows } = await db.query<{
      status: string;
      lease_token: string | null;
      due: number;
    }>(
      `SELECT status, lease_token,
              (extract(epoch FROM next_attempt_at) * 1000)::float8 AS due
         FROM trip_notifications WHERE status <> 'sent'`,
    );
    assert.deepEqual(
      rows.map(row => [row.status, row.lease_token, new Date(row.due)]),
      [
        ['pending', null, t('06:00')],
        ['pending', null, t('06:00')],
        ['pending', null, t('06:00')],
      ],
    );

    // They go out as soon as their device says where to send them.
    await w.setPush(silent, TOKEN);
    assert.deepEqual(await w.monitor.deliverDue(), {
      delivered: 3,
      failed: 0,
      dropped: 0,
    });
  });

  it('ends all the alerts that waited in vain at once, however many', async () => {
    const w = new World(db, { now: t('05:00') });
    const silent = await w.device(null);
    await w.sync(silent, [
      tripInput(),
      tripInput({ id: 'B2@2026-11-20', title: 'Two' }),
      tripInput({ id: 'C3@2026-11-20', title: 'Three' }),
    ]);
    await checkAt(w, '05:30', '05:45', '06:00');
    // A minute after the departure the heads-ups named. A limit of one
    // alert is no limit on these: none of them is sent.
    w.clock = at('07:31');
    assert.deepEqual(await w.monitor.deliverDue({ limit: 1 }), {
      delivered: 0,
      failed: 0,
      dropped: 3,
    });
    assert.deepEqual(await statuses(w), [
      ['heads_up', 'dropped', 'no_device_token'],
      ['heads_up', 'dropped', 'no_device_token'],
      ['heads_up', 'dropped', 'no_device_token'],
    ]);
  });

  it('does not let one device’s bad token touch another’s', async () => {
    const { w, first, second } = await twoDevices();
    w.push.results = [UNREGISTERED];
    const report = await deliverAt(w, at('06:00'));
    assert.deepEqual(report, { delivered: 1, failed: 1, dropped: 0 });
    const pushes = [
      (await w.list(first)).push.registered,
      (await w.list(second)).push.registered,
    ];
    assert.deepEqual(pushes.sort(), [false, true]);
  });
});
