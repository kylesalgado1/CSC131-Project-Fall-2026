// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { getVerdict } from '../../prediction';
import { FakeBaselineProvider } from '../../prediction/providers/fake';
import { NoLiveConditions } from '../../prediction/providers/live';
import { DEFAULT_PREFERENCES, PredictionSource } from '../../prediction/types';
import { DEFAULT_MONITOR_CONFIG, MonitorConfig } from '../config';
import {
  clockTime,
  decideActions,
  Evaluation,
  evaluationInstant,
  hasStoredPlan,
  isDegraded,
  latticeAfter,
  latticeAtOrAfter,
  latticeAtOrBefore,
  nextStep,
  Plan,
  planFromVerdict,
} from '../plan';
import { TripRow } from '../store';

// Friday 20 November 2026 on the Pacific clock, which is what the alerts
// of a Los Angeles trip show.
const t = (clock: string) => new Date(`2026-11-20T${clock}:00-08:00`);
const seconds = (n: number, from: Date) => new Date(from.getTime() + n * 1000);

const ARRIVE_BY = t('08:00');
const DEPART_AT = t('07:30');
const ARRIVE_AT = t('07:50');
const CONFIG = DEFAULT_MONITOR_CONFIG;

const LIVE: PredictionSource = {
  baseline: 'tomtom',
  fallback: false,
  live: true,
};
const NO_LIVE: PredictionSource = {
  baseline: 'tomtom',
  fallback: false,
  live: false,
};
const FALLBACK: PredictionSource = {
  baseline: 'pems',
  fallback: true,
  live: true,
};

/** A trip just stored: inside the horizon, waiting for its first plan. */
const row = (over: Partial<TripRow> = {}): TripRow => ({
  id: '0b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d',
  deviceId: '7b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d',
  clientId: 'A1B2C3@2026-11-20',
  title: 'Chem lab',
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  destinationName: 'Sac State',
  arriveBy: ARRIVE_BY,
  startsAt: null,
  timeZone: 'America/Los_Angeles',
  status: 'active',
  phase: 'planning',
  contentVersion: 1,
  action: null,
  departAt: null,
  arriveAt: null,
  driveMinutes: null,
  reason: null,
  confidence: null,
  confidenceReason: null,
  notes: null,
  lateByMinutes: null,
  marginMinutes: null,
  source: null,
  evaluatedAt: null,
  noPlanReason: null,
  evalFailures: 0,
  lastErrorCode: null,
  lastErrorAt: null,
  anchorAt: null,
  monitoringStartedAt: null,
  headsUpState: 'pending',
  headsUpSentAt: null,
  notifiedDepartAt: null,
  candidateDepartAt: null,
  notifiedDegraded: null,
  lastUpdateAt: null,
  updateCount: 0,
  leaveSentAt: null,
  lateSentAt: null,
  departedAt: null,
  nextCheckAt: t('05:00'),
  leaseToken: null,
  leaseUntil: null,
  createdAt: t('05:00'),
  updatedAt: t('05:00'),
  endedAt: null,
  ...over,
});

/** The recommendation "leave at 7:30, arrive 7:50", as the backend gives it. */
const plan = (over: Partial<Plan> = {}): Plan => ({
  action: 'leave_later',
  departAt: DEPART_AT,
  arriveAt: ARRIVE_AT,
  driveMinutes: 20,
  reason:
    'Leaving in 2 hr 30 min still gets you there with 10 minutes to spare.',
  confidence: 'High',
  confidenceReason: 'Plenty of data for this route.',
  notes: [],
  marginMinutes: 10,
  source: LIVE,
  ...over,
});

const got = (over: Partial<Plan> = {}): Evaluation => ({
  outcome: 'plan',
  plan: plan(over),
});

/** "Leave now" as the backend gives it when asked at the given instant. */
const leaveNowAt = (at: Date, over: Partial<Plan> = {}): Evaluation =>
  got({
    action: 'leave_now',
    departAt: at,
    arriveAt: new Date(at.getTime() + 20 * 60_000),
    ...over,
  });

const failed = (
  code:
    | 'routing_unavailable'
    | 'no_coverage'
    | 'internal'
    | 'budget_exhausted' = 'routing_unavailable',
): Evaluation => ({ outcome: 'failed', code });

/** A trip that has the 7:30 plan stored, made at the given time. */
const planned = (evaluatedAt: Date, over: Partial<TripRow> = {}): TripRow =>
  row({
    phase: 'planned',
    action: 'leave_later',
    departAt: DEPART_AT,
    arriveAt: ARRIVE_AT,
    driveMinutes: 20,
    reason: 'Leaving later still gets you there.',
    confidence: 'High',
    confidenceReason: 'Plenty of data for this route.',
    notes: [],
    marginMinutes: 10,
    source: LIVE,
    evaluatedAt,
    anchorAt: DEPART_AT,
    ...over,
  });

/** The same trip once it is monitored and its heads-up has been queued. */
const headsUpSent = (over: Partial<TripRow> = {}): TripRow =>
  planned(t('06:00'), {
    phase: 'monitoring',
    monitoringStartedAt: t('05:30'),
    headsUpState: 'sent',
    headsUpSentAt: t('06:00'),
    notifiedDepartAt: DEPART_AT,
    notifiedDegraded: false,
    lastUpdateAt: t('06:00'),
    ...over,
  });

const decide = (
  trip: TripRow,
  evaluation: Evaluation,
  now: Date,
  config: MonitorConfig = CONFIG,
) => decideActions(trip, evaluation, now, config);

/**
 * The same answer, as one about an earlier instant than the check: what a
 * check that came late, or was retried, gets.
 */
const asOf = (at: Date, evaluation: Evaluation): Evaluation =>
  evaluation.outcome === 'plan' ? { ...evaluation, asOf: at } : evaluation;

/** The trip as the next check finds it, after a decision is stored. */
const after = (trip: TripRow, change: object): TripRow => ({
  ...trip,
  ...change,
});

