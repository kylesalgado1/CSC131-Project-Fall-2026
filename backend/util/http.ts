/** The part of `fetch` the backend uses, so tests can pass a fake. */
export type FetchLike = (url: string) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/**
 * GETs a URL and parses the JSON body. A non-2xx response throws an
 * `ErrorType` saying which service failed and with what status.
 */
export async function fetchJson<T>(
  fetchFn: FetchLike,
  url: string,
  service: string,
  ErrorType: new (message: string) => Error = Error,
): Promise<T> {
  const res = await fetchFn(url);
  if (!res.ok) {
    throw new ErrorType(`${service} request failed: HTTP ${res.status}`);
  }
  return (await res.json()) as T;
}
