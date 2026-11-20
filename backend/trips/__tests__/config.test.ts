// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  FAR_SLOT_INTERVAL_MINUTES,
  MAX_PLAN_MINUTES,
  slotTimesFor,
  SLOT_INTERVAL_MINUTES,
} from '../../prediction/predict';
import { DEFAULT_PREFERENCES } from '../../prediction/types';
import {
  DEFAULT_MONITOR_CONFIG,
  MAX_LEAD_MINUTES,
  monitorConfigFromEnv,
  MONITOR_POLL_MINUTES,
  PLANNING_HORIZON_MINUTES,
} from '../config';

const read = (env: Record<string, string | undefined>) => {
  const warnings: string[] = [];
  const config = monitorConfigFromEnv(env, message => warnings.push(message));
  return { config, warnings };
};

describe('the planning horizon', () => {
  it('is one far slot short of the farthest the prediction plans', () => {
    assert.equal(
      PLANNING_HORIZON_MINUTES,
      MAX_PLAN_MINUTES - FAR_SLOT_INTERVAL_MINUTES,
    );
    assert.equal(PLANNING_HORIZON_MINUTES, 690);
  });

  it('is where the slots first reach a target off the half hour', () => {
    const route = {
      origin: { lat: 38.2383, lng: -122.0402 },
      destination: { lat: 38.5593, lng: -121.4237 },
    };
    const arriveBy = new Date('2026-11-21T16:50:00Z');
    const lastSlot = (minutesAhead: number): Date => {
      const now = new Date(arriveBy.getTime() - minutesAhead * 60_000);
      const slots = slotTimesFor({
        route,
        now,
        preferences: { ...DEFAULT_PREFERENCES, goal: 'arrive_by', arriveBy },
      });
      return slots[slots.length - 1];
    };
    // At the horizon there is a slot at or after the target; at the farthest
    // the prediction plans, the slots stop short of it.
    assert.ok(lastSlot(PLANNING_HORIZON_MINUTES) >= arriveBy);
    assert.ok(lastSlot(MAX_PLAN_MINUTES) < arriveBy);
  });

  it('is checked as often as the prediction has slots', () => {
    assert.equal(MONITOR_POLL_MINUTES, SLOT_INTERVAL_MINUTES);
  });
});

