import Fastify, { FastifyInstance } from 'fastify';
import { getVerdict } from '../prediction';
import { PredictionProviders } from '../prediction/predict';
import { NoBaselineCoverageError } from '../prediction/providers/pems/provider';
import { RoutingError } from '../prediction/providers/routing/types';
import { DEFAULT_PREFERENCES, Goal } from '../prediction/types';

export interface ServerDeps {
  providers: PredictionProviders;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
}

interface VerdictBody {
  origin: { lat: number; lng: number };
  destination: { lat: number; lng: number };
  arriveBy?: string;
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
      preferences: {
        type: 'object',
        additionalProperties: false,
        properties: {
          goal: { enum: ['minimize_time', 'arrive_by', 'balance'] },
          // Story 6-2: 15 minutes to 3 hours.
          maxWaitMinutes: { type: 'integer', minimum: 15, maximum: 180 },
          minSavingsMinutes: { type: 'integer', minimum: 0, maximum: 180 },
        },
      },
    },
  },
} as const;

export function buildServer({
  providers,
  now = () => new Date(),
}: ServerDeps): FastifyInstance {
  const app = Fastify();

  app.get('/health', async () => ({ status: 'ok' }));

  app.post<{ Body: VerdictBody }>(
    '/verdict',
    { schema: verdictSchema },
    async request => {
      const { origin, destination, arriveBy, preferences } = request.body;
      return getVerdict(
        {
          route: { origin, destination },
          now: now(),
          preferences: {
            ...DEFAULT_PREFERENCES,
            ...preferences,
            ...(arriveBy ? { arriveBy: new Date(arriveBy) } : {}),
          },
        },
        providers,
      );
    },
  );

  // Every failure leaves through here. Expected ones get a clear message;
  // unexpected ones are logged and never shown to the client.
  app.setErrorHandler((error, request, reply) => {
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
  });

  return app;
}
