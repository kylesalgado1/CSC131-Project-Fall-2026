import { Database } from '../db/db';
import { PredictionSource } from '../prediction/types';
import { errorName } from '../util/errorName';
import { addMinutes, HOUR_MS, MINUTE_MS } from '../util/time';
import { issueCredential, parseBearer, verifySecret } from './auth';
import {
  DEFAULT_MONITOR_CONFIG,
  MAX_AHEAD_ARRIVAL_DAYS,
  MAX_PAST_ARRIVAL_HOURS,
  MAX_START_OFFSET_HOURS,
  MonitorConfig,
  PLANNING_HORIZON_MINUTES,
} from './config';
import { databaseFailure, guardDatabase } from './databaseFailures';
import {
  BadRequestError,
  NotFoundError,
  RegistrationsClosedError,
  SupersededError,
  UnauthorizedError,
} from './errors';
import {
  applySnapshot,
  countDevicesCreatedSince,
  createDevice,
  deleteDevice,
  Device,
  EMPTY_SNAPSHOT_DIGEST,
  findDevice,
  getTrip,
  getTripAlerts,
  getTrips,
  isMonitoringSchemaReady,
  markDeparted,
  NO_ALERTS,
  purgeExpired,
  SnapshotResult,
  SnapshotTrip,
  touchDevice,
  TripAlerts,
  TripRow,
  updatePush,
} from './store';
import {
  ErrorCode,
  Limits,
  MonitorHealth,
  MonitorStatus,
  PushBody,
  PushStatus,
  PushStatusSource,
  Recommendation,
  Registration,
  SyncBody,
  SyncResponse,
  TripDetail,
  TripInput,
  TripPhase,
  TripState,
} from './types';

/** The most devices the server takes on in an hour, whoever is asking. */
export const MAX_REGISTRATIONS_PER_HOUR = 200;

/** How long a sync waits for its trips' first evaluation. */
export const INLINE_EVALUATION_TIMEOUT_MS = 4000;

/** A device's last-seen time is written at most this often. */
const LAST_SEEN_INTERVAL_MS = MINUTE_MS;

/** How long "the tables are missing" is believed before looking again. */
const AVAILABILITY_RECHECK_MS = MINUTE_MS;

/** A check this overdue means the plan was not refreshed on schedule. */
const OVERDUE_CHECK_MINUTES = 5;

/** How often the sync path enforces retention. */
const PURGE_INTERVAL_MS = HOUR_MS;

const ERROR_CODES: readonly string[] = [
  'routing_unavailable',
  'no_coverage',
  'internal',
  'budget_exhausted',
];

const UNKNOWN_SOURCE: PredictionSource = {
  baseline: 'unknown',
  fallback: false,
  live: false,
};

/** What a server that runs no monitor says about it. */
const MONITOR_OFF: MonitorStatus = {
  enabled: false,
  dependable: false,
  lastTickAt: null,
};

/** What a TripService is built from. Only the database is required. */
export interface TripServiceDeps {
  db: Database;
  /** The server's clock decides "now". Overridable for tests. */
  now?: () => Date;
  config?: MonitorConfig;
  /** Whether alerts can be sent at all. Absent: they cannot. */
  push?: PushStatusSource;
  /**
   * Evaluates the device's due trips, so a sync can answer with their first
   * recommendation. Only used on a server that runs the monitor (see
   * `monitorStatus`). Absent: trips wait for the monitor.
   */
  evaluateNow?: (deviceId: string) => Promise<void>;
  /**
   * Whether a monitor is running and can be counted on. Absent: it is not,
   * and nothing is planned or queued for a trip on this server.
   */
  monitorStatus?: () => Promise<MonitorStatus>;
  /** How long a sync waits for `evaluateNow`. */
  inlineEvaluationTimeoutMs?: number;
  /** Where failures that must not fail a request are noted. */
  log?: (line: string) => void;
}

const iso = (date: Date | null): string | null =>
  date === null ? null : date.toISOString();