describe('planFromVerdict', () => {
  const route = {
    origin: { lat: 38.2383, lng: -122.0402 },
    destination: { lat: 38.5593, lng: -121.4237 },
  };
  const verdictAt = (
    now: Date,
    minutesAt: (departAt: Date) => number = () => 20,
  ) =>
    getVerdict(
      {
        route,
        now,
        preferences: {
          ...DEFAULT_PREFERENCES,
          goal: 'arrive_by',
          arriveBy: ARRIVE_BY,
        },
      },
      {
        baseline: new FakeBaselineProvider(
          minutesAt,
          100,
          undefined,
          'fixture',
        ),
        live: new NoLiveConditions(),
      },
    );

  it('takes the recommended departure of a leave-later verdict', async () => {
    const result = await verdictAt(t('05:00'));
    assert.equal(result.verdict.action, 'leave_later');
    assert.deepEqual(planFromVerdict(result), {
      action: 'leave_later',
      departAt: t('07:30'),
      arriveAt: t('07:50'),
      driveMinutes: 20,
      reason: result.verdict.reason,
      confidence: result.verdict.confidence,
      confidenceReason: result.verdict.confidenceReason,
      notes: [],
      marginMinutes: 10,
      source: { baseline: 'fixture', fallback: false, live: false },
    });
  });

  it('takes the recommended departure of a wait verdict', async () => {
    // Leaving now takes an hour and misses the target; in 15 minutes the
    // road has cleared.
    const result = await verdictAt(t('07:15'), departAt =>
      departAt.getTime() < t('07:30').getTime() ? 60 : 20,
    );
    assert.equal(result.verdict.action, 'wait');
    const mapped = planFromVerdict(result);
    assert.ok(!('noPlan' in mapped));
    assert.equal(mapped.action, 'wait');
    assert.deepEqual(mapped.departAt, t('07:30'));
    assert.deepEqual(mapped.arriveAt, t('07:50'));
    assert.equal(mapped.driveMinutes, 20);
    assert.equal(mapped.lateByMinutes, undefined);
    assert.equal(mapped.marginMinutes, 10);
  });

  it('takes "now" for a leave-now verdict', async () => {
    const result = await verdictAt(t('07:30'));
    assert.equal(result.verdict.action, 'leave_now');
    const mapped = planFromVerdict(result);
    assert.ok(!('noPlan' in mapped));
    assert.equal(mapped.action, 'leave_now');
    assert.deepEqual(mapped.departAt, t('07:30'));
    assert.deepEqual(mapped.arriveAt, t('07:50'));
    assert.equal(mapped.lateByMinutes, undefined);
    assert.equal(mapped.marginMinutes, 10);
  });

  it('says by how much the target is missed when it cannot be met', async () => {
    const result = await verdictAt(t('07:50'));
    const mapped = planFromVerdict(result);
    assert.ok(!('noPlan' in mapped));
    assert.equal(mapped.action, 'leave_now');
    assert.deepEqual(mapped.departAt, t('07:50'));
    assert.deepEqual(mapped.arriveAt, t('08:10'));
    assert.equal(mapped.lateByMinutes, 10);
    assert.equal(mapped.marginMinutes, undefined);
    assert.ok(!('marginMinutes' in mapped));
  });

  it('has no departure for a no-rush verdict, only the reason', async () => {
    const result = await verdictAt(
      new Date(ARRIVE_BY.getTime() - 13 * 3600_000),
    );
    assert.equal(result.verdict.action, 'no_rush');
    assert.deepEqual(planFromVerdict(result), {
      noPlan: result.verdict.reason,
    });
  });

  it('never works a departure out itself', async () => {
    // Whatever the verdict says is taken as it is, even a departure no
    // drive time would explain.
    const result = await verdictAt(t('05:00'));
    const odd = {
      ...result,
      verdict: {
        ...result.verdict,
        recommended: {
          departAt: t('06:10'),
          arriveAt: t('07:55'),
          driveMinutes: 3,
        },
      },
    };
    const mapped = planFromVerdict(odd);
    assert.ok(!('noPlan' in mapped));
    assert.deepEqual(mapped.departAt, t('06:10'));
    assert.deepEqual(mapped.arriveAt, t('07:55'));
    assert.equal(mapped.driveMinutes, 3);
  });
});

describe('the lattice of a trip', () => {
  it('is every 15 minutes through the anchor, before and after it', () => {
    assert.deepEqual(latticeAtOrBefore(DEPART_AT, t('06:07')), t('06:00'));
    assert.deepEqual(latticeAtOrBefore(DEPART_AT, t('06:15')), t('06:15'));
    assert.deepEqual(latticeAtOrBefore(DEPART_AT, t('07:44')), t('07:30'));
    assert.deepEqual(latticeAfter(DEPART_AT, t('06:15')), t('06:30'));
    assert.deepEqual(latticeAfter(DEPART_AT, t('06:16')), t('06:30'));
    assert.deepEqual(latticeAtOrAfter(DEPART_AT, t('05:30')), t('05:30'));
    assert.deepEqual(latticeAtOrAfter(DEPART_AT, t('05:31')), t('05:45'));
  });

  it('follows an anchor that is off the quarter hour', () => {
    const anchor = t('07:52');
    assert.deepEqual(latticeAtOrBefore(anchor, t('06:30')), t('06:22'));
    assert.deepEqual(latticeAfter(anchor, t('06:22')), t('06:37'));
    assert.deepEqual(latticeAtOrAfter(anchor, t('05:52')), t('05:52'));
  });
});

describe('evaluationInstant', () => {
  const instant = (anchorAt: Date | null, now: Date) =>
    evaluationInstant({ anchorAt, arriveBy: ARRIVE_BY }, now, CONFIG);

  it('is now, to the minute, for a trip with no plan yet', () => {
    assert.deepEqual(instant(null, seconds(42, t('05:07'))), {
      at: t('05:07'),
      lagged: false,
    });
  });

  it('is the lattice instant for a check that comes on time', () => {
    assert.deepEqual(instant(DEPART_AT, t('06:00')), {
      at: t('06:00'),
      lagged: false,
    });
    assert.deepEqual(instant(DEPART_AT, seconds(20, t('06:00'))), {
      at: t('06:00'),
      lagged: false,
    });
  });

  it('counts a check as late only past the allowed lag', () => {
    assert.deepEqual(instant(DEPART_AT, seconds(120, t('06:00'))), {
      at: t('06:00'),
      lagged: false,
    });
    assert.deepEqual(instant(DEPART_AT, seconds(121, t('06:00'))), {
      at: t('06:00'),
      lagged: true,
    });
  });

  it('keeps to the lattice however late the check is', () => {
    // Asleep for 40 minutes: the last lattice instant, never "now".
    assert.deepEqual(instant(DEPART_AT, t('06:40')), {
      at: t('06:30'),
      lagged: true,
    });
    assert.deepEqual(instant(DEPART_AT, seconds(59, t('06:44'))), {
      at: t('06:30'),
      lagged: true,
    });
    assert.deepEqual(instant(DEPART_AT, t('06:45')), {
      at: t('06:45'),
      lagged: false,
    });
  });

  it('keeps to the lattice after the departure has passed', () => {
    assert.deepEqual(instant(DEPART_AT, t('07:46')), {
      at: t('07:45'),
      lagged: false,
    });
  });

  it('is never a whole slot behind, and always on the lattice', () => {
    for (let minute = 0; minute < 120; minute++) {
      const now = new Date(t('05:30').getTime() + minute * 60_000);
      const { at } = instant(DEPART_AT, now);
      const lagMs = now.getTime() - at.getTime();
      assert.ok(lagMs >= 0 && lagMs < 15 * 60_000);
      assert.equal((DEPART_AT.getTime() - at.getTime()) % (15 * 60_000), 0);
    }
  });

  it('uses now when the lattice instant is beyond the planning horizon', () => {
    // The trip is 685 minutes from its target, five inside the horizon. Its
    // last lattice instant is ten minutes ago: five outside it.
    const justInside = new Date(ARRIVE_BY.getTime() - 685 * 60_000);
    const anchor = new Date(ARRIVE_BY.getTime() - 35 * 60_000);
    assert.deepEqual(
      latticeAtOrBefore(anchor, justInside),
      new Date(ARRIVE_BY.getTime() - 695 * 60_000),
    );
    assert.deepEqual(
      evaluationInstant(
        { anchorAt: anchor, arriveBy: ARRIVE_BY },
        justInside,
        CONFIG,
      ),
      { at: justInside, lagged: false },
    );
    // One slot on, the lattice instant is inside the horizon and is used.
    const later = new Date(ARRIVE_BY.getTime() - 679 * 60_000);
    assert.deepEqual(
      evaluationInstant(
        { anchorAt: anchor, arriveBy: ARRIVE_BY },
        later,
        CONFIG,
      ),
      { at: new Date(ARRIVE_BY.getTime() - 680 * 60_000), lagged: false },
    );
  });
});

