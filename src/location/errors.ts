export type LocationProblem = 'denied' | 'services_off' | 'unavailable';

/** A reason the phone's position could not be had, in words a person can act on. */
export class LocationError extends Error {
  constructor(readonly problem: LocationProblem, message: string) {
    super(message);
    this.name = 'LocationError';
  }
}

export const MESSAGES: Record<LocationProblem, string> = {
  denied:
    'Location is turned off for Wait It Out. Turn it on in Settings, or choose a starting address instead.',
  services_off:
    'Location services are off on this phone. Turn them on, or choose a starting address instead.',
  unavailable:
    'Could not find your location. Try again, or choose a starting address instead.',
};

export const fail = (problem: LocationProblem) =>
  new LocationError(problem, MESSAGES[problem]);