const instant = (text: string, field: string): Date => {
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) {
    throw new BadRequestError(`${field} is not a date and time.`);
  }
  return date;
};

/** Checks the trips of a snapshot against each other and parses their dates. */
function snapshotTrips(inputs: TripInput[]): SnapshotTrip[] {
  const seen = new Set<string>();
  return inputs.map(input => {
    if (seen.has(input.id)) {
      throw new BadRequestError('Two trips in the list have the same id.');
    }
    seen.add(input.id);
    return {
      id: input.id,
      title: input.title,
      origin: { lat: input.origin.lat, lng: input.origin.lng },
      destination: { lat: input.destination.lat, lng: input.destination.lng },
      destinationName: input.destinationName ?? null,
      arriveBy: instant(input.arriveBy, 'arriveBy'),
      startsAt:
        input.startsAt === undefined
          ? null
          : instant(input.startsAt, 'startsAt'),
      timeZone: input.timeZone,
    };
  });
}

interface Plan {
  action: Recommendation['action'];
  departAt: Date;
  arriveAt: Date;
  driveMinutes: number;
  evaluatedAt: Date;
}

const planOf = (row: TripRow): Plan | null =>
  row.action !== null &&
  row.departAt !== null &&
  row.arriveAt !== null &&
  row.driveMinutes !== null &&
  row.evaluatedAt !== null
    ? {
        action: row.action,
        departAt: row.departAt,
        arriveAt: row.arriveAt,
        driveMinutes: row.driveMinutes,
        evaluatedAt: row.evaluatedAt,
      }
    : null;

/**
 * The phase a client is told. It is read off the clock as well as the row,
 * so it is right even when no monitor has looked at the trip lately: a trip
 * past its arrival time has ended, one that has entered the planning horizon
 * is waiting for its plan, and "planned" is only said of a trip with a plan.
 */
function phaseOf(row: TripRow, now: Date, hasPlan: boolean): TripPhase {
  if (row.status === 'departed') {
    return 'departed';
  }
  const untilArrivalMs = row.arriveBy.getTime() - now.getTime();
  if (row.status === 'ended' || untilArrivalMs <= 0) {
    return 'ended';
  }
  if (row.phase === 'scheduled') {
    return untilArrivalMs > PLANNING_HORIZON_MINUTES * MINUTE_MS
      ? 'scheduled'
      : 'planning';
  }
  if (row.phase === 'planned' && !hasPlan) {
    return 'planning';
  }
  return row.phase;
}

/**
 * Whether a recommendation is older than it should be: its next check is
 * well overdue, or checks have been failing since it was made for longer
 * than a plan can be trusted.
 */
function isStale(
  row: TripRow,
  plan: Plan,
  now: Date,
  config: MonitorConfig,
): boolean {
  const overdue =
    row.nextCheckAt !== null &&
    now.getTime() - row.nextCheckAt.getTime() >
      OVERDUE_CHECK_MINUTES * MINUTE_MS;
  const failing =
    row.lastErrorAt !== null &&
    row.lastErrorAt.getTime() > plan.evaluatedAt.getTime() &&
    now.getTime() - plan.evaluatedAt.getTime() >
      config.staleAfterMinutes * MINUTE_MS;
  return overdue || failing;
}

/**
 * What a client is told about a trip. `alerts` is what the outbox says about
 * it; without it no alert is claimed to have been sent.
 */
