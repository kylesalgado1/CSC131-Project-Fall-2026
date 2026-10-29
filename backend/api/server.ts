import Fastify, {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from 'fastify';
import { getVerdict } from '../prediction';
import { PlaceSearch, SearchError } from '../places/types';
import { PredictionProviders } from '../prediction/predict';
import { NoBaselineCoverageError } from '../prediction/providers/pems/provider';
import { RoutingError } from '../prediction/providers/routing/types';
import { DEFAULT_PREFERENCES, Goal } from '../prediction/types';

export interface ServerDeps {
  providers: PredictionProviders;
  /** Place search for choosing a start and destination. Absent when not set up. */
  places?: PlaceSearch;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
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
  now = () => new Date(),
}: ServerDeps): FastifyInstance {
  const app = Fastify();

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

  app.setErrorHandler(sendError);

  return app;
}
