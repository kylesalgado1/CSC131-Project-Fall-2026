import * as Location from 'expo-location';
import { getCurrentLocation, lastKnownLocation } from '../currentLocation';
import { LocationError } from '../errors';

jest.mock('expo-location', () => ({
  Accuracy: { Balanced: 3 },
  requestForegroundPermissionsAsync: jest.fn(),
  getForegroundPermissionsAsync: jest.fn(),
  hasServicesEnabledAsync: jest.fn(),
  getCurrentPositionAsync: jest.fn(),
  getLastKnownPositionAsync: jest.fn(),
}));

const mocked = Location as unknown as Record<string, jest.Mock>;
const fix = (lat: number, lng: number) => ({
  coords: { latitude: lat, longitude: lng },
});

beforeEach(() => {
  jest.resetAllMocks();
  mocked.requestForegroundPermissionsAsync.mockResolvedValue({
    status: 'granted',
  });
  mocked.getForegroundPermissionsAsync.mockResolvedValue({ status: 'granted' });
  mocked.hasServicesEnabledAsync.mockResolvedValue(true);
  mocked.getCurrentPositionAsync.mockResolvedValue(fix(38.2383, -122.0402));
});

const problemOf = async (promise: Promise<unknown>) =>
  promise.then(
    () => undefined,
    (e: LocationError) => e,
  );

describe('getCurrentLocation', () => {
  it("returns the phone's position", async () => {
    expect(await getCurrentLocation()).toEqual({
      lat: 38.2383,
      lng: -122.0402,
    });
  });

  it('asks for permission to use location while the app is open, not always', async () => {
    await getCurrentLocation();
    expect(mocked.requestForegroundPermissionsAsync).toHaveBeenCalledTimes(1);
  });

  it('says so when permission is refused, in words that say what to do', async () => {
    mocked.requestForegroundPermissionsAsync.mockResolvedValue({
      status: 'denied',
    });
    const error = await problemOf(getCurrentLocation());
    expect(error).toBeInstanceOf(LocationError);
    expect(error?.problem).toBe('denied');
    expect(error?.message).toMatch(/Settings/);
    expect(mocked.getCurrentPositionAsync).not.toHaveBeenCalled();
  });

  it('says so when location services are off', async () => {
    mocked.hasServicesEnabledAsync.mockResolvedValue(false);
    expect((await problemOf(getCurrentLocation()))?.problem).toBe(
      'services_off',
    );
  });

  it('says so when the phone cannot find itself', async () => {
    mocked.getCurrentPositionAsync.mockRejectedValue(
      new Error('Location request failed'),
    );
    const error = await problemOf(getCurrentLocation());
    expect(error?.problem).toBe('unavailable');
    expect(error?.message).toMatch(/starting address/);
  });

  it('gives up after a while instead of waiting forever', async () => {
    jest.useFakeTimers();
    try {
      mocked.getCurrentPositionAsync.mockReturnValue(
        new Promise(() => undefined),
      );
      const pending = problemOf(getCurrentLocation(1000));
      await jest.advanceTimersByTimeAsync(1001);
      expect((await pending)?.problem).toBe('unavailable');
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('lastKnownLocation', () => {
  it('returns the last position when permission was already given', async () => {
    mocked.getLastKnownPositionAsync.mockResolvedValue(fix(38.5, -121.5));
    expect(await lastKnownLocation()).toEqual({ lat: 38.5, lng: -121.5 });
  });

  it('never shows a prompt, and says nothing without permission', async () => {
    mocked.getForegroundPermissionsAsync.mockResolvedValue({
      status: 'undetermined',
    });
    expect(await lastKnownLocation()).toBeUndefined();
    expect(mocked.requestForegroundPermissionsAsync).not.toHaveBeenCalled();
  });

  it('says nothing when there is no last position, or the lookup fails', async () => {
    mocked.getLastKnownPositionAsync.mockResolvedValue(null);
    expect(await lastKnownLocation()).toBeUndefined();
    mocked.getLastKnownPositionAsync.mockRejectedValue(new Error('boom'));
    expect(await lastKnownLocation()).toBeUndefined();
  });
});
