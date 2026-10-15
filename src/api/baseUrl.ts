import Constants from 'expo-constants';

export const DEFAULT_API_PORT = 3000;

interface BaseUrlInputs {
  /** An explicit address, from EXPO_PUBLIC_API_URL. */
  override?: string;
  /** Where Metro is serving the app from, such as "192.168.1.5:8081". */
  hostUri?: string;
  port?: number;
}

/**
 * Where to find the backend. A phone cannot reach "localhost" on your
 * computer, so by default this uses the same address Expo loaded the app
 * from, on the backend's port.
 */
export function apiBaseUrl({
  override,
  hostUri,
  port = DEFAULT_API_PORT,
}: BaseUrlInputs): string {
  if (override) {
    return override.replace(/\/+$/, '');
  }
  const host = hostUri?.split(':')[0];
  // A tunnel address leads to Metro, not to the backend on your computer.
  if (!host || host.endsWith('.exp.direct') || host.includes('ngrok')) {
    return `http://localhost:${port}`;
  }
  return `http://${host}:${port}`;
}

export const defaultBaseUrl = (): string =>
  apiBaseUrl({
    override: process.env.EXPO_PUBLIC_API_URL,
    hostUri: Constants.expoConfig?.hostUri,
  });
