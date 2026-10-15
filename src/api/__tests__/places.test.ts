import { ApiError } from '../client';
import { isAbort, searchPlaces } from '../places';
import { Place } from '../types';

const place: Place = {
  id: 'a',
  name: 'Sacramento State',
  address: '6000 J St',
  lat: 38.56,
  lng: -121.42,
};
const reply = (status: number, json: unknown = { places: [place] }) =>
  jest.fn(
    async () =>
      ({ ok: status < 400, status, json: async () => json } as Response),
  );
const urlOf = (fetchFn: jest.Mock) =>
  new URL((fetchFn.mock.calls[0] as unknown as [string])[0]);

describe('searchPlaces', () => {
  it('asks the backend for the text and returns the places', async () => {
    const fetchFn = reply(200);
    expect(
      await searchPlaces('http://h:3000', 'sac state', undefined, { fetchFn }),
    ).toEqual([place]);
    const url = urlOf(fetchFn);
    expect(url.origin + url.pathname).toBe('http://h:3000/places');
    expect(url.searchParams.get('q')).toBe('sac state');
    expect(url.searchParams.has('lat')).toBe(false);
  });

  it('adds where the user is, to rank nearby places first', async () => {
    const fetchFn = reply(200);
    await searchPlaces(
      'http://h',
      'raleys',
      { lat: 38.2383, lng: -122.0402 },
      { fetchFn },
    );
    expect(urlOf(fetchFn).searchParams.get('lat')).toBe('38.2383');
    expect(urlOf(fetchFn).searchParams.get('lng')).toBe('-122.0402');
  });

  it('encodes text that would break a web address', async () => {
    const fetchFn = reply(200);
    await searchPlaces('http://h', "raley's & co #1", undefined, { fetchFn });
    expect(urlOf(fetchFn).searchParams.get('q')).toBe("raley's & co #1");
  });

  it.each([
    [400, 'bad_request'],
    [502, 'search_unavailable'],
    [503, 'search_unavailable'],
    [500, 'server'],
  ])('turns HTTP %s into %s', async (status, kind) => {
    const error = await searchPlaces('http://h', 'sac', undefined, {
      fetchFn: reply(status),
    }).catch((e: ApiError) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).kind).toBe(kind);
  });

  it('explains a network failure', async () => {
    const fetchFn = jest
      .fn()
      .mockRejectedValue(new TypeError('Network request failed'));
    const error = await searchPlaces('http://h', 'sac', undefined, {
      fetchFn,
    }).catch((e: ApiError) => e);
    expect((error as ApiError).kind).toBe('network');
    expect((error as ApiError).message).toMatch(/same Wi-Fi/);
  });

  it('lets a newer search cancel it, and reports that as a cancellation', async () => {
    const controller = new AbortController();
    const fetchFn = jest.fn(
      (_url: unknown, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () =>
            reject(Object.assign(new Error('aborted'), { name: 'AbortError' })),
          );
        }),
    );
    const pending = searchPlaces('http://h', 'sac', undefined, {
      fetchFn: fetchFn as unknown as typeof fetch,
      signal: controller.signal,
    }).catch((e: Error) => e);
    controller.abort();
    expect(isAbort(await pending)).toBe(true);
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
      const pending = searchPlaces('http://h', 'sac', undefined, {
        fetchFn: fetchFn as unknown as typeof fetch,
        timeoutMs: 500,
      }).catch((e: ApiError) => e);
      await jest.advanceTimersByTimeAsync(501);
      expect(((await pending) as ApiError).kind).toBe('network');
    } finally {
      jest.useRealTimers();
    }
  });
});
