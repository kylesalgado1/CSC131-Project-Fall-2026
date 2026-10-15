import { DayType } from '../../calendar';
import { Route } from '../../types';

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
  /**
   * How fast traffic moves at this station on an empty road, in mph. Absent
   * when the station has no usable overnight readings.
   */
  freeFlowMph?: number;
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

/** A stretch of road covered by one PeMS station. */
export interface RouteSegment {
  stationId: number;
  lengthMiles: number;
}

export interface ResolvedRoute {
  /** Stations along the route, in driving order. */
  segments: RouteSegment[];
  /** Route length with no station: ramps, surface streets, gaps. */
  uncoveredMiles: number;
  /**
   * The routing service's travel time for the whole route with no traffic.
   * When known, baselines add PeMS delay to it instead of summing PeMS speeds.
   */
  freeFlowMinutes?: number;
}

/**
 * Maps a trip to the PeMS stations it passes, in order. This needs route
 * geometry (from a routing service) matched to station locations.
 */
export interface RouteResolver {
  resolve(route: Route): Promise<ResolvedRoute>;
}
