/**
 * The shape of the backend's POST /verdict, as it arrives over the wire.
 * Dates are ISO 8601 strings. Keep in step with backend/prediction/types.ts.
 */
export type Goal = 'minimize_time' | 'arrive_by' | 'balance';
export type Confidence = 'High' | 'Medium' | 'Low';

export interface LatLng {
  lat: number;
  lng: number;
}

/** A place a user can pick as a start or a destination. */
export interface Place extends LatLng {
  id: string;
  /** Short name to show: a business, a campus, or the street address. */
  name: string;
  /** The full address, to show beneath the name. */
  address: string;
}

export interface VerdictRequest {
  origin: LatLng;
  destination: LatLng;
  /** ISO 8601 deadline: the latest time to be there. */
  arriveBy?: string;
  /** ISO 8601: the latest time to be on the road. */
  leaveBy?: string;
  preferences?: {
    goal?: Goal;
    maxWaitMinutes?: number;
    minSavingsMinutes?: number;
  };
}

export interface DepartureOption {
  departAt: string;
  arriveAt: string;
  driveMinutes: number;
}

/** How the answer sits against the arrive-by deadline. */
export interface DeadlineInfo {
  arriveBy: string;
  /** Minutes to spare between the recommended arrival and the deadline. */
  marginMinutes: number;
  /** The last departure that still arrives in time, when it can be found. */
  latestDeparture?: DepartureOption;
}

export interface Verdict {
  /**
   * `leave_later` is a departure time for a deadline far off. `no_rush` means
   * the deadline is too far off to plan yet; `recommended` repeats `leaveNow`.
   */
  action: 'leave_now' | 'wait' | 'leave_later' | 'no_rush';
  waitMinutes: number;
  reason: string;
  leaveNow: DepartureOption;
  recommended: DepartureOption;
  minutesSaved: number;
  arrivalDelayMinutes: number;
  /** Set when no departure meets the deadline. */
  lateByMinutes?: number;
  /** Set when there is a deadline and the recommended option meets it. */
  deadline?: DeadlineInfo;
  confidence: Confidence;
  confidenceReason: string;
  notes: string[];
  generatedAt: string;
}

export interface Slot extends DepartureOption {
  confidence: Confidence;
  confidenceReason: string;
  weatherFactor?: number;
}

export interface VerdictResponse {
  verdict: Verdict;
  slots: Slot[];
}
