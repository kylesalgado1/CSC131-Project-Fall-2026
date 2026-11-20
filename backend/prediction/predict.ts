import { addMinutes, MINUTE_MS, minutesBetween } from '../util/time';
import { CampusBreak, localTime, specialDayName } from './calendar';
import { assessConfidence } from './confidence';
import { BaselineProvider } from './providers/baseline';
import { liveUnavailable, LiveConditionsProvider } from './providers/live';
import {
  HourlyWeather,
  rainDelayFactor,
  WeatherProvider,
  weatherAt,
} from './providers/weather';
import {
  LatLng,
  PredictionSource,
  Route,
  SlotPrediction,
  TripRequest,
} from './types';

export const SLOT_INTERVAL_MINUTES = 15;
export const HORIZON_MINUTES = 180;
/** Past the normal horizon, slots are this far apart. */
export const FAR_SLOT_INTERVAL_MINUTES = 30;
/** The farthest ahead a far-off deadline is planned for. */
export const MAX_PLAN_MINUTES = 12 * 60;
/** Extra forecast hours beyond the last slot: time to drive. */
const WEATHER_EXTRA_HOURS = 3;
/** Live congestion fades to zero this many minutes after "now". */
export const LIVE_DECAY_MINUTES = 60;

/**
 * The earliest the user can leave: now, or later if they said they cannot
 * leave before then. Slot 0 is this moment.
 */
export function departureStart({ now, preferences }: TripRequest): Date {
  const after = preferences.leaveAfter;
  return after && after.getTime() > now.getTime() ? after : now;
}

/**
 * When each departure slot is, slot 0 being "leave now" (or at the earliest
 * time the user can leave). Every 15 minutes for 3 hours. When the arrive-by deadline is farther off, more slots follow on
 * the half hour, up to the deadline (at most 12 hours out), so a far-off
 * deadline can be answered with a departure time. Those sit on the clock, not
 * on "now", so the planned time holds still as the app refreshes.
 */
export function slotTimesFor(request: TripRequest): Date[] {
  const start = departureStart(request);
  const times = Array.from(
    { length: HORIZON_MINUTES / SLOT_INTERVAL_MINUTES + 1 },
    (_, i) => addMinutes(start, i * SLOT_INTERVAL_MINUTES),
  );
  const deadline = request.preferences.arriveBy;
  if (!deadline) {
    return times;
  }
  const grid = FAR_SLOT_INTERVAL_MINUTES * MINUTE_MS;
  const horizonEnd = start.getTime() + HORIZON_MINUTES * MINUTE_MS;
  const limit = start.getTime() + MAX_PLAN_MINUTES * MINUTE_MS;
  // Through the first slot at or after the deadline, so the last one that
  // still makes it can be told from the end of the forecast.
  const end = Math.min(limit, Math.ceil(deadline.getTime() / grid) * grid);
  for (
    let at = Math.floor(horizonEnd / grid) * grid + grid;
    at <= end;
    at += grid
  ) {
    times.push(new Date(at));
  }
  return times;
}

export interface PredictionProviders {
  baseline: BaselineProvider;
  live: LiveConditionsProvider;
  /** Optional. Without it, or when it fails, rain is not accounted for. */
  weather?: WeatherProvider;
  /** Local breaks such as spring break, flagged on slots and in the notes. */
  campusBreaks?: CampusBreak[];
}

const midpointOf = ({ origin, destination }: Route): LatLng => ({
  lat: (origin.lat + destination.lat) / 2,
  lng: (origin.lng + destination.lng) / 2,
});

/**
 * Predicts drive time for every departure slot from now through the horizon.
 * Live congestion is added on top of the baseline and fades out linearly,
 * since a current slowdown says little about traffic an hour from now. Rain
 * lengthens the baseline for the hours it falls in. A live feed or forecast
 * that fails is treated as unavailable; the baseline must succeed. The answer
 * also says where the figures came from: which baseline source, whether a
 * fallback had to answer, and whether live conditions were available.
 */
export async function predict(
  request: TripRequest,
  { baseline, live: liveSource, weather, campusBreaks }: PredictionProviders,
): Promise<{ slots: SlotPrediction[]; source: PredictionSource }> {
  const { route, now } = request;
  const departures = slotTimesFor(request);
  const weatherHours =
    Math.ceil(minutesBetween(now, departures[departures.length - 1]) / 60) +
    WEATHER_EXTRA_HOURS;

  // The three sources are independent, so ask for them at the same time.
  const [live, forecast, bases] = await Promise.all([
    liveSource.getAdjustment(route, now).catch(liveUnavailable),
    weather
      ? weather
          .getHourly(midpointOf(route), now, weatherHours)
          .catch((): HourlyWeather[] => [])
      : [],
    baseline.getBaselines
      ? baseline.getBaselines(route, departures)
      : Promise.all(departures.map(at => baseline.getBaseline(route, at))),
  ]);

  const slots = departures.map((departAt, i) => {
    const base = bases[i];
    const liveFade = Math.max(
      0,
      1 - minutesBetween(now, departAt) / LIVE_DECAY_MINUTES,
    );
    const weatherFactor = rainDelayFactor(
      weatherAt(forecast, departAt)?.precipitationMm ?? 0,
    );
    const driveMinutes = Math.max(
      1,
      Math.round(base.minutes * weatherFactor + live.extraMinutes * liveFade),
    );
    const { confidence, reason } = assessConfidence(base, live);
    return {
      departAt,
      driveMinutes,
      arriveAt: addMinutes(departAt, driveMinutes),
      confidence,
      confidenceReason: reason,
      weatherFactor,
      holiday: specialDayName(localTime(departAt).date, campusBreaks),
    };
  });
  return {
    slots,
    source: {
      baseline: bases[0]?.source ?? 'unknown',
      fallback: bases.some(base => base.fallback === true),
      live: live.available,
    },
  };
}

/** The slots of `predict` alone, for callers that do not need the source. */
export async function predictSlots(
  request: TripRequest,
  providers: PredictionProviders,
): Promise<SlotPrediction[]> {
  return (await predict(request, providers)).slots;
}
