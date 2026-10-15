import { Place } from '../../api/types';
import { flush, renderHook } from '../../testing';
import { usePlaceSearch } from '../usePlaceSearch';

const place = (id: string): Place => ({
  id,
  name: `Place ${id}`,
  address: `${id} St`,
  lat: 38,
  lng: -121,
});

/** A stand-in backend: answers each search with the places `answer` gives for it. */
function backend(answer: (q: string) => Place[] | Error | Promise<Place[]>) {
  const asked: string[] = [];
  const fetchFn = jest.fn(async (raw: string, init?: RequestInit) => {
    const url = new URL(raw);
    const q = url.searchParams.get('q')!;
    asked.push(url.search);
    const result = await answer(q);
    if (init?.signal?.aborted) {
      throw Object.assign(new Error('aborted'), { name: 'AbortError' });
    }
    if (result instanceof Error) {
      throw result;
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({ places: result }),
    } as Response;
  });
  return { fetchFn: fetchFn as unknown as typeof fetch, asked, calls: fetchFn };
}

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

const options = (fetchFn: typeof fetch) => ({
  baseUrl: 'http://h:3000',
  fetchFn,
});

describe('usePlaceSearch', () => {
  it('asks nothing until there are three letters', async () => {
    const { fetchFn, calls } = backend(() => [place('a')]);
    const hook = renderHook(() => usePlaceSearch('sa', options(fetchFn)));
    await flush(2000);
    expect(calls).not.toHaveBeenCalled();
    expect(hook.result.current).toMatchObject({ places: [], loading: false });
  });

  it('ignores spaces around the text', async () => {
    const { fetchFn, calls } = backend(() => [place('a')]);
    renderHook(() => usePlaceSearch('  s  ', options(fetchFn)));
    await flush(2000);
    expect(calls).not.toHaveBeenCalled();
  });

  it('waits for typing to pause, shows it is searching, then shows the places', async () => {
    const { fetchFn, calls } = backend(() => [place('a'), place('b')]);
    const hook = renderHook(() => usePlaceSearch('sac', options(fetchFn)));
    expect(hook.result.current.loading).toBe(true);
    await flush(200);
    expect(calls).not.toHaveBeenCalled();
    await flush(200);
    expect(calls).toHaveBeenCalledTimes(1);
    expect(hook.result.current).toMatchObject({
      loading: false,
      forQuery: 'sac',
    });
    expect(hook.result.current.places.map(p => p.id)).toEqual(['a', 'b']);
  });

  it('asks once for a burst of typing, using the final text', async () => {
    const { fetchFn, calls, asked } = backend(q => [place(q)]);
    const text = { current: 'sac' };
    const hook = renderHook(() =>
      usePlaceSearch(text.current, options(fetchFn)),
    );
    for (const next of ['sacr', 'sacra', 'sacram']) {
      text.current = next;
      hook.rerender(() => usePlaceSearch(next, options(fetchFn)));
      await flush(100);
    }
    await flush(400);
    expect(calls).toHaveBeenCalledTimes(1);
    expect(asked[0]).toContain('q=sacram');
    expect(hook.result.current.places[0].id).toBe('sacram');
  });

  it('ranks by where the user is when it knows', async () => {
    const { fetchFn, asked } = backend(() => []);
    renderHook(() =>
      usePlaceSearch('raleys', {
        ...options(fetchFn),
        near: { lat: 38.2383, lng: -122.0402 },
      }),
    );
    await flush(400);
    expect(asked[0]).toContain('lat=38.2383');
    expect(asked[0]).toContain('lng=-122.0402');
  });

  it('drops an answer that a newer search has replaced', async () => {
    let releaseSlow!: () => void;
    const slow = new Promise<Place[]>(resolve => {
      releaseSlow = () => resolve([place('old')]);
    });
    const { fetchFn } = backend(q => (q === 'sac' ? slow : [place('new')]));
    const hook = renderHook(() => usePlaceSearch('sac', options(fetchFn)));
    await flush(400); // the first search is now in flight
    hook.rerender(() => usePlaceSearch('sacr', options(fetchFn)));
    await flush(400);
    releaseSlow();
    await flush();
    expect(hook.result.current.places.map(p => p.id)).toEqual(['new']);
    expect(hook.result.current.forQuery).toBe('sacr');
  });

  it('says when nothing matched, so the screen can tell that from still typing', async () => {
    const { fetchFn } = backend(() => []);
    const hook = renderHook(() => usePlaceSearch('qqqq', options(fetchFn)));
    await flush(400);
    expect(hook.result.current).toMatchObject({
      places: [],
      loading: false,
      forQuery: 'qqqq',
    });
    expect(hook.result.current.error).toBeUndefined();
  });

  it('reports a failure and shows no places', async () => {
    const { fetchFn } = backend(() => new Error('down'));
    const hook = renderHook(() => usePlaceSearch('sac', options(fetchFn)));
    await flush(400);
    expect(hook.result.current.places).toEqual([]);
    expect(hook.result.current.error?.message).toMatch(
      /Could not reach the server/,
    );
    expect(hook.result.current.loading).toBe(false);
  });

  it('forgets earlier results when the text is cleared', async () => {
    const { fetchFn } = backend(() => [place('a')]);
    const hook = renderHook(() => usePlaceSearch('sac', options(fetchFn)));
    await flush(400);
    expect(hook.result.current.places).toHaveLength(1);
    hook.rerender(() => usePlaceSearch('', options(fetchFn)));
    expect(hook.result.current).toMatchObject({
      places: [],
      loading: false,
      forQuery: '',
    });
  });

  it('does nothing more after it is removed', async () => {
    const { fetchFn, calls } = backend(() => [place('a')]);
    const hook = renderHook(() => usePlaceSearch('sac', options(fetchFn)));
    hook.unmount();
    await flush(2000);
    expect(calls).not.toHaveBeenCalled();
  });
});
