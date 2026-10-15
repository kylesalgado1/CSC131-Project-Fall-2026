import { sampleResponse } from '../../samples';
import { ApiError, fetchVerdict } from '../client';
import { VerdictRequest } from '../types';

const request: VerdictRequest = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  preferences: { goal: 'balance' },
};
const body = sampleResponse('wait', new Date('2026-10-21T14:00:00Z'));

const respond = (status: number, json: unknown = {}) =>
  jest.fn(
    async () =>
      ({ ok: status < 400, status, json: async () => json } as Response),
  );

describe('fetchVerdict', () => {
  it('posts the trip as JSON and returns the answer', async () => {
    const fetchFn = respond(200, body);
    const result = await fetchVerdict('http://host:3000', request, { fetchFn });
    expect(result).toEqual(body);
    const [url, init] = fetchFn.mock.calls[0] as unknown as [
      string,
      RequestInit,
    ];
    expect(url).toBe('http://host:3000/verdict');
    expect(init.method).toBe('POST');
    expect(init.headers).toEqual({ 'content-type': 'application/json' });
    expect(JSON.parse(init.body as string)).toEqual(request);
  });

  it.each([
    [400, 'bad_request'],
    [422, 'no_coverage'],
    [502, 'routing_unavailable'],
    [500, 'server'],
    [503, 'server'],
  ])('turns HTTP %s into %s', async (status, kind) => {
    const error = await fetchVerdict('http://h', request, {
      fetchFn: respond(status),
    }).catch((e: ApiError) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).kind).toBe(kind);
    expect((error as ApiError).message.length).toBeGreaterThan(10);
  });

  it('explains a network failure in terms of the likely cause', async () => {
    const fetchFn = jest
      .fn()
      .mockRejectedValue(new TypeError('Network request failed'));
    const error = await fetchVerdict('http://h', request, { fetchFn }).catch(
      (e: ApiError) => e,
    );
    expect((error as ApiError).kind).toBe('network');
    expect((error as ApiError).message).toMatch(/same Wi-Fi/);
  });

  it('gives up when the server takes too long', async () => {
    jest.useFakeTimers();
    try {
      const fetchFn = jest.fn(
        (_url: unknown, init?: RequestInit) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener('abort', () =>
              reject(new Error('aborted')),
            );
          }),
      );
      const pending = fetchVerdict('http://h', request, {
        fetchFn: fetchFn as unknown as typeof fetch,
        timeoutMs: 1000,
      }).catch((e: ApiError) => e);
      await jest.advanceTimersByTimeAsync(1001);
      expect(((await pending) as ApiError).kind).toBe('network');
    } finally {
      jest.useRealTimers();
    }
  });
});
