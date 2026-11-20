// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// Fastify depends on an ES-module-only package that Jest cannot load.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { trustProxyFromEnv } from '../server';
import { FixedWindowLimiter } from '../tripRoutes';

describe('FixedWindowLimiter', () => {
  it('allows the limit in each window, per key', () => {
    let now = 0;
    const limiter = new FixedWindowLimiter(2, 1000, () => now);
    assert.equal(limiter.allow('a'), true);
    assert.equal(limiter.allow('a'), true);
    assert.equal(limiter.allow('a'), false);
    assert.equal(limiter.allow('b'), true);

    now = 999;
    assert.equal(limiter.allow('a'), false);
    now = 1000;
    assert.equal(limiter.allow('a'), true);
  });

  it('says how long until a key may try again', () => {
    let now = 0;
    const limiter = new FixedWindowLimiter(1, 60_000, () => now);
    assert.equal(limiter.retryAfterSeconds('a'), 0);
    limiter.allow('a');
    now = 15_500;
    assert.equal(limiter.retryAfterSeconds('a'), 45);
    now = 90_000;
    assert.equal(limiter.retryAfterSeconds('a'), 0);
  });

  it('starts a new window when the clock goes backwards', () => {
    let now = 5000;
    const limiter = new FixedWindowLimiter(1, 1000, () => now);
    assert.equal(limiter.allow('a'), true);
    now = 0;
    assert.equal(limiter.allow('a'), true);
    assert.equal(limiter.allow('a'), false);
  });

  it('forgets the oldest keys beyond its bound', () => {
    const limiter = new FixedWindowLimiter(1, 1000, () => 0, 2);
    assert.equal(limiter.allow('a'), true);
    assert.equal(limiter.allow('b'), true);
    assert.equal(limiter.allow('c'), true);
    // 'a' was dropped to make room, so it starts again; 'c' is remembered.
    assert.equal(limiter.allow('c'), false);
    assert.equal(limiter.allow('a'), true);
  });
});

describe('trustProxyFromEnv', () => {
  const read = (value?: string) => {
    const warnings: string[] = [];
    const trust = trustProxyFromEnv({ TRUST_PROXY: value }, message =>
      warnings.push(message),
    );
    return { trust, warnings };
  };

  it('trusts no proxy unless told to', () => {
    for (const value of [undefined, '', ' ', 'false', 'FALSE', '0']) {
      assert.deepEqual(read(value), { trust: false, warnings: [] });
    }
  });

  it('reads a number of proxies, or true for all', () => {
    assert.deepEqual(read('1'), { trust: 1, warnings: [] });
    assert.deepEqual(read(' 2 '), { trust: 2, warnings: [] });
    assert.deepEqual(read('true'), { trust: true, warnings: [] });
  });

  it('trusts none for anything else, warning without the value', () => {
    for (const value of ['yes', '-1', '1.5', '10.0.0.0/8']) {
      const { trust, warnings } = read(value);
      assert.equal(trust, false);
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0].includes('TRUST_PROXY'));
      assert.ok(!warnings[0].includes(value));
    }
  });
});