describe('nextStep', () => {
  it('ends a trip at its arrival time, and not a moment before', () => {
    assert.deepEqual(nextStep(planned(t('05:00')), ARRIVE_BY, CONFIG), {
      step: 'end',
    });
    assert.deepEqual(nextStep(planned(t('05:00')), t('09:00'), CONFIG), {
      step: 'end',
    });
    assert.equal(
      nextStep(planned(t('05:00')), seconds(-1, ARRIVE_BY), CONFIG).step,
      'evaluate',
    );
  });

  it('makes a trip beyond the horizon wait for it, asking nobody', () => {
    const entersAt = new Date(ARRIVE_BY.getTime() - 690 * 60_000);
    assert.deepEqual(
      nextStep(row({ phase: 'planning' }), seconds(-1, entersAt), CONFIG),
      { step: 'wait', phase: 'scheduled', nextCheckAt: entersAt },
    );
    assert.deepEqual(nextStep(row({ phase: 'scheduled' }), entersAt, CONFIG), {
      step: 'evaluate',
      at: entersAt,
      lagged: false,
    });
  });

  it('asks about a trip as of its lattice instant', () => {
    assert.deepEqual(nextStep(planned(t('05:00')), t('06:01'), CONFIG), {
      step: 'evaluate',
      at: t('06:00'),
      lagged: false,
    });
    assert.deepEqual(nextStep(planned(t('05:00')), t('06:10'), CONFIG), {
      step: 'evaluate',
      at: t('06:00'),
      lagged: true,
    });
  });

  it('asks nobody once the leave alert has gone out', () => {
    const left = headsUpSent({ leaveSentAt: t('07:30') });
    assert.deepEqual(nextStep(left, t('07:31'), CONFIG), {
      step: 'wait',
      phase: 'monitoring',
      nextCheckAt: ARRIVE_BY,
    });
  });

  it('asks once more for a trip added back with no plan to show', () => {
    const addedBack = row({
      phase: 'monitoring',
      anchorAt: DEPART_AT,
      headsUpState: 'sent',
      leaveSentAt: t('07:30'),
    });
    assert.equal(hasStoredPlan(addedBack), false);
    assert.equal(nextStep(addedBack, t('07:40'), CONFIG).step, 'evaluate');
  });
});

describe('clockTime', () => {
  it('shows the time on the trip’s own clock', () => {
    assert.equal(clockTime(t('07:30'), 'America/Los_Angeles'), '7:30 AM');
    assert.equal(clockTime(t('07:30'), 'America/New_York'), '10:30 AM');
    assert.equal(clockTime(t('12:05'), 'America/Los_Angeles'), '12:05 PM');
  });

  it('falls back to the campus clock for a zone it does not know', () => {
    assert.equal(clockTime(t('07:30'), 'Mars/Olympus_Mons'), '7:30 AM');
    assert.equal(clockTime(t('07:30'), ''), '7:30 AM');
  });

  it('uses a plain space before AM and PM', () => {
    assert.ok(!clockTime(t('07:30'), 'America/Los_Angeles').includes(' '));
    assert.match(clockTime(t('19:30'), 'America/Los_Angeles'), /^7:30 PM$/);
  });
});

describe('isDegraded', () => {
  it('is true without live conditions, on a fallback, or with no source', () => {
    assert.equal(isDegraded(LIVE), false);
    assert.equal(isDegraded(NO_LIVE), true);
    assert.equal(isDegraded(FALLBACK), true);
    assert.equal(isDegraded(null), true);
  });
});

describe('a first plan', () => {
  it('is stored, and monitoring is set to start two hours before it', () => {
    const { change, alerts } = decide(row(), got(), t('05:00'));
    assert.deepEqual(alerts, []);
    assert.deepEqual(change, {
      phase: 'planned',
      action: 'leave_later',
      departAt: DEPART_AT,
      arriveAt: ARRIVE_AT,
      driveMinutes: 20,
      reason:
        'Leaving in 2 hr 30 min still gets you there with 10 minutes to spare.',
      confidence: 'High',
      confidenceReason: 'Plenty of data for this route.',
      notes: [],
      lateByMinutes: null,
      marginMinutes: 10,
      source: LIVE,
      evaluatedAt: t('05:00'),
      noPlanReason: null,
      evalFailures: 0,
      lastErrorCode: null,
      lastErrorAt: null,
      anchorAt: DEPART_AT,
      monitoringStartedAt: null,
      headsUpState: 'pending',
      headsUpSentAt: null,
      notifiedDepartAt: null,
      candidateDepartAt: null,
      notifiedDegraded: null,
      lastUpdateAt: null,
      updateCount: 0,
      leaveSentAt: null,
      lateSentAt: null,
      nextCheckAt: t('05:30'),
    });
  });

  it('records the instant it is as of, which its sentences count from', () => {
    // A check that came late: asked at 5:08 about the lattice instant 5:00.
    // "Leaving in 2 hr 30 min" counts from 5:00, so that is its time.
    const late = asOf(t('05:00'), got());
    assert.deepEqual(
      decide(row(), late, t('05:08')).change.evaluatedAt,
      t('05:00'),
    );
    // Told nothing else, a plan is as of the moment of the check.
    const now = seconds(37, t('05:00'));
    assert.deepEqual(decide(row(), got(), now).change.evaluatedAt, now);
  });

  it('measures how fresh a plan is from the instant it is as of', () => {
    // As of 5:29, stored at 5:40. By 6:00 it is 31 minutes old, not 20: too
    // old for a heads-up after a failed check.
    const stored = decide(row(), asOf(t('05:29'), got()), t('05:40'));
    const trip = after(row(), stored.change);
    const { alerts } = decide(trip, failed(), t('06:00'));
    assert.deepEqual(alerts, []);
  });

  it('clears the last failure and the reason there was no plan', () => {
    const trip = row({
      evalFailures: 2,
      lastErrorCode: 'routing_unavailable',
      lastErrorAt: t('04:58'),
      noPlanReason: 'No need to leave yet.',
    });
    const { change } = decide(trip, got(), t('05:00'));
    assert.equal(change.evalFailures, 0);
    assert.equal(change.lastErrorCode, null);
    assert.equal(change.lastErrorAt, null);
    assert.equal(change.noPlanReason, null);
  });

  it('wakes on the first lattice instant of monitoring when the lead is not whole slots', () => {
    const config = {
      ...CONFIG,
      monitorLeadMinutes: 100,
      headsUpLeadMinutes: 50,
    };
    // 100 minutes before 7:30 is 5:50; the lattice has 6:00 next.
    const { change } = decide(row(), got(), t('05:00'), config);
    assert.equal(change.phase, 'planned');
    assert.deepEqual(change.nextCheckAt, t('06:00'));
  });
});

describe('the start of active monitoring', () => {
  it('is not yet a minute before the two-hour mark', () => {
    const { change, alerts } = decide(planned(t('05:00')), got(), t('05:29'));
    assert.equal(change.phase, 'planned');
    assert.equal(change.monitoringStartedAt, null);
    assert.deepEqual(change.nextCheckAt, t('05:30'));
    assert.deepEqual(alerts, []);
  });

  it('is at the two-hour mark', () => {
    const { change, alerts } = decide(planned(t('05:00')), got(), t('05:30'));
    assert.equal(change.phase, 'monitoring');
    assert.deepEqual(change.monitoringStartedAt, t('05:30'));
    assert.deepEqual(change.nextCheckAt, t('05:45'));
    assert.deepEqual(alerts, []);
  });

  it('is at once for a trip created inside the window', () => {
    const { change, alerts } = decide(row(), got(), t('05:50'));
    assert.equal(change.phase, 'monitoring');
    assert.deepEqual(change.monitoringStartedAt, t('05:50'));
    // The heads-up is not due for another ten minutes.
    assert.deepEqual(alerts, []);
    assert.deepEqual(change.nextCheckAt, t('06:00'));
  });

  it('does not end when the departure moves beyond the two-hour lead', () => {
    const monitored = planned(t('05:30'), {
      phase: 'monitoring',
      monitoringStartedAt: t('05:30'),
    });
    const later = got({ departAt: t('08:15'), arriveAt: t('08:35') });
    const trip = { ...monitored, arriveBy: t('09:00') };
    const { change } = decide(trip, later, t('05:45'));
    assert.equal(change.phase, 'monitoring');
    assert.deepEqual(change.monitoringStartedAt, t('05:30'));
    assert.deepEqual(change.nextCheckAt, t('06:00'));
  });

  it('checks every slot on the lattice, and never past the arrival time', () => {
    const monitored = headsUpSent();
    assert.deepEqual(
      decide(monitored, got(), seconds(30, t('06:15'))).change.nextCheckAt,
      t('06:30'),
    );
    // A late plan a few minutes before the target: the next slot would be
    // after it.
    const late = leaveNowAt(t('07:52'), { lateByMinutes: 12 });
    const trip = headsUpSent({ lateSentAt: t('07:37'), anchorAt: t('07:37') });
    assert.deepEqual(
      decide(trip, late, t('07:52')).change.nextCheckAt,
      ARRIVE_BY,
    );
  });
});

