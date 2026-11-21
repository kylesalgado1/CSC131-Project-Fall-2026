import * as Location from 'expo-location';
import { LatLng } from '../api/types';
import { fail, LocationError } from './errors';

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(fail('unavailable')), ms);
    work.then(
      value => {
        clearTimeout(timer);
        resolve(value);
      },
      error => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/**
 * Where the phone is right now. Asks for permission the first time it is
 * needed, and only while the app is open. One reading, not ongoing tracking.
 */
export async function getCurrentLocation(timeoutMs = 15_000): Promise<LatLng> {
  const permission = await Location.requestForegroundPermissionsAsync();
  if (permission.status !== 'granted') {
    throw fail('denied');
  }
  if (!(await Location.hasServicesEnabledAsync())) {
    throw fail('services_off');
  }
  try {
    const position = await withTimeout(
      Location.getCurrentPositionAsync({
        accuracy: Location.Accuracy.Balanced,
      }),
      timeoutMs,
    );
    return { lat: position.coords.latitude, lng: position.coords.longitude };
  } catch (error) {
    throw error instanceof LocationError ? error : fail('unavailable');
  }
}

/**
 * The last position the phone knew, if permission was already given. Never
 * shows a prompt, so it is safe for hints such as ranking search results.
 */
export async function lastKnownLocation(): Promise<LatLng | undefined> {
  try {
    const permission = await Location.getForegroundPermissionsAsync();
    if (permission.status !== 'granted') {
      return undefined;
    }
    const position = await Location.getLastKnownPositionAsync();
    return position
      ? { lat: position.coords.latitude, lng: position.coords.longitude }
      : undefined;
  } catch {
    return undefined;
  }
}
