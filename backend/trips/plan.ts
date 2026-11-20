import { PredictionResult } from '../prediction';
import { LOCAL_TIME_ZONE } from '../prediction/calendar';
import { Confidence, PredictionSource } from '../prediction/types';
import { addMinutes, MINUTE_MS, minutesBetween } from '../util/time';
import {
  MonitorConfig,
  MONITOR_POLL_MINUTES,
  PLANNING_HORIZON_MINUTES,
} from './config';
import { StoredPhase, TripRow } from './store';
import { AlertKind, ErrorCode } from './types';

/**
 * The monitor's decisions, as pure functions: what to do with a trip that is
 * due for a check, given the clock and what the prediction said. Nothing here
 * reads a clock, a database or the network, so every rule can be tested with
 * exact times. See monitor.ts for the part that does the reading and writing.
 */

/** A departure the backend recommends for a trip. */
export interface Plan {
  action: 'leave_now' | 'wait' | 'leave_later';
  departAt: Date;
  arriveAt: Date;
  driveMinutes: number;
  /** The verdict's sentence, for the app. It never goes into an alert. */
  reason: string;
  confidence: Confidence;
  confidenceReason: string;
  notes: string[];
  /** Set when even leaving at departAt misses the arrival target. */
  lateByMinutes?: number;
  /** Minutes to spare before the arrival target. */
  marginMinutes?: number;
  source: PredictionSource;
}

/** The backend has no departure to recommend yet, and says why. */
export interface NoPlan {
  noPlan: string;
}

/** What became of asking the prediction about a trip. */
export type Evaluation =
  | {
      outcome: 'plan';
      plan: Plan;
      /**
       * The instant the prediction was asked about, which the plan's
       * sentences ("leaving in 30 minutes") are relative to. It can be up to
       * a slot before the check itself. Absent: the moment of the check.
       */
      asOf?: Date;
    }
  | { outcome: 'no_plan'; reason: string }
  | { outcome: 'failed'; code: ErrorCode };

/** What to do with a trip that is due, before anything is asked. */
export type NextStep =
  /** Its arrival time has passed: monitoring is over. */
  | { step: 'end' }
  /** Nothing to ask yet, or nothing left to ask: only when to look again. */
  | { step: 'wait'; phase: StoredPhase; nextCheckAt: Date }
  /** Ask the prediction, as of the given instant. */
  | { step: 'evaluate'; at: Date; lagged: boolean };

/** The columns of a trip the monitor writes after a check. */
export type TripChange = Pick<
  TripRow,
  | 'phase'
  | 'action'
  | 'departAt'
  | 'arriveAt'
  | 'driveMinutes'
  | 'reason'
  | 'confidence'
  | 'confidenceReason'
  | 'notes'
  | 'lateByMinutes'
  | 'marginMinutes'
  | 'source'
  | 'evaluatedAt'
  | 'noPlanReason'
  | 'evalFailures'
  | 'lastErrorCode'
  | 'lastErrorAt'
  | 'anchorAt'
  | 'monitoringStartedAt'
  | 'headsUpState'
  | 'headsUpSentAt'
  | 'notifiedDepartAt'
  | 'candidateDepartAt'
  | 'notifiedDegraded'
  | 'lastUpdateAt'
  | 'updateCount'
  | 'leaveSentAt'
  | 'lateSentAt'
  | 'nextCheckAt'
>;

/** What an alert carries to the phone: the APNs payload. */
export interface AlertPayload {
  aps: {
    alert: { title: string; body: string };
    sound: 'default';
    'thread-id': string;
    category: typeof ALERT_CATEGORY;
  };
  /** The app's id for the trip. */
  tripId: string;
  kind: AlertKind;
  departAt: string;
  arriveBy: string;
}

/** An alert to put in the outbox. */
export interface PlannedAlert {
  kind: AlertKind;
  /** Unique for the trip's version, so the same alert is never queued twice. */
  dedupeKey: string;
  title: string;
  body: string;
  /** When the alert stops being useful. */
  expiresAt: Date;
  payload: AlertPayload;
}