export function tripStateOf(
  row: TripRow,
  now: Date,
  config: MonitorConfig = DEFAULT_MONITOR_CONFIG,
  alerts: TripAlerts = NO_ALERTS,
): TripState {
  const stored = planOf(row);
  const phase = phaseOf(row, now, stored !== null);
  // A trip that is over has no plan worth showing, whether or not the
  // monitor has got round to erasing it.
  const live = phase !== 'departed' && phase !== 'ended';
  const plan = live ? stored : null;
  const recommendation: Recommendation | null = plan && {
    action: plan.action,
    departAt: plan.departAt.toISOString(),
    arriveAt: plan.arriveAt.toISOString(),
    driveMinutes: plan.driveMinutes,
    reason: row.reason ?? '',
    confidence: row.confidence ?? 'Low',
    confidenceReason: row.confidenceReason ?? '',
    notes: row.notes ?? [],
    ...(row.lateByMinutes === null ? {} : { lateByMinutes: row.lateByMinutes }),
    ...(row.marginMinutes === null ? {} : { marginMinutes: row.marginMinutes }),
    evaluatedAt: plan.evaluatedAt.toISOString(),
    source: row.source ?? UNKNOWN_SOURCE,
    stale: isStale(row, plan, now, config),
  };
  const { lastAlert } = alerts;
  return {
    id: row.clientId,
    arriveBy: row.arriveBy.toISOString(),
    phase,
    recommendation,
    noPlanReason: live ? row.noPlanReason : null,
    planAvailableAt:
      phase === 'scheduled'
        ? addMinutes(row.arriveBy, -PLANNING_HORIZON_MINUTES).toISOString()
        : null,
    monitoring: {
      startsAt:
        plan &&
        addMinutes(plan.departAt, -config.monitorLeadMinutes).toISOString(),
      startedAt: iso(row.monitoringStartedAt),
      headsUpAt:
        plan &&
        addMinutes(plan.departAt, -config.headsUpLeadMinutes).toISOString(),
      headsUpSentAt: iso(alerts.headsUpSentAt),
      leaveAlertSentAt: iso(alerts.leaveAlertSentAt),
      endsAt: row.arriveBy.toISOString(),
      nextCheckAt: live ? iso(row.nextCheckAt) : null,
      lastAlert: lastAlert && {
        kind: lastAlert.kind,
        status: lastAlert.status,
        at: lastAlert.at.toISOString(),
        ...(lastAlert.reason === undefined ? {} : { reason: lastAlert.reason }),
      },
    },
    lastError:
      live && row.lastErrorCode !== null && row.lastErrorAt !== null
        ? {
            code: ERROR_CODES.includes(row.lastErrorCode)
              ? (row.lastErrorCode as ErrorCode)
              : 'internal',
            at: row.lastErrorAt.toISOString(),
          }
        : null,
  };
}

/**
 * The device registry and the trips each device asked the server to watch.
 * Everything here is scoped to one device: a trip of another device does not
 * exist as far as its caller can tell.
 */
export class TripService {
  /** The database as it is: for the two things that read its failures. */
  private readonly rawDb: Database;
  /** The database with its failures turned into answers for a client. */
  private readonly db: Database;
  private readonly now: () => Date;
  private readonly config: MonitorConfig;
  private readonly push: PushStatusSource;
  private readonly evaluateNow?: (deviceId: string) => Promise<void>;
  private readonly monitorStatus: () => Promise<MonitorStatus>;
  private readonly inlineEvaluationTimeoutMs: number;
  private readonly log: (line: string) => void;

  private available = false;
  private availabilityCheckedAt?: number;
  private availabilityCheck?: Promise<boolean>;
  private purgedAt?: number;

  constructor({
    db,
    now = () => new Date(),
    config = DEFAULT_MONITOR_CONFIG,
    push = { configured: false },
    evaluateNow,
    monitorStatus = async () => MONITOR_OFF,
    inlineEvaluationTimeoutMs = INLINE_EVALUATION_TIMEOUT_MS,
    log = line => console.error(line),
  }: TripServiceDeps) {
    this.rawDb = db;
    this.db = guardDatabase(db, log);
    this.now = now;
    this.config = config;
    this.push = push;
    this.evaluateNow = evaluateNow;
    this.monitorStatus = monitorStatus;
    this.inlineEvaluationTimeoutMs = inlineEvaluationTimeoutMs;
    this.log = log;
  }

