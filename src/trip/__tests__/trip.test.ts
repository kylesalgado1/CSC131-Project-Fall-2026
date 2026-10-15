import AsyncStorage from '@react-native-async-storage/async-storage';
import { Place } from '../../api/types';
import { QUICK_PICKS } from '../quickPicks';
import {
  loadRecents,
  loadTrip,
  MAX_RECENTS,
  saveRecents,
  saveTrip,
  withRecent,
} from '../storage';
import { CURRENT_LOCATION, startLabel, swapped, Trip } from '../types';

const place = (id: string, lat = 38, lng = -121): Place => ({
  id,
  name: `Place ${id}`,
  address: `${id} Street`,
  lat,
  lng,
});

beforeEach(async () => {
  await AsyncStorage.clear();
});

describe('startLabel', () => {
  it('says "Current location" for the phone\'s position, else the place name', () => {
    expect(startLabel({ kind: 'current' })).toBe(CURRENT_LOCATION);
    expect(startLabel({ kind: 'place', place: place('a') })).toBe('Place a');
  });
});

describe('swapped', () => {
  it('turns a place-to-place trip around', () => {
    const trip: Trip = {
      from: { kind: 'place', place: place('a') },
      to: place('b'),
    };
    expect(swapped(trip)).toEqual({
      from: { kind: 'place', place: place('b') },
      to: place('a'),
    });
  });

  it('cannot swap a trip that starts at the current location, or has no destination', () => {
    expect(
      swapped({ from: { kind: 'current' }, to: place('b') }),
    ).toBeUndefined();
    expect(
      swapped({ from: { kind: 'place', place: place('a') } }),
    ).toBeUndefined();
  });

  it('is its own opposite', () => {
    const trip: Trip = {
      from: { kind: 'place', place: place('a') },
      to: place('b'),
    };
    expect(swapped(swapped(trip)!)).toEqual(trip);
  });
});

describe('quick picks', () => {
  it('are real places with coordinates in California', () => {
    expect(QUICK_PICKS.length).toBeGreaterThan(0);
    for (const p of QUICK_PICKS) {
      expect(p.lat).toBeGreaterThan(32);
      expect(p.lat).toBeLessThan(42);
      expect(p.lng).toBeLessThan(-114);
    }
    expect(new Set(QUICK_PICKS.map(p => p.id)).size).toBe(QUICK_PICKS.length);
  });
});

describe('saved trip', () => {
  it('comes back as it was saved', async () => {
    const trip: Trip = {
      from: { kind: 'place', place: place('a') },
      to: place('b'),
    };
    await saveTrip(trip);
    expect(await loadTrip()).toEqual(trip);
  });

  it('remembers a start at the current location, without any coordinates', async () => {
    await saveTrip({ from: { kind: 'current' }, to: place('b') });
    expect(await AsyncStorage.getItem('waitItOut.trip.v1')).not.toMatch(
      /lat.*lat/s,
    );
    expect(await loadTrip()).toEqual({
      from: { kind: 'current' },
      to: place('b'),
    });
  });

  it('is undefined when nothing was saved', async () => {
    expect(await loadTrip()).toBeUndefined();
  });

  it.each([
    ['not JSON', '{oops'],
    ['not an object', '42'],
    ['no start', '{"to":null}'],
    ['an unknown start', '{"from":{"kind":"teleport"}}'],
    [
      'a start place with no coordinates',
      '{"from":{"kind":"place","place":{"id":"a","name":"A","address":"A"}}}',
    ],
  ])('ignores damaged data: %s', async (_label, text) => {
    await AsyncStorage.setItem('waitItOut.trip.v1', text);
    expect(await loadTrip()).toBeUndefined();
  });

  it('drops a damaged destination but keeps a good start', async () => {
    await AsyncStorage.setItem(
      'waitItOut.trip.v1',
      '{"from":{"kind":"current"},"to":{"name":"no coordinates"}}',
    );
    expect(await loadTrip()).toEqual({
      from: { kind: 'current' },
      to: undefined,
    });
  });

  it('never throws when storage itself fails', async () => {
    // Once each, so the mock behaves normally again for the next test.
    const store = AsyncStorage as unknown as Record<
      'getItem' | 'setItem',
      jest.Mock
    >;
    store.getItem
      .mockRejectedValueOnce(new Error('disk'))
      .mockRejectedValueOnce(new Error('disk'));
    store.setItem
      .mockRejectedValueOnce(new Error('disk'))
      .mockRejectedValueOnce(new Error('disk'));
    expect(await loadTrip()).toBeUndefined();
    expect(await loadRecents()).toEqual([]);
    await expect(
      saveTrip({ from: { kind: 'current' } }),
    ).resolves.toBeUndefined();
    await expect(saveRecents([place('a')])).resolves.toBeUndefined();
  });
});

describe('recent places', () => {
  it('puts the newest first and does not repeat a place', () => {
    const a = place('a', 38.1, -121.1);
    const b = place('b', 38.2, -121.2);
    const list = withRecent(withRecent(withRecent([], a), b), a);
    expect(list.map(p => p.id)).toEqual(['a', 'b']);
  });

  it('counts the same spot under another id as the same place', () => {
    const list = withRecent(
      [place('a', 38.5, -121.5)],
      place('different-id', 38.5, -121.5),
    );
    expect(list.map(p => p.id)).toEqual(['different-id']);
  });

  it('keeps only the last few', () => {
    let list: Place[] = [];
    for (let i = 0; i < MAX_RECENTS + 3; i++) {
      list = withRecent(list, place(String(i), 38 + i, -121));
    }
    expect(list).toHaveLength(MAX_RECENTS);
    expect(list[0].id).toBe(String(MAX_RECENTS + 2));
  });

  it('are saved and loaded, ignoring anything damaged', async () => {
    await saveRecents([place('a'), place('b', 39, -122)]);
    expect((await loadRecents()).map(p => p.id)).toEqual(['a', 'b']);
    await AsyncStorage.setItem(
      'waitItOut.recents.v1',
      JSON.stringify([place('a'), { name: 'broken' }, 7]),
    );
    expect((await loadRecents()).map(p => p.id)).toEqual(['a']);
    await AsyncStorage.setItem('waitItOut.recents.v1', '"not a list"');
    expect(await loadRecents()).toEqual([]);
  });
});