/** What a check decided: the trip's new state and at most one alert. */
export interface Decision {
  change: TripChange;
  alerts: PlannedAlert[];
}

/** The notification category the app registers its "I've left" action for. */
export const ALERT_CATEGORY = 'WAIT_IT_OUT_TRIP';

/** A trip with no departure to recommend is asked about again this often. */
export const NO_PLAN_RECHECK_MINUTES = 30;

/**
 * How long to wait after each failure in a row before asking again. It
 * grows, because every failed evaluation is still counted against the day's
 * budget, which every trip shares: a route that never answers must not use
 * it up. While a trip is actively monitored the wait is never longer than
 * its normal check, so a recovery is seen within one slot.
 */
export const FAILURE_BACKOFF_MINUTES = [1, 2, 5, 15, 30];

/**
 * How long to wait when asking again soon cannot help: the route has no
 * traffic data, or the day's evaluations are used up.
 */
export const LONG_BACKOFF_MINUTES = 30;

/** A leave alert is worth delivering for this long after the departure. */
const LEAVE_ALERT_USEFUL_MINUTES = 30;

/** Every alert is given at least this long to be delivered. */
const MIN_ALERT_LIFETIME_MINUTES = 10;

/**
 * Maps the backend's verdict to the departure to store for a trip. This is
 * a mapping and nothing more: the departure is always one the verdict gave,
 * never one worked out here from a drive time.
 */
export function planFromVerdict({
  verdict,
  source,
}: PredictionResult): Plan | NoPlan {
  if (verdict.action === 'no_rush') {
    return { noPlan: verdict.reason };
  }
  const option =
    verdict.action === 'leave_now' ? verdict.leaveNow : verdict.recommended;
  const marginMinutes = verdict.deadline?.marginMinutes;
  return {
    action: verdict.action,
    departAt: option.departAt,
    arriveAt: option.arriveAt,
    driveMinutes: option.driveMinutes,
    reason: verdict.reason,
    confidence: verdict.confidence,
    confidenceReason: verdict.confidenceReason,
    notes: verdict.notes,
    ...(verdict.lateByMinutes === undefined
      ? {}
      : { lateByMinutes: verdict.lateByMinutes }),
    ...(marginMinutes === undefined ? {} : { marginMinutes }),
    source,
  };
}

const POLL_MS = MONITOR_POLL_MINUTES * MINUTE_MS;

const floorToMinute = (date: Date): Date =>
  new Date(Math.floor(date.getTime() / MINUTE_MS) * MINUTE_MS);

/**
 * The lattice of a trip: the instants a whole number of slots before or
 * after its anchor. These give the one on or before an instant, the first
 * one after it, and the first one on or after it.
 */
export function latticeAtOrBefore(anchor: Date, instant: Date): Date {
  const slots = Math.floor((instant.getTime() - anchor.getTime()) / POLL_MS);
  return new Date(anchor.getTime() + slots * POLL_MS);
}

export function latticeAfter(anchor: Date, instant: Date): Date {
  return new Date(latticeAtOrBefore(anchor, instant).getTime() + POLL_MS);
}

export function latticeAtOrAfter(anchor: Date, instant: Date): Date {
  const slots = Math.ceil((instant.getTime() - anchor.getTime()) / POLL_MS);
  return new Date(anchor.getTime() + slots * POLL_MS);
}

/**
 * The instant to ask the prediction about.
 *
 * Within three hours the backend's departure slots sit every 15 minutes from
 * the instant it is asked about, so the departure it recommends is always on
 * a 15-minute lattice through that instant. Asked at arbitrary instants, the
 * recommendation would jump by up to a slot with traffic unchanged. So once
 * a trip has a recommended departure (its anchor) it is only ever asked
 * about instants on the lattice through it: one answer can then be compared
 * with the next, and a change means traffic changed.
 *
 * With an anchor that is the last lattice instant, which is less than a slot
 * ago; lagged says the check came later than maxLagSeconds after it. Without
 * one, or when the lattice instant lies outside the planning horizon, it is
 * now, to the minute.
 */