  /**
   * Whether the trip tables exist. Once they do, that is remembered for
   * good. While they do not, the database is asked again at most once a
   * minute, so running the migration later needs no restart.
   *
   * False only ever means the database said the tables are not there. When
   * it could not be asked this throws TemporarilyUnavailableError, and
   * nothing is remembered: the next caller asks again.
   */
  async isAvailable(): Promise<boolean> {
    if (this.available) {
      return true;
    }
    const at = this.now().getTime();
    const sinceCheckMs =
      this.availabilityCheckedAt === undefined
        ? Infinity
        : Math.abs(at - this.availabilityCheckedAt);
    if (sinceCheckMs < AVAILABILITY_RECHECK_MS && this.availabilityCheck) {
      return this.availabilityCheck;
    }
    this.availabilityCheckedAt = at;
    const check: Promise<boolean> = isMonitoringSchemaReady(this.rawDb).then(
      ready => {
        this.available = ready;
        return ready;
      },
      error => {
        // Unless a newer check has taken its place meanwhile.
        if (this.availabilityCheck === check) {
          this.availabilityCheckedAt = undefined;
          this.availabilityCheck = undefined;
        }
        throw databaseFailure(error, this.log);
      },
    );
    this.availabilityCheck = check;
    return check;
  }

  /** What clients may rely on when deciding what to show. */
  limits(): Limits {
    return {
      planningHorizonMinutes: PLANNING_HORIZON_MINUTES,
      monitorLeadMinutes: this.config.monitorLeadMinutes,
      headsUpLeadMinutes: this.config.headsUpLeadMinutes,
      meaningfulShiftMinutes: this.config.meaningfulShiftMinutes,
      maxTrips: this.config.maxTrips,
    };
  }

  /**
   * Registers a new device and returns its credential, which is not kept:
   * only the hash of the secret is stored. Refused once too many devices
   * have registered in the last hour, which bounds what a flood can store.
   */
  async register(platform: 'ios' = 'ios'): Promise<Registration> {
    const now = this.now();
    const recent = await countDevicesCreatedSince(
      this.db,
      new Date(now.getTime() - HOUR_MS),
    );
    if (recent >= MAX_REGISTRATIONS_PER_HOUR) {
      throw new RegistrationsClosedError();
    }
    const credential = issueCredential();
    await createDevice(this.db, {
      id: credential.deviceId,
      secretHash: credential.secretHash,
      platform,
      now,
    });
    return {
      deviceId: credential.deviceId,
      token: credential.token,
      limits: this.limits(),
    };
  }

  /**
   * The device an Authorization header belongs to. The header's shape is
   * checked before anything is looked up, and the secret is compared in
   * constant time. Throws UnauthorizedError for anything else.
   */
  async authenticate(header: string | undefined): Promise<Device> {
    const credential = parseBearer(header);
    if (!credential) {
      throw new UnauthorizedError();
    }
    const device = await findDevice(this.db, credential.deviceId);
    if (!device || !verifySecret(credential.secret, device.secretHash)) {
      throw new UnauthorizedError();
    }
    const now = this.now();
    if (
      Math.abs(now.getTime() - device.lastSeenAt.getTime()) >=
      LAST_SEEN_INTERVAL_MS
    ) {
      await touchDevice(this.db, device.id, now);
      return { ...device, lastSeenAt: now };
    }
    return device;
  }

  /** Whether alerts can reach this device. */
  pushStatusFor(device: Device): PushStatus {
    return {
      configured: this.push.configured,
      registered: device.apnsToken !== null,
      authorized: device.notificationsAuthorized === true,
      ...(device.pushFailureReason !== null && device.pushFailureAt !== null
        ? {
            lastFailure: {
              reason: device.pushFailureReason,
              at: device.pushFailureAt.toISOString(),
            },
          }
        : {}),
    };
  }

  /** What a client is told about a trip. */
  toTripState(row: TripRow, now: Date, alerts?: TripAlerts): TripState {
    return tripStateOf(row, now, this.config, alerts);
  }

