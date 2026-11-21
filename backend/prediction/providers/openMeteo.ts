import { fetchJson, FetchLike } from '../../util/http';
import { HOUR_MS, startOfHourMs } from '../../util/time';
import { LatLng } from '../types';
import { HourlyWeather, WeatherProvider } from './weather';

interface OpenMeteoResponse {
  hourly?: { time: string[]; precipitation: Array<number | null> };
}

/**
 * Hourly rain from Open-Meteo, which needs no key. Its free tier is for
 * non-commercial use, so check the terms before a public launch.
 */
export class OpenMeteoWeatherProvider implements WeatherProvider {
  constructor(
    private readonly baseUrl = 'https://api.open-meteo.com',
    private readonly fetchFn: FetchLike = url => fetch(url),
  ) {}

  async getHourly(
    { lat, lng }: LatLng,
    from: Date,
    hours: number,
  ): Promise<HourlyWeather[]> {
    const body = await fetchJson<OpenMeteoResponse>(
      this.fetchFn,
      `${this.baseUrl}/v1/forecast?latitude=${lat.toFixed(3)}` +
        `&longitude=${lng.toFixed(3)}&hourly=precipitation&forecast_days=2` +
        '&timezone=UTC',
      'Open-Meteo',
    );
    const { hourly } = body;
    if (!hourly) {
      throw new Error('Open-Meteo response had no hourly data');
    }

    // Each value is the rain over the hour *before* its timestamp, so the
    // reading for the hour starting at T is the one stamped T + 1 hour.
    const first = startOfHourMs(from.getTime());
    const last = first + hours * HOUR_MS;
    return hourly.time.flatMap((stamp, i) => {
      const start = Date.parse(`${stamp}:00Z`) - HOUR_MS;
      return start >= first && start < last
        ? [
            {
              at: new Date(start),
              precipitationMm: hourly.precipitation[i] ?? 0,
            },
          ]
        : [];
    });
  }
}
