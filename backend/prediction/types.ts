export interface LatLng {
  lat: number;
  lng: number;
}

export interface Route {
  origin: LatLng;
  destination: LatLng;
}

export type Goal = 'minimize_time' | 'arrive_by' | 'balance';

export interface Preferences {
  goal: Goal;
  /** Longest wait the user will accept, in minutes. */
  maxWaitMinutes: number;
  /** Waiting must save at least this many minutes of drive time. */
  minSavingsMinutes: number;
  /** Optional deadline. When set, no recommendation arrives after it. */
  arriveBy?: Date;
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
}

export interface DepartureOption {
  departAt: Date;
  arriveAt: Date;
  driveMinutes: number;
}

export interface Verdict {
  action: 'leave_now' | 'wait';
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
  confidence: Confidence;
  confidenceReason: string;
  /** Heads-up messages, such as a holiday or rain, for display. */
  notes: string[];
  generatedAt: Date;
}

export const DEFAULT_PREFERENCES: Preferences = {
  goal: 'balance',
  maxWaitMinutes: 180,
  minSavingsMinutes: 10,
};
