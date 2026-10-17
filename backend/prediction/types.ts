export interface LatLng {
  lat: number;
  lng: number;
}

export interface Route {
  origin: LatLng;
  destination: LatLng;
}

export type Goal = 'minimize_time' | 'arrive_by';

export interface Preferences {
  goal: Goal;
  /** Longest wait the user will accept, in minutes. Absent means no limit. */
  maxWaitMinutes?: number;
  /** Waiting must save at least this many minutes of drive time. */
  minSavingsMinutes: number;
  /** Optional deadline. When set, no recommendation arrives after it. */
  arriveBy?: Date;
  /**
   * Optional latest time to be on the road. When set, no recommendation
   * waits past it, though leaving now is always allowed.
   */
  leaveBy?: Date;
}

export interface TripRequest {
  route: Route;
  now: Date;
  preferences: Preferences;
}

export type Confidence = 'High' | 'Medium' | 'Low';

export interface Incident {
  description: string;
  road?: string;
  delayMinutes?: number;
}

export interface BaselineResult {
  /** Typical drive time for the route at the requested departure time. */
  minutes: number;
  /** How many days of history the figure is based on. */
  sampleCount: number;
  /**
   * Share of that history that was measured rather than estimated, 0-1.
   * Leave out when the source does not distinguish.
   */
  observedShare?: number;
  /**
   * Set when the figure is an estimate rather than history for that day:
   * a holiday or campus break guessed from a typical weekend.
   */
  basis?: 'holiday_estimate';
}

export interface LiveAdjustment {
  /** False when the live feed could not be reached. */
  available: boolean;
  /** Extra minutes of drive time right now, on top of the baseline. */
  extraMinutes: number;
  incidents: Incident[];
}

/** Predicted drive for one possible departure time. */
export interface SlotPrediction {
  departAt: Date;
  /** Whole minutes. */
  driveMinutes: number;
  arriveAt: Date;
  confidence: Confidence;
  confidenceReason: string;
  /** Multiplier applied for rain; 1 or absent means none. */
  weatherFactor?: number;
  /** The holiday or campus break this departure falls on, if any. */
  holiday?: string;
}

export interface DepartureOption {
  departAt: Date;
  arriveAt: Date;
  driveMinutes: number;
}

/** How the answer sits against the user's arrive-by deadline. */
export interface DeadlineInfo {
  arriveBy: Date;
  /** Minutes to spare between the recommended arrival and the deadline. */
  marginMinutes: number;
  /**
   * The last departure that still arrives in time. Absent when the forecast
   * ends before it can be found.
   */
  latestDeparture?: DepartureOption;
}

export interface Verdict {
  /**
   * `leave_later` is for a deadline far enough off that the answer is a
   * departure time rather than a short wait. `no_rush` is for a deadline
   * where there is nothing to recommend, either because it is beyond what can
   * be planned yet or because waiting would save too little driving to
   * matter. `recommended` just repeats `leaveNow`.
   */
  action: 'leave_now' | 'wait' | 'leave_later' | 'no_rush';
  /** 0 when action is leave_now. */
  waitMinutes: number;
  /** One-sentence explanation shown with the answer. */
  reason: string;
  leaveNow: DepartureOption;
  /** The option the verdict recommends. Equals leaveNow for leave_now. */
  recommended: DepartureOption;
  /** Drive minutes saved versus leaving now. 0 for leave_now. */
  minutesSaved: number;
  /** Minutes later the user arrives versus leaving now. 0 for leave_now. */
  arrivalDelayMinutes: number;
  /** Set when no departure meets the deadline. */
  lateByMinutes?: number;
  /** Set when there is a deadline and the recommended option meets it. */
  deadline?: DeadlineInfo;
  confidence: Confidence;
  confidenceReason: string;
  /** Heads-up messages, such as a holiday or rain, for display. */
  notes: string[];
  generatedAt: Date;
}

export const DEFAULT_PREFERENCES: Preferences = {
  goal: 'minimize_time',
  minSavingsMinutes: 10,
};