  /** Stores where the device's alerts go and whether it allows them. */
  async setPush(device: Device, body: PushBody): Promise<{ push: PushStatus }> {
    const updated = await updatePush(
      this.db,
      device.id,
      {
        // Hex reads the same in either case; one token must be one row.
        apnsToken:
          body.apnsToken === null ? null : body.apnsToken.toLowerCase(),
        environment: body.environment,
        authorized: body.authorized,
      },
      this.now(),
    );
    if (!updated) {
      throw new UnauthorizedError();
    }
    return { push: this.pushStatusFor(updated) };
  }

  /** Forgets the device, its trips and its queued alerts. */
  async unregister(device: Device): Promise<void> {
    await deleteDevice(this.db, device.id);
  }

  /**
   * Makes the device's monitored trips exactly those in the body (see
   * `applySnapshot` for the rules), then answers with the state of them all.
   * On a server that runs the monitor, a snapshot that is applied gets its
   * due trips evaluated before the answer, when that takes no longer than a
   * few seconds.
   *
   * A server that does not run the monitor evaluates nothing: a trip would
   * get a plan nobody refreshes and alerts nobody sends, and would look
   * monitored. Its trips stay without a plan, and the answer says the
   * monitor is off, so the app can ask for a verdict itself and say so.
   */
  async sync(device: Device, body: SyncBody): Promise<SyncResponse> {
    const now = this.now();
    const trips = snapshotTrips(body.trips);
    // A retry of something already applied must stay harmless however late
    // it arrives, so only a snapshot that can still be applied is held to
    // the window.
    if (body.revision > device.syncRevision) {
      this.checkWindow(trips, now);
    }
    const result = await applySnapshot(
      this.db,
      device.id,
      body.revision,
      trips,
      now,
    );
    if (!result.applied) {
      return this.snapshot(device, result);
    }
    const monitor = await this.monitorHealth();
    if (monitor.enabled) {
      await this.evaluateInline(device.id);
    }
    await this.purgeOccasionally(now);
    return this.snapshot(device, result, monitor);
  }

  /** The state of every trip of the device, changing nothing. */
  async list(device: Device): Promise<SyncResponse> {
    return this.snapshot(device, {
      applied: false,
      revision: device.syncRevision,
      digest: device.syncDigest ?? EMPTY_SNAPSHOT_DIGEST,
    });
  }

  /** One trip of the device. Throws NotFoundError for anybody else's. */
  async get(device: Device, clientId: string): Promise<TripDetail> {
    const now = this.now();
    const trip = await getTrip(this.db, device.id, clientId);
    if (!trip) {
      throw new NotFoundError();
    }
    const alerts = await getTripAlerts(this.db, device.id);
    return {
      trip: this.toTripState(trip, now, alerts.get(trip.id)),
      serverTime: now.toISOString(),
      push: this.pushStatusFor(device),
      limits: this.limits(),
      monitor: await this.monitorHealth(),
    };
  }

  /**
   * "I've left": ends the trip's monitoring. `arriveBy` must be the trip's
   * current arrival time, else SupersededError and nothing changes.
   */
  async departed(
    device: Device,
    clientId: string,
    arriveBy: string,
  ): Promise<{ trip: TripState }> {
    const now = this.now();
    const result = await markDeparted(
      this.db,
      device.id,
      clientId,
      instant(arriveBy, 'arriveBy'),
      now,
    );
    if (result.outcome === 'not_found') {
      throw new NotFoundError();
    }
    if (result.outcome === 'superseded') {
      throw new SupersededError();
    }
    const alerts = await getTripAlerts(this.db, device.id);
    return {
      trip: this.toTripState(result.trip, now, alerts.get(result.trip.id)),
    };
  }

  /**
   * Enforces retention now, whether or not anybody is syncing and whether or
   * not this server runs the monitor: for a timer. Never throws; a failure is
   * noted by its kind.
   */
  async enforceRetention(): Promise<void> {
    try {
      if (await this.isAvailable()) {
        await purgeExpired(this.rawDb, this.now(), this.config.retentionHours);
      }
    } catch (error) {
      this.log(`Trip purge failed: ${errorName(error)}`);
    }
  }

