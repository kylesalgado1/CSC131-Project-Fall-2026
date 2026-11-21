import { randomUUID } from 'crypto';
import { Database, Queryable } from '../db/db';
import { getVerdict, PredictionResult } from '../prediction';
import { PredictionProviders } from '../prediction/predict';
import { NoBaselineCoverageError } from '../prediction/providers/pems/provider';
import { RoutingError } from '../prediction/providers/routing/types';
import { DEFAULT_PREFERENCES } from '../prediction/types';
import { PushEnvironment, PushResult, PushSender } from '../push/apns';
import { errorName } from '../util/errorName';
import { MINUTE_MS } from '../util/time';
import {
  DEFAULT_MONITOR_BUDGET,
  DEFAULT_MONITOR_CONFIG,
  MonitorBudget,
  MonitorConfig,
} from './config';
import {
  catchUpInstant,
  decideActions,
  Decision,
  Evaluation,
  nextStep,
  planFromVerdict,
  PlannedAlert,
} from './plan';
import {
  CLEAR_LEASE_SQL,
  mapTrip,
  purgeExpired,
  retireTrips,
  StoredPhase,
  tripColumns,
  TripRecord,
  TripRow,
} from './store';
import { AlertKind, ErrorCode, MonitorStatus, TickReport } from './types';

export type { TickReport } from './types';

/**
 * The worker behind trip monitoring. A tick does three things in turn:
 *
 * 1. Checks the trips that are due, one at a time. Each is claimed with a
 *    short lease, asked about outside any transaction (a provider can take
 *    seconds), and written back only if the lease still holds and the trip
 *    has not changed meanwhile. So two workers never both act on a trip, an
 *    edit or "I've left" during a check discards its result, and a worker
 *    that dies simply lets its lease run out. What a check decides is in
 *    plan.ts.
 * 2. Delivers the alerts that are queued, the same way.
 * 3. Enforces retention.
 *
 * Everything it knows is in the database, so a restart carries on where the
 * last process stopped, and a tick that comes late catches up.
 */

/** How long a worker may hold a trip or an alert before another takes over. */
const LEASE_MS = 2 * MINUTE_MS;

/** A prediction that takes longer than this counts as a routing failure. */
export const EVALUATION_TIMEOUT_MS = 20_000;

/**
 * For every trip a pass may ask about, this many more may be claimed for
 * work that asks nobody: ending a trip, or putting off one that is not yet
 * within the planning horizon.
 */
const CLAIMS_PER_EVALUATION = 10;

/**
 * For every alert a pass may send, this many more may be claimed for work
 * that sends nothing: dropping one that is of no use any more.
 */
const CLAIMS_PER_DELIVERY = 10;

/**
 * A device that can only be waited for: it has not said whether it allows
 * alerts, or it allows them and has no token to send them to. (`d` is the
 * devices table.) Its alerts are not claimed, so however many of them wait,
 * and however long, they take nothing from the alerts that can be sent.
 */
const DEVICE_CAN_ONLY_WAIT = `(d.notifications_authorized IS NULL
       OR (d.notifications_authorized AND d.apns_token IS NULL))`;

/** The most alerts one tick tries to send. */
export const DELIVERIES_PER_TICK = 50;

/** How long to wait before each new attempt at an alert APNs did not take. */
export const SEND_RETRY_SECONDS = [30, 60, 120, 300];

/** An alert is given up on after this many failed attempts. */
export const MAX_SEND_ATTEMPTS = 6;

/** How long an alert waits for a device that has no usable token yet. */
const TOKEN_WAIT_MS = MINUTE_MS;

/** The monitor counts as ticked from outside for this long after a tick. */
export const EXTERNAL_TICK_FRESH_MINUTES = 3;

/** What a TripMonitor is built from. */
export interface TripMonitorDeps {
  db: Database;
  providers: PredictionProviders;
  push: PushSender;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
  config?: MonitorConfig;
  budget?: MonitorBudget;
  /** Whether this server runs the worker (MONITOR=on). Reported to clients. */
  enabled?: boolean;
  /** Whether this server never sleeps (MONITOR_ALWAYS_ON=true). */
  alwaysOn?: boolean;
  /** How long one prediction may take. */
  evaluationTimeoutMs?: number;
  /** Where failures are noted: their kind only, never their details. */
  log?: (line: string) => void;
}

/** Which trips or alerts a pass covers. */
export interface PassOptions {
  /** Only this device's. Absent: everybody's. */
  deviceId?: string;
  /** The most evaluations, or the most deliveries, in this pass. */
  limit?: number;
}

/** How a tick was started, and what it covers. */
export interface TickOptions extends PassOptions {
  /**
   * True when something outside this process started it: the tick route or
   * the tick script, on a scheduler's clock. That is what makes a server
   * that sleeps dependable.
   */
  external?: boolean;
}

