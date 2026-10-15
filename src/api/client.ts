import { VerdictRequest, VerdictResponse } from './types';

export type ApiErrorKind =
  | 'network'
  | 'no_coverage'
  | 'routing_unavailable'
  | 'bad_request'
  | 'server';

/** A failure the screen can explain to the user in plain words. */
export class ApiError extends Error {
  constructor(readonly kind: ApiErrorKind, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface FetchVerdictOptions {
  fetchFn?: typeof fetch;
  /** Give up after this long. A new trip can take a few seconds. */
  timeoutMs?: number;
}

const STATUS_KIND: Record<number, ApiErrorKind> = {
  400: 'bad_request',
  422: 'no_coverage',
  502: 'routing_unavailable',
};

const STATUS_MESSAGE: Record<ApiErrorKind, string> = {
  network: 'Could not reach the server.',
  no_coverage: 'There is not enough traffic data for this trip yet.',
  routing_unavailable: 'The routing service could not plan this trip.',
  bad_request: 'The server did not understand that request.',
  server: 'The server had a problem. Try again in a moment.',
};

export async function fetchVerdict(
  baseUrl: string,
  request: VerdictRequest,
  { fetchFn = fetch, timeoutMs = 20_000 }: FetchVerdictOptions = {},
): Promise<VerdictResponse> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetchFn(`${baseUrl}/verdict`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(request),
      signal: controller.signal,
    });
  } catch {
    throw new ApiError(
      'network',
      `${STATUS_MESSAGE.network} Check that the backend is running and that this phone is on the same Wi-Fi.`,
    );
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    const kind = STATUS_KIND[response.status] ?? 'server';
    throw new ApiError(kind, STATUS_MESSAGE[kind]);
  }
  return (await response.json()) as VerdictResponse;
}
