import { startOfHourMs } from '../../util/time';
import { TtlCache } from '../../util/ttlCache';
import { LatLng } from '../types';

export interface HourlyWeather {
  /** Start of the hour this reading covers. */
  at: Date;
  precipitationMm: number;
}

export interface WeatherProvider {
  /** Hourly precipitation from the hour containing `from`, for `hours` hours. */
  getHourly(point: LatLng, from: Date, hours: number): Promise<HourlyWeather[]>;
}

/**
 * How rain slows a drive, heaviest band first. The rain-rate bands (mm per
 * hour) are the standard meteorological ones. The multipliers are
 * placeholders to tune against logged trips, not measured values.
 */
const RAIN_BANDS = [
  { fromMm: 7.6, factor: 1.2, label: 'Heavy rain' },
  { fromMm: 2.5, factor: 1.1, label: 'Moderate rain' },
  { fromMm: 0.1, factor: 1.05, label: 'Light rain' },
] as const;

/** How much longer a drive takes in this rain, as a multiplier. 1 when dry. */
export function rainDelayFactor(precipitationMm: number): number {
  return RAIN_BANDS.find(b => precipitationMm >= b.fromMm)?.factor ?? 1;
}

/** Describes the rain behind a delay factor, or undefined when there is none. */
export function rainLabel(factor: number): string | undefined {
  return RAIN_BANDS.find(b => factor >= b.factor)?.label;
}

/** The reading that covers a departure time, if the forecast has one. */
export function weatherAt(
  forecast: HourlyWeather[],
  at: Date,
): HourlyWeather | undefined {
  const hourStart = startOfHourMs(at.getTime());
  return forecast.find(h => h.at.getTime() === hourStart);
}

export class NoWeather implements WeatherProvider {
  async getHourly(): Promise<HourlyWeather[]> {
    return [];
  }
}

/** Remembers a forecast so repeated requests do not call the service. */
export class CachedWeatherProvider implements WeatherProvider {
  private readonly cache: TtlCache<HourlyWeather[]>;

  constructor(
    private readonly inner: WeatherProvider,
    ttlMs = 30 * 60_000,
    now: () => number = Date.now,
  ) {
    this.cache = new TtlCache(ttlMs, now);
  }

  getHourly(
    point: LatLng,
    from: Date,
    hours: number,
  ): Promise<HourlyWeather[]> {
    // About 1 km of precision, and one entry per forecast hour.
    const place = `${point.lat.toFixed(2)},${point.lng.toFixed(2)}`;
    const key = `${place}|${startOfHourMs(from.getTime())}|${hours}`;
    return this.cache.get(key, () => this.inner.getHourly(point, from, hours));
  }
}
