import Fastify, {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from 'fastify';
import { getVerdict } from '../prediction';
import { PlaceSearch, SearchError } from '../places/types';
import { PredictionProviders } from '../prediction/predict';
import { NoBaselineCoverageError } from '../prediction/providers/pems/provider';
import {
  RoutePathProvider,
  RoutingError,
} from '../prediction/providers/routing/types';
import { DEFAULT_PREFERENCES, Goal, LatLng } from '../prediction/types';
import { ApiError, RateLimitedError } from '../trips/errors';
import { TripService } from '../trips/service';
import { TickReport } from '../trips/types';
import { registerTripRoutes } from './tripRoutes';

export interface ServerDeps {
  providers: PredictionProviders;
  /** Place search for choosing a start and destination. Absent when not set up. */
  places?: PlaceSearch;
  /** Route geometry for drawing a trip on a map. Absent when not set up. */
  paths?: RoutePathProvider;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
  /**
   * The device registry and monitored trips. Absent, the server has no
   * device, trip or monitoring routes at all.
   */
  trips?: TripService;
  /** The secret for POST /internal/monitor/tick. Absent: the route is a 404. */
  tickSecret?: string;
  /** Runs one monitoring tick. Absent when this server runs no monitor. */
  tick?: () => Promise<TickReport>;
  /**
   * How many trip lists one device may send in an hour. Absent: the usual
   * limit (see tripRoutes.ts).
   */
  tripSyncsPerHour?: number;
  /**
   * How many proxies in front of the server to believe when they say who
   * the client is (or true for all of them). Absent or false: none, and the
   * client is whoever connected.
   */
  trustProxy?: boolean | number;
}

/** Where warnings go unless the caller says otherwise: the server's log. */
const defaultWarn = (message: string): void => console.warn(message);

/**
 * Reads TRUST_PROXY: a whole number of proxies to believe, or "true" for
 * all of them. Unset, "false" or "0" trusts none. Behind a host's load
 * balancer the server otherwise sees every client as the balancer, and
 * anything counted per client address counts them all as one.
 */
export function trustProxyFromEnv(
  env: Record<string, string | undefined> = process.env,
  warn: (message: string) => void = defaultWarn,
): boolean | number {
  const raw = env.TRUST_PROXY?.trim().toLowerCase();
  if (!raw || raw === 'false') {
    return false;
  }
  if (raw === 'true') {
    return true;
  }
  if (/^\d{1,3}$/.test(raw)) {
    return Number(raw) || false;
  }
  warn('TRUST_PROXY is not a usable value; trusting no proxy.');
  return false;
}

interface VerdictBody {
  origin: { lat: number; lng: number };
  destination: { lat: number; lng: number };
  arriveBy?: string;
  leaveBy?: string;
  leaveAfter?: string;
  preferences?: {
    goal?: Goal;
    maxWaitMinutes?: number;
    minSavingsMinutes?: number;
  };
}

interface RouteBody {
  origin: LatLng;
  destination: LatLng;
}

/** The most points a route's path is sent with. */
export const MAX_ROUTE_POINTS = 400;

const point = {
  type: 'object',
  required: ['lat', 'lng'],
  additionalProperties: false,
  properties: {
    lat: { type: 'number', minimum: -90, maximum: 90 },
    lng: { type: 'number', minimum: -180, maximum: 180 },
  },
} as const;

const verdictSchema = {
  body: {
    type: 'object',
    required: ['origin', 'destination'],
    additionalProperties: false,
    properties: {
      origin: point,
      destination: point,
      arriveBy: { type: 'string', format: 'date-time' },
      leaveBy: { type: 'string', format: 'date-time' },
      leaveAfter: { type: 'string', format: 'date-time' },
      preferences: {
        type: 'object',
        additionalProperties: false,
        properties: {
          goal: { enum: ['minimize_time', 'arrive_by'] },
          // Story 6-2: 15 minutes to 3 hours.
          maxWaitMinutes: { type: 'integer', minimum: 15, maximum: 180 },
          minSavingsMinutes: { type: 'integer', minimum: 0, maximum: 180 },
        },
      },
    },
  },
} as const;

const routeSchema = {
  body: {
    type: 'object',
    required: ['origin', 'destination'],
    additionalProperties: false,
    properties: {
      origin: point,
      destination: point,
    },
  },
} as const;

const placesSchema = {
  querystring: {
    type: 'object',
    required: ['q'],
    additionalProperties: false,
    properties: {
      // The app waits for 3 characters; 2 is the least worth asking about.
      q: { type: 'string', minLength: 2, maxLength: 100 },
      lat: { type: 'number', minimum: -90, maximum: 90 },
      lng: { type: 'number', minimum: -180, maximum: 180 },
    },
  },
} as const;

/**
 * Thins a path to at most `max` points, evenly spaced along it, always
 * keeping the first and the last. A path that is already short enough is
 * returned as it is.
 */
export function samplePath(points: LatLng[], max = MAX_ROUTE_POINTS): LatLng[] {
  // Fewer than two cannot keep both ends.
  const count = Math.max(2, Math.floor(max));
  if (points.length <= count) {
    return points;
  }
  const stride = (points.length - 1) / (count - 1);
  return Array.from(
    { length: count },
    (_, i) => points[Math.round(i * stride)],
  );
}

/**
 * Every failure leaves through here. Expected ones get a clear message;
 * unexpected ones are logged and never shown to the client.
 */
function sendError(
  error: Error,
  request: FastifyRequest,
  reply: FastifyReply,
): FastifyReply {
  if (error instanceof NoBaselineCoverageError) {
    return reply.code(422).send({
      error: 'no_coverage',
      message: 'There is not enough traffic data for this route yet.',
    });
  }
  if (error instanceof RoutingError) {
    request.log.error(error);
    return reply.code(502).send({
      error: 'routing_unavailable',
      message: 'The routing service could not plan this trip.',
    });
  }
  if (error instanceof SearchError) {
    request.log.error(error);
    return reply.code(502).send({
      error: 'search_unavailable',
      message: 'Place search is not available right now.',
    });
  }
  if (error instanceof ApiError) {
    if (
      error instanceof RateLimitedError &&
      error.retryAfterSeconds !== undefined
    ) {
      reply.header('retry-after', error.retryAfterSeconds);
    }
    return reply
      .code(error.status)
      .send({ error: error.code, message: error.message, ...error.details });
  }
  const status = (error as { statusCode?: number }).statusCode ?? 500;
  if (status >= 500) {
    request.log.error(error);
    return reply
      .code(500)
      .send({ error: 'internal', message: 'Something went wrong.' });
  }
  return reply
    .code(status)
    .send({ error: 'bad_request', message: (error as Error).message });
}

export function buildServer({
  providers,
  places,
  paths,
  now = () => new Date(),
  trips,
  tickSecret,
  tick,
  tripSyncsPerHour,
  trustProxy = false,
}: ServerDeps): FastifyInstance {
  const app = Fastify({
    // Fastify's types leave out the hop count, though it takes one; this is
    // the function it would make of it.
    trustProxy:
      typeof trustProxy === 'number'
        ? (_address: string, hop: number) => hop < trustProxy
        : trustProxy,
  });

  app.get('/health', async () => ({ status: 'ok' }));

  app.get<{ Querystring: { q: string; lat?: number; lng?: number } }>(
    '/places',
    { schema: placesSchema },
    async (request, reply) => {
      if (!places) {
        return reply.code(503).send({
          error: 'search_unavailable',
          message: 'Place search is not set up on this server.',
        });
      }
      const { q, lat, lng } = request.query;
      if ((lat === undefined) !== (lng === undefined)) {
        return reply.code(400).send({
          error: 'bad_request',
          message: 'Give both lat and lng, or neither.',
        });
      }
      const near = lat === undefined ? undefined : { lat, lng: lng as number };
      return { places: await places.search(q, near) };
    },
  );

  app.post<{ Body: VerdictBody }>(
    '/verdict',
    { schema: verdictSchema },
    async request => {
      const {
        origin,
        destination,
        arriveBy,
        leaveBy,
        leaveAfter,
        preferences,
      } = request.body;
      return getVerdict(
        {
          route: { origin, destination },
          now: now(),
          preferences: {
            ...DEFAULT_PREFERENCES,
            // With a deadline the aim is to arrive just in time; without one,
            // to wait only when traffic clears. A client can still say which.
            goal: arriveBy ? 'arrive_by' : 'minimize_time',
            ...preferences,
            ...(arriveBy ? { arriveBy: new Date(arriveBy) } : {}),
            ...(leaveBy ? { leaveBy: new Date(leaveBy) } : {}),
            ...(leaveAfter ? { leaveAfter: new Date(leaveAfter) } : {}),
          },
        },
        providers,
      );
    },
  );

  app.post<{ Body: RouteBody }>(
    '/route',
    { schema: routeSchema },
    async (request, reply) => {
      if (!paths) {
        return reply.code(503).send({
          error: 'route_unavailable',
          message: 'Route geometry is not set up on this server.',
        });
      }
      const { origin, destination } = request.body;
      const path = await paths.getPath({ origin, destination });
      if (path.points.length < 2) {
        throw new RoutingError('The routing service returned no path');
      }
      return {
        // Only the coordinates leave, whatever else a service attached.
        points: samplePath(path.points).map(({ lat, lng }) => ({ lat, lng })),
        distanceMiles: path.distanceMiles,
        source: path.source ?? 'unknown',
        fallback: path.fallback === true,
      };
    },
  );

  if (trips) {
    registerTripRoutes(app, trips, { tickSecret, tick, now, tripSyncsPerHour });
  }

  app.setErrorHandler(sendError);

  return app;
}