export function evaluationInstant(
  trip: Pick<TripRow, 'anchorAt' | 'arriveBy'>,
  now: Date,
  config: MonitorConfig,
): { at: Date; lagged: boolean } {
  if (trip.anchorAt !== null) {
    const at = latticeAtOrBefore(trip.anchorAt, now);
    const inHorizon =
      trip.arriveBy.getTime() - at.getTime() <=
      PLANNING_HORIZON_MINUTES * MINUTE_MS;
    if (inHorizon) {
      const lagged = now.getTime() - at.getTime() > config.maxLagSeconds * 1000;
      return { at, lagged };
    }
  }
  return { at: floorToMinute(now), lagged: false };
}

/** The instant a late check is asked about again: now, to the minute. */
export const catchUpInstant = floorToMinute;

/** What the monitor needs of a stored or a new recommendation. */
interface KnownPlan {
  action: Plan['action'];
  departAt: Date;
  arriveAt: Date;
  lateByMinutes?: number;
  source: PredictionSource | null;
  evaluatedAt: Date;
}

const storedPlan = (trip: TripRow): KnownPlan | null =>
  trip.action !== null &&
  trip.departAt !== null &&
  trip.arriveAt !== null &&
  trip.evaluatedAt !== null
    ? {
        action: trip.action,
        departAt: trip.departAt,
        arriveAt: trip.arriveAt,
        ...(trip.lateByMinutes === null
          ? {}
          : { lateByMinutes: trip.lateByMinutes }),
        source: trip.source,
        evaluatedAt: trip.evaluatedAt,
      }
    : null;

/** Whether a trip has a recommendation stored. */
export const hasStoredPlan = (trip: TripRow): boolean =>
  storedPlan(trip) !== null;

/**
 * What to do with a due trip before asking anything (steps 0, 1 and 5 of the
 * state machine). All by the real clock.
 *
 * - Past its arrival time: it is over.
 * - Farther from its arrival time than a departure can be planned for: it
 *   waits, without a provider call, for the moment it enters the horizon.
 * - Its leave alert has gone out: there is nothing more to say, so no
 *   provider is asked again and it waits for its arrival time, to be ended.
 *   (Unless it has no recommendation stored, as after being cancelled and
 *   added back: then it is asked about until it has one, so the app has one
 *   to show.)
 * - Otherwise: ask, as of the trip's lattice instant.
 */
export function nextStep(
  trip: TripRow,
  now: Date,
  config: MonitorConfig,
): NextStep {
  const untilArrivalMs = trip.arriveBy.getTime() - now.getTime();
  if (untilArrivalMs <= 0) {
    return { step: 'end' };
  }
  if (untilArrivalMs > PLANNING_HORIZON_MINUTES * MINUTE_MS) {
    return {
      step: 'wait',
      phase: 'scheduled',
      nextCheckAt: addMinutes(trip.arriveBy, -PLANNING_HORIZON_MINUTES),
    };
  }
  if (trip.leaveSentAt !== null && hasStoredPlan(trip)) {
    return { step: 'wait', phase: trip.phase, nextCheckAt: trip.arriveBy };
  }
  return { step: 'evaluate', ...evaluationInstant(trip, now, config) };
}

/**
 * A time of day for an alert, such as "7:30 AM", on the trip's own clock. A
 * zone this server does not know falls back to the campus's.
 */
export function clockTime(at: Date, timeZone: string): string {
  const format = (zone: string): string =>
    new Intl.DateTimeFormat('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      timeZone: zone,
    }).format(at);
  let text: string;
  try {
    text = format(timeZone);
  } catch {
    text = format(LOCAL_TIME_ZONE);
  }
  // Newer Node puts a narrow no-break space before AM or PM.
  return text.replace(/ /g, ' ');
}

/**
 * Whether a recommendation rests on less than the full picture: no live
 * conditions, or a fallback source. A plan like that may look rosier than
 * the one it replaces only because it knows less.
 */
