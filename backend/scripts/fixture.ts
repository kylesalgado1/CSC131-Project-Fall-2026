import { FastifyInstance } from 'fastify';
import { buildServer } from '../api/server';
import { Database } from '../db/db';
import { runMigrations } from '../db/migrate';
import { createPgliteDatabase } from '../db/pglite';
import { CompositePlaceSearch } from '../places/compositePlaces';
import { PredictionProviders } from '../prediction/predict';
import { FakeBaselineProvider } from '../prediction/providers/fake';
import { liveUnavailable } from '../prediction/providers/live';
import {
  RoutePath,
  RoutePathProvider,
} from '../prediction/providers/routing/types';
import { Route } from '../prediction/types';
import { PushMessage, PushResult, PushSender } from '../push/apns';
import { BadRequestError } from '../trips/errors';
import { TickReport } from '../trips/types';
import { wireMonitoring } from '../trips/wiring';
import { distanceMeters, metersToMiles } from '../util/geo';
import { MINUTE_MS } from '../util/time';

/**
 * A whole backend with nothing real behind it, for controlled end-to-end
 * runs of the app: an in-memory database, traffic and a clock that do what
 * they are told, and a push sender that records instead of sending. Its
 * answers are labelled as fixture data (source.baseline is 'fixture'). It is
 * development tooling and must never be deployed: see serve-fixture.ts.
 */

/** The drive time the fixture starts with. */
export const FIXTURE_DRIVE_MINUTES = 25;

/** The farthest one request may move the fixture's clock while ticking. */
export const MAX_TICKED_MINUTES = 24 * 60;

const PATH_POINTS = 9;

/** One alert the fixture would have sent. Device tokens are not kept. */
export interface FixturePush {
  /** The fixture's time when it was sent. */
  sentAt: string;
  /** The notification's id, as APNs would get it. */
  id: string;
  /** The trip row the alert collapses under. */
  collapseId: string;
  environment: 'sandbox' | 'production';
  expiresAt: string;
  /** The APNs payload: the title, the body and the trip it is about. */
  payload: object;
}

/** What the fixture is doing, for GET /fixture/state. */
export interface FixtureState {
  now: string;
  driveMinutes: number;
  live: { available: boolean; extraMinutes: number };
  /** How many alerts have been recorded. */
  pushes: number;
  /** Every stored trip as the monitor sees it. No coordinates or titles. */
  trips: Array<{
    id: string;
    status: string;
    phase: string;
    arriveBy: string;
    departAt: string | null;
    nextCheckAt: string | null;
    headsUpState: string;
    leaveSentAt: string | null;
    lateSentAt: string | null;
    updateCount: number;
    alerts: Array<{ kind: string; status: string; reason: string | null }>;
  }>;
}

/** A running fixture: the server, and the knobs its routes turn. */
export interface Fixture {
  app: FastifyInstance;
  /** The fixture's clock. */
  now(): Date;
  /** Runs one monitoring tick at the fixture's time. */
  tick(): Promise<TickReport>;
  /** Every alert recorded so far, oldest first. */
  pushes(): FixturePush[];
  state(): Promise<FixtureState>;
  close(): Promise<void>;
}

/** Records alerts instead of sending them. Every one is "accepted". */
class RecordingPushSender implements PushSender {
  readonly configured = true;
  readonly pushes: FixturePush[] = [];

  constructor(private readonly now: () => Date) {}

  async send(message: PushMessage): Promise<PushResult> {
    this.pushes.push({
      sentAt: this.now().toISOString(),
      id: message.id,
      collapseId: message.collapseId,
      environment: message.environment,
      expiresAt: message.expiresAt.toISOString(),
      payload: message.payload,
    });
    return { ok: true, apnsId: message.id };
  }
}

/** A straight line from start to end, in a few points, tagged as made up. */
class FixturePathProvider implements RoutePathProvider {
  async getPath({ origin, destination }: Route): Promise<RoutePath> {
    const points = Array.from({ length: PATH_POINTS }, (_, i) => {
      const along = i / (PATH_POINTS - 1);
      return {
        lat: origin.lat + (destination.lat - origin.lat) * along,
        lng: origin.lng + (destination.lng - origin.lng) * along,
      };
    });
    return {
      points,
      distanceMiles: metersToMiles(distanceMeters(origin, destination)),
      source: 'fixture',
    };
  }
}

