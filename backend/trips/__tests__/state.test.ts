// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { DEFAULT_MONITOR_CONFIG, PLANNING_HORIZON_MINUTES } from '../config';
import { tripStateOf } from '../service';
import { TripAlerts, TripRow } from '../store';

const NOW = new Date('2026-11-20T15:00:00.000Z');
const minutes = (n: number, from: Date = NOW) =>
  new Date(from.getTime() + n * 60_000);
const at = (n: number) => minutes(n).toISOString();

const ARRIVE_BY = minutes(240);
const DEPART_AT = minutes(180);

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
  nextCheckAt: NOW,
  leaseToken: null,
  leaseUntil: null,
  createdAt: NOW,
  updatedAt: NOW,
  endedAt: null,
  ...over,
});

/** What the monitor stores with a recommendation. */
const planned: Partial<TripRow> = {
  phase: 'planned',
  action: 'leave_later',
  departAt: DEPART_AT,
  arriveAt: minutes(228),
  driveMinutes: 48,
  reason: 'Leave at 10:00 to arrive by 11:00.',
  confidence: 'High',
  confidenceReason: 'Plenty of data for this route.',
  notes: ['Light rain expected.'],
  marginMinutes: 12,
  source: { baseline: 'tomtom', fallback: false, live: true },
  evaluatedAt: NOW,
  anchorAt: DEPART_AT,
  nextCheckAt: minutes(60),
};

const state = (over: Partial<TripRow> = {}, now: Date = NOW) =>
  tripStateOf(row(over), now);

describe('what a client is told about a trip', () => {
  it('describes a trip waiting for its first plan', () => {
    assert.deepEqual(state(), {
      id: 'A1B2C3@2026-11-20',
      arriveBy: ARRIVE_BY.toISOString(),
      phase: 'planning',
      recommendation: null,
      noPlanReason: null,
      planAvailableAt: null,
      monitoring: {
        startsAt: null,
        startedAt: null,
        headsUpAt: null,
        headsUpSentAt: null,
        leaveAlertSentAt: null,
        endsAt: ARRIVE_BY.toISOString(),
        nextCheckAt: NOW.toISOString(),
        lastAlert: null,
      },
      lastError: null,
    });
  });

  it('describes a planned trip with its recommendation', () => {
    assert.deepEqual(state(planned), {
      id: 'A1B2C3@2026-11-20',
      arriveBy: ARRIVE_BY.toISOString(),
      phase: 'planned',
      recommendation: {
        action: 'leave_later',
        departAt: at(180),
        arriveAt: at(228),
        driveMinutes: 48,
        reason: 'Leave at 10:00 to arrive by 11:00.',
        confidence: 'High',
        confidenceReason: 'Plenty of data for this route.',
        notes: ['Light rain expected.'],
        marginMinutes: 12,
        evaluatedAt: NOW.toISOString(),
        source: { baseline: 'tomtom', fallback: false, live: true },
        stale: false,
      },
      noPlanReason: null,
      planAvailableAt: null,
      monitoring: {
        // Two hours and ninety minutes before the departure.
        startsAt: at(60),
        startedAt: null,
        headsUpAt: at(90),
        headsUpSentAt: null,
        leaveAlertSentAt: null,
        endsAt: ARRIVE_BY.toISOString(),
        nextCheckAt: at(60),
        lastAlert: null,
      },
      lastError: null,
    });
  });

  it('says how late a trip will be instead of its margin', () => {
    const { recommendation } = state({
      ...planned,
      action: 'leave_now',
      marginMinutes: null,
      lateByMinutes: 7,
    });
    assert.equal(recommendation?.lateByMinutes, 7);
    assert.ok(recommendation && !('marginMinutes' in recommendation));
  });

  it('fills in what a stored plan leaves out', () => {
    const { recommendation } = state({
      ...planned,
      notes: null,
      source: null,
      marginMinutes: null,
    });
    assert.deepEqual(recommendation?.notes, []);
    assert.deepEqual(recommendation?.source, {
      baseline: 'unknown',
      fallback: false,
      live: false,
    });
    assert.ok(recommendation && !('lateByMinutes' in recommendation));
    assert.ok(recommendation && !('marginMinutes' in recommendation));
  });

  it('uses the lead times it is configured with', () => {
    const { monitoring } = tripStateOf(row(planned), NOW, {
      ...DEFAULT_MONITOR_CONFIG,
      monitorLeadMinutes: 60,
      headsUpLeadMinutes: 30,
    });
    assert.equal(monitoring.startsAt, at(120));
    assert.equal(monitoring.headsUpAt, at(150));
  });

  it('passes on why there is no departure to recommend yet', () => {
    const told = state({ noPlanReason: 'There is no rush yet.' });
    assert.equal(told.noPlanReason, 'There is no rush yet.');
    assert.equal(told.recommendation, null);
  });
});