/** The prediction took longer than a check can wait. */
class EvaluationTimeoutError extends Error {
  constructor() {
    super('The prediction took too long');
    this.name = 'EvaluationTimeoutError';
  }
}

interface ClaimedAlert {
  id: string;
  tripId: string;
  deviceId: string;
  contentVersion: number;
  kind: AlertKind;
  payload: { departAt?: unknown };
  attempts: number;
  expiresAt: Date;
  createdAt: Date;
}

interface AlertRecord {
  id: string;
  trip_id: string;
  device_id: string;
  content_version: number;
  kind: AlertKind;
  payload: string;
  attempts: number;
  expires_at: number;
  created_at: number;
}

/** The trip and device an alert is for, as they are at delivery. */
interface AlertContext {
  status: string;
  content_version: number;
  notified_depart_at: number | null;
  leave_sent_at: number | null;
  late_sent_at: number | null;
  apns_token: string | null;
  apns_environment: PushEnvironment | null;
  notifications_authorized: boolean | null;
}

type Delivery = 'delivered' | 'failed' | 'dropped' | 'waiting';

/** What became of a claimed alert, and whether APNs was asked about it. */
interface Handled {
  outcome: Delivery;
  attempted: boolean;
}

const epochMs = (column: string): string =>
  `(extract(epoch FROM ${column}) * 1000)::float8`;

const iso = (date: Date | null): string | null =>
  date === null ? null : date.toISOString();

const json = (value: unknown): string | null =>
  value === null ? null : JSON.stringify(value);

/**
 * A failure as a short code. These are stored and shown to the app, so
 * nothing but letters, digits and underscores gets through.
 */
const shortCode = (reason: string): string =>
  reason.replace(/[^A-Za-z0-9_]/g, '').slice(0, 64) || 'unknown';

const otherEnvironment = (environment: PushEnvironment): PushEnvironment =>
  environment === 'sandbox' ? 'production' : 'sandbox';

/** An alert the user gains nothing from getting twice. */
const isInformational = (kind: AlertKind): boolean =>
  kind === 'heads_up' || kind === 'update';

export class TripMonitor {
  private readonly db: Database;
  private readonly providers: PredictionProviders;
  private readonly push: PushSender;
  private readonly now: () => Date;
  private readonly config: MonitorConfig;
  private readonly budget: MonitorBudget;
  private readonly enabled: boolean;
  private readonly alwaysOn: boolean;
  private readonly evaluationTimeoutMs: number;
  private readonly log: (line: string) => void;

  // Whatever this process is doing for the monitor, it does one thing at a
  // time: the ticker, the tick route and a sync's first evaluation share
  // this queue.
  private queue: Promise<unknown> = Promise.resolve();

  constructor({
    db,
    providers,
    push,
    now = () => new Date(),
    config = DEFAULT_MONITOR_CONFIG,
    budget = DEFAULT_MONITOR_BUDGET,
    enabled = false,
    alwaysOn = false,
    evaluationTimeoutMs = EVALUATION_TIMEOUT_MS,
    log = line => console.error(line),
  }: TripMonitorDeps) {
    this.db = db;
    this.providers = providers;
    this.push = push;
    this.now = now;
    this.config = config;
    this.budget = budget;
    this.enabled = enabled;
    this.alwaysOn = alwaysOn;
    this.evaluationTimeoutMs = evaluationTimeoutMs;
    this.log = log;
  }

  /**
   * Whether trips are being checked while the app is closed. Enabled says
   * this server runs the worker. Dependable says it can be counted on: the
   * server was declared always on, or something outside it started a tick
   * within the last few minutes. A server that sleeps when idle and has no
   * scheduler waking it is neither, however recently it happened to tick.
   * Never throws: when the heartbeat cannot be read, a tick from outside is
   * not assumed.
   */
  async status(): Promise<MonitorStatus> {
    let heartbeat:
      | { last_tick_at: number | null; last_external_tick_at: number | null }
      | undefined;
    try {
      const { rows } = await this.db.query<NonNullable<typeof heartbeat>>(
        `SELECT ${epochMs('last_tick_at')} AS last_tick_at,
                ${epochMs('last_external_tick_at')} AS last_external_tick_at
           FROM monitor_state WHERE id = 1`,
      );
      heartbeat = rows[0];
    } catch (error) {
      // Whether this server runs the worker is not in the database, and
      // must not read as "no" because the heartbeat could not be: only
      // what the heartbeat would have shown is left unsaid.
      this.log(`Monitor heartbeat could not be read: ${errorName(error)}`);
    }
    const lastTickMs = heartbeat?.last_tick_at ?? null;
    const externalMs = heartbeat?.last_external_tick_at ?? null;
    const tickedFromOutside =
      externalMs !== null &&
      Math.abs(this.now().getTime() - externalMs) <=
        EXTERNAL_TICK_FRESH_MINUTES * MINUTE_MS;
    return {
      enabled: this.enabled,
      dependable: this.enabled && (this.alwaysOn || tickedFromOutside),
      lastTickAt: lastTickMs === null ? null : new Date(Math.round(lastTickMs)),
    };
  }