export const isDegraded = (source: PredictionSource | null): boolean =>
  source === null || !source.live || source.fallback;

const laterOf = (a: Date, b: Date): Date =>
  a.getTime() >= b.getTime() ? a : b;

const earlierOf = (a: Date, b: Date): Date =>
  a.getTime() <= b.getTime() ? a : b;

const sameInstant = (a: Date | null, b: Date): boolean =>
  a !== null && a.getTime() === b.getTime();

/**
 * Builds one alert. The texts state times and nothing else: they never
 * promise that an alert will come or that the user will arrive on time, and
 * never say why traffic changed.
 */
function alertFor(
  trip: TripRow,
  kind: AlertKind,
  dedupeKey: string,
  departAt: Date,
  expiresAt: Date,
  title: string,
  body: string,
): PlannedAlert {
  return {
    kind,
    dedupeKey,
    title,
    body,
    expiresAt,
    payload: {
      aps: {
        alert: { title, body },
        sound: 'default',
        'thread-id': `trip-${trip.clientId}`,
        category: ALERT_CATEGORY,
      },
      tripId: trip.clientId,
      kind,
      departAt: departAt.toISOString(),
      arriveBy: trip.arriveBy.toISOString(),
    },
  };
}

function headsUpAlert(trip: TripRow, plan: KnownPlan): PlannedAlert {
  const clock = (at: Date) => clockTime(at, trip.timeZone);
  return alertFor(
    trip,
    'heads_up',
    'heads_up',
    plan.departAt,
    plan.departAt,
    `Heads up: ${trip.title}`,
    `Plan to leave around ${clock(plan.departAt)} to arrive by ${clock(
      trip.arriveBy,
    )}. We'll keep checking traffic.`,
  );
}

function updateAlert(
  trip: TripRow,
  plan: KnownPlan,
  previous: Date,
  number: number,
): PlannedAlert {
  const clock = (at: Date) => clockTime(at, trip.timeZone);
  const earlier = plan.departAt.getTime() < previous.getTime();
  return alertFor(
    trip,
    'update',
    `update:${number}`,
    plan.departAt,
    plan.departAt,
    earlier
      ? `Leave earlier for ${trip.title}`
      : `Updated plan for ${trip.title}`,
    `Leave at ${clock(plan.departAt)} instead of ${clock(
      previous,
    )}. Predicted arrival ${clock(plan.arriveAt)}; your target is ${clock(
      trip.arriveBy,
    )}.`,
  );
}

/** When a leave alert for the given departure stops being worth sending. */
const leaveAlertExpiry = (trip: TripRow, departAt: Date, now: Date): Date =>
  laterOf(
    earlierOf(trip.arriveBy, addMinutes(departAt, LEAVE_ALERT_USEFUL_MINUTES)),
    addMinutes(now, MIN_ALERT_LIFETIME_MINUTES),
  );

/**
 * How a leave alert may be worded.
 *
 * - current: the plan is one to act on as it stands.
 * - stale: the departure is now, but the plan is old; say since when.
 * - overdue: the departure passed a while ago and nothing newer is known,
 *   so the arrival the plan predicted cannot be promised any more. Only the
 *   departure that was planned and the target are stated.
 */
type LeaveWording = 'current' | 'stale' | 'overdue';

function leaveAlert(
  trip: TripRow,
  plan: KnownPlan,
  now: Date,
  wording: LeaveWording,
): PlannedAlert {
  const clock = (at: Date) => clockTime(at, trip.timeZone);
  const target = `Your target is ${clock(trip.arriveBy)}.`;
  const since = `Traffic could not be re-checked since ${clock(
    plan.evaluatedAt,
  )}.`;
  const leave = `Leave at ${clock(plan.departAt)} to arrive around ${clock(
    plan.arriveAt,
  )}.`;
  const bodies: Record<LeaveWording, string> = {
    current: `${leave} ${target}`,
    stale: `${leave} ${target} ${since}`,
    overdue: `You planned to leave at ${clock(
      plan.departAt,
    )}. ${target} ${since}`,
  };
  return alertFor(
    trip,
    'leave_now',
    'leave_now',
    plan.departAt,
    leaveAlertExpiry(trip, plan.departAt, now),
    `Time to leave for ${trip.title}`,
    bodies[wording],
  );
}