describe('the phase', () => {
  it('is scheduled beyond the planning horizon, with when a plan is due', () => {
    const arriveBy = minutes(PLANNING_HORIZON_MINUTES + 30);
    const told = state({
      phase: 'scheduled',
      arriveBy,
      nextCheckAt: minutes(30),
    });
    assert.equal(told.phase, 'scheduled');
    assert.equal(told.planAvailableAt, at(30));
    assert.equal(told.monitoring.nextCheckAt, at(30));
  });

  it('is planning from the moment the trip enters the horizon', () => {
    const arriveBy = minutes(PLANNING_HORIZON_MINUTES + 30);
    const scheduled = { phase: 'scheduled', arriveBy } as const;
    assert.equal(state(scheduled, minutes(29)).phase, 'scheduled');
    // The monitor has not looked yet, but the answer is already right.
    const entered = state(scheduled, minutes(30));
    assert.equal(entered.phase, 'planning');
    assert.equal(entered.planAvailableAt, null);
  });

  it('is planned only for a trip that has a plan', () => {
    assert.equal(state(planned).phase, 'planned');
    // Monitored again after a cancellation erased its plan.
    assert.equal(state({ phase: 'planned' }).phase, 'planning');
  });

  it('is monitoring once the monitor says so', () => {
    const told = state({
      ...planned,
      phase: 'monitoring',
      monitoringStartedAt: minutes(-5),
    });
    assert.equal(told.phase, 'monitoring');
    assert.equal(told.monitoring.startedAt, at(-5));
  });

  it('is departed once the user has left, even past the arrival time', () => {
    const left = { status: 'departed', nextCheckAt: null } as const;
    assert.equal(state(left).phase, 'departed');
    assert.equal(state(left, minutes(300)).phase, 'departed');
  });

  it('is ended for a trip stored as ended', () => {
    assert.equal(state({ status: 'ended', nextCheckAt: null }).phase, 'ended');
  });

  it('is ended at the arrival time whether or not the monitor has noticed', () => {
    const monitored = { ...planned, phase: 'monitoring' } as const;
    assert.equal(state(monitored, minutes(239)).phase, 'monitoring');
    const told = state(
      { ...monitored, lastErrorCode: 'internal', lastErrorAt: minutes(200) },
      minutes(240),
    );
    assert.equal(told.phase, 'ended');
    // Nothing about a trip that is over is still advice.
    assert.equal(told.recommendation, null);
    assert.equal(told.monitoring.startsAt, null);
    assert.equal(told.monitoring.headsUpAt, null);
    assert.equal(told.monitoring.nextCheckAt, null);
    assert.equal(told.lastError, null);
  });
});

describe('a stale recommendation', () => {
  const staleAt = (over: Partial<TripRow>, now: Date) =>
    state({ ...planned, ...over }, now).recommendation?.stale;

  it('is one whose next check is more than 5 minutes overdue', () => {
    assert.equal(staleAt({ nextCheckAt: minutes(60) }, minutes(65)), false);
    assert.equal(staleAt({ nextCheckAt: minutes(60) }, minutes(66)), true);
  });

  it('is so in any phase', () => {
    assert.equal(
      staleAt({ phase: 'monitoring', nextCheckAt: minutes(60) }, minutes(70)),
      true,
    );
  });

  it('is one that checks have been failing on for over 30 minutes', () => {
    const failing = {
      lastErrorCode: 'routing_unavailable',
      lastErrorAt: minutes(29),
      nextCheckAt: minutes(32),
    };
    assert.equal(staleAt(failing, minutes(30)), false);
    assert.equal(staleAt(failing, minutes(31)), true);
  });

  it('is not one that was refreshed after its last failure', () => {
    const recovered = {
      lastErrorCode: 'routing_unavailable',
      lastErrorAt: minutes(-10),
      nextCheckAt: minutes(45),
    };
    assert.equal(staleAt(recovered, minutes(40)), false);
  });
});

describe('the last evaluation failure', () => {
  it('is reported with its code and time', () => {
    for (const code of [
      'routing_unavailable',
      'no_coverage',
      'internal',
      'budget_exhausted',
    ]) {
      assert.deepEqual(
        state({ lastErrorCode: code, lastErrorAt: minutes(-2) }).lastError,
        { code, at: at(-2) },
      );
    }
  });

  it('is reported as internal when the code is not one clients know', () => {
    assert.deepEqual(
      state({ lastErrorCode: 'TypeError', lastErrorAt: NOW }).lastError,
      { code: 'internal', at: NOW.toISOString() },
    );
  });
});

describe('alerts', () => {
  it('are claimed as sent only when the outbox says so', () => {
    // The monitor's own note that it queued the heads-up is not enough.
    const queued = state({
      ...planned,
      phase: 'monitoring',
      headsUpState: 'sent',
      headsUpSentAt: NOW,
      leaveSentAt: NOW,
    });
    assert.equal(queued.monitoring.headsUpSentAt, null);
    assert.equal(queued.monitoring.leaveAlertSentAt, null);
    assert.equal(queued.monitoring.lastAlert, null);
  });

  it('are passed on from the outbox', () => {
    const alerts: TripAlerts = {
      headsUpSentAt: minutes(1),
      leaveAlertSentAt: minutes(92),
      lastAlert: {
        kind: 'late',
        status: 'dropped',
        at: minutes(95),
        reason: 'expired',
      },
    };
    const told = tripStateOf(row(planned), NOW, DEFAULT_MONITOR_CONFIG, alerts);
    assert.equal(told.monitoring.headsUpSentAt, at(1));
    assert.equal(told.monitoring.leaveAlertSentAt, at(92));
    assert.deepEqual(told.monitoring.lastAlert, {
      kind: 'late',
      status: 'dropped',
      at: at(95),
      reason: 'expired',
    });
  });

  it('leave out the reason when there is none', () => {
    const told = tripStateOf(row(planned), NOW, DEFAULT_MONITOR_CONFIG, {
      headsUpSentAt: null,
      leaveAlertSentAt: null,
      lastAlert: { kind: 'heads_up', status: 'queued', at: NOW },
    });
    assert.deepEqual(told.monitoring.lastAlert, {
      kind: 'heads_up',
      status: 'queued',
      at: NOW.toISOString(),
    });
  });
});
