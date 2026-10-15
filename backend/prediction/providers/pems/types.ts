import { DayType } from '../../calendar';

/** One 5-minute station reading, already on the local clock. */
export interface PemsObservation {
  stationId: number;
  /** Local calendar date, YYYY-MM-DD. */
  localDate: string;
  minuteOfDay: number;
  avgSpeedMph: number;
  totalFlow: number | null;
  /** Share of the period actually measured, 0-100. */
  pctObserved: number | null;
}

/** Typical speed at one station for a day type and 15-minute bucket. */
export interface ProfileRow {
  stationId: number;
  dayType: DayType;
  /** 0-95, see BUCKET_MINUTES. */
  bucket: number;
  avgSpeedMph: number;
  /** Distinct days that contributed. */
  sampleCount: number;
  /**
   * Share of the contributing readings that were measured, 0-1. The rest were
   * filled in by PeMS from neighboring stations and history.
   */
  observedShare: number;
}

/** A mainline detector station from the PeMS metadata files. */
export interface PemsStation {
  id: number;
  /** Route number as PeMS prints it, e.g. "80", "50", "51". */
  freeway: string;
  /** N, S, E or W. */
  direction: string;
  /** Stretch of road this station represents. */
  lengthMiles: number;
  latitude: number;
  longitude: number;
}