/**
 * The leave alert for a departure the user was told, sent while the newest
 * plan is a later one from a poorer source (see `heldDeparture`). It names
 * no arrival: the one predicted with full data may no longer be stored, and
 * the newer plan's rests on less.
 */
function heldLeaveAlert(trip: TripRow, heldAt: Date, now: Date): PlannedAlert {
  const clock = (at: Date) => clockTime(at, trip.timeZone);
  return alertFor(
    trip,
    'leave_now',
    'leave_now',
    heldAt,
    leaveAlertExpiry(trip, heldAt, now),
    `Time to leave for ${trip.title}`,
    `Leave at ${clock(heldAt)}. Your target is ${clock(
      trip.arriveBy,
    )}. Traffic could not be fully re-checked.`,
  );
}

function lateAlert(
  trip: TripRow,
  plan: KnownPlan,
  lateByMinutes: number,
  now: Date,
): PlannedAlert {
  const clock = (at: Date) => clockTime(at, trip.timeZone);
  return alertFor(
    trip,
    'late',
    'late',
    plan.departAt,
    laterOf(trip.arriveBy, addMinutes(now, MIN_ALERT_LIFETIME_MINUTES)),
    `Running late for ${trip.title}`,
    `Leaving at ${clock(
      plan.departAt,
    )}, you may arrive about ${lateByMinutes} minute${
      lateByMinutes === 1 ? '' : 's'
    } after ${clock(trip.arriveBy)}.`,
  );
}

const changeOf = (trip: TripRow): TripChange => ({
  phase: trip.phase,
  action: trip.action,
  departAt: trip.departAt,
  arriveAt: trip.arriveAt,
  driveMinutes: trip.driveMinutes,
  reason: trip.reason,
  confidence: trip.confidence,
  confidenceReason: trip.confidenceReason,
  notes: trip.notes,
  lateByMinutes: trip.lateByMinutes,
  marginMinutes: trip.marginMinutes,
  source: trip.source,
  evaluatedAt: trip.evaluatedAt,
  noPlanReason: trip.noPlanReason,
  evalFailures: trip.evalFailures,
  lastErrorCode: trip.lastErrorCode,
  lastErrorAt: trip.lastErrorAt,
  anchorAt: trip.anchorAt,
  monitoringStartedAt: trip.monitoringStartedAt,
  headsUpState: trip.headsUpState,
  headsUpSentAt: trip.headsUpSentAt,
  notifiedDepartAt: trip.notifiedDepartAt,
  candidateDepartAt: trip.candidateDepartAt,
  notifiedDegraded: trip.notifiedDegraded,
  lastUpdateAt: trip.lastUpdateAt,
  updateCount: trip.updateCount,
  leaveSentAt: trip.leaveSentAt,
  lateSentAt: trip.lateSentAt,
  nextCheckAt: trip.nextCheckAt,
});

/** Takes what the prediction said into the trip's stored state. */
function recordEvaluation(
  change: TripChange,
  evaluation: Evaluation,
  now: Date,
): void {
  if (evaluation.outcome === 'failed') {
    change.evalFailures += 1;
    change.lastErrorCode = evaluation.code;
    change.lastErrorAt = now;
    return;
  }
  change.evalFailures = 0;
  change.lastErrorCode = null;
  change.lastErrorAt = null;
  if (evaluation.outcome === 'no_plan') {
    change.noPlanReason = evaluation.reason;
    return;
  }
  const { plan } = evaluation;
  change.action = plan.action;
  change.departAt = plan.departAt;
  change.arriveAt = plan.arriveAt;
  change.driveMinutes = Math.round(plan.driveMinutes);
  change.reason = plan.reason;
  change.confidence = plan.confidence;
  change.confidenceReason = plan.confidenceReason;
  change.notes = plan.notes;
  change.lateByMinutes =
    plan.lateByMinutes === undefined ? null : Math.round(plan.lateByMinutes);
  change.marginMinutes =
    plan.marginMinutes === undefined ? null : Math.round(plan.marginMinutes);
  change.source = plan.source;
  // The instant the plan is as of, so that its sentences, which are
  // relative to that instant, are never taken to be newer than they are.
  change.evaluatedAt = evaluation.asOf ?? now;
  change.noPlanReason = null;
  // The lattice follows the recommended departure from here on.
  change.anchorAt = plan.departAt;
}

