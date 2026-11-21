// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  DEFAULT_MONITOR_BUDGET,
  DEFAULT_TICK_SECONDS,
  monitorBudgetFromEnv,
  monitorSwitchesFromEnv,
  tickSecondsFromEnv,
} from '../config';

const warned = <T>(
  read: (
    env: Record<string, string | undefined>,
    warn: (message: string) => void,
  ) => T,
  env: Record<string, string | undefined>,
) => {
  const warnings: string[] = [];
  const value = read(env, message => warnings.push(message));
  return { value, warnings };
};

describe('monitorSwitchesFromEnv', () => {
  it('leaves the worker off unless MONITOR says on', () => {
    assert.deepEqual(monitorSwitchesFromEnv({}), {
      enabled: false,
      alwaysOn: false,
    });
    for (const value of ['off', 'true', '1', 'yes', '']) {
      assert.equal(monitorSwitchesFromEnv({ MONITOR: value }).enabled, false);
    }
  });

  it('turns it on with MONITOR=on', () => {
    assert.equal(monitorSwitchesFromEnv({ MONITOR: 'on' }).enabled, true);
    assert.equal(monitorSwitchesFromEnv({ MONITOR: ' ON ' }).enabled, true);
  });

  it('believes a server is always on only when told MONITOR_ALWAYS_ON=true', () => {
    assert.equal(
      monitorSwitchesFromEnv({ MONITOR_ALWAYS_ON: 'true' }).alwaysOn,
      true,
    );
    for (const value of ['on', '1', 'yes', 'false', '']) {
      assert.equal(
        monitorSwitchesFromEnv({ MONITOR_ALWAYS_ON: value }).alwaysOn,
        false,
      );
    }
  });
});

describe('monitorBudgetFromEnv', () => {
  it('is 10 evaluations a tick and 150 a day unless told', () => {
    const { value, warnings } = warned(monitorBudgetFromEnv, {});
    assert.deepEqual(value, { evaluationsPerTick: 10, dailyEvaluations: 150 });
    assert.deepEqual(value, DEFAULT_MONITOR_BUDGET);
    assert.deepEqual(warnings, []);
  });

  it('reads the daily budget from MONITOR_DAILY_EVALUATION_BUDGET', () => {
    const { value, warnings } = warned(monitorBudgetFromEnv, {
      MONITOR_DAILY_EVALUATION_BUDGET: '400',
    });
    assert.deepEqual(value, { evaluationsPerTick: 10, dailyEvaluations: 400 });
    assert.deepEqual(warnings, []);
    assert.equal(DEFAULT_MONITOR_BUDGET.dailyEvaluations, 150);
  });

  it('accepts zero, which stops every provider call', () => {
    const { value } = warned(monitorBudgetFromEnv, {
      MONITOR_DAILY_EVALUATION_BUDGET: '0',
    });
    assert.equal(value.dailyEvaluations, 0);
  });

  for (const bad of ['lots', '-5', '1.5', '1e3', '100001']) {
    it(`ignores ${JSON.stringify(bad)}, warning once without the value`, () => {
      const { value, warnings } = warned(monitorBudgetFromEnv, {
        MONITOR_DAILY_EVALUATION_BUDGET: bad,
      });
      assert.deepEqual(value, DEFAULT_MONITOR_BUDGET);
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0].includes('MONITOR_DAILY_EVALUATION_BUDGET'));
      assert.ok(!warnings[0].includes(bad));
    });
  }
});

describe('tickSecondsFromEnv', () => {
  it('is a minute unless told', () => {
    assert.equal(DEFAULT_TICK_SECONDS, 60);
    assert.deepEqual(warned(tickSecondsFromEnv, {}), {
      value: 60,
      warnings: [],
    });
  });

  it('reads MONITOR_TICK_SECONDS', () => {
    assert.deepEqual(
      warned(tickSecondsFromEnv, { MONITOR_TICK_SECONDS: '30' }),
      { value: 30, warnings: [] },
    );
  });

  for (const bad of ['fast', '0', '5', '901', '60.5']) {
    it(`ignores ${JSON.stringify(bad)}, warning once without the value`, () => {
      const { value, warnings } = warned(tickSecondsFromEnv, {
        MONITOR_TICK_SECONDS: bad,
      });
      assert.equal(value, 60);
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0].includes('MONITOR_TICK_SECONDS'));
    });
  }
});
