import { FastifyInstance, FastifyRequest } from 'fastify';
import { bearerMatches } from '../trips/auth';
import {
  BadRequestError,
  MonitoringUnavailableError,
  NotFoundError,
  RateLimitedError,
  UnauthorizedError,
} from '../trips/errors';
import { TripService } from '../trips/service';
import { Device } from '../trips/store';
import { PushBody, SyncBody, TickReport } from '../trips/types';
import { errorName } from '../util/errorName';
import { HOUR_MS } from '../util/time';

/** How many devices one client address may register in an hour. */
export const REGISTRATIONS_PER_ADDRESS_PER_HOUR = 20;

/**
 * How many trip lists one device may send in an hour. The app sends one for
 * each change the user makes and one a minute while it retries, so this is
 * far above honest use. It bounds how fast one device can make the server
 * write; it does not protect the daily evaluation budget, which one allowed
 * list of trips can use up through the monitor.
 */
export const TRIP_SYNCS_PER_DEVICE_PER_HOUR = 120;

/** A tick secret shorter than this is too easy to guess, and is ignored. */
export const MIN_TICK_SECRET_LENGTH = 32;

/**
 * Counts attempts per key in fixed windows, in memory. Good enough to slow
 * one address down on one server; it is not shared between servers and
 * forgets everything on a restart.
 */
export class FixedWindowLimiter {
  private readonly windows = new Map<
    string,
    { start: number; count: number }
  >();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
    /** Past this many keys the oldest are forgotten, to bound the memory. */
    private readonly maxKeys = 10_000,
  ) {}

  /** Counts one attempt. False when the key has used up its window. */
  allow(key: string): boolean {
    const at = this.now();
    const current = this.windows.get(key);
    if (!current || at - current.start >= this.windowMs || at < current.start) {
      // Re-inserted, so the map stays ordered by when each window began.
      this.windows.delete(key);
      this.windows.set(key, { start: at, count: 1 });
      this.forgetOldest();
      return this.limit >= 1;
    }
    current.count += 1;
    return current.count <= this.limit;
  }

  /** Whole seconds until the key's window ends. Zero when it has none. */
  retryAfterSeconds(key: string): number {
    const current = this.windows.get(key);
    if (!current) {
      return 0;
    }
    const remainingMs = current.start + this.windowMs - this.now();
    return Math.max(0, Math.ceil(remainingMs / 1000));
  }

  private forgetOldest(): void {
    for (const key of this.windows.keys()) {
      if (this.windows.size <= this.maxKeys) {
        return;
      }
      this.windows.delete(key);
    }
  }
}

/** What the trip routes need beside the service. All of it is optional. */
export interface TripRouteOptions {
  /**
   * The shared secret for POST /internal/monitor/tick. Without one, or with
   * one shorter than MIN_TICK_SECRET_LENGTH, the route answers 404.
   */
  tickSecret?: string;
  /**
   * Runs one monitoring tick. Absent when this server does not run the
   * monitor: the route then answers 503.
   */
  tick?: () => Promise<TickReport>;
  /** The server's clock, which the hourly limits count their hours by. */
  now?: () => Date;
  /**
   * How many trip lists one device may send in an hour. Absent:
   * TRIP_SYNCS_PER_DEVICE_PER_HOUR.
   */
  tripSyncsPerHour?: number;
  /** Told once when the tick secret is too short to use. */
  warn?: (message: string) => void;
  /** Told when a tick started by the route fails after it has answered. */
  log?: (line: string) => void;
}

const point = {
  type: 'object',
  required: ['lat', 'lng'],
  additionalProperties: false,
  properties: {
    lat: { type: 'number', minimum: -90, maximum: 90 },
    lng: { type: 'number', minimum: -180, maximum: 180 },
  },
} as const;

// Text the database can store: PostgreSQL takes any character but NUL.
const STORABLE_TEXT = '^[^\\u0000]*$';

// The app's id for an occurrence, e.g. "<uuid>@2026-11-20". No dots or
// slashes, so it is always exactly one path segment.
const tripId = {
  type: 'string',
  minLength: 1,
  maxLength: 80,
  pattern: '^[A-Za-z0-9][A-Za-z0-9@:_-]*$',
} as const;

const registerSchema = {
  body: {
    type: 'object',
    required: ['platform'],
    additionalProperties: false,
    properties: {
      platform: { enum: ['ios'] },
    },
  },
} as const;

const pushSchema = {
  body: {
    type: 'object',
    required: ['apnsToken', 'environment', 'authorized'],
    additionalProperties: false,
    properties: {
      // Null clears it.
      apnsToken: {
        type: ['string', 'null'],
        pattern: '^[0-9a-fA-F]{32,400}$',
      },
      environment: { enum: ['sandbox', 'production'] },
      authorized: { type: 'boolean' },
    },
  },
} as const;

