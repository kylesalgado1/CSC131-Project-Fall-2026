import { fetchJson } from '../http';
import { addMinutes, minutesBetween, startOfHourMs } from '../time';
import { TtlCache } from '../ttlCache';

describe('time helpers', () => {
  const t = new Date('2026-10-21T15:20:30Z');

  it('adds and measures minutes', () => {
    expect(addMinutes(t, 45).toISOString()).toBe('2026-10-21T16:05:30.000Z');
    expect(minutesBetween(t, addMinutes(t, 45))).toBe(45);
    expect(minutesBetween(addMinutes(t, 10), t)).toBe(-10);
  });

  it('rounds to whole minutes', () => {
    expect(minutesBetween(t, new Date(t.getTime() + 89_000))).toBe(1);
    expect(minutesBetween(t, new Date(t.getTime() + 91_000))).toBe(2);
  });

  it('finds the start of the hour', () => {
    expect(new Date(startOfHourMs(t.getTime())).toISOString()).toBe(
      '2026-10-21T15:00:00.000Z',
    );
  });
});

describe('fetchJson', () => {
  it('parses the body of a good response', async () => {
    const body = await fetchJson<{ a: number }>(
      async () => ({ ok: true, status: 200, json: async () => ({ a: 1 }) }),
      'http://x',
      'Svc',
    );
    expect(body).toEqual({ a: 1 });
  });

  it('throws the given error type naming the service and status', async () => {
    class CustomError extends Error {}
    await expect(
      fetchJson(
        async () => ({ ok: false, status: 503, json: async () => ({}) }),
        'http://x',
        'Svc',
        CustomError,
      ),
    ).rejects.toThrow(new CustomError('Svc request failed: HTTP 503'));
  });
});

describe('TtlCache', () => {
  it('loads once per key until the entry expires', async () => {
    let clock = 0;
    let loads = 0;
    const cache = new TtlCache<number>(1000, () => clock);
    const load = async () => ++loads;
    expect(await cache.get('a', load)).toBe(1);
    expect(await cache.get('a', load)).toBe(1);
    expect(await cache.get('b', load)).toBe(2);
    clock = 1500;
    expect(await cache.get('a', load)).toBe(3);
  });

  it('shares one load between requests that arrive together', async () => {
    let loads = 0;
    const cache = new TtlCache<number>(1000);
    const load = async () => {
      loads += 1;
      return 42;
    };
    const results = await Promise.all(
      Array.from({ length: 10 }, () => cache.get('a', load)),
    );
    expect(results).toEqual(Array(10).fill(42));
    expect(loads).toBe(1);
  });

  it('forgets a failed load so the next caller retries', async () => {
    const cache = new TtlCache<number>(1000);
    await expect(
      cache.get('a', () => Promise.reject(new Error('down'))),
    ).rejects.toThrow('down');
    expect(await cache.get('a', async () => 7)).toBe(7);
  });

  it('drops the oldest entries past its size limit', async () => {
    let loads = 0;
    const cache = new TtlCache<number>(1000, Date.now, 2);
    const load = async () => ++loads;
    await cache.get('a', load);
    await cache.get('b', load);
    await cache.get('c', load); // evicts a
    expect(loads).toBe(3);
    await cache.get('b', load);
    await cache.get('c', load);
    expect(loads).toBe(3);
    await cache.get('a', load);
    expect(loads).toBe(4);
  });
});