  /**
   * One round of monitoring: note that it ran, check the trips that are due,
   * deliver the alerts that are queued, and enforce retention.
   */
  tick(options: TickOptions = {}): Promise<TickReport> {
    const { deviceId, limit, external } = options;
    return this.exclusive(async () => {
      await this.heartbeat(external === true);
      // The limit is on evaluations; deliveries keep their own.
      const { evaluated, queued } = await this.evaluatePass({
        deviceId,
        limit,
      });
      const delivery = await this.deliverPass({ deviceId });
      try {
        await purgeExpired(this.db, this.now(), this.config.retentionHours);
      } catch (error) {
        this.log(`Trip purge failed: ${errorName(error)}`);
      }
      return { evaluated, queued, ...delivery };
    });
  }

  /**
   * Checks the trips that are due, earliest arrival first, one at a time.
   * Answers how many the prediction was asked about and how many alerts
   * were queued.
   */
  evaluateDue(
    options: PassOptions = {},
  ): Promise<{ evaluated: number; queued: number }> {
    return this.exclusive(() => this.evaluatePass(options));
  }

  /**
   * Sends the alerts that are queued and due, oldest first, one at a time.
   * "Delivered" means APNs accepted the alert, never that it was shown.
   */
  deliverDue(
    options: PassOptions = {},
  ): Promise<{ delivered: number; failed: number; dropped: number }> {
    return this.exclusive(() => this.deliverPass(options));
  }

  /**
   * Resolves once everything this monitor has been asked to do so far is
   * done, however it ended. For shutting down: the connections a tick uses
   * must not be closed under it.
   */
  idle(): Promise<void> {
    return this.queue.then(() => undefined);
  }

