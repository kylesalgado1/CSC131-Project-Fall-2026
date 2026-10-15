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

export interface VerdictRequest {
  origin: LatLng;
  destination: LatLng;
  /** ISO 8601 deadline. */
  arriveBy?: string;
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

export interface Verdict {
  action: 'leave_now' | 'wait';
  waitMinutes: number;
  reason: string;
  leaveNow: DepartureOption;
  recommended: DepartureOption;
  minutesSaved: number;
  arrivalDelayMinutes: number;
  /** Set when no departure meets the deadline. */
  lateByMinutes?: number;
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