const syncSchema = (maxTrips: number) =>
  ({
    body: {
      type: 'object',
      required: ['revision', 'trips'],
      additionalProperties: false,
      properties: {
        revision: {
          type: 'integer',
          minimum: 1,
          maximum: Number.MAX_SAFE_INTEGER,
        },
        trips: {
          type: 'array',
          maxItems: maxTrips,
          items: {
            type: 'object',
            required: [
              'id',
              'title',
              'origin',
              'destination',
              'arriveBy',
              'timeZone',
            ],
            additionalProperties: false,
            properties: {
              id: tripId,
              // Used in notification text.
              title: {
                type: 'string',
                minLength: 1,
                maxLength: 120,
                pattern: STORABLE_TEXT,
              },
              origin: point,
              destination: point,
              destinationName: {
                type: 'string',
                maxLength: 120,
                pattern: STORABLE_TEXT,
              },
              arriveBy: { type: 'string', format: 'date-time' },
              startsAt: { type: 'string', format: 'date-time' },
              // An IANA name such as America/Los_Angeles.
              timeZone: {
                type: 'string',
                minLength: 1,
                maxLength: 64,
                pattern: STORABLE_TEXT,
              },
            },
          },
        },
      },
    },
  } as const);

const tripParams = {
  type: 'object',
  required: ['id'],
  properties: { id: tripId },
} as const;

const tripSchema = { params: tripParams } as const;

const departedSchema = {
  params: tripParams,
  body: {
    type: 'object',
    required: ['arriveBy'],
    additionalProperties: false,
    properties: {
      // Which arrival time the user left for: see SupersededError.
      arriveBy: { type: 'string', format: 'date-time' },
    },
  },
} as const;

const tickSchema = {
  querystring: {
    type: 'object',
    properties: {
      wait: { type: 'string', maxLength: 5 },
    },
  },
} as const;

/**
 * The part of a JSON schema that says what type a value must be. A value
 * given by an enum has no type to check, and is left to the validator.
 */
interface TypedSchema {
  readonly type?: string | readonly string[];
  readonly enum?: readonly unknown[];
  readonly properties?: Readonly<Record<string, TypedSchema>>;
  readonly items?: TypedSchema;
}

const jsonTypeOf = (value: unknown): string => {
  if (value === null) {
    return 'null';
  }
  return Array.isArray(value) ? 'array' : typeof value;
};

/**
 * Where in a body a value is not of the JSON type its schema names, as a
 * sentence such as "body/trips/0/origin/lat must be number", or nothing when
 * every value is. Only what is present is looked at: what is required, and
 * every other rule, is left to the schema validator.
 */
export function mistypedValue(
  schema: TypedSchema,
  value: unknown,
  path = 'body',
): string | undefined {
  const actual = jsonTypeOf(value);
  const wanted = typeof schema.type === 'string' ? [schema.type] : schema.type;
  if (
    wanted &&
    !wanted.some(
      type => type === actual || (type === 'integer' && actual === 'number'),
    )
  ) {
    return `${path} must be ${wanted.join(' or ')}`;
  }
  if (schema.properties && actual === 'object') {
    const object = value as Record<string, unknown>;
    for (const [key, property] of Object.entries(schema.properties)) {
      if (Object.prototype.hasOwnProperty.call(object, key)) {
        const found = mistypedValue(property, object[key], `${path}/${key}`);
        if (found) {
          return found;
        }
      }
    }
  }
  if (schema.items && Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      const found = mistypedValue(schema.items, item, `${path}/${index}`);
      if (found) {
        return found;
      }
    }
  }
  return undefined;
}

/**
 * Refuses a body in which a value has the wrong JSON type, before the
 * schema validator sees it. Fastify's validator converts between types
 * unless told otherwise: a null coordinate would become 0, a null
 * permission false, a string revision a number. /verdict and /places keep
 * that behaviour for the React Native client; the device and trip routes
 * take a body as it was sent or not at all.
 */
const strictBody =
  (schema: TypedSchema) =>
  async (request: FastifyRequest): Promise<void> => {
    const mistyped = mistypedValue(schema, request.body);
    if (mistyped) {
      throw new BadRequestError(mistyped);
    }
  };

/** Where warnings go unless the caller says otherwise: the server's log. */
const defaultWarn = (message: string): void => console.warn(message);
const defaultLog = (line: string): void => console.error(line);

/**
 * Adds the device, trip and monitoring-tick routes.
 *
 * A device registers once, without a credential, and gets one back. Every
 * other device and trip route needs it, as `Authorization: Bearer <token>`,
 * and only ever touches that device's own trips. While the trip tables are
 * missing every route here answers 503 monitoring_unavailable; when the
 * database cannot be asked they answer 503 temporarily_unavailable, which
 * says nothing about what the server holds. The tick route is for an
 * operator's scheduler and has its own secret.
 */