describe('the heads-up', () => {
  const monitored = planned(t('05:45'), {
    phase: 'monitoring',
    monitoringStartedAt: t('05:30'),
  });

  it('is not sent a minute before the 90-minute mark', () => {
    const { change, alerts } = decide(monitored, got(), t('05:59'));
    assert.deepEqual(alerts, []);
    assert.equal(change.headsUpState, 'pending');
  });

  it('is sent at the 90-minute mark, naming the departure and the target', () => {
    const { change, alerts } = decide(monitored, got(), t('06:00'));
    assert.deepEqual(alerts, [
      {
        kind: 'heads_up',
        dedupeKey: 'heads_up',
        title: 'Heads up: Chem lab',
        body: "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
        expiresAt: DEPART_AT,
        payload: {
          aps: {
            alert: {
              title: 'Heads up: Chem lab',
              body: "Plan to leave around 7:30 AM to arrive by 8:00 AM. We'll keep checking traffic.",
            },
            sound: 'default',
            'thread-id': 'trip-A1B2C3@2026-11-20',
            category: 'WAIT_IT_OUT_TRIP',
          },
          tripId: 'A1B2C3@2026-11-20',
          kind: 'heads_up',
          departAt: DEPART_AT.toISOString(),
          arriveBy: ARRIVE_BY.toISOString(),
        },
      },
    ]);
    assert.equal(change.headsUpState, 'sent');
    assert.deepEqual(change.headsUpSentAt, t('06:00'));
    assert.deepEqual(change.notifiedDepartAt, DEPART_AT);
    assert.equal(change.notifiedDegraded, false);
    assert.deepEqual(change.lastUpdateAt, t('06:00'));
    assert.equal(change.candidateDepartAt, null);
    assert.equal(change.leaveSentAt, null);
    assert.deepEqual(change.nextCheckAt, t('06:15'));
  });

  it('is sent once', () => {
    const first = decide(monitored, got(), t('06:00'));
    const second = decide(after(monitored, first.change), got(), t('06:15'));
    assert.deepEqual(second.alerts, []);
    assert.equal(second.change.headsUpState, 'sent');
    assert.deepEqual(second.change.headsUpSentAt, t('06:00'));
  });

  it('is sent at once, as a catch-up, for a trip created after its time', () => {
    const { change, alerts } = decide(row(), got(), t('06:40'));
    assert.equal(change.phase, 'monitoring');
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].kind, 'heads_up');
    assert.deepEqual(change.headsUpSentAt, t('06:40'));
  });

  it('remembers whether the plan it named came from a poorer source', () => {
    const { change } = decide(monitored, got({ source: NO_LIVE }), t('06:00'));
    assert.equal(change.notifiedDegraded, true);
  });

  it('shows the times on the trip’s own clock', () => {
    const eastern = { ...monitored, timeZone: 'America/New_York' };
    const { alerts } = decide(eastern, got(), t('06:00'));
    assert.equal(
      alerts[0].body,
      "Plan to leave around 10:30 AM to arrive by 11:00 AM. We'll keep checking traffic.",
    );
  });

  it('never carries the verdict’s own sentence', () => {
    const { alerts } = decide(
      monitored,
      got({ reason: 'A crash on I-80 W is slowing everything down.' }),
      t('06:00'),
    );
    assert.ok(!JSON.stringify(alerts).includes('crash'));
  });
});

describe('the leave alert', () => {
  it('goes out when the backend says to leave now', () => {
    const { change, alerts } = decide(
      headsUpSent(),
      leaveNowAt(DEPART_AT),
      DEPART_AT,
    );
    assert.equal(alerts.length, 1);
    const [alert] = alerts;
    assert.equal(alert.kind, 'leave_now');
    assert.equal(alert.dedupeKey, 'leave_now');
    assert.equal(alert.title, 'Time to leave for Chem lab');
    assert.equal(
      alert.body,
      'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
    );
    assert.deepEqual(alert.payload.aps.alert, {
      title: alert.title,
      body: alert.body,
    });
    assert.equal(alert.payload.kind, 'leave_now');
    assert.equal(alert.payload.departAt, DEPART_AT.toISOString());
    // Useful for half an hour, but not past the target.
    assert.deepEqual(alert.expiresAt, ARRIVE_BY);
    assert.deepEqual(change.leaveSentAt, DEPART_AT);
    assert.equal(change.lateSentAt, null);
    assert.equal(change.headsUpState, 'sent');
    // Nothing more to say: the next thing is the end of the trip.
    assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
  });

  it('is useful for half an hour after the departure', () => {
    const trip = headsUpSent({ arriveBy: t('09:00') });
    const { alerts } = decide(trip, leaveNowAt(DEPART_AT), DEPART_AT);
    assert.deepEqual(alerts[0].expiresAt, t('08:00'));
  });

  it('is given at least ten minutes to be delivered', () => {
    // The target is five minutes off and can still be met.
    const trip = headsUpSent({ arriveBy: t('07:35') });
    const now = t('07:30');
    const { alerts } = decide(
      trip,
      leaveNowAt(now, { arriveAt: t('07:33') }),
      now,
    );
    assert.deepEqual(alerts[0].expiresAt, t('07:40'));
  });

  it('skips a heads-up that never went out', () => {
    // Created when the departure is already due.
    const { change, alerts } = decide(row(), leaveNowAt(DEPART_AT), DEPART_AT);
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
    assert.equal(change.phase, 'monitoring');
    assert.equal(change.headsUpState, 'skipped');
    assert.equal(change.headsUpSentAt, null);
  });

  it('is not held back by an update a minute ago', () => {
    const trip = headsUpSent({
      updateCount: 3,
      lastUpdateAt: t('07:14'),
      notifiedDepartAt: t('07:30'),
    });
    const { alerts } = decide(trip, leaveNowAt(t('07:15')), t('07:15'));
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
    assert.equal(
      alerts[0].body,
      'Leave at 7:15 AM to arrive around 7:35 AM. Your target is 8:00 AM.',
    );
  });

  it('is the last thing a trip is told', () => {
    const left = headsUpSent({ leaveSentAt: DEPART_AT });
    for (const evaluation of [
      got(),
      got({ departAt: t('07:00'), arriveAt: t('07:20') }),
      leaveNowAt(t('07:45')),
      leaveNowAt(t('07:45'), { lateByMinutes: 5 }),
      failed(),
    ]) {
      const { change, alerts } = decide(left, evaluation, t('07:45'));
      assert.deepEqual(alerts, []);
      assert.deepEqual(change.leaveSentAt, DEPART_AT);
      assert.equal(change.lateSentAt, null);
      assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
    }
  });
});

