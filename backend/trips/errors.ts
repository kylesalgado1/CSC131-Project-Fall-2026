/**
 * A failure the API answers with a status and a snake_case code of its own.
 * The message is written for the person using the app, so it never carries
 * internal detail.
 */
export class ApiError extends Error {
  constructor(
    /** The HTTP status the API answers with. */
    readonly status: number,
    /** The snake_case code clients tell failures apart by. */
    readonly code: string,
    message: string,
    /** Extra fields for the response body, beside the code and message. */
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

/** No credential, a malformed one, or one no device has. */
export class UnauthorizedError extends ApiError {
  constructor(message = 'This device is not registered.') {
    super(401, 'unauthorized', message);
    this.name = 'UnauthorizedError';
  }
}

/** Nothing by that id, or nothing the caller is allowed to see. */
export class NotFoundError extends ApiError {
  constructor(message = 'No such trip.') {
    super(404, 'not_found', message);
    this.name = 'NotFoundError';
  }
}

/** What the request asks for is not acceptable, though its JSON is valid. */
export class BadRequestError extends ApiError {
  constructor(message: string) {
    super(400, 'bad_request', message);
    this.name = 'BadRequestError';
  }
}

/** Too many requests from one address, or from one device. */
export class RateLimitedError extends ApiError {
  constructor(
    /** How long until the caller may try again, when that is known. */
    readonly retryAfterSeconds?: number,
    message = 'Too many new devices from this network. Try again later.',
  ) {
    super(429, 'rate_limited', message);
    this.name = 'RateLimitedError';
  }
}

/**
 * The trip tables are missing: migration 005 has not been applied. On the
 * device and trip routes it means that and nothing else, so a client may
 * take it to mean the server holds nothing for it. (The tick route also
 * answers it on a server that does not run the monitor.) A database that
 * could not be asked is a TemporarilyUnavailableError instead.
 */
export class MonitoringUnavailableError extends ApiError {
  constructor() {
    super(
      503,
      'monitoring_unavailable',
      'Trip monitoring is not set up on this server.',
    );
    this.name = 'MonitoringUnavailableError';
  }
}

/**
 * The database could not be reached, or could not answer. Nothing is known
 * about what the server holds, so the same request is worth sending again.
 */
export class TemporarilyUnavailableError extends ApiError {
  constructor() {
    super(
      503,
      'temporarily_unavailable',
      'The server is having trouble right now. Try again shortly.',
    );
    this.name = 'TemporarilyUnavailableError';
  }
}

/** The server has taken on as many new devices as it will for now. */
export class RegistrationsClosedError extends ApiError {
  constructor() {
    super(
      503,
      'registrations_closed',
      'This server is not taking new devices right now. Try again later.',
    );
    this.name = 'RegistrationsClosedError';
  }
}

/** A different snapshot was already stored under the same revision. */
export class RevisionConflictError extends ApiError {
  constructor(
    /** The revision the server holds. */
    readonly revision: number,
  ) {
    super(
      409,
      'revision_conflict',
      'A different set of trips already used this revision. Send it again with a higher one.',
      { revision },
    );
    this.name = 'RevisionConflictError';
  }
}

/** "I've left" for an arrival time the trip no longer has. */
export class SupersededError extends ApiError {
  constructor() {
    super(409, 'superseded', 'This trip was rescheduled.');
    this.name = 'SupersededError';
  }
}
