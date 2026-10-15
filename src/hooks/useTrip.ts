import { useCallback, useEffect, useState } from 'react';
import { Place } from '../api/types';
import {
  loadRecents,
  loadTrip,
  saveRecents,
  saveTrip,
  withRecent,
} from '../trip/storage';
import { Start, swapped, Trip } from '../trip/types';

const FRESH: Trip = { from: { kind: 'current' } };

/**
 * The trip being planned, and the places used lately. Both are remembered on
 * the phone, so reopening the app picks up where the user left off.
 */
export function useTrip() {
  const [trip, setTrip] = useState<Trip>(FRESH);
  const [recents, setRecents] = useState<Place[]>([]);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let alive = true;
    Promise.all([loadTrip(), loadRecents()]).then(([saved, lately]) => {
      if (!alive) {
        return;
      }
      if (saved) {
        setTrip(saved);
      }
      setRecents(lately);
      setReady(true);
    });
    return () => {
      alive = false;
    };
  }, []);

  // Only after loading, or a fresh trip would overwrite the saved one.
  useEffect(() => {
    if (ready) {
      saveTrip(trip);
    }
  }, [trip, ready]);
  useEffect(() => {
    if (ready) {
      saveRecents(recents);
    }
  }, [recents, ready]);

  const remember = useCallback((place: Place) => {
    setRecents(current => withRecent(current, place));
  }, []);

  const setFrom = useCallback(
    (from: Start) => {
      setTrip(current => ({ ...current, from }));
      if (from.kind === 'place') {
        remember(from.place);
      }
    },
    [remember],
  );

  const setTo = useCallback(
    (to: Place) => {
      setTrip(current => ({ ...current, to }));
      remember(to);
    },
    [remember],
  );

  const swap = useCallback(() => {
    setTrip(current => swapped(current) ?? current);
  }, []);

  return { trip, recents, ready, setFrom, setTo, swap };
}
