import { Confidence, LatLng, PredictionSource } from '../prediction/types';

/**
 * The wire shapes of the device and trip endpoints, and the few types the
 * monitor shares with them. Dates are ISO strings here, as they are sent.
 */

/** What a client may rely on when it decides what to show. */
export interface Limits {
  /** How far ahead of the arrival target a departure can be planned. */
  planningHorizonMinutes: number;
  /** Active monitoring starts this long before the recommended departure. */
  monitorLeadMinutes: number;
  /** The heads-up goes out this long before the recommended departure. */
  headsUpLeadMinutes: number;
  /** A departure that moved by at least this much is worth an update. */
  meaningfulShiftMinutes: number;
  /** The most trips one snapshot may hold. */
  maxTrips: number;
}

/** Whether alerts can reach a device. */
export interface PushStatus {
  /** The server has APNs credentials. */
  configured: boolean;
  /** This device has a usable APNs token on file. */
  registered: boolean;
  /** The last value the device reported. False until it reports one. */
  authorized: boolean;
  /** Set when APNs rejected this device's token or the last send failed. */
  lastFailure?: { reason: string; at: string };
}

/** Whether anything is checking trips while the app is closed. */
export interface MonitorHealth {
  /** This server runs the monitoring worker. */
  enabled: boolean;
  /** The worker can be counted on: always on, or ticked from outside. */
  dependable: boolean;
  lastTickAt: string | null;
}

/** The same, as the monitor reports it. */
export interface MonitorStatus {
  enabled: boolean;
  dependable: boolean;
  lastTickAt: Date | null;
}

/** What the trip routes need to know about push. A push sender is one. */
export interface PushStatusSource {
  /** Whether the server has what it needs to send alerts. */
  readonly configured: boolean;
}

/** What one monitoring tick did. */
export interface TickReport {
  evaluated: number;
  queued: number;
  delivered: number;
  failed: number;
  dropped: number;
}

/** One trip of a snapshot, as a client sends it. */
export interface TripInput {
  id: string;
  title: string;
  origin: LatLng;
  destination: LatLng;
  destinationName?: string;
  arriveBy: string;
  startsAt?: string;
  timeZone: string;
}

/** The body of PUT /trips: every trip the device wants monitored. */
export interface SyncBody {
  revision: number;
  trips: TripInput[];
}

/** The body of PUT /devices/me/push. */
export interface PushBody {
  apnsToken: string | null;
  environment: 'sandbox' | 'production';
  authorized: boolean;
}

/** Where a trip stands, as a client is told. See `phaseOf` in service.ts. */
export type TripPhase =
  | 'scheduled'
  | 'planning'
  | 'planned'
  | 'monitoring'
  | 'departed'
  | 'ended';

/** The alerts the monitor sends for a trip. */
export type AlertKind = 'heads_up' | 'update' | 'leave_now' | 'late';

/** Why a trip's last evaluation failed. */
export type ErrorCode =
  | 'routing_unavailable'
  | 'no_coverage'
  | 'internal'
  | 'budget_exhausted';

/** The departure the backend recommends for a trip. */
export interface Recommendation {
  action: 'leave_now' | 'wait' | 'leave_later';
  departAt: string;
  arriveAt: string;
  driveMinutes: number;
  /**
   * The verdict's sentence. It counts from evaluatedAt ("leaving in 30
   * minutes"), so it is only true to the minute for a moment.
   */
  reason: string;
  confidence: Confidence;
  confidenceReason: string;
  notes: string[];
  /** Set when even leaving at departAt misses the arrival target. */
  lateByMinutes?: number;
  /** Minutes to spare before the arrival target. */
  marginMinutes?: number;
  /**
   * The instant this recommendation is as of: the one the prediction was
   * asked about. Usually the minute it was made. After a check that came
   * late or was retried it is earlier, by less than 15 minutes, so that
   * `reason` is never taken to be newer than it is.
   */
  evaluatedAt: string;
  source: PredictionSource;
  /** True when the server could not refresh this on schedule. */
  stale: boolean;
}

/** The last alert queued for a trip, and what became of it. */
export interface LastAlert {
  kind: AlertKind;
  /** 'sent' means APNs accepted it, never that it was delivered. */
  status: 'queued' | 'sent' | 'dropped' | 'failed';
  /** When APNs accepted it; for any other status, when it was queued. */
  at: string;
  reason?: string;
}

/** Everything a client is told about one monitored trip. */
export interface TripState {
  id: string;
  arriveBy: string;
  phase: TripPhase;
  recommendation: Recommendation | null;
  /** Why there is no departure to recommend yet, in the backend's words. */
  noPlanReason: string | null;
  /** For a scheduled trip: when it enters the planning horizon. */
  planAvailableAt: string | null;
  monitoring: {
    startsAt: string | null;
    startedAt: string | null;
    headsUpAt: string | null;
    /** Only once APNs accepted the heads-up. */
    headsUpSentAt: string | null;
    /** Only once APNs accepted the leave alert. */
    leaveAlertSentAt: string | null;
    endsAt: string;
    nextCheckAt: string | null;
    lastAlert: LastAlert | null;
  };
  /** The last evaluation failure, cleared by the next success. */
  lastError: { code: ErrorCode; at: string } | null;
}

/** The answer to PUT /trips and GET /trips. */
export interface SyncResponse {
  /** The revision the server holds after handling the request. */
  revision: number;
  /** True when this request's snapshot was applied now. */
  applied: boolean;
  /** SHA-256 of the snapshot the server holds, in its canonical form. */
  digest: string;
  serverTime: string;
  limits: Limits;
  push: PushStatus;
  monitor: MonitorHealth;
  /** Every trip of the device that is not cancelled, by arrival time. */
  trips: TripState[];
}

/** The answer to GET /trips/:id. */
export interface TripDetail {
  trip: TripState;
  serverTime: string;
  push: PushStatus;
  limits: Limits;
  monitor: MonitorHealth;
}

/** The answer to POST /devices. The token is shown this once. */
export interface Registration {
  deviceId: string;
  token: string;
  limits: Limits;
}