describe('the late alert', () => {
  const lateAt = (at: Date, lateByMinutes: number) =>
    leaveNowAt(at, {
      arriveAt: new Date(ARRIVE_BY.getTime() + lateByMinutes * 60_000),
      lateByMinutes,
    });

  it('goes out, once, when even leaving now misses the target', () => {
    const { change, alerts } = decide(
      headsUpSent(),
      lateAt(t('07:45'), 5),
      t('07:45'),
    );
    assert.equal(alerts.length, 1);
    const [alert] = alerts;
    assert.equal(alert.kind, 'late');
    assert.equal(alert.dedupeKey, 'late');
    assert.equal(alert.title, 'Running late for Chem lab');
    assert.equal(
      alert.body,
      'Leaving at 7:45 AM, you may arrive about 5 minutes after 8:00 AM.',
    );
    assert.equal(alert.payload.departAt, t('07:45').toISOString());
    assert.deepEqual(alert.expiresAt, ARRIVE_BY);
    assert.deepEqual(change.lateSentAt, t('07:45'));
    assert.deepEqual(change.notifiedDepartAt, t('07:45'));
    // The leave alert is still owed if the plan recovers.
    assert.equal(change.leaveSentAt, null);
    assert.deepEqual(change.nextCheckAt, ARRIVE_BY);

    const again = decide(
      after(headsUpSent(), change),
      lateAt(t('07:46'), 6),
      t('07:46'),
    );
    assert.deepEqual(again.alerts, []);
    assert.deepEqual(again.change.lateSentAt, t('07:45'));
  });

  it('says "1 minute" for one', () => {
    const { alerts } = decide(headsUpSent(), lateAt(t('07:41'), 1), t('07:41'));
    assert.equal(
      alerts[0].body,
      'Leaving at 7:41 AM, you may arrive about 1 minute after 8:00 AM.',
    );
  });

  it('is given at least ten minutes to be delivered', () => {
    const { alerts } = decide(
      headsUpSent(),
      lateAt(t('07:55'), 15),
      t('07:55'),
    );
    assert.deepEqual(alerts[0].expiresAt, t('08:05'));
  });

  it('skips a heads-up that never went out', () => {
    // Created when the target is already out of reach.
    const { change, alerts } = decide(row(), lateAt(t('07:45'), 5), t('07:45'));
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['late'],
    );
    assert.equal(change.phase, 'monitoring');
    assert.equal(change.headsUpState, 'skipped');
    // Asked again a slot later, in case traffic clears.
    assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
  });

  it('keeps asking, a slot at a time, while the target is still ahead', () => {
    const trip = row({ arriveBy: t('09:00') });
    const hopeless = leaveNowAt(t('07:45'), {
      arriveAt: t('09:20'),
      lateByMinutes: 20,
    });
    const { change } = decide(trip, hopeless, t('07:45'));
    assert.deepEqual(change.nextCheckAt, t('08:00'));
    assert.deepEqual(change.anchorAt, t('07:45'));
  });

  it('is followed by one update and the leave alert when the plan recovers', () => {
    const trip = row({ arriveBy: t('09:00') });
    const first = decide(
      trip,
      leaveNowAt(t('07:45'), { arriveAt: t('09:20'), lateByMinutes: 20 }),
      t('07:45'),
    );
    assert.deepEqual(
      first.alerts.map(alert => alert.kind),
      ['late'],
    );

    // Traffic clears: leaving at 8:30 now arrives at 8:50.
    const recovered = got({ departAt: t('08:30'), arriveAt: t('08:50') });
    const second = decide(after(trip, first.change), recovered, t('08:00'));
    assert.deepEqual(second.alerts, []);
    assert.deepEqual(second.change.candidateDepartAt, t('08:30'));

    const third = decide(after(trip, second.change), recovered, t('08:15'));
    assert.equal(third.alerts.length, 1);
    assert.equal(third.alerts[0].kind, 'update');
    assert.equal(third.alerts[0].title, 'Updated plan for Chem lab');
    assert.equal(
      third.alerts[0].body,
      'Leave at 8:30 AM instead of 7:45 AM. Predicted arrival 8:50 AM; your target is 9:00 AM.',
    );
    assert.deepEqual(third.change.notifiedDepartAt, t('08:30'));

    const fourth = decide(
      after(trip, third.change),
      leaveNowAt(t('08:30'), { arriveAt: t('08:50') }),
      t('08:30'),
    );
    assert.deepEqual(
      fourth.alerts.map(alert => alert.kind),
      ['leave_now'],
    );
    assert.deepEqual(fourth.change.leaveSentAt, t('08:30'));
    assert.deepEqual(fourth.change.lateSentAt, t('07:45'));
  });

  it('is followed by the leave alert alone when the recovery is "leave now"', () => {
    const lateTrip = headsUpSent({
      lateSentAt: t('07:15'),
      notifiedDepartAt: t('07:15'),
    });
    const { alerts } = decide(lateTrip, leaveNowAt(DEPART_AT), DEPART_AT);
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
  });

  it('is never sent after the leave alert', () => {
    const left = headsUpSent({ leaveSentAt: DEPART_AT });
    const { change, alerts } = decide(left, lateAt(t('07:45'), 5), t('07:45'));
    assert.deepEqual(alerts, []);
    assert.equal(change.lateSentAt, null);
  });
});

