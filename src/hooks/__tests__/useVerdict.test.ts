import { act } from 'react-test-renderer';
import { LatLng, Place } from '../../api/types';
import { DEFAULT_SETTINGS } from '../../lib/request';
import { LocationError } from '../../location/errors';
import { sampleResponse } from '../../samples';
import { flush, renderHook } from '../../testing';
import { Trip } from '../../trip/types';
import {
  LOCATION_REUSE_MS,
  REFRESH_MS,
  useVerdict,
  UseVerdictInput,
} from '../useVerdict';

const START = new Date('2026-10-21T14:00:00Z');
const place = (id: string, lat: number, lng: number): Place => ({
  id,
  name: `Place ${id}`,
  address: id,
  lat,
  lng,
});
const home = place('home', 38.2383, -122.0402);
const campus = place('campus', 38.5593, -121.4237);

/** A stand-in backend that records the trip of every request it gets. */
function backend() {
  const bodies: Array<{ origin: LatLng; destination: LatLng }> = [];
  const fetchFn = jest.fn(async (_url: string, init?: RequestInit) => {
    bodies.push(JSON.parse(init!.body as string));
    return {
      ok: true,
      status: 200,
      json: async () => sampleResponse('leave_now', START),
    } as Response;
  });
  return {
    fetchFn: fetchFn as unknown as typeof fetch,
    bodies,
    calls: fetchFn,
  };
}

function setup(trip: Trip, extra: Partial<UseVerdictInput> = {}) {
  const api = backend();
  const input = (
    t: Trip,
    more: Partial<UseVerdictInput> = {},
  ): UseVerdictInput => ({
    source: 'live',
    trip: t,
    settings: DEFAULT_SETTINGS,
    baseUrl: 'http://h:3000',
    fetchFn: api.fetchFn,
    now: () => new Date(),
    ...extra,
    ...more,
  });
  const hook = renderHook(() => useVerdict(input(trip)));
  return {
    ...api,
    hook,
    with: (t: Trip, more: Partial<UseVerdictInput> = {}) =>
      hook.rerender(() => useVerdict(input(t, more))),
  };
}

beforeEach(() => jest.useFakeTimers().setSystemTime(START));
afterEach(() => jest.useRealTimers());

describe('useVerdict without a destination', () => {
  it('asks nothing, and is not stuck loading', async () => {
    const locate = jest.fn();
    const t = setup({ from: { kind: 'current' } }, { locate });
    await flush(2000);
    expect(t.calls).not.toHaveBeenCalled();
    expect(locate).not.toHaveBeenCalled(); // no permission prompt before a trip exists
    expect(t.hook.result.current).toMatchObject({
      loading: false,
      refreshing: false,
      locating: false,
    });
    expect(t.hook.result.current.response).toBeUndefined();
  });

  it('starts as soon as a destination is chosen', async () => {
    const t = setup({ from: { kind: 'place', place: home } });
    await flush(1);
    expect(t.calls).not.toHaveBeenCalled();
    t.with({ from: { kind: 'place', place: home }, to: campus });
    await flush(600);
    expect(t.calls).toHaveBeenCalledTimes(1);
    expect(t.hook.result.current.response).toBeDefined();
  });

  it('still shows a sample, which ignores the trip', async () => {
    const locate = jest.fn();
    const t = setup({ from: { kind: 'current' } }, { source: 'wait', locate });
    await flush(1);
    expect(t.hook.result.current.response?.verdict.action).toBe('wait');
    expect(t.calls).not.toHaveBeenCalled();
    expect(locate).not.toHaveBeenCalled();
  });
});

describe('useVerdict from a chosen place', () => {
  it('sends that place as the start, without using the location', async () => {
    const locate = jest.fn();
    const t = setup(
      { from: { kind: 'place', place: home }, to: campus },
      { locate },
    );
    await flush(1);
    expect(t.bodies[0]).toMatchObject({
      origin: { lat: 38.2383, lng: -122.0402 },
      destination: { lat: 38.5593, lng: -121.4237 },
    });
    expect(locate).not.toHaveBeenCalled();
  });
});