const iso = (ms: number | null): string | null =>
  ms === null ? null : new Date(Math.round(ms)).toISOString();

const epochMs = (column: string): string =>
  `(extract(epoch FROM ${column}) * 1000)::float8 AS ${column}`;

const clockSchema = {
  body: {
    type: 'object',
    additionalProperties: false,
    properties: {
      now: { type: 'string', format: 'date-time' },
      advanceMinutes: { type: 'number', minimum: 0, maximum: 8 * 24 * 60 },
      tick: { type: 'boolean' },
    },
  },
} as const;

const trafficSchema = {
  body: {
    type: 'object',
    required: ['driveMinutes'],
    additionalProperties: false,
    properties: {
      driveMinutes: { type: 'number', minimum: 1, maximum: 600 },
    },
  },
} as const;

const liveSchema = {
  body: {
    type: 'object',
    required: ['available'],
    additionalProperties: false,
    properties: {
      available: { type: 'boolean' },
      extraMinutes: { type: 'number', minimum: 0, maximum: 600 },
    },
  },
} as const;

const NO_TICKS: TickReport = {
  evaluated: 0,
  queued: 0,
  delivered: 0,
  failed: 0,
  dropped: 0,
};

const add = (a: TickReport, b: TickReport): TickReport => ({
  evaluated: a.evaluated + b.evaluated,
  queued: a.queued + b.queued,
  delivered: a.delivered + b.delivered,
  failed: a.failed + b.failed,
  dropped: a.dropped + b.dropped,
});

/**
 * Builds the fixture server. Beside the real API (with the device and trip
 * routes, wired as serve.ts wires them) it has these, all JSON:
 *
 * - GET  /fixture/state    the clock, the traffic and every trip's state
 * - POST /fixture/clock    { now } or { advanceMinutes }, forward only. With
 *                          "tick": true a tick runs at every minute passed,
 *                          as on a server that stays awake; without it the
 *                          clock jumps, as when a server slept.
 * - POST /fixture/traffic  { driveMinutes }: the typical drive, from now on
 * - POST /fixture/live     { available, extraMinutes? }: live conditions
 * - POST /fixture/tick     one monitoring tick, answering its report
 * - GET  /fixture/pushes   every alert "sent" so far
 *
 * The clock starts at the given time (the real time, to the minute, unless
 * told) and only moves when told to. Nothing ticks by itself. Refuses to be
 * built when NODE_ENV is "production".
 */