  private checkWindow(trips: SnapshotTrip[], now: Date): void {
    const earliest = now.getTime() - MAX_PAST_ARRIVAL_HOURS * HOUR_MS;
    const latest = now.getTime() + MAX_AHEAD_ARRIVAL_DAYS * 24 * HOUR_MS;
    for (const trip of trips) {
      const arriveBy = trip.arriveBy.getTime();
      if (arriveBy <= earliest) {
        throw new BadRequestError(
          `A trip's arrival time passed more than ${MAX_PAST_ARRIVAL_HOURS} hours ago.`,
        );
      }
      if (arriveBy >= latest) {
        throw new BadRequestError(
          `A trip's arrival time is more than ${MAX_AHEAD_ARRIVAL_DAYS} days away.`,
        );
      }
      // The start time is only a label, but it is stored, and the database
      // does not take every date a request can spell (year 0, say).
      if (
        trip.startsAt !== null &&
        Math.abs(trip.startsAt.getTime() - arriveBy) >
          MAX_START_OFFSET_HOURS * HOUR_MS
      ) {
        throw new BadRequestError(
          `A trip's start time is more than ${MAX_START_OFFSET_HOURS} hours from its arrival time.`,
        );
      }
    }
  }

  private async snapshot(
    device: Device,
    result: SnapshotResult,
    /** The monitor's health, when the caller has already asked for it. */
    known?: MonitorHealth,
  ): Promise<SyncResponse> {
    // Read the clock again: the evaluation may have taken a while.
    const now = this.now();
    const [rows, alerts, monitor] = await Promise.all([
      getTrips(this.db, device.id),
      getTripAlerts(this.db, device.id),
      known ?? this.monitorHealth(),
    ]);
    return {
      revision: result.revision,
      applied: result.applied,
      digest: result.digest,
      serverTime: now.toISOString(),
      limits: this.limits(),
      push: this.pushStatusFor(device),
      monitor,
      trips: rows.map(row => this.toTripState(row, now, alerts.get(row.id))),
    };
  }

  private async monitorHealth(): Promise<MonitorHealth> {
    let status = MONITOR_OFF;
    try {
      status = await this.monitorStatus();
    } catch (error) {
      // Not knowing is reported as "off": never promise a monitor.
      this.log(`Monitor status failed: ${errorName(error)}`);
    }
    return {
      enabled: status.enabled,
      dependable: status.enabled && status.dependable,
      lastTickAt: iso(status.lastTickAt),
    };
  }

  /**
   * Gives the device's due trips a few seconds to get their first
   * recommendation. The evaluation carries on if it takes longer, and its
   * failure never fails the sync.
   */
  private async evaluateInline(deviceId: string): Promise<void> {
    const { evaluateNow } = this;
    if (!evaluateNow) {
      return;
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<void>(resolve => {
      timer = setTimeout(resolve, this.inlineEvaluationTimeoutMs);
    });
    const evaluation = Promise.resolve()
      .then(() => evaluateNow(deviceId))
      .catch(error =>
        this.log(`Inline evaluation failed: ${errorName(error)}`),
      );
    await Promise.race([evaluation, timeout]);
    clearTimeout(timer);
  }

  /**
   * Enforces retention about once an hour from the sync path as well, so
   * rows do not outlive their trips even where no timer runs it.
   */
  private async purgeOccasionally(now: Date): Promise<void> {
    const at = now.getTime();
    if (
      this.purgedAt !== undefined &&
      Math.abs(at - this.purgedAt) < PURGE_INTERVAL_MS
    ) {
      return;
    }
    this.purgedAt = at;
    try {
      await purgeExpired(this.rawDb, now, this.config.retentionHours);
    } catch (error) {
      this.log(`Trip purge failed: ${errorName(error)}`);
    }
  }
}
