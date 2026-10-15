import AsyncStorage from '@react-native-async-storage/async-storage';
import { Place } from '../api/types';
import { Trip } from './types';

const TRIP_KEY = 'waitItOut.trip.v1';
const RECENTS_KEY = 'waitItOut.recents.v1';
export const MAX_RECENTS = 5;

const isPlace = (value: unknown): value is Place => {
  const p = value as Place | null;
  return (
    !!p &&
    typeof p.id === 'string' &&
    typeof p.name === 'string' &&
    typeof p.address === 'string' &&
    Number.isFinite(p.lat) &&
    Number.isFinite(p.lng)
  );
};

/** Reads saved JSON. Anything missing or damaged is treated as not saved. */
async function read(key: string): Promise<unknown> {
  try {
    const text = await AsyncStorage.getItem(key);
    return text ? JSON.parse(text) : undefined;
  } catch {
    return undefined;
  }
}

/** Saving is a convenience: a failure must never break the app. */
async function write(key: string, value: unknown): Promise<void> {
  try {
    await AsyncStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Nothing to do. The trip just will not be remembered next time.
  }
}

export async function loadTrip(): Promise<Trip | undefined> {
  const saved = (await read(TRIP_KEY)) as
    | { from?: { kind?: string; place?: unknown }; to?: unknown }
    | undefined;
  if (!saved?.from) {
    return undefined;
  }
  const to = isPlace(saved.to) ? saved.to : undefined;
  if (saved.from.kind === 'current') {
    return { from: { kind: 'current' }, to };
  }
  if (saved.from.kind === 'place' && isPlace(saved.from.place)) {
    return { from: { kind: 'place', place: saved.from.place }, to };
  }
  return undefined;
}

export const saveTrip = (trip: Trip): Promise<void> => write(TRIP_KEY, trip);

export async function loadRecents(): Promise<Place[]> {
  const saved = await read(RECENTS_KEY);
  return Array.isArray(saved)
    ? saved.filter(isPlace).slice(0, MAX_RECENTS)
    : [];
}

/** Puts a place first in the recents, without repeating it. */
export function withRecent(recents: Place[], place: Place): Place[] {
  const rest = recents.filter(
    r => r.id !== place.id && !(r.lat === place.lat && r.lng === place.lng),
  );
  return [place, ...rest].slice(0, MAX_RECENTS);
}

export const saveRecents = (recents: Place[]): Promise<void> =>
  write(RECENTS_KEY, recents);
