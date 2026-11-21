/**
 * The class of a failure, for logs. Never its message: a message can carry
 * a URL, a token or somebody's coordinates.
 */
export const errorName = (error: unknown): string =>
  error instanceof Error ? error.constructor.name : typeof error;