describe('updates after the heads-up', () => {
  const earlier = got({ departAt: t('07:15'), arriveAt: t('07:50') });
  const later = got({ departAt: t('07:45'), arriveAt: t('07:58') });

  it('announces an earlier departure at once', () => {
    const { change, alerts } = decide(headsUpSent(), earlier, t('06:30'));
    assert.equal(alerts.length, 1);
    const [alert] = alerts;
    assert.equal(alert.kind, 'update');
    assert.equal(alert.dedupeKey, 'update:1');
    assert.equal(alert.title, 'Leave earlier for Chem lab');
    assert.equal(
      alert.body,
      'Leave at 7:15 AM instead of 7:30 AM. Predicted arrival 7:50 AM; your target is 8:00 AM.',
    );
    assert.equal(alert.payload.kind, 'update');
    assert.equal(alert.payload.departAt, t('07:15').toISOString());
    assert.deepEqual(alert.expiresAt, t('07:15'));
    assert.deepEqual(change.notifiedDepartAt, t('07:15'));
    assert.deepEqual(change.lastUpdateAt, t('06:30'));
    assert.equal(change.updateCount, 1);
    assert.equal(change.candidateDepartAt, null);
    assert.deepEqual(change.anchorAt, t('07:15'));
    assert.deepEqual(change.nextCheckAt, t('06:45'));
  });

  it('announces a later departure only when two checks in a row agree', () => {
    const first = decide(headsUpSent(), later, t('06:30'));
    assert.deepEqual(first.alerts, []);
    assert.deepEqual(first.change.candidateDepartAt, t('07:45'));
    assert.deepEqual(first.change.notifiedDepartAt, DEPART_AT);
    // The plan itself is stored at once, so the app shows it.
    assert.deepEqual(first.change.departAt, t('07:45'));

    const second = decide(
      after(headsUpSent(), first.change),
      later,
      t('06:45'),
    );
    assert.equal(second.alerts.length, 1);
    const [alert] = second.alerts;
    assert.equal(alert.kind, 'update');
    assert.equal(alert.title, 'Updated plan for Chem lab');
    assert.equal(
      alert.body,
      'Leave at 7:45 AM instead of 7:30 AM. Predicted arrival 7:58 AM; your target is 8:00 AM.',
    );
    assert.deepEqual(second.change.notifiedDepartAt, t('07:45'));
    assert.equal(second.change.candidateDepartAt, null);
    assert.equal(second.change.updateCount, 1);
  });

  it('forgets a later departure that did not last', () => {
    const first = decide(headsUpSent(), later, t('06:30'));
    const back = decide(after(headsUpSent(), first.change), got(), t('06:45'));
    assert.deepEqual(back.alerts, []);
    assert.equal(back.change.candidateDepartAt, null);
    // And a different later departure starts the count again.
    const other = got({ departAt: t('08:00'), arriveAt: t('08:13') });
    const trip = { ...headsUpSent(), arriveBy: t('08:30') };
    const one = decide(after(trip, first.change), other, t('06:45'));
    assert.deepEqual(one.alerts, []);
    assert.deepEqual(one.change.candidateDepartAt, t('08:00'));
  });

  it('says nothing when the departure has not moved', () => {
    const { change, alerts } = decide(headsUpSent(), got(), t('06:30'));
    assert.deepEqual(alerts, []);
    assert.equal(change.updateCount, 0);
    assert.deepEqual(change.notifiedDepartAt, DEPART_AT);
  });

  it('says nothing for a shift below the threshold', () => {
    const config = { ...CONFIG, meaningfulShiftMinutes: 20 };
    const sooner = decide(headsUpSent(), earlier, t('06:30'), config);
    assert.deepEqual(sooner.alerts, []);
    assert.deepEqual(sooner.change.notifiedDepartAt, DEPART_AT);
    const first = decide(headsUpSent(), later, t('06:30'), config);
    const second = decide(
      after(headsUpSent(), first.change),
      later,
      t('06:45'),
      config,
    );
    assert.deepEqual(second.alerts, []);
    assert.equal(second.change.candidateDepartAt, null);
    assert.equal(second.change.updateCount, 0);
  });

  it('does not announce "leave later" from a poorer source than the last', () => {
    for (const source of [NO_LIVE, FALLBACK]) {
      const poorer = got({
        departAt: t('07:45'),
        arriveAt: t('07:58'),
        source,
      });
      const first = decide(headsUpSent(), poorer, t('06:30'));
      const second = decide(
        after(headsUpSent(), first.change),
        poorer,
        t('06:45'),
      );
      assert.deepEqual(first.alerts, []);
      assert.deepEqual(second.alerts, []);
      assert.equal(second.change.candidateDepartAt, null);
      assert.deepEqual(second.change.notifiedDepartAt, DEPART_AT);
      // The plan is stored all the same, with where it came from.
      assert.deepEqual(second.change.departAt, t('07:45'));
      assert.deepEqual(second.change.source, source);
    }
  });

  it('still says "time to leave" at the departure it announced, whatever a poorer source says later', () => {
    for (const source of [NO_LIVE, FALLBACK]) {
      const poorer = got({
        departAt: t('07:45'),
        arriveAt: t('07:58'),
        source,
      });
      // The user was told 7:30. From 6:30 on every check says 7:45, from
      // less than the full picture.
      let trip = headsUpSent();
      const said: Array<{ at: string; kind: string }> = [];
      for (const clock of ['06:30', '06:45', '07:00', '07:15', '07:29']) {
        const { change, alerts } = decide(trip, poorer, t(clock));
        said.push(...alerts.map(alert => ({ at: clock, kind: alert.kind })));
        trip = after(trip, change);
      }
      assert.deepEqual(said, []);
      // It wakes at the departure it announced.
      assert.deepEqual(trip.nextCheckAt, DEPART_AT);

      const { change, alerts } = decide(trip, poorer, DEPART_AT);
      assert.equal(alerts.length, 1);
      const [alert] = alerts;
      assert.equal(alert.kind, 'leave_now');
      assert.equal(alert.dedupeKey, 'leave_now');
      assert.equal(alert.title, 'Time to leave for Chem lab');
      // No arrival is named: the poorer plan's is not to be believed.
      assert.equal(
        alert.body,
        'Leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be fully re-checked.',
      );
      assert.equal(alert.payload.kind, 'leave_now');
      assert.equal(alert.payload.departAt, DEPART_AT.toISOString());
      assert.deepEqual(alert.expiresAt, ARRIVE_BY);
      assert.deepEqual(change.leaveSentAt, DEPART_AT);
      assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
      // The app still shows the newest plan, with where it came from.
      assert.deepEqual(change.departAt, t('07:45'));
      assert.deepEqual(change.source, source);
    }
  });

  it('keeps to the departure it announced when the checks then fail outright', () => {
    for (const source of [NO_LIVE, FALLBACK]) {
      const poorer = got({
        departAt: t('07:45'),
        arriveAt: t('07:58'),
        source,
      });
      // 7:00: the poorer plan for 7:45 is stored. Then nothing answers.
      let trip = after(
        headsUpSent(),
        decide(headsUpSent(), poorer, t('07:00')).change,
      );
      const down = decide(trip, failed('no_coverage'), t('07:20'));
      assert.deepEqual(down.alerts, []);
      // Not in half an hour, and not at 7:45: at 7:30, as the user was told.
      assert.deepEqual(down.change.nextCheckAt, DEPART_AT);
      trip = after(trip, down.change);

      const { change, alerts } = decide(trip, failed('no_coverage'), DEPART_AT);
      assert.deepEqual(
        alerts.map(alert => alert.kind),
        ['leave_now'],
      );
      assert.equal(
        alerts[0].body,
        'Leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be fully re-checked.',
      );
      assert.equal(alerts[0].payload.departAt, DEPART_AT.toISOString());
      assert.deepEqual(change.leaveSentAt, DEPART_AT);
    }
  });

  it('wakes for a held departure even when it is off the newest plan’s lattice', () => {
    const trip = headsUpSent({ notifiedDepartAt: t('07:20') });
    const poorer = got({
      departAt: t('07:45'),
      arriveAt: t('07:58'),
      source: NO_LIVE,
    });
    // The lattice through 7:45 has 7:15 and 7:30, and not 7:20.
    const { change } = decide(trip, poorer, t('07:15'));
    assert.deepEqual(change.nextCheckAt, t('07:20'));
  });

  it('holds "time to leave" to nothing once the poorer plan’s own departure has come', () => {
    // Asleep through 7:30 and 7:45: the plan in hand says to leave now.
    const now = t('07:46');
    const { alerts } = decide(
      headsUpSent({ arriveBy: t('08:30') }),
      leaveNowAt(now, { source: NO_LIVE }),
      now,
    );
    assert.equal(
      alerts[0].body,
      'Leave at 7:46 AM to arrive around 8:06 AM. Your target is 8:30 AM.',
    );
  });

  it('does not hold "time to leave" for somebody already told they are late', () => {
    const trip = headsUpSent({ lateSentAt: t('07:00') });
    const poorer = got({
      departAt: t('07:45'),
      arriveAt: t('07:58'),
      source: NO_LIVE,
    });
    assert.deepEqual(decide(trip, poorer, DEPART_AT).alerts, []);
  });

  it('does not hold "time to leave" when the plan it announced was no better', () => {
    const trip = headsUpSent({ notifiedDegraded: true, source: NO_LIVE });
    const poorer = got({
      departAt: t('07:45'),
      arriveAt: t('07:58'),
      source: NO_LIVE,
    });
    // Seen once at 7:30: a candidate for an update, and no leave alert.
    const { change, alerts } = decide(trip, poorer, DEPART_AT);
    assert.deepEqual(alerts, []);
    assert.equal(change.leaveSentAt, null);
    assert.deepEqual(change.candidateDepartAt, t('07:45'));
  });

  it('does announce "leave later" when the last plan was no better', () => {
    const trip = headsUpSent({ notifiedDegraded: true, source: NO_LIVE });
    const poorer = got({
      departAt: t('07:45'),
      arriveAt: t('07:58'),
      source: NO_LIVE,
    });
    const first = decide(trip, poorer, t('06:30'));
    const second = decide(after(trip, first.change), poorer, t('06:45'));
    assert.deepEqual(
      second.alerts.map(alert => alert.kind),
      ['update'],
    );
    assert.equal(second.change.notifiedDegraded, true);
  });

  it('announces "leave earlier" whatever the source', () => {
    const poorer = got({
      departAt: t('07:15'),
      arriveAt: t('07:50'),
      source: FALLBACK,
    });
    const { change, alerts } = decide(headsUpSent(), poorer, t('06:30'));
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['update'],
    );
    assert.equal(change.notifiedDegraded, true);
  });

  it('stops at the most updates a trip gets', () => {
    const trip = headsUpSent({ updateCount: 3, lastUpdateAt: t('06:15') });
    const { change, alerts } = decide(trip, earlier, t('06:45'));
    assert.deepEqual(alerts, []);
    assert.equal(change.updateCount, 3);
    assert.deepEqual(change.notifiedDepartAt, DEPART_AT);
  });

  it('numbers each update, so none is queued twice', () => {
    const trip = headsUpSent({ updateCount: 1, lastUpdateAt: t('06:15') });
    const { alerts } = decide(trip, earlier, t('06:45'));
    assert.equal(alerts[0].dedupeKey, 'update:2');
  });

  it('leaves at least the minimum interval between two updates', () => {
    const config = { ...CONFIG, updateMinIntervalMinutes: 20 };
    const trip = headsUpSent({ updateCount: 1, lastUpdateAt: t('06:30') });
    const tooSoon = decide(trip, earlier, t('06:45'), config);
    assert.deepEqual(tooSoon.alerts, []);
    assert.deepEqual(tooSoon.change.notifiedDepartAt, DEPART_AT);
    // Said as soon as the interval has passed, if it is still so.
    const cooled = decide(
      after(trip, tooSoon.change),
      earlier,
      t('07:00'),
      config,
    );
    assert.deepEqual(
      cooled.alerts.map(alert => alert.kind),
      ['update'],
    );
    assert.equal(cooled.change.updateCount, 2);
  });

  it('keeps a confirmed later departure until the interval lets it be said', () => {
    const config = { ...CONFIG, updateMinIntervalMinutes: 40 };
    const trip = headsUpSent({ lastUpdateAt: t('06:15') });
    const first = decide(trip, later, t('06:30'), config);
    const second = decide(after(trip, first.change), later, t('06:45'), config);
    assert.deepEqual(second.alerts, []);
    assert.deepEqual(second.change.candidateDepartAt, t('07:45'));
    const third = decide(after(trip, second.change), later, t('07:00'), config);
    assert.deepEqual(
      third.alerts.map(alert => alert.kind),
      ['update'],
    );
  });

  it('is never sent before the heads-up', () => {
    const monitored = planned(t('05:30'), {
      phase: 'monitoring',
      monitoringStartedAt: t('05:30'),
    });
    const { alerts } = decide(monitored, earlier, t('05:44'));
    assert.deepEqual(alerts, []);
  });

  it('sends one update, not a stream, for a drive time on a slot boundary', () => {
    // 7:30 and 7:15 alternate, as a 50/51-minute drive would make them.
    let trip = headsUpSent();
    const kinds: string[] = [];
    const clocks = ['06:15', '06:30', '06:45', '07:00'];
    clocks.forEach((clock, i) => {
      const evaluation = i % 2 === 0 ? earlier : got();
      const { change, alerts } = decide(trip, evaluation, t(clock));
      kinds.push(...alerts.map(alert => alert.kind));
      trip = after(trip, change);
    });
    assert.deepEqual(kinds, ['update']);
    assert.deepEqual(trip.notifiedDepartAt, t('07:15'));
  });
});