describe('useVerdict from the current location', () => {
  const trip: Trip = { from: { kind: 'current' }, to: campus };

  it('asks the phone where it is and starts from there', async () => {
    const onLocated = jest.fn();
    const locate = jest.fn().mockResolvedValue({ lat: 38.1, lng: -121.9 });
    const t = setup(trip, { locate, onLocated });
    await flush(1);
    expect(locate).toHaveBeenCalledTimes(1);
    expect(t.bodies[0].origin).toEqual({ lat: 38.1, lng: -121.9 });
    expect(onLocated).toHaveBeenCalledWith({ lat: 38.1, lng: -121.9 });
  });

  it('says it is locating while it waits for the phone', async () => {
    let found!: (p: LatLng) => void;
    const locate = jest.fn(
      () => new Promise<LatLng>(resolve => (found = resolve)),
    );
    const t = setup(trip, { locate });
    await flush(1);
    expect(t.hook.result.current.locating).toBe(true);
    expect(t.calls).not.toHaveBeenCalled();
    found({ lat: 38.1, lng: -121.9 });
    await flush();
    expect(t.hook.result.current.locating).toBe(false);
    expect(t.calls).toHaveBeenCalledTimes(1);
  });

  it('asks the phone again on every refresh, so the answer follows the user', async () => {
    const locate = jest
      .fn()
      .mockResolvedValueOnce({ lat: 38.1, lng: -121.9 })
      .mockResolvedValueOnce({ lat: 38.4, lng: -121.6 });
    const t = setup(trip, { locate });
    await flush(1);
    await flush(REFRESH_MS);
    expect(locate).toHaveBeenCalledTimes(2);
    expect(t.bodies.map(b => b.origin)).toEqual([
      { lat: 38.1, lng: -121.9 },
      { lat: 38.4, lng: -121.6 },
    ]);
  });

  it('reuses a recent position when a setting changes, instead of asking again', async () => {
    const locate = jest.fn().mockResolvedValue({ lat: 38.1, lng: -121.9 });
    const t = setup(trip, { locate });
    await flush(1);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, arriveBy: { hour: 8, minute: 0 } },
    });
    await flush(1);
    expect(locate).toHaveBeenCalledTimes(1);
    expect(t.calls).toHaveBeenCalledTimes(2);
    expect(t.bodies[1].origin).toEqual({ lat: 38.1, lng: -121.9 });
  });

  it('asks the phone again once the position is a minute old', async () => {
    const locate = jest
      .fn()
      .mockResolvedValueOnce({ lat: 38.1, lng: -121.9 })
      .mockResolvedValueOnce({ lat: 38.4, lng: -121.6 });
    const t = setup(trip, { locate });
    await flush(1);
    await flush(LOCATION_REUSE_MS + 1);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, arriveBy: { hour: 8, minute: 0 } },
    });
    await flush(1);
    expect(locate).toHaveBeenCalledTimes(2);
    expect(t.bodies[1].origin).toEqual({ lat: 38.4, lng: -121.6 });
  });

  it('reports why when the position is not available, and asks no one', async () => {
    const locate = jest
      .fn()
      .mockRejectedValue(
        new LocationError('denied', 'Location is turned off.'),
      );
    const t = setup(trip, { locate });
    await flush(1);
    const { error, locating, loading } = t.hook.result.current;
    expect(error).toBeInstanceOf(LocationError);
    expect((error as LocationError).problem).toBe('denied');
    expect(locating).toBe(false);
    expect(loading).toBe(true); // still no answer to show
    expect(t.calls).not.toHaveBeenCalled();
  });

  it('can be tried again after a failure', async () => {
    const locate = jest
      .fn()
      .mockRejectedValueOnce(new LocationError('unavailable', 'No fix.'))
      .mockResolvedValue({ lat: 38.1, lng: -121.9 });
    const t = setup(trip, { locate });
    await flush(1);
    expect(t.hook.result.current.error).toBeDefined();
    act(() => {
      t.hook.result.current.refresh();
    });
    await flush();
    expect(t.hook.result.current.response).toBeDefined();
    expect(t.hook.result.current.error).toBeUndefined();
  });

  it('starts from the new start when it is switched to a place', async () => {
    const locate = jest.fn().mockResolvedValue({ lat: 38.1, lng: -121.9 });
    const t = setup(trip, { locate });
    await flush(1);
    t.with({ from: { kind: 'place', place: home }, to: campus }, { locate });
    await flush(600);
    expect(t.bodies[1].origin).toEqual(
      expect.objectContaining({ lat: 38.2383 }),
    );
    expect(locate).toHaveBeenCalledTimes(1);
  });

  it('ignores a position that arrives after the trip has changed', async () => {
    let found!: (p: LatLng) => void;
    const locate = jest.fn(
      () => new Promise<LatLng>(resolve => (found = resolve)),
    );
    const t = setup(trip, { locate });
    await flush(1);
    t.with({ from: { kind: 'place', place: home }, to: campus }, { locate });
    await flush(600);
    found({ lat: 1, lng: 1 }); // the old position arrives late
    await flush();
    expect(t.bodies).toHaveLength(1);
    expect(t.bodies[0].origin).toEqual(
      expect.objectContaining({ lat: 38.2383 }),
    );
  });
});