/**
 * Rule 4d: whether a departure that moved since the user was last told is
 * worth an update.
 *
 * An earlier departure is announced at once: there is less time than the
 * user thinks. A later one is announced only when two checks in a row agree
 * on it, and never when it comes from a poorer source than the departure it
 * would replace, so traffic sitting on a slot boundary, or a live feed that
 * dropped out, cannot send the user back and forth. On the 15-minute lattice
 * a shift is always zero or whole slots, so it is this that stops flapping,
 * not the size of the threshold.
 */
function updateRule(
  trip: TripRow,
  change: TripChange,
  plan: KnownPlan,
  now: Date,
  config: MonitorConfig,
): PlannedAlert | undefined {
  const previous = change.notifiedDepartAt;
  if (previous === null) {
    return undefined;
  }
  const shift = minutesBetween(previous, plan.departAt);
  if (Math.abs(shift) < config.meaningfulShiftMinutes) {
    change.candidateDepartAt = null;
    return undefined;
  }
  const degraded = isDegraded(plan.source);
  if (shift > 0) {
    if (degraded && change.notifiedDegraded === false) {
      change.candidateDepartAt = null;
      return undefined;
    }
    if (!sameInstant(change.candidateDepartAt, plan.departAt)) {
      change.candidateDepartAt = plan.departAt;
      return undefined;
    }
  } else {
    change.candidateDepartAt = null;
  }
  // Whichever was said last: an update, the heads-up or the late alert.
  const lastSaidAt =
    change.lastUpdateAt !== null && change.lateSentAt !== null
      ? laterOf(change.lastUpdateAt, change.lateSentAt)
      : change.lastUpdateAt ?? change.lateSentAt;
  const tooSoon =
    lastSaidAt !== null &&
    now.getTime() - lastSaidAt.getTime() <
      config.updateMinIntervalMinutes * MINUTE_MS;
  if (change.updateCount >= config.maxUpdatesPerTrip || tooSoon) {
    // A later departure seen twice stays confirmed until it can be said.
    return undefined;
  }
  change.updateCount += 1;
  change.notifiedDepartAt = plan.departAt;
  change.notifiedDegraded = degraded;
  change.lastUpdateAt = now;
  change.candidateDepartAt = null;
  return updateAlert(trip, plan, previous, change.updateCount);
}

/**
 * The departure the leave alert is held to, if any.
 *
 * Rule 4d never announces a later departure that comes from a poorer source
 * than the one the user was told (the live feed dropped out, or a fallback
 * answered). Such a plan is stored, so the app shows it with its source,
 * but it must not postpone "time to leave" either: the user still believes
 * the departure they were told, and the later one may only look possible
 * because it knows less. So the leave alert stays due at what was told,
 * whether that plan is the one this check just got or the one it found
 * stored after a check that failed. Somebody already told they are late is
 * not held to anything.
 */
function heldDeparture(
  change: TripChange,
  plan: Pick<KnownPlan, 'departAt' | 'source'>,
): Date | null {
  const told = change.notifiedDepartAt;
  return told !== null &&
    change.notifiedDegraded === false &&
    change.lateSentAt === null &&
    isDegraded(plan.source) &&
    plan.departAt.getTime() > told.getTime()
    ? told
    : null;
}