describe('a check that fails', () => {
  /** The waits before each retry of a check that keeps failing. */
  const waitsOf = (first: TripRow, now: Date, checks: number): number[] => {
    let trip = first;
    const waits: number[] = [];
    for (let i = 0; i < checks; i++) {
      const { change } = decide(trip, failed(), now);
      waits.push((change.nextCheckAt!.getTime() - now.getTime()) / 60_000);
      trip = after(trip, change);
    }
    return waits;
  };

  it('is retried after 1, 2, 5, 15 and then every 30 minutes', () => {
    // Every failed check is counted against the budget all trips share, so
    // a route that never answers is asked about less and less often.
    assert.deepEqual(waitsOf(row(), t('05:00'), 7), [1, 2, 5, 15, 30, 30, 30]);
  });

  it('counts the failures in a row on the trip', () => {
    let trip = row();
    for (let i = 0; i < 4; i++) {
      trip = after(trip, decide(trip, failed(), t('05:00')).change);
    }
    assert.equal(trip.evalFailures, 4);
  });

  it('is retried no later than the next normal check while the trip is monitored', () => {
    // A recovery is seen within one slot; the first retries are as quick.
    assert.deepEqual(
      waitsOf(headsUpSent(), t('06:15'), 7),
      [1, 2, 5, 15, 15, 15, 15],
    );
  });

  it('is asked again for a trip added back after its leave alert, until it has a plan to show', () => {
    const addedBack = row({
      phase: 'monitoring',
      anchorAt: DEPART_AT,
      headsUpState: 'sent',
      leaveSentAt: DEPART_AT,
    });
    const now = t('07:33');
    const down = decide(addedBack, failed(), now);
    assert.deepEqual(down.alerts, []);
    assert.deepEqual(down.change.nextCheckAt, t('07:34'));
    assert.equal(
      nextStep(after(addedBack, down.change), t('07:34'), CONFIG).step,
      'evaluate',
    );

    const none = decide(addedBack, failed('budget_exhausted'), now);
    assert.deepEqual(none.change.nextCheckAt, ARRIVE_BY);
    const early = decide(addedBack, failed('budget_exhausted'), t('07:20'));
    assert.deepEqual(early.change.nextCheckAt, t('07:50'));

    // Once it has a plan there is nothing left to ask or to say.
    const up = decide(
      after(addedBack, down.change),
      leaveNowAt(t('07:34')),
      t('07:34'),
    );
    assert.deepEqual(up.alerts, []);
    assert.deepEqual(up.change.departAt, t('07:34'));
    assert.deepEqual(up.change.nextCheckAt, ARRIVE_BY);
    assert.deepEqual(up.change.leaveSentAt, DEPART_AT);
  });

  it('is retried after half an hour when asking again cannot help', () => {
    for (const code of ['no_coverage', 'budget_exhausted'] as const) {
      const { change } = decide(row(), failed(code), t('05:00'));
      assert.deepEqual(change.nextCheckAt, t('05:30'));
      assert.equal(change.lastErrorCode, code);
    }
  });

  it('records what went wrong and leaves a trip with no plan in planning', () => {
    const { change, alerts } = decide(
      row({ phase: 'scheduled' }),
      failed('internal'),
      t('05:00'),
    );
    assert.deepEqual(alerts, []);
    assert.equal(change.phase, 'planning');
    assert.equal(change.lastErrorCode, 'internal');
    assert.deepEqual(change.lastErrorAt, t('05:00'));
    assert.equal(change.evalFailures, 1);
    assert.equal(change.departAt, null);
  });

  it('keeps the stored plan and its age', () => {
    const { change } = decide(headsUpSent(), failed(), t('06:15'));
    assert.deepEqual(change.departAt, DEPART_AT);
    assert.deepEqual(change.evaluatedAt, t('06:00'));
    assert.deepEqual(change.anchorAt, DEPART_AT);
  });

  it('never queues an update', () => {
    const { alerts } = decide(headsUpSent(), failed(), t('06:15'));
    assert.deepEqual(alerts, []);
  });

  it('still starts monitoring on time, from the stored plan', () => {
    const { change } = decide(planned(t('05:00')), failed(), t('05:30'));
    assert.equal(change.phase, 'monitoring');
    assert.deepEqual(change.monitoringStartedAt, t('05:30'));
  });

  it('still sends the heads-up from a plan that is fresh enough', () => {
    const monitored = planned(t('05:45'), {
      phase: 'monitoring',
      monitoringStartedAt: t('05:30'),
    });
    const { change, alerts } = decide(monitored, failed(), t('06:00'));
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['heads_up'],
    );
    assert.equal(change.headsUpState, 'sent');
    assert.equal(change.lastErrorCode, 'routing_unavailable');
  });

  it('does not send the heads-up from a plan that has gone stale', () => {
    const monitored = planned(t('05:29'), {
      phase: 'monitoring',
      monitoringStartedAt: t('05:30'),
    });
    const { change, alerts } = decide(monitored, failed(), t('06:00'));
    assert.deepEqual(alerts, []);
    assert.equal(change.headsUpState, 'pending');
  });

  it('wakes for what the clock alone decides, however long the backoff', () => {
    // The heads-up is due in 3 minutes; the backoff would be 30.
    const monitored = planned(t('05:45'), {
      phase: 'monitoring',
      monitoringStartedAt: t('05:30'),
    });
    assert.deepEqual(
      decide(monitored, failed('no_coverage'), t('05:57')).change.nextCheckAt,
      t('06:00'),
    );
    // The departure is due in 10 minutes.
    assert.deepEqual(
      decide(headsUpSent(), failed('no_coverage'), t('07:20')).change
        .nextCheckAt,
      DEPART_AT,
    );
    // Monitoring starts in 20 minutes.
    assert.deepEqual(
      decide(planned(t('05:00')), failed('no_coverage'), t('05:10')).change
        .nextCheckAt,
      t('05:30'),
    );
    // And never past the arrival time.
    const lateTrip = headsUpSent({ lateSentAt: t('07:40') });
    assert.deepEqual(
      decide(lateTrip, failed('no_coverage'), t('07:45')).change.nextCheckAt,
      ARRIVE_BY,
    );
  });

  it('sends the leave alert at the stored departure all the same', () => {
    const trip = headsUpSent({ evaluatedAt: t('07:15') });
    const { change, alerts } = decide(trip, failed(), DEPART_AT);
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
    assert.equal(
      alerts[0].body,
      'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
    );
    assert.deepEqual(change.leaveSentAt, DEPART_AT);
    assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
  });

  it('says so when the plan behind the leave alert is old', () => {
    const trip = headsUpSent({ evaluatedAt: t('06:45') });
    const { alerts } = decide(trip, failed(), seconds(40, DEPART_AT));
    assert.equal(
      alerts[0].body,
      'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM. Traffic could not be re-checked since 6:45 AM.',
    );
  });

  it('does not promise the stored plan’s arrival once its departure is well past', () => {
    // Planned at 7:15 to leave at 7:30. The server slept, and at 7:44 the
    // check fails: leaving now no longer arrives at 7:50.
    const trip = headsUpSent({ evaluatedAt: t('07:15') });
    const { change, alerts } = decide(trip, failed(), t('07:44'));
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
    assert.equal(alerts[0].title, 'Time to leave for Chem lab');
    assert.equal(
      alerts[0].body,
      'You planned to leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be re-checked since 7:15 AM.',
    );
    assert.equal(alerts[0].payload.departAt, DEPART_AT.toISOString());
    assert.deepEqual(alerts[0].expiresAt, ARRIVE_BY);
    assert.deepEqual(change.leaveSentAt, t('07:44'));
  });

  it('counts a stored departure as well past only beyond the lag a late check is allowed', () => {
    const trip = headsUpSent({ evaluatedAt: t('07:15') });
    const bodyAt = (now: Date) => decide(trip, failed(), now).alerts[0].body;
    const onTime =
      'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM.';
    // Two minutes are allowed, counted in whole minutes like the times.
    assert.equal(bodyAt(t('07:32')), onTime);
    assert.equal(bodyAt(seconds(59, t('07:32'))), onTime);
    assert.equal(
      bodyAt(t('07:33')),
      'You planned to leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be re-checked since 7:15 AM.',
    );
  });

  it('words a late "leave now" that could not be asked about again as the older answer it is', () => {
    // Asked at 7:44 about the lattice instant 7:30 and told "leave now";
    // the second question, about 7:44, failed.
    const lagged = asOf(DEPART_AT, leaveNowAt(DEPART_AT));
    const { change, alerts } = decide(headsUpSent(), lagged, t('07:44'));
    assert.equal(
      alerts[0].body,
      'You planned to leave at 7:30 AM. Your target is 8:00 AM. Traffic could not be re-checked since 7:30 AM.',
    );
    assert.deepEqual(change.evaluatedAt, DEPART_AT);
    // Asked on time, the same answer is one to act on.
    assert.equal(
      decide(headsUpSent(), lagged, seconds(45, DEPART_AT)).alerts[0].body,
      'Leave at 7:30 AM to arrive around 7:50 AM. Your target is 8:00 AM.',
    );
  });

  it('does not send the leave alert before the stored departure', () => {
    const { alerts, change } = decide(headsUpSent(), failed(), t('07:29'));
    assert.deepEqual(alerts, []);
    assert.deepEqual(change.nextCheckAt, DEPART_AT);
  });

  it('does not tell somebody already told they are late to leave', () => {
    const trip = headsUpSent({
      action: 'leave_now',
      departAt: t('07:45'),
      arriveAt: t('08:05'),
      lateByMinutes: 5,
      lateSentAt: t('07:45'),
    });
    const { alerts } = decide(trip, failed(), t('07:46'));
    assert.deepEqual(alerts, []);
  });

  it('is forgotten at the next success, which leaves the plan as it was', () => {
    const trip = headsUpSent();
    const down = decide(trip, failed(), t('06:15'));
    const up = decide(after(trip, down.change), got(), t('06:16'));
    assert.deepEqual(up.alerts, []);
    assert.deepEqual(up.change.departAt, DEPART_AT);
    assert.deepEqual(up.change.notifiedDepartAt, DEPART_AT);
    assert.equal(up.change.lastErrorCode, null);
    assert.equal(up.change.lastErrorAt, null);
    assert.equal(up.change.evalFailures, 0);
    assert.deepEqual(up.change.evaluatedAt, t('06:16'));
    assert.deepEqual(up.change.nextCheckAt, t('06:30'));
  });
});

