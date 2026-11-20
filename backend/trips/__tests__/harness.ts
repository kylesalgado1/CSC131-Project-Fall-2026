// Shared by the monitor's tests: an in-memory Postgres, traffic that does
// what a test tells it, a push sender that records instead of sending, and
// a clock that only moves when told. Nothing here sleeps or uses a network.
import assert from 'node:assert/strict';
import { Database } from '../../db/db';
import { runMigrations } from '../../db/migrate';
import { createPgliteDatabase } from '../../db/pglite';
import { PredictionProviders } from '../../prediction/predict';
import { LiveAdjustment, Route } from '../../prediction/types';
import { PushMessage, PushResult, PushSender } from '../../push/apns';
import {
  DEFAULT_MONITOR_BUDGET,
  DEFAULT_MONITOR_CONFIG,
  MonitorBudget,
  MonitorConfig,
} from '../config';
import { TripMonitor } from '../monitor';
import { TripService } from '../service';
import { Device, mapTrip, tripColumns, TripRecord, TripRow } from '../store';
import { SyncResponse, TickReport, TripInput, TripState } from '../types';
import { wireMonitoring } from '../wiring';

export const MINUTE = 60_000;

/** A time on Friday 20 November 2026, on the Pacific clock. */
export const t = (clock: string): Date =>
  new Date(`2026-11-20T${clock}:00-08:00`);

export const addMinutes = (date: Date, n: number): Date =>
  new Date(date.getTime() + n * MINUTE);

export const LAB = 'A1B2C3@2026-11-20';
export const GYM = 'D4E5F6@2026-11-20';
export const TOKEN = 'ab'.repeat(32);
export const OTHER_TOKEN = 'cd'.repeat(32);

/** A trip to arrive by 8:00 AM, as the app sends it. */
export const tripInput = (over: Partial<TripInput> = {}): TripInput => ({
  id: LAB,
  title: 'Chem lab',
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  destinationName: 'Sac State',
  arriveBy: t('08:00').toISOString(),
  timeZone: 'America/Los_Angeles',
  ...over,
});

/** A fresh database with every migration applied. */
export async function migratedDatabase(): Promise<Database> {
  const db = await createPgliteDatabase();
  await runMigrations(db);
  return db;
}

/** Empties what the tests write, so each starts from nothing. */
export async function resetDatabase(db: Database): Promise<void> {
  // Takes the trips and the queued alerts with it.
  await db.exec('TRUNCATE devices CASCADE');
  await db.exec(
    `UPDATE monitor_state
        SET last_tick_at = NULL, last_external_tick_at = NULL,
            budget_day = NULL, budget_used = 0`,
  );
}

/** Traffic a test controls: how long the drive takes, and whether it is known. */
export class Traffic {
  /** The typical drive, whenever one leaves. */
  driveMinutes = 20;
  /** Set to make the drive depend on when one leaves: a rush hour, say. */
  driveMinutesAt?: (departAt: Date) => number;
  /** Set to make every prediction fail with it. */
  failure?: Error;
  /** Set to make the predictions for some routes fail, and not the rest. */
  failureFor?: (route: Route) => Error | undefined;
  /** Set to make predictions never answer. */
  hangs = false;
  /** Live conditions, when there are any. */
  live?: LiveAdjustment;
  /** How many predictions were asked for. */
  asks = 0;
  /** Every instant a prediction was asked about, in order. */
  askedAbout: Date[] = [];
  /** The route of every prediction asked for, in order. */
  askedRoutes: Route[] = [];
  /** Runs while a prediction is being made. */
  onAsk?: () => Promise<void>;

  providers(): PredictionProviders {
    return {
      baseline: {
        getBaseline: async (route, departAt) => {
          const failure = this.failureFor?.(route) ?? this.failure;
          if (failure) {
            throw failure;
          }
          return {
            minutes: this.driveMinutesAt?.(departAt) ?? this.driveMinutes,
            sampleCount: 100,
            source: 'fixture',
          };
        },
      },
      live: {
        // Asked once per prediction, with the instant it is about.
        getAdjustment: async (route, now) => {
          this.asks += 1;
          this.askedAbout.push(now);
          this.askedRoutes.push(route);
          if (this.hangs) {
            await new Promise(() => undefined);
          }
          await this.onAsk?.();
          return (
            this.live ?? { available: false, extraMinutes: 0, incidents: [] }
          );
        },
      },
    };
  }
}

/** One alert APNs would have been asked to deliver. */
export interface Sent {
  at: Date;
  message: PushMessage;
  kind: string;
  title: string;
  body: string;
}

/** A push sender that records what it is given and answers as told. */
export class RecordingPush implements PushSender {
  configured = true;
  /** What to answer next, in order. When empty, every send is accepted. */
  results: PushResult[] = [];
  /** Every send, whatever became of it. */
  attempts: Sent[] = [];
  /** The sends that were accepted. */
  sent: Sent[] = [];
  /** Runs during a send, before it answers. */
  onSend?: (message: PushMessage) => Promise<void>;
  closed = false;

  constructor(private readonly now: () => Date) {}

  async send(message: PushMessage): Promise<PushResult> {
    const payload = message.payload as {
      kind: string;
      aps: { alert: { title: string; body: string } };
    };
    const record: Sent = {
      at: this.now(),
      message,
      kind: payload.kind,
      title: payload.aps.alert.title,
      body: payload.aps.alert.body,
    };
    this.attempts.push(record);
    await this.onSend?.(message);
    const result = this.results.shift() ?? { ok: true, apnsId: message.id };
    if (result.ok) {
      this.sent.push(record);
    }
    return result;
  }

