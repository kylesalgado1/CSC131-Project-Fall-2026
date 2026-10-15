import AsyncStorage from '@react-native-async-storage/async-storage';
import { act } from 'react-test-renderer';
import { Place } from '../../api/types';
import { flush, renderHook } from '../../testing';
import { Trip } from '../../trip/types';
import { useTrip } from '../useTrip';

const place = (id: string, lat: number): Place => ({
  id,
  name: `Place ${id}`,
  address: `${id} St`,
  lat,
  lng: -121,
});
const a = place('a', 38.1);
const b = place('b', 38.2);
const c = place('c', 38.3);

const stored = async (key: string) =>
  JSON.parse((await AsyncStorage.getItem(key)) ?? 'null');

beforeEach(async () => {
  jest.useFakeTimers();
  await AsyncStorage.clear();
});
afterEach(() => jest.useRealTimers());

async function open() {
  const hook = renderHook(() => useTrip());
  await flush();
  return hook;
}

describe('useTrip', () => {
  it('starts at the current location with no destination', async () => {
    const hook = await open();
    expect(hook.result.current.ready).toBe(true);
    expect(hook.result.current.trip).toEqual({ from: { kind: 'current' } });
    expect(hook.result.current.recents).toEqual([]);
  });

  it('is not ready until what was saved has been read', async () => {
    const hook = renderHook(() => useTrip());
    expect(hook.result.current.ready).toBe(false);
    await flush();
    expect(hook.result.current.ready).toBe(true);
  });

  it('picks up where the user left off', async () => {
    const trip: Trip = { from: { kind: 'place', place: a }, to: b };
    await AsyncStorage.setItem('waitItOut.trip.v1', JSON.stringify(trip));
    await AsyncStorage.setItem('waitItOut.recents.v1', JSON.stringify([c]));
    const hook = await open();
    expect(hook.result.current.trip).toEqual(trip);
    expect(hook.result.current.recents).toEqual([c]);
  });

  it('does not overwrite the saved trip with a blank one while loading', async () => {
    const trip: Trip = { from: { kind: 'place', place: a }, to: b };
    await AsyncStorage.setItem('waitItOut.trip.v1', JSON.stringify(trip));
    await open();
    expect(await stored('waitItOut.trip.v1')).toEqual(trip);
  });

  it('saves a chosen destination and remembers it as recent', async () => {
    const hook = await open();
    act(() => hook.result.current.setTo(b));
    await flush();
    expect(hook.result.current.trip.to).toEqual(b);
    expect(hook.result.current.recents).toEqual([b]);
    expect(await stored('waitItOut.trip.v1')).toEqual({
      from: { kind: 'current' },
      to: b,
    });
    expect(await stored('waitItOut.recents.v1')).toEqual([b]);
  });

  it('remembers a chosen start place but not the current location', async () => {
    const hook = await open();
    act(() => hook.result.current.setFrom({ kind: 'place', place: a }));
    act(() => hook.result.current.setFrom({ kind: 'current' }));
    await flush();
    expect(hook.result.current.recents).toEqual([a]);
    expect(hook.result.current.trip.from).toEqual({ kind: 'current' });
  });

  it('keeps the newest recent first and does not repeat one', async () => {
    const hook = await open();
    act(() => hook.result.current.setTo(a));
    act(() => hook.result.current.setTo(b));
    act(() => hook.result.current.setTo(a));
    await flush();
    expect(hook.result.current.recents.map(p => p.id)).toEqual(['a', 'b']);
  });

  it('swaps start and destination when both are places', async () => {
    const hook = await open();
    act(() => hook.result.current.setFrom({ kind: 'place', place: a }));
    act(() => hook.result.current.setTo(b));
    act(() => hook.result.current.swap());
    await flush();
    expect(hook.result.current.trip).toEqual({
      from: { kind: 'place', place: b },
      to: a,
    });
    expect(await stored('waitItOut.trip.v1')).toEqual({
      from: { kind: 'place', place: b },
      to: a,
    });
  });

  it('leaves the trip alone when swapping makes no sense', async () => {
    const hook = await open();
    act(() => hook.result.current.setTo(b)); // starts at the current location
    act(() => hook.result.current.swap());
    await flush();
    expect(hook.result.current.trip).toEqual({
      from: { kind: 'current' },
      to: b,
    });
  });
});