/**
 * The alert rules, first match wins, so a check queues one alert at most.
 * fresh says the plan is the one this check just got; otherwise it is
 * the stored one, after a check that failed or had no departure to give, and
 * only what the clock alone decides can be said (never an update, and no
 * heads-up from a plan that has gone stale).
 */
function alertRule(
  trip: TripRow,
  change: TripChange,
  plan: KnownPlan,
  fresh: boolean,
  now: Date,
  config: MonitorConfig,
): PlannedAlert | undefined {
  if (change.leaveSentAt !== null) {
    return undefined;
  }
  const { departAt } = plan;
  const skipHeadsUp = (): void => {
    if (change.headsUpState === 'pending') {
      change.headsUpState = 'skipped';
    }
  };
  const stale =
    now.getTime() - plan.evaluatedAt.getTime() >
    config.staleAfterMinutes * MINUTE_MS;
  const heldAt = heldDeparture(change, plan);
  const due = now.getTime() >= (heldAt ?? departAt).getTime();

  // 4a. Even leaving now misses the target. Said once.
  if (fresh && plan.lateByMinutes !== undefined) {
    if (change.lateSentAt !== null) {
      return undefined;
    }
    change.lateSentAt = now;
    change.notifiedDepartAt = departAt;
    change.notifiedDegraded = isDegraded(plan.source);
    change.candidateDepartAt = null;
    skipHeadsUp();
    return lateAlert(trip, plan, plan.lateByMinutes, now);
  }

  // 4b. Time to leave: the backend says so, or the departure has come.
  // From a stored plan it is only said to somebody not yet told they are
  // late, since nothing newer says they could still make it.
  const leaveNow = fresh
    ? plan.action === 'leave_now' || due
    : due && change.lateSentAt === null;
  if (leaveNow) {
    change.leaveSentAt = now;
    change.candidateDepartAt = null;
    skipHeadsUp();
    if (heldAt !== null && now.getTime() < departAt.getTime()) {
      return heldLeaveAlert(trip, heldAt, now);
    }
    // A departure that passed more than a late check's allowance ago, with
    // nothing newer known: from a stored plan after a failed check, or from
    // a late check whose second question failed. Counted in whole minutes,
    // as the alert states its times and as the prediction is asked.
    const overdue =
      floorToMinute(now).getTime() - departAt.getTime() >
      config.maxLagSeconds * 1000;
    const wording = !fresh && stale ? 'stale' : 'current';
    return leaveAlert(trip, plan, now, overdue ? 'overdue' : wording);
  }

  // 4c. The one heads-up, also for a trip created or changed inside the
  // window.
  const headsUpDue =
    now.getTime() >= addMinutes(departAt, -config.headsUpLeadMinutes).getTime();
  if (
    change.headsUpState === 'pending' &&
    change.lateSentAt === null &&
    headsUpDue &&
    (fresh || !stale)
  ) {
    change.headsUpState = 'sent';
    change.headsUpSentAt = now;
    change.notifiedDepartAt = departAt;
    change.notifiedDegraded = isDegraded(plan.source);
    change.lastUpdateAt = now;
    change.candidateDepartAt = null;
    return headsUpAlert(trip, plan);
  }

  // 4d. The departure moved since the user was last told.
  if (fresh && (change.headsUpState === 'sent' || change.lateSentAt !== null)) {
    return updateRule(trip, change, plan, now, config);
  }
  return undefined;
}

function backoffMinutes(
  code: ErrorCode,
  failures: number,
  monitoring: boolean,
): number {
  if (code === 'no_coverage' || code === 'budget_exhausted') {
    return LONG_BACKOFF_MINUTES;
  }
  const index = Math.min(failures, FAILURE_BACKOFF_MINUTES.length) - 1;
  const minutes = FAILURE_BACKOFF_MINUTES[Math.max(0, index)];
  return monitoring ? Math.min(minutes, MONITOR_POLL_MINUTES) : minutes;
}

/**
 * When to look at the trip again. Always after now and never after its
 * arrival time, which is when it is ended.
 */