export async function buildFixture(
  options: {
    now?: Date;
    log?: (line: string) => void;
    env?: Record<string, string | undefined>;
  } = {},
): Promise<Fixture> {
  if ((options.env ?? process.env).NODE_ENV === 'production') {
    throw new Error(
      'The fixture server serves made-up data and must not run in production.',
    );
  }
  const db: Database = await createPgliteDatabase();
  await runMigrations(db);

  let clock =
    options.now ?? new Date(Math.floor(Date.now() / MINUTE_MS) * MINUTE_MS);
  const now = (): Date => clock;
  const traffic = { driveMinutes: FIXTURE_DRIVE_MINUTES };
  const live = { available: false, extraMinutes: 0 };

  const providers: PredictionProviders = {
    baseline: new FakeBaselineProvider(
      () => traffic.driveMinutes,
      100,
      undefined,
      'fixture',
    ),
    live: {
      getAdjustment: async () =>
        live.available
          ? { available: true, extraMinutes: live.extraMinutes, incidents: [] }
          : liveUnavailable(),
    },
  };
  const push = new RecordingPushSender(now);
  const { monitor, trips } = wireMonitoring({
    db,
    providers,
    push,
    // The fixture is its own scheduler: it reports a monitor that can be
    // counted on, so the app shows what it shows when all is well.
    enabled: true,
    alwaysOn: true,
    now,
    log: options.log,
  });
  const app = buildServer({
    providers,
    // Known names such as "sac state" resolve; nothing is looked up online.
    places: new CompositePlaceSearch([]),
    paths: new FixturePathProvider(),
    now,
    trips,
    // The fixture's clock stands still until it is told to move, so an
    // hourly limit would never start a new hour.
    tripSyncsPerHour: Infinity,
  });

  const tick = (): Promise<TickReport> => monitor.tick();

  const state = async (): Promise<FixtureState> => {
    const stored = await db.query<{
      id: string;
      client_id: string;
      status: string;
      phase: string;
      arrive_by: number;
      depart_at: number | null;
      next_check_at: number | null;
      heads_up_state: string;
      leave_sent_at: number | null;
      late_sent_at: number | null;
      update_count: number;
    }>(
      `SELECT id, client_id, status, phase, ${epochMs('arrive_by')},
              ${epochMs('depart_at')}, ${epochMs('next_check_at')},
              heads_up_state, ${epochMs('leave_sent_at')},
              ${epochMs('late_sent_at')}, update_count
         FROM trips ORDER BY trips.arrive_by, client_id`,
    );
    const alerts = await db.query<{
      trip_id: string;
      kind: string;
      status: string;
      last_error: string | null;
    }>(
      `SELECT trip_id, kind, status, last_error
         FROM trip_notifications ORDER BY created_at, id`,
    );
    return {
      now: clock.toISOString(),
      driveMinutes: traffic.driveMinutes,
      live: { ...live },
      pushes: push.pushes.length,
      trips: stored.rows.map(row => ({
        id: row.client_id,
        status: row.status,
        phase: row.phase,
        arriveBy: new Date(Math.round(row.arrive_by)).toISOString(),
        departAt: iso(row.depart_at),
        nextCheckAt: iso(row.next_check_at),
        headsUpState: row.heads_up_state,
        leaveSentAt: iso(row.leave_sent_at),
        lateSentAt: iso(row.late_sent_at),
        updateCount: row.update_count,
        alerts: alerts.rows
          .filter(alert => alert.trip_id === row.id)
          .map(alert => ({
            kind: alert.kind,
            status: alert.status,
            reason: alert.last_error,
          })),
      })),
    };
  };

  app.get('/fixture/state', async () => state());

  app.post<{ Body: { now?: string; advanceMinutes?: number; tick?: boolean } }>(
    '/fixture/clock',
    { schema: clockSchema },
    async request => {
      const { now: wanted, advanceMinutes, tick: ticking } = request.body;
      if ((wanted === undefined) === (advanceMinutes === undefined)) {
        throw new BadRequestError('Give either now or advanceMinutes.');
      }
      const target =
        wanted !== undefined
          ? new Date(wanted)
          : new Date(clock.getTime() + (advanceMinutes as number) * MINUTE_MS);
      if (target.getTime() < clock.getTime()) {
        throw new BadRequestError('The fixture clock only moves forward.');
      }
      if (!ticking) {
        clock = target;
        return { now: clock.toISOString(), ticks: 0, report: NO_TICKS };
      }
      if (target.getTime() - clock.getTime() > MAX_TICKED_MINUTES * MINUTE_MS) {
        throw new BadRequestError(
          `With tick, the clock moves at most ${MAX_TICKED_MINUTES} minutes at a time.`,
        );
      }
      // A tick at every whole minute on the way, and one on arrival.
      let report = NO_TICKS;
      let ticks = 0;
      const firstMinute =
        Math.floor(clock.getTime() / MINUTE_MS) * MINUTE_MS + MINUTE_MS;
      for (let at = firstMinute; at < target.getTime(); at += MINUTE_MS) {
        clock = new Date(at);
        report = add(report, await tick());
        ticks += 1;
      }
      clock = target;
      report = add(report, await tick());
      ticks += 1;
      return { now: clock.toISOString(), ticks, report };
    },
  );

  app.post<{ Body: { driveMinutes: number } }>(
    '/fixture/traffic',
    { schema: trafficSchema },
    async request => {
      traffic.driveMinutes = request.body.driveMinutes;
      return { driveMinutes: traffic.driveMinutes };
    },
  );

  app.post<{ Body: { available: boolean; extraMinutes?: number } }>(
    '/fixture/live',
    { schema: liveSchema },
    async request => {
      live.available = request.body.available;
      live.extraMinutes = request.body.available
        ? request.body.extraMinutes ?? 0
        : 0;
      return { live: { ...live } };
    },
  );

  app.post('/fixture/tick', async () => tick());

  app.get('/fixture/pushes', async () => ({ pushes: push.pushes }));

  return {
    app,
    now,
    tick,
    pushes: () => [...push.pushes],
    state,
    async close() {
      await app.close();
      await db.close();
    },
  };
}