describe('useVerdict timing', () => {
  const trip: Trip = { from: { kind: 'place', place: home }, to: campus };

  it('answers at once on launch and when a place is picked', async () => {
    const t = setup(trip);
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(1);
    t.with({
      from: { kind: 'place', place: home },
      to: place('sfsu', 37.72, -122.48),
    });
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(2);
  });

  it('waits for quick preference edits to settle before asking again', async () => {
    const t = setup(trip);
    await flush(1);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, maxWaitMinutes: 60 },
    });
    await flush(100);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, maxWaitMinutes: 45 },
    });
    await flush(400);
    expect(t.calls).toHaveBeenCalledTimes(1); // still waiting for taps to stop
    await flush(200);
    expect(t.calls).toHaveBeenCalledTimes(2);
  });

  it('asks at once when Leave by or Arrive by is set or cleared', async () => {
    const t = setup(trip);
    await flush(1);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, arriveBy: { hour: 8, minute: 0 } },
    });
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(2);
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, leaveBy: { hour: 7, minute: 0 } },
    });
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(3);
    t.with(trip);
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(4);
  });

  it('keeps the old answer on screen while a changed setting loads', async () => {
    const t = setup(trip);
    await flush(1);
    const before = t.hook.result.current.response;
    expect(before).toBeDefined();
    let answer!: (r: Response) => void;
    t.calls.mockImplementationOnce(
      () => new Promise<Response>(resolve => (answer = resolve)),
    );
    t.with(trip, {
      settings: { ...DEFAULT_SETTINGS, arriveBy: { hour: 8, minute: 0 } },
    });
    await flush(1);
    const waiting = t.hook.result.current;
    expect(waiting.response).toBe(before);
    expect(waiting.loading).toBe(false);
    expect(waiting.refreshing).toBe(true);
    answer({
      ok: true,
      status: 200,
      json: async () => sampleResponse('wait', START),
    } as Response);
    await flush();
    expect(t.hook.result.current.refreshing).toBe(false);
    expect(t.hook.result.current.response).not.toBe(before);
  });

  it('answers a restored trip at once even if the screen showed no trip first', async () => {
    const t = setup(
      { from: { kind: 'current' } },
      { locate: jest.fn().mockResolvedValue({ lat: 38.1, lng: -121.9 }) },
    );
    await flush(1);
    expect(t.calls).not.toHaveBeenCalled();
    t.with(
      { from: { kind: 'current' }, to: campus },
      { locate: jest.fn().mockResolvedValue({ lat: 38.1, lng: -121.9 }) },
    );
    await flush(1);
    expect(t.calls).toHaveBeenCalledTimes(1);
  });
});

describe('useVerdict when the trip changes', () => {
  it('drops the old answer straight away, since it belongs to another trip', async () => {
    const t = setup({ from: { kind: 'place', place: home }, to: campus });
    await flush(1);
    expect(t.hook.result.current.response).toBeDefined();
    t.with({
      from: { kind: 'place', place: home },
      to: place('sfsu', 37.72, -122.48),
    });
    expect(t.hook.result.current.response).toBeUndefined();
    expect(t.hook.result.current.loading).toBe(true);
    await flush(600);
    expect(t.hook.result.current.response).toBeDefined();
  });

  it('stops refreshing once it is removed', async () => {
    const t = setup({ from: { kind: 'place', place: home }, to: campus });
    await flush(1);
    t.hook.unmount();
    await flush(REFRESH_MS * 3);
    expect(t.calls).toHaveBeenCalledTimes(1);
  });
});
