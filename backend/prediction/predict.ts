import { addMinutes } from '../util/time';
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
import { LatLng, Route, SlotPrediction, TripRequest } from './types';

export const SLOT_INTERVAL_MINUTES = 15;
export const HORIZON_MINUTES = 180;
/** Forecast hours to fetch: the horizon plus time to drive. */
const WEATHER_HOURS = 6;
/** Live congestion fades to zero this many minutes after "now". */
export const LIVE_DECAY_MINUTES = 60;

/** Minutes after "now" of each departure slot, slot 0 being "leave now". */
const SLOT_OFFSETS = Array.from(
  { length: HORIZON_MINUTES / SLOT_INTERVAL_MINUTES + 1 },
  (_, i) => i * SLOT_INTERVAL_MINUTES,
);

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
 * that fails is treated as unavailable; the baseline must succeed.
 */
export async function predictSlots(
  request: TripRequest,
  { baseline, live: liveSource, weather, campusBreaks }: PredictionProviders,
): Promise<SlotPrediction[]> {
  const { route, now } = request;
  const departures = SLOT_OFFSETS.map(offset => addMinutes(now, offset));

  // The three sources are independent, so ask for them at the same time.
  const [live, forecast, bases] = await Promise.all([
    liveSource.getAdjustment(route, now).catch(liveUnavailable),
    weather
      ? weather
          .getHourly(midpointOf(route), now, WEATHER_HOURS)
          .catch((): HourlyWeather[] => [])
      : [],
    baseline.getBaselines
      ? baseline.getBaselines(route, departures)
      : Promise.all(departures.map(at => baseline.getBaseline(route, at))),
  ]);

  return departures.map((departAt, i) => {
    const base = bases[i];
    const liveFade = Math.max(0, 1 - SLOT_OFFSETS[i] / LIVE_DECAY_MINUTES);
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
}