describe('monitorConfigFromEnv', () => {
  it('is the defaults when nothing is set', () => {
    const { config, warnings } = read({});
    assert.deepEqual(config, DEFAULT_MONITOR_CONFIG);
    assert.deepEqual(config, {
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
    });
    assert.deepEqual(warnings, []);
  });

  it('reads each setting from its variable', () => {
    const { config, warnings } = read({
      MONITOR_LEAD_MINUTES: '150',
      HEADS_UP_LEAD_MINUTES: '60',
      MEANINGFUL_SHIFT_MINUTES: '10',
      UPDATE_MIN_INTERVAL_MINUTES: '20',
      MAX_UPDATES_PER_TRIP: '5',
      MONITOR_MAX_LAG_SECONDS: '90',
      TRIP_RETENTION_HOURS: '48',
    });
    assert.deepEqual(config, {
      ...DEFAULT_MONITOR_CONFIG,
      monitorLeadMinutes: 150,
      headsUpLeadMinutes: 60,
      meaningfulShiftMinutes: 10,
      updateMinIntervalMinutes: 20,
      maxUpdatesPerTrip: 5,
      maxLagSeconds: 90,
      retentionHours: 48,
    });
    assert.deepEqual(warnings, []);
  });

  it('does not change the defaults it starts from', () => {
    read({ MONITOR_LEAD_MINUTES: '150' });
    assert.equal(DEFAULT_MONITOR_CONFIG.monitorLeadMinutes, 120);
  });

  it('treats an empty variable as unset', () => {
    const { config, warnings } = read({ MONITOR_LEAD_MINUTES: '  ' });
    assert.deepEqual(config, DEFAULT_MONITOR_CONFIG);
    assert.deepEqual(warnings, []);
  });

  const unusable: Array<[string, string, string]> = [
    ['a word', 'MAX_UPDATES_PER_TRIP', 'many'],
    ['a fraction', 'MEANINGFUL_SHIFT_MINUTES', '7.5'],
    ['a negative number', 'UPDATE_MIN_INTERVAL_MINUTES', '-5'],
    ['a number in another notation', 'MAX_UPDATES_PER_TRIP', '1e1'],
    ['a value below the range', 'MEANINGFUL_SHIFT_MINUTES', '0'],
    ['a value above the range', 'MAX_UPDATES_PER_TRIP', '21'],
    ['a lag too short to be met', 'MONITOR_MAX_LAG_SECONDS', '5'],
    ['a lag as long as a slot', 'MONITOR_MAX_LAG_SECONDS', '900'],
    ['a lead that is not whole slots', 'MONITOR_LEAD_MINUTES', '100'],
    ['a lead of zero', 'MONITOR_LEAD_MINUTES', '0'],
    ['a lead beyond the slot horizon', 'MONITOR_LEAD_MINUTES', '195'],
    // At the whole horizon the slot after the departure is not yet in
    // sight, so the first plan named could move with traffic unchanged.
    ['a lead of the whole slot horizon', 'MONITOR_LEAD_MINUTES', '180'],
    ['a heads-up of the whole slot horizon', 'HEADS_UP_LEAD_MINUTES', '180'],
    ['a heads-up that is not whole slots', 'HEADS_UP_LEAD_MINUTES', '50'],
    [
      'a retention shorter than trips stay acceptable',
      'TRIP_RETENTION_HOURS',
      '12',
    ],
  ];
  for (const [name, variable, value] of unusable) {
    it(`ignores ${name}, warning once without the value`, () => {
      const { config, warnings } = read({ [variable]: value });
      assert.deepEqual(config, DEFAULT_MONITOR_CONFIG);
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0].includes(variable));
      assert.ok(!warnings[0].includes(value));
    });
  }

  it('keeps the usable settings beside an unusable one', () => {
    const { config, warnings } = read({
      MAX_UPDATES_PER_TRIP: 'lots',
      TRIP_RETENTION_HOURS: '72',
    });
    assert.equal(config.maxUpdatesPerTrip, 3);
    assert.equal(config.retentionHours, 72);
    assert.equal(warnings.length, 1);
  });

  it('accepts a heads-up as early as monitoring starts', () => {
    const { config, warnings } = read({
      MONITOR_LEAD_MINUTES: '90',
      HEADS_UP_LEAD_MINUTES: '90',
    });
    assert.equal(config.monitorLeadMinutes, 90);
    assert.equal(config.headsUpLeadMinutes, 90);
    assert.deepEqual(warnings, []);
  });

  it('accepts leads up to one slot short of the slot horizon', () => {
    assert.equal(MAX_LEAD_MINUTES, 165);
    const { config, warnings } = read({
      MONITOR_LEAD_MINUTES: '165',
      HEADS_UP_LEAD_MINUTES: '165',
    });
    assert.equal(config.monitorLeadMinutes, 165);
    assert.equal(config.headsUpLeadMinutes, 165);
    assert.deepEqual(warnings, []);
  });

  it('falls back to the defaults, with a warning each, when both leads are the whole horizon', () => {
    const { config, warnings } = read({
      MONITOR_LEAD_MINUTES: '180',
      HEADS_UP_LEAD_MINUTES: '180',
    });
    // Each is refused with its own warning; neither is left at 180.
    assert.deepEqual(config, DEFAULT_MONITOR_CONFIG);
    assert.equal(warnings.length, 2);
  });

  it('refuses a heads-up before monitoring starts', () => {
    const { config, warnings } = read({
      MONITOR_LEAD_MINUTES: '60',
      HEADS_UP_LEAD_MINUTES: '75',
    });
    assert.equal(config.monitorLeadMinutes, 120);
    assert.equal(config.headsUpLeadMinutes, 90);
    assert.equal(warnings.length, 1);
    assert.ok(warnings[0].includes('HEADS_UP_LEAD_MINUTES'));
    assert.ok(warnings[0].includes('MONITOR_LEAD_MINUTES'));
  });

  it('refuses a lead shorter than the default heads-up', () => {
    const { config, warnings } = read({ MONITOR_LEAD_MINUTES: '60' });
    assert.equal(config.monitorLeadMinutes, 120);
    assert.equal(config.headsUpLeadMinutes, 90);
    assert.equal(warnings.length, 1);
  });
});