export function registerTripRoutes(
  app: FastifyInstance,
  trips: TripService,
  options: TripRouteOptions = {},
): void {
  const {
    tick,
    now = () => new Date(),
    warn = defaultWarn,
    log = defaultLog,
    tripSyncsPerHour = TRIP_SYNCS_PER_DEVICE_PER_HOUR,
  } = options;
  let tickSecret = options.tickSecret || undefined;
  if (tickSecret && tickSecret.length < MIN_TICK_SECRET_LENGTH) {
    warn(
      `MONITOR_TICK_SECRET is shorter than ${MIN_TICK_SECRET_LENGTH} characters and is ignored.`,
    );
    tickSecret = undefined;
  }
  const registrations = new FixedWindowLimiter(
    REGISTRATIONS_PER_ADDRESS_PER_HOUR,
    HOUR_MS,
    () => now().getTime(),
  );
  const syncs = new FixedWindowLimiter(tripSyncsPerHour, HOUR_MS, () =>
    now().getTime(),
  );

  const requireMonitoring = async (): Promise<void> => {
    if (!(await trips.isAvailable())) {
      throw new MonitoringUnavailableError();
    }
  };

  // Checked before the body is read, so a caller without a credential learns
  // nothing else about the request it sent.
  const devices = new WeakMap<FastifyRequest, Device>();
  const requireDevice = async (request: FastifyRequest): Promise<void> => {
    await requireMonitoring();
    devices.set(
      request,
      await trips.authenticate(request.headers.authorization),
    );
  };
  const deviceOf = (request: FastifyRequest): Device => {
    const device = devices.get(request);
    if (!device) {
      throw new UnauthorizedError();
    }
    return device;
  };

  // For the two routes that read no body. A client that labels every
  // request as JSON would otherwise be refused for sending an empty one.
  const allowNoBody = (request: FastifyRequest): void => {
    const { headers } = request;
    const length = headers['content-length'];
    if (
      headers['transfer-encoding'] === undefined &&
      (length === undefined || length === '0')
    ) {
      delete headers['content-type'];
    }
  };

  // Also checked before the body is read. Without a secret the route gives
  // nothing away, not even that it exists.
  const requireTickSecret = async (request: FastifyRequest): Promise<void> => {
    if (!tickSecret) {
      throw new NotFoundError('There is nothing here.');
    }
    if (!bearerMatches(request.headers.authorization, tickSecret)) {
      throw new UnauthorizedError('The monitor secret is missing or wrong.');
    }
    allowNoBody(request);
  };

  app.post<{ Body: { platform: 'ios' } }>(
    '/devices',
    {
      schema: registerSchema,
      onRequest: requireMonitoring,
      preValidation: strictBody(registerSchema.body),
    },
    async (request, reply) => {
      if (!registrations.allow(request.ip)) {
        throw new RateLimitedError(registrations.retryAfterSeconds(request.ip));
      }
      return reply.code(201).send(await trips.register(request.body.platform));
    },
  );

  app.put<{ Body: PushBody }>(
    '/devices/me/push',
    {
      schema: pushSchema,
      onRequest: requireDevice,
      preValidation: strictBody(pushSchema.body),
    },
    async request => trips.setPush(deviceOf(request), request.body),
  );

  app.delete(
    '/devices/me',
    {
      onRequest: async request => {
        await requireDevice(request);
        allowNoBody(request);
      },
    },
    async (request, reply) => {
      await trips.unregister(deviceOf(request));
      return reply.code(204).send();
    },
  );

  const tripsSchema = syncSchema(trips.limits().maxTrips);
  app.put<{ Body: SyncBody }>(
    '/trips',
    {
      schema: tripsSchema,
      onRequest: requireDevice,
      preValidation: strictBody(tripsSchema.body),
    },
    async request => {
      const device = deviceOf(request);
      if (!syncs.allow(device.id)) {
        throw new RateLimitedError(
          syncs.retryAfterSeconds(device.id),
          'Too many trip updates from this device. Try again later.',
        );
      }
      return trips.sync(device, request.body);
    },
  );

  app.get('/trips', { onRequest: requireDevice }, async request =>
    trips.list(deviceOf(request)),
  );

  app.get<{ Params: { id: string } }>(
    '/trips/:id',
    { schema: tripSchema, onRequest: requireDevice },
    async request => trips.get(deviceOf(request), request.params.id),
  );

  app.post<{ Params: { id: string }; Body: { arriveBy: string } }>(
    '/trips/:id/departed',
    {
      schema: departedSchema,
      onRequest: requireDevice,
      preValidation: strictBody(departedSchema.body),
    },
    async request =>
      trips.departed(
        deviceOf(request),
        request.params.id,
        request.body.arriveBy,
      ),
  );

  app.post<{ Querystring: { wait?: string } }>(
    '/internal/monitor/tick',
    { schema: tickSchema, onRequest: requireTickSecret },
    async (request, reply) => {
      if (!tick || !(await trips.isAvailable())) {
        throw new MonitoringUnavailableError();
      }
      const { wait } = request.query;
      if (wait === '1' || wait === 'true') {
        return tick();
      }
      // A scheduler gives up after a couple of seconds, so answer first.
      tick().catch(error => log(`Monitoring tick failed: ${errorName(error)}`));
      return reply.code(202).send({ accepted: true });
    },
  );
}
