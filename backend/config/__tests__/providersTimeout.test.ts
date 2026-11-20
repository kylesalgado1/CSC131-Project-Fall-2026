import { Database } from '../../db/db';
import { Route } from '../../prediction/types';
import { buildProviders, TOMTOM_TIMEOUT_MS } from '../providers';

const KEY = 'SECRETKEY123';
const route: Route = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
};

/** Wiring must not read the database, so every call here is a failure. */
const unused = (): never => {
  throw new Error('The database was used while wiring the providers.');
};
const db: Database = {
  query: unused,
  exec: unused,
  transaction: unused,
  close: unused,
};

const osrmAnswer = {
  ok: true,
  status: 200,
  json: async () => ({
    code: 'Ok',
    routes: [
      {
        distance: 16093.44,
        duration: 600,
        geometry: {
          coordinates: [
            [-122.0402, 38.2383],
            [-121.4237, 38.5593],
          ],
        },
      },
    ],
  }),
};

describe('the TomTom client buildProviders wires up', () => {
  const realFetch = global.fetch;
  const fetchMock = jest.fn();

  beforeEach(() => {
    fetchMock.mockReset();
    global.fetch = fetchMock as unknown as typeof fetch;
  });

  afterEach(() => {
    global.fetch = realFetch;
  });

  it('gives every request 15 seconds, so one that hangs cannot hold up the rest', async () => {
    expect(TOMTOM_TIMEOUT_MS).toBe(15_000);
    const timeout = jest.spyOn(AbortSignal, 'timeout');
    try {
      fetchMock.mockResolvedValue({
        ok: false,
        status: 503,
        json: async () => ({}),
      });
      const { paths } = buildProviders(
        db,
        [],
        { TOMTOM_API_KEY: KEY },
        () => undefined,
      );
      await expect(paths.getPath(route)).rejects.toThrow();

      const tomtomCalls = fetchMock.mock.calls.filter(([url]) =>
        String(url).includes('api.tomtom.com'),
      );
      expect(tomtomCalls).toHaveLength(1);
      const [, init] = tomtomCalls[0];
      expect(init.signal).toBeInstanceOf(AbortSignal);
      expect(timeout).toHaveBeenCalledWith(15_000);
      // A signal of its own for each request.
      expect(timeout).toHaveBeenCalledTimes(1);
    } finally {
      timeout.mockRestore();
    }
  });

  it('falls back like any other failure when a request times out', async () => {
    const warnings: string[] = [];
    fetchMock.mockImplementation(async (url: string) => {
      if (String(url).includes('api.tomtom.com')) {
        // What fetch rejects with when its signal times out.
        throw new DOMException(
          'The operation was aborted due to timeout',
          'TimeoutError',
        );
      }
      return osrmAnswer;
    });
    const { paths } = buildProviders(db, [], { TOMTOM_API_KEY: KEY }, message =>
      warnings.push(message),
    );
    const path = await paths.getPath(route);
    expect(path.source).toBe('osrm');
    expect(path.fallback).toBe(true);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toMatch(/^TomTom failed, using PeMS: /);
    expect(warnings.join()).not.toContain(KEY);
  });

  it('gives the other services no deadline of this kind', async () => {
    fetchMock.mockResolvedValue(osrmAnswer);
    const { paths } = buildProviders(db, [], {});
    await paths.getPath(route);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][1]).toBeUndefined();
  });
});