  private exclusive<T>(work: () => Promise<T>): Promise<T> {
    const run = this.queue.then(work, work);
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async heartbeat(external: boolean): Promise<void> {
    await this.db.query(
      `INSERT INTO monitor_state (id, last_tick_at, last_external_tick_at)
       VALUES (1, $1::timestamptz,
               CASE WHEN $2::boolean THEN $1::timestamptz END)
       ON CONFLICT (id) DO UPDATE SET
         last_tick_at = EXCLUDED.last_tick_at,
         last_external_tick_at = COALESCE(
           EXCLUDED.last_external_tick_at,
           monitor_state.last_external_tick_at)`,
      [iso(this.now()), external],
    );
  }

  private async evaluatePass({
    deviceId,
    limit = this.budget.evaluationsPerTick,
  }: PassOptions): Promise<{ evaluated: number; queued: number }> {
    let evaluated = 0;
    let queued = 0;
    const maxClaims = Math.max(1, limit) * CLAIMS_PER_EVALUATION;
    for (let claims = 0; claims < maxClaims && evaluated < limit; claims++) {
      const token = randomUUID();
      const trip = await this.claimTrip(token, deviceId);
      if (!trip) {
        break;
      }
      try {
        const done = await this.checkTrip(trip, token);
        evaluated += done.asked ? 1 : 0;
        queued += done.queued;
      } catch (error) {
        // Its lease runs out by itself, and the next tick tries again.
        this.log(`Trip check failed: ${errorName(error)}`);
      }
    }
    return { evaluated, queued };
  }

  /** Takes the due trip with the earliest arrival that nobody else holds. */
  private async claimTrip(
    token: string,
    deviceId: string | undefined,
  ): Promise<TripRow | undefined> {
    const now = this.now();
    const { rows } = await this.db.query<TripRecord>(
      `UPDATE trips SET lease_token = $1::uuid, lease_until = $2::timestamptz
        WHERE id = (
          SELECT id FROM trips
           WHERE status = 'active'
             AND next_check_at <= $3::timestamptz
             AND (lease_until IS NULL OR lease_until < $3::timestamptz)
             AND ($4::uuid IS NULL OR device_id = $4::uuid)
           ORDER BY arrive_by, id
           LIMIT 1
             FOR UPDATE SKIP LOCKED)
      RETURNING ${tripColumns()}`,
      [
        token,
        iso(new Date(now.getTime() + LEASE_MS)),
        iso(now),
        deviceId ?? null,
      ],
    );
    return rows[0] ? mapTrip(rows[0]) : undefined;
  }

  private async checkTrip(
    trip: TripRow,
    token: string,
  ): Promise<{ asked: boolean; queued: number }> {
    const step = nextStep(trip, this.now(), this.config);
    if (step.step === 'end') {
      await this.endTrip(trip, token);
      return { asked: false, queued: 0 };
    }
    if (step.step === 'wait') {
      await this.putOff(trip, token, step.phase, step.nextCheckAt);
      return { asked: false, queued: 0 };
    }
    const { evaluation, asked } = await this.evaluate(
      trip,
      step.at,
      step.lagged,
    );
    // The clock again: the answer may have taken a while.
    const now = this.now();
    if (now.getTime() >= trip.arriveBy.getTime()) {
      await this.endTrip(trip, token);
      return { asked, queued: 0 };
    }
    const decision = decideActions(trip, evaluation, now, this.config);
    return { asked, queued: await this.writeBack(trip, token, decision, now) };
  }

  /**
   * Asks the prediction about a trip as of the given instant, if the day's
   * budget allows. A check that ran late and is told "leave now" asks once
   * more as of this minute, so the departure and arrival it reports are ones
   * the user can still act on.
   */
  private async evaluate(
    trip: TripRow,
    at: Date,
    lagged: boolean,
  ): Promise<{ evaluation: Evaluation; asked: boolean }> {
    if (!(await this.spendEvaluation(false))) {
      return {
        evaluation: { outcome: 'failed', code: 'budget_exhausted' },
        asked: false,
      };
    }
    let mapped;
    // The instant the answer in hand is about.
    let asOf = at;
    try {
      mapped = planFromVerdict(await this.ask(trip, at));
    } catch (error) {
      return {
        evaluation: { outcome: 'failed', code: this.codeOf(error) },
        asked: true,
      };
    }
    if (lagged && !('noPlan' in mapped) && mapped.action === 'leave_now') {
      try {
        await this.spendEvaluation(true);
        const thisMinute = catchUpInstant(this.now());
        mapped = planFromVerdict(await this.ask(trip, thisMinute));
        asOf = thisMinute;
      } catch (error) {
        // The first answer stands: better a few minutes old than none. It
        // is stored and worded as the older answer it is.
        this.log(`Trip re-evaluation failed: ${errorName(error)}`);
      }
    }
    return {
      evaluation:
        'noPlan' in mapped
          ? { outcome: 'no_plan', reason: mapped.noPlan }
          : { outcome: 'plan', plan: mapped, asOf },
      asked: true,
    };
  }

  private async ask(trip: TripRow, at: Date): Promise<PredictionResult> {
    const verdict = getVerdict(
      {
        route: { origin: trip.origin, destination: trip.destination },
        now: at,
        preferences: {
          ...DEFAULT_PREFERENCES,
          goal: 'arrive_by',
          arriveBy: trip.arriveBy,
        },
      },
      this.providers,
    );
    // If the deadline wins, this may still fail later with nobody waiting.
    verdict.catch(() => undefined);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new EvaluationTimeoutError()),
        this.evaluationTimeoutMs,
      );
    });
    try {
      return await Promise.race([verdict, deadline]);
    } finally {
      clearTimeout(timer);
    }
  }

  private codeOf(error: unknown): ErrorCode {
    if (error instanceof NoBaselineCoverageError) {
      return 'no_coverage';
    }
    if (
      error instanceof RoutingError ||
      error instanceof EvaluationTimeoutError
    ) {
      return 'routing_unavailable';
    }
    this.log(`Trip evaluation failed: ${errorName(error)}`);
    return 'internal';
  }

  /**
   * Counts one evaluation against the day's budget. False when the budget
   * is used up, unless forced: the second question of a late check is
   * counted but never refused, since half an answer helps nobody.
   */
  private async spendEvaluation(force: boolean): Promise<boolean> {
    if (!force && this.budget.dailyEvaluations <= 0) {
      return false;
    }
    const day = this.now().toISOString().slice(0, 10);
    const { rows } = await this.db.query(
      `INSERT INTO monitor_state (id, budget_day, budget_used)
       VALUES (1, $1::date, 1)
       ON CONFLICT (id) DO UPDATE SET
         budget_day = $1::date,
         budget_used = CASE WHEN monitor_state.budget_day = $1::date
                            THEN monitor_state.budget_used + 1
                            ELSE 1 END
       WHERE $3::boolean
          OR monitor_state.budget_day IS DISTINCT FROM $1::date
          OR monitor_state.budget_used < $2::integer
       RETURNING budget_used`,
      [day, this.budget.dailyEvaluations, force],
    );
    return rows.length > 0;
  }

  // Every write for a claimed trip is conditional on the claim still being
  // good: same lease, same version of the trip, still active.
  private static readonly HELD = `id = $1::uuid AND lease_token = $2::uuid
     AND content_version = $3::integer AND status = 'active'`;

  private async endTrip(trip: TripRow, token: string): Promise<void> {
    const now = this.now();
    await this.db.transaction(async tx => {
      const { rows } = await tx.query(
        `UPDATE trips SET ${CLEAR_LEASE_SQL}
          WHERE ${TripMonitor.HELD} RETURNING id`,
        [trip.id, token, trip.contentVersion],
      );
      if (rows.length > 0) {
        await retireTrips(tx, [trip.id], 'ended', now);
      }
    });
  }

  private async putOff(
    trip: TripRow,
    token: string,
    phase: StoredPhase,
    nextCheckAt: Date,
  ): Promise<void> {
    await this.db.query(
      `UPDATE trips
          SET phase = $4::text, next_check_at = $5::timestamptz,
              updated_at = $6::timestamptz, ${CLEAR_LEASE_SQL}
        WHERE ${TripMonitor.HELD} RETURNING id`,
      [
        trip.id,
        token,
        trip.contentVersion,
        phase,
        iso(nextCheckAt),
        iso(this.now()),
      ],
    );
  }

  /**
   * Stores what a check decided and queues its alerts, in one transaction,
   * unless the claim was lost. Answers how many alerts were queued.
   */
  private async writeBack(
    trip: TripRow,
    token: string,
    { change, alerts }: Decision,
    now: Date,
  ): Promise<number> {
    return this.db.transaction(async tx => {
      const { rows } = await tx.query(
        `UPDATE trips SET
           phase = $4::text, action = $5::text,
           depart_at = $6::timestamptz, arrive_at = $7::timestamptz,
           drive_minutes = $8::integer, reason = $9::text,
           confidence = $10::text, confidence_reason = $11::text,
           notes = $12::jsonb, late_by_minutes = $13::integer,
           margin_minutes = $14::integer, source = $15::jsonb,
           evaluated_at = $16::timestamptz, no_plan_reason = $17::text,
           eval_failures = $18::integer, last_error_code = $19::text,
           last_error_at = $20::timestamptz, anchor_at = $21::timestamptz,
           monitoring_started_at = $22::timestamptz,
           heads_up_state = $23::text, heads_up_sent_at = $24::timestamptz,
           notified_depart_at = $25::timestamptz,
           candidate_depart_at = $26::timestamptz,
           notified_degraded = $27::boolean,
           last_update_at = $28::timestamptz, update_count = $29::integer,
           leave_sent_at = $30::timestamptz, late_sent_at = $31::timestamptz,
           next_check_at = $32::timestamptz,
           updated_at = $33::timestamptz, ${CLEAR_LEASE_SQL}
         WHERE ${TripMonitor.HELD} RETURNING id`,
        [
          trip.id,
          token,
          trip.contentVersion,
          change.phase,
          change.action,
          iso(change.departAt),
          iso(change.arriveAt),
          change.driveMinutes,
          change.reason,
          change.confidence,
          change.confidenceReason,
          json(change.notes),
          change.lateByMinutes,
          change.marginMinutes,
          json(change.source),
          iso(change.evaluatedAt),
          change.noPlanReason,
          change.evalFailures,
          change.lastErrorCode,
          iso(change.lastErrorAt),
          iso(change.anchorAt),
          iso(change.monitoringStartedAt),
          change.headsUpState,
          iso(change.headsUpSentAt),
          iso(change.notifiedDepartAt),
          iso(change.candidateDepartAt),
          change.notifiedDegraded,
          iso(change.lastUpdateAt),
          change.updateCount,
          iso(change.leaveSentAt),
          iso(change.lateSentAt),
          iso(change.nextCheckAt),
          iso(now),
        ],
      );
      if (rows.length === 0) {
        // Edited, cancelled, left or taken over meanwhile: the result is
        // about a trip that is no longer this one.
        return 0;
      }
      let queued = 0;
      for (const alert of alerts) {
        queued += (await this.queueAlert(tx, trip, alert, now)) ? 1 : 0;
      }
      return queued;
    });
  }

  /**
   * Puts an alert in the outbox, once. Any older alert of the trip still
   * waiting to be sent is dropped: the new one says what is true now, and a
   * device that comes back after an hour should get one alert, not a burst.
   */
  private async queueAlert(
    tx: Queryable,
    trip: TripRow,
    alert: PlannedAlert,
    now: Date,
  ): Promise<boolean> {
    const id = randomUUID();
    const { rows } = await tx.query(
      `INSERT INTO trip_notifications
              (id, trip_id, device_id, content_version, kind, dedupe_key,
               title, body, payload, status, attempts, next_attempt_at,
               expires_at, created_at)
       VALUES ($1::uuid, $2::uuid, $3::uuid, $4::integer, $5::text, $6::text,
               $7::text, $8::text, $9::jsonb, 'pending', 0, $10::timestamptz,
               $11::timestamptz, $10::timestamptz)
       ON CONFLICT (trip_id, content_version, dedupe_key) DO NOTHING
       RETURNING id`,
      [
        id,
        trip.id,
        trip.deviceId,
        trip.contentVersion,
        alert.kind,
        alert.dedupeKey,
        alert.title,
        alert.body,
        JSON.stringify(alert.payload),
        iso(now),
        iso(alert.expiresAt),
      ],
    );
    if (rows.length === 0) {
      return false;
    }
    await tx.query(
      `UPDATE trip_notifications
          SET status = 'dropped', last_error = 'superseded'
        WHERE trip_id = $1::uuid AND status = 'pending' AND id <> $2::uuid`,
      [trip.id, id],
    );
    return true;
  }

  private async deliverPass({
    deviceId,
    limit = DELIVERIES_PER_TICK,
  }: PassOptions): Promise<{
    delivered: number;
    failed: number;
    dropped: number;
  }> {
    const report = { delivered: 0, failed: 0, dropped: 0 };
    if (!this.push.configured) {
      // Nothing can be sent, so nothing is claimed. Alerts wait in case
      // push is set up, until they are no longer worth sending.
      report.dropped = await this.dropUnsendable(deviceId);
      return report;
    }
    report.dropped = await this.dropUnawaited(deviceId);
    // The limit is on what APNs is asked; deciding that an alert is not to
    // be sent costs it nothing, and is bounded separately.
    const maxClaims = Math.max(1, limit) * CLAIMS_PER_DELIVERY;
    let sends = 0;
    for (let claims = 0; claims < maxClaims && sends < limit; claims++) {
      const token = randomUUID();
      const alert = await this.claimAlert(token, deviceId);
      if (!alert) {
        break;
      }
      try {
        const { outcome, attempted } = await this.deliver(alert, token);
        sends += attempted ? 1 : 0;
        if (outcome !== 'waiting') {
          report[outcome] += 1;
        }
      } catch (error) {
        // Its lease runs out by itself, and it is tried again.
        this.log(`Alert delivery failed: ${errorName(error)}`);
        sends += 1;
      }
    }
    return report;
  }

  /**
   * Drops the alerts that waited for their device until they were of no
   * use: it never said whether it allows alerts, or never got a token.
   * These are not claimed one by one (see DEVICE_CAN_ONLY_WAIT), so they
   * are ended here, all at once.
   */
  private async dropUnawaited(deviceId: string | undefined): Promise<number> {
    const { rows } = await this.db.query(
      `UPDATE trip_notifications n
          SET status = 'dropped',
              last_error = CASE WHEN d.apns_token IS NULL
                                THEN 'no_device_token' ELSE 'expired' END,
              lease_token = NULL, lease_until = NULL
         FROM devices d
        WHERE d.id = n.device_id
          AND (n.status = 'pending'
               OR (n.status = 'sending' AND n.lease_until < $1::timestamptz))
          AND n.expires_at < $1::timestamptz
          AND ($2::uuid IS NULL OR n.device_id = $2::uuid)
          AND ${DEVICE_CAN_ONLY_WAIT}
      RETURNING n.id`,
      [iso(this.now()), deviceId ?? null],
    );
    return rows.length;
  }

  private async dropUnsendable(deviceId: string | undefined): Promise<number> {
    const { rows } = await this.db.query(
      `UPDATE trip_notifications
          SET status = 'dropped', last_error = 'push_not_configured'
        WHERE status = 'pending' AND expires_at < $1::timestamptz
          AND ($2::uuid IS NULL OR device_id = $2::uuid)
      RETURNING id`,
      [iso(this.now()), deviceId ?? null],
    );
    return rows.length;
  }

  /**
   * Takes the oldest alert that is due: one waiting for its turn, or one a
   * worker claimed and never finished (it crashed mid-send), which is sent
   * again under the same id. An alert whose device can only be waited for
   * is left where it is: it becomes due the moment the device reports.
   */
  private async claimAlert(
    token: string,
    deviceId: string | undefined,
  ): Promise<ClaimedAlert | undefined> {
    const now = this.now();
    const { rows } = await this.db.query<AlertRecord>(
      `UPDATE trip_notifications
          SET status = 'sending', lease_token = $1::uuid,
              lease_until = $2::timestamptz
        WHERE id = (
          SELECT n.id
            FROM trip_notifications n
            JOIN devices d ON d.id = n.device_id
           WHERE ((n.status = 'pending'
                   AND n.next_attempt_at <= $3::timestamptz)
               OR (n.status = 'sending' AND n.lease_until < $3::timestamptz))
             AND ($4::uuid IS NULL OR n.device_id = $4::uuid)
             AND NOT ${DEVICE_CAN_ONLY_WAIT}
           ORDER BY n.created_at, n.id
           LIMIT 1
             FOR UPDATE OF n SKIP LOCKED)
      RETURNING id, trip_id, device_id, content_version, kind,
                payload::text AS payload, attempts,
                ${epochMs('expires_at')} AS expires_at,
                ${epochMs('created_at')} AS created_at`,
      [
        token,
        iso(new Date(now.getTime() + LEASE_MS)),
        iso(now),
        deviceId ?? null,
      ],
    );
    const row = rows[0];
    return row
      ? {
          id: row.id,
          tripId: row.trip_id,
          deviceId: row.device_id,
          contentVersion: row.content_version,
          kind: row.kind,
          payload: JSON.parse(row.payload),
          attempts: row.attempts,
          expiresAt: new Date(Math.round(row.expires_at)),
          createdAt: new Date(Math.round(row.created_at)),
        }
      : undefined;
  }

  /**
   * Sends one claimed alert, or decides it should not be sent: checked
   * against the trip and the device as they are now, not as they were when
   * it was queued.
   */
  private async deliver(alert: ClaimedAlert, token: string): Promise<Handled> {
    const now = this.now();
    const { rows } = await this.db.query<AlertContext>(
      `SELECT t.status, t.content_version,
              ${epochMs('t.notified_depart_at')} AS notified_depart_at,
              ${epochMs('t.leave_sent_at')} AS leave_sent_at,
              ${epochMs('t.late_sent_at')} AS late_sent_at,
              d.apns_token, d.apns_environment, d.notifications_authorized
         FROM trips t JOIN devices d ON d.id = t.device_id
        WHERE t.id = $1::uuid`,
      [alert.tripId],
    );
    const context = rows[0];
    const unsent = async (outcome: Promise<Delivery>): Promise<Handled> => ({
      outcome: await outcome,
      attempted: false,
    });
    const drop = (reason: string): Promise<Handled> =>
      unsent(this.settle(alert, token, 'dropped', { lastError: reason }));

    if (!context || context.status !== 'active') {
      return drop('trip_inactive');
    }
    if (context.content_version !== alert.contentVersion) {
      return drop('superseded');
    }
    if (now.getTime() > alert.expiresAt.getTime()) {
      return drop(context.apns_token === null ? 'no_device_token' : 'expired');
    }
    if (context.notifications_authorized === false) {
      return drop('not_authorized');
    }
    if (this.isOutdated(alert, context)) {
      return drop('superseded');
    }
    if (
      context.apns_token === null ||
      context.notifications_authorized === null
    ) {
      // The device stopped being one that can be sent to between the claim
      // and here. It may be again, so look in a minute.
      return unsent(
        this.settle(alert, token, 'pending', {
          nextAttemptAt: new Date(now.getTime() + TOKEN_WAIT_MS),
        }),
      );
    }

    const deviceToken = context.apns_token;
    const environment = context.apns_environment ?? 'production';
    const message = {
      id: alert.id,
      deviceToken,
      environment,
      collapseId: alert.tripId,
      expiresAt: alert.expiresAt,
      payload: alert.payload,
      // Missing "time to leave" is worse than hearing it twice.
      atLeastOnce: !isInformational(alert.kind),
    };
    let result = await this.push.send(message);
    if (
      !result.ok &&
      result.kind === 'invalid_token' &&
      result.reason === 'BadDeviceToken'
    ) {
      // APNs says this of a good token sent to the wrong one of its two
      // hosts, so ask the other before believing it.
      const other = otherEnvironment(environment);
      const second = await this.push.send({ ...message, environment: other });
      if (second.ok) {
        result = second;
        await this.db.query(
          `UPDATE devices SET apns_environment = $3::text
            WHERE id = $1::uuid AND apns_token = $2::text`,
          [alert.deviceId, deviceToken, other],
        );
      } else if (second.kind === 'retryable') {
        result = second;
      }
    }
    return {
      outcome: await this.record(alert, token, deviceToken, result),
      attempted: true,
    };
  }

  /**
   * Whether an alert says something that is no longer so. A heads-up or an
   * update names a departure: it is outdated once the user is to be told
   * another one, or once the leave alert has gone. A leave alert is
   * outdated once the user was told, later, that they will be late.
   *
   * What counts is the departure the user is to be told, not the newest
   * plan. A plan that moved without an alert of its own (a later departure
   * seen only once so far, or one from a poorer source, which is never
   * announced) leaves a waiting heads-up as true as it was: dropping it
   * would leave the trip with no heads-up at all, since none is queued
   * twice. A move that is announced queues its own alert, and that drops
   * every older one still waiting.
   */
  private isOutdated(alert: ClaimedAlert, context: AlertContext): boolean {
    if (isInformational(alert.kind)) {
      const told =
        context.notified_depart_at === null
          ? null
          : new Date(Math.round(context.notified_depart_at)).toISOString();
      return context.leave_sent_at !== null || told !== alert.payload.departAt;
    }
    return (
      alert.kind === 'leave_now' &&
      context.late_sent_at !== null &&
      context.late_sent_at > alert.createdAt.getTime()
    );
  }

  /** Stores what APNs said about an alert, on the alert and the device. */
  private async record(
    alert: ClaimedAlert,
    token: string,
    deviceToken: string,
    result: PushResult,
  ): Promise<Delivery> {
    const now = this.now();
    if (result.ok) {
      const outcome = await this.settle(alert, token, 'sent', {
        sentAt: now,
        apnsId: result.apnsId ?? alert.id,
      });
      await this.db.query(
        `UPDATE devices
            SET push_failure_reason = NULL, push_failure_at = NULL
          WHERE id = $1::uuid AND push_failure_reason IS NOT NULL`,
        [alert.deviceId],
      );
      return outcome;
    }
    const reason = shortCode(result.reason);
    if (result.kind === 'invalid_token') {
      // Forget the token, unless the device has registered another since.
      // The alert waits: a fresh token may arrive while it is still useful.
      await this.db.query(
        `UPDATE devices
            SET apns_token = NULL, push_failure_reason = $3::text,
                push_failure_at = $4::timestamptz
          WHERE id = $1::uuid AND apns_token = $2::text`,
        [alert.deviceId, deviceToken, reason, iso(now)],
      );
      await this.settle(alert, token, 'pending', {
        lastError: reason,
        nextAttemptAt: new Date(now.getTime() + TOKEN_WAIT_MS),
      });
      return 'failed';
    }
    if (result.kind === 'config') {
      await this.db.query(
        `UPDATE devices
            SET push_failure_reason = $2::text,
                push_failure_at = $3::timestamptz
          WHERE id = $1::uuid`,
        [alert.deviceId, reason, iso(now)],
      );
      return this.settle(alert, token, 'failed', { lastError: reason });
    }
    if (result.unconfirmed === true && isInformational(alert.kind)) {
      // APNs may have taken it. A second heads-up is worse than none.
      return this.settle(alert, token, 'failed', {
        lastError: 'timeout_unconfirmed',
      });
    }
    const attempts = alert.attempts + 1;
    const waitSeconds =
      SEND_RETRY_SECONDS[Math.min(attempts, SEND_RETRY_SECONDS.length) - 1];
    const nextAttemptAt = new Date(now.getTime() + waitSeconds * 1000);
    const givenUp =
      attempts >= MAX_SEND_ATTEMPTS ||
      nextAttemptAt.getTime() > alert.expiresAt.getTime();
    await this.settle(alert, token, givenUp ? 'failed' : 'pending', {
      lastError: reason,
      attempts,
      nextAttemptAt: givenUp ? undefined : nextAttemptAt,
    });
    return 'failed';
  }

  /**
   * Stores what became of a claimed alert and gives up the claim. An alert
   * that vanished meanwhile (its trip ended, or its device was deleted)
   * counts as dropped.
   */
  private async settle(
    alert: ClaimedAlert,
    token: string,
    status: 'pending' | 'sent' | 'failed' | 'dropped',
    fields: {
      lastError?: string;
      attempts?: number;
      nextAttemptAt?: Date;
      sentAt?: Date;
      apnsId?: string;
    } = {},
  ): Promise<Delivery> {
    const { rows } = await this.db.query(
      `UPDATE trip_notifications
          SET status = $3::text,
              last_error = CASE WHEN $3::text = 'sent' THEN NULL
                                ELSE COALESCE($4::text, last_error) END,
              attempts = COALESCE($5::integer, attempts),
              next_attempt_at = COALESCE($6::timestamptz, next_attempt_at),
              sent_at = $7::timestamptz,
              apns_id = COALESCE($8::text, apns_id),
              lease_token = NULL, lease_until = NULL
        WHERE id = $1::uuid AND lease_token = $2::uuid
      RETURNING id`,
      [
        alert.id,
        token,
        status,
        fields.lastError ?? null,
        fields.attempts ?? null,
        iso(fields.nextAttemptAt ?? null),
        iso(fields.sentAt ?? null),
        fields.apnsId ?? null,
      ],
    );
    if (rows.length === 0) {
      return 'dropped';
    }
    if (status === 'pending') {
      return 'waiting';
    }
    return status === 'sent' ? 'delivered' : status;
  }
}