  async close(): Promise<void> {
    this.closed = true;
  }

  /** The kinds of the accepted alerts, in order. */
  kinds(): string[] {
    return this.sent.map(sent => sent.kind);
  }
}

export interface WorldOptions {
  now: Date;
  config?: Partial<MonitorConfig>;
  budget?: Partial<MonitorBudget>;
  enabled?: boolean;
  alwaysOn?: boolean;
  evaluationTimeoutMs?: number;
  /** False builds the monitor and the service with no push sender set up. */
  push?: boolean;
}

/**
 * A server's worth of monitoring on a database: the monitor and the trip
 * service wired together as serve.ts wires them, with a clock, traffic and
 * push the test controls.
 */
export class World {
  clock: Date;
  readonly traffic = new Traffic();
  readonly push: RecordingPush;
  readonly logs: string[] = [];
  readonly config: MonitorConfig;
  monitor: TripMonitor;
  service: TripService;
  /** A tick as the tick route starts it. Absent when the worker is off. */
  externalTick?: () => Promise<TickReport>;
  /** The reports of every tick so far. */
  reports: TickReport[] = [];
  private revision = 0;
  private readonly options: WorldOptions;

  constructor(private readonly db: Database, options: WorldOptions) {
    this.options = options;
    this.clock = options.now;
    this.config = { ...DEFAULT_MONITOR_CONFIG, ...options.config };
    this.push = new RecordingPush(() => this.clock);
    this.push.configured = options.push !== false;
    ({
      monitor: this.monitor,
      service: this.service,
      externalTick: this.externalTick,
    } = this.build());
  }

  /** A new monitor and service on the same database: a restarted server. */
  restart(): void {
    ({
      monitor: this.monitor,
      service: this.service,
      externalTick: this.externalTick,
    } = this.build());
  }

  /** Another worker on the same database, with the same clock and traffic. */
  secondMonitor(): TripMonitor {
    return this.build().monitor;
  }

  private build(): {
    monitor: TripMonitor;
    service: TripService;
    externalTick?: () => Promise<TickReport>;
  } {
    const { options } = this;
    const { monitor, trips, externalTick } = wireMonitoring({
      db: this.db,
      providers: this.traffic.providers(),
      push: this.push,
      now: () => this.clock,
      config: this.config,
      budget: { ...DEFAULT_MONITOR_BUDGET, ...options.budget },
      enabled: options.enabled ?? true,
      alwaysOn: options.alwaysOn ?? false,
      evaluationTimeoutMs: options.evaluationTimeoutMs,
      log: line => this.logs.push(line),
    });
    return { monitor, service: trips, externalTick };
  }

  /** Registers a device. With a token unless told otherwise. */
  async device(
    push: { apnsToken: string | null; authorized: boolean } | null = {
      apnsToken: TOKEN,
      authorized: true,
    },
  ): Promise<string> {
    const { token } = await this.service.register();
    if (push) {
      await this.setPush(token, push.apnsToken, push.authorized);
    }
    return token;
  }

  async authenticate(token: string): Promise<Device> {
    return this.service.authenticate(`Bearer ${token}`);
  }

  async setPush(
    token: string,
    apnsToken: string | null,
    authorized = true,
  ): Promise<void> {
    await this.service.setPush(await this.authenticate(token), {
      apnsToken,
      environment: 'sandbox',
      authorized,
    });
  }

  /** Sends the device's whole list of trips, as the app does. */
  async sync(token: string, trips: TripInput[]): Promise<SyncResponse> {
    this.revision += 1;
    return this.service.sync(await this.authenticate(token), {
      revision: this.revision,
      trips,
    });
  }

  async list(token: string): Promise<SyncResponse> {
    return this.service.list(await this.authenticate(token));
  }

  /** What the app is told about one trip. */
  async state(token: string, id: string = LAB): Promise<TripState> {
    const trip = (await this.list(token)).trips.find(one => one.id === id);
    assert.ok(trip, `no trip ${id}`);
    return trip;
  }

  /** Moves the clock and runs one tick, as the ticker would at that time. */
  async tickAt(at: Date): Promise<TickReport> {
    this.clock = at;
    const report = await this.monitor.tick();
    this.reports.push(report);
    return report;
  }

  /**
   * Runs a tick every minute, from the minute after the clock's time up to
   * and including the given time: what a server that stays awake does.
   */
  async runUntil(end: Date): Promise<void> {
    const first = Math.floor(this.clock.getTime() / MINUTE) * MINUTE + MINUTE;
    for (let at = first; at <= end.getTime(); at += MINUTE) {
      await this.tickAt(new Date(at));
    }
  }

  /** A trip's row whatever its status. */
  async row(clientId: string = LAB): Promise<TripRow> {
    const { rows } = await this.db.query<TripRecord>(
      `SELECT ${tripColumns()} FROM trips WHERE client_id = $1`,
      [clientId],
    );
    assert.equal(rows.length, 1, `no single row for ${clientId}`);
    return mapTrip(rows[0]);
  }

  /** The outbox, oldest first. */
  async outbox(): Promise<
    Array<{
      kind: string;
      status: string;
      last_error: string | null;
      attempts: number;
      content_version: number;
    }>
  > {
    const { rows } = await this.db.query<{
      kind: string;
      status: string;
      last_error: string | null;
      attempts: number;
      content_version: number;
    }>(
      `SELECT kind, status, last_error, attempts, content_version
         FROM trip_notifications ORDER BY created_at, id`,
    );
    return rows;
  }
}