function nextCheckFor(
  trip: TripRow,
  change: TripChange,
  evaluation: Evaluation,
  now: Date,
  config: MonitorConfig,
): Date {
  const departAt = change.departAt;
  // Rule 5: after the leave alert there is nothing left but to end it. A
  // trip added back after its leave alert has no plan to show until it is
  // asked about successfully, so until then it is asked again like any other.
  if (change.leaveSentAt !== null && departAt !== null) {
    return trip.arriveBy;
  }
  const moments: Date[] = [];
  if (departAt !== null) {
    // A leave alert held to an earlier departure is due then. After a
    // successful check that is a lattice instant anyway; this makes it not
    // depend on that, and wakes a failing trip for it too.
    const heldAt = heldDeparture(change, { departAt, source: change.source });
    if (heldAt !== null) {
      moments.push(heldAt);
    }
  }
  if (evaluation.outcome === 'plan' && departAt !== null) {
    moments.push(
      change.phase === 'monitoring'
        ? latticeAfter(departAt, now)
        : // The first lattice instant of active monitoring.
          latticeAtOrAfter(
            departAt,
            addMinutes(departAt, -config.monitorLeadMinutes),
          ),
    );
  } else {
    if (evaluation.outcome === 'failed') {
      moments.push(
        addMinutes(
          now,
          backoffMinutes(
            evaluation.code,
            change.evalFailures,
            change.phase === 'monitoring',
          ),
        ),
      );
    } else if (departAt === null) {
      moments.push(addMinutes(now, NO_PLAN_RECHECK_MINUTES));
    } else {
      moments.push(latticeAfter(change.anchorAt ?? departAt, now));
    }
    if (departAt !== null) {
      // What the clock alone decides must not wait for a retry.
      if (change.lateSentAt === null) {
        moments.push(departAt);
      }
      if (change.headsUpState === 'pending') {
        moments.push(addMinutes(departAt, -config.headsUpLeadMinutes));
      }
      if (change.phase !== 'monitoring') {
        moments.push(addMinutes(departAt, -config.monitorLeadMinutes));
      }
    }
  }
  return moments
    .filter(moment => moment.getTime() > now.getTime())
    .reduce(earlierOf, trip.arriveBy);
}

/**
 * Decides what a check does to a trip: its new state and at most one alert
 * (steps 2 to 5 of the state machine). now is the real clock at the moment
 * of deciding, and every threshold is measured against it.
 *
 * - The evaluation is recorded: a plan replaces the stored one and clears
 *   the last failure; a failure is counted; "no departure yet" keeps
 *   whatever plan there was.
 * - The phase and alert rules then run on the plan in effect, the new one
 *   or else the stored one. A trip is actively monitored from monitorLead
 *   before its departure, and stays so even if the departure later moves
 *   away.
 * - Then the next check is set.
 */
export function decideActions(
  trip: TripRow,
  evaluation: Evaluation,
  now: Date,
  config: MonitorConfig,
): Decision {
  const change = changeOf(trip);
  recordEvaluation(change, evaluation, now);

  const plan: KnownPlan | null =
    evaluation.outcome === 'plan'
      ? { ...evaluation.plan, evaluatedAt: evaluation.asOf ?? now }
      : storedPlan(trip);
  const fresh = evaluation.outcome === 'plan';

  const alerts: PlannedAlert[] = [];
  if (plan === null) {
    if (change.phase !== 'monitoring') {
      change.phase = 'planning';
    }
  } else {
    if (change.phase !== 'monitoring') {
      const monitoringFrom = addMinutes(
        plan.departAt,
        -config.monitorLeadMinutes,
      );
      if (now.getTime() >= monitoringFrom.getTime()) {
        change.phase = 'monitoring';
        change.monitoringStartedAt = now;
      } else {
        change.phase = 'planned';
      }
    }
    const alert = alertRule(trip, change, plan, fresh, now, config);
    if (alert) {
      alerts.push(alert);
    }
  }
  change.nextCheckAt = nextCheckFor(trip, change, evaluation, now, config);
  return { change, alerts };
}