describe('a check with no departure to recommend', () => {
  const noPlan: Evaluation = {
    outcome: 'no_plan',
    reason: 'Traffic is steady, so there is no need to go yet.',
  };

  it('keeps a trip without a plan in planning, and asks again in half an hour', () => {
    const { change, alerts } = decide(
      row({
        evalFailures: 1,
        lastErrorCode: 'internal',
        lastErrorAt: t('04:59'),
      }),
      noPlan,
      t('05:00'),
    );
    assert.deepEqual(alerts, []);
    assert.equal(change.phase, 'planning');
    assert.equal(change.noPlanReason, noPlan.reason);
    assert.deepEqual(change.nextCheckAt, t('05:30'));
    assert.equal(change.lastErrorCode, null);
    assert.equal(change.evalFailures, 0);
  });

  it('does not put the next check past the arrival time', () => {
    const { change } = decide(row(), noPlan, t('07:50'));
    assert.deepEqual(change.nextCheckAt, ARRIVE_BY);
  });

  it('asks again in half an hour for a trip added back after its leave alert', () => {
    const addedBack = row({
      phase: 'monitoring',
      anchorAt: DEPART_AT,
      headsUpState: 'sent',
      leaveSentAt: t('07:00'),
    });
    const { change, alerts } = decide(addedBack, noPlan, t('07:10'));
    assert.deepEqual(alerts, []);
    assert.deepEqual(change.nextCheckAt, t('07:40'));
  });

  it('keeps a plan the trip already has, and asks again a slot later', () => {
    const { change, alerts } = decide(headsUpSent(), noPlan, t('06:15'));
    assert.deepEqual(alerts, []);
    assert.deepEqual(change.departAt, DEPART_AT);
    assert.deepEqual(change.evaluatedAt, t('06:00'));
    assert.equal(change.noPlanReason, noPlan.reason);
    assert.deepEqual(change.nextCheckAt, t('06:30'));
  });

  it('still sends what the clock alone decides', () => {
    const { alerts } = decide(
      headsUpSent({ evaluatedAt: t('07:15') }),
      noPlan,
      DEPART_AT,
    );
    assert.deepEqual(
      alerts.map(alert => alert.kind),
      ['leave_now'],
    );
  });
});

describe('every decision', () => {
  it('sets the next check after now and no later than the arrival time', () => {
    const trips = [row(), planned(t('05:00')), headsUpSent()];
    const evaluations = [
      got(),
      got({ departAt: t('07:15'), arriveAt: t('07:50') }),
      failed(),
      failed('no_coverage'),
      { outcome: 'no_plan', reason: 'No rush.' } as Evaluation,
    ];
    for (const trip of trips) {
      for (const evaluation of evaluations) {
        for (let minute = 0; minute < 180; minute += 7) {
          const now = new Date(t('05:00').getTime() + minute * 60_000 - 1);
          const { change, alerts } = decide(trip, evaluation, now);
          assert.ok(change.nextCheckAt !== null);
          assert.ok(change.nextCheckAt.getTime() > now.getTime());
          assert.ok(change.nextCheckAt.getTime() <= ARRIVE_BY.getTime());
          assert.ok(alerts.length <= 1);
        }
      }
    }
  });
});
