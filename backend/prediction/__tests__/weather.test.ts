import { decide } from '../decide';
import { getVerdict } from '../index';
import { addMinutes } from '../../util/time';
import { predictSlots } from '../predict';
import { FakeBaselineProvider } from '../providers/fake';
import { NoLiveConditions } from '../providers/live';
import { OpenMeteoWeatherProvider } from '../providers/openMeteo';
import {
  CachedWeatherProvider,
  HourlyWeather,
  NoWeather,
  rainDelayFactor,
  rainLabel,
  WeatherProvider,
  weatherAt,
} from '../providers/weather';
import { DEFAULT_PREFERENCES, SlotPrediction, TripRequest } from '../types';

const NOW = new Date('2026-10-21T15:00:00Z');
const request: TripRequest = {
  route: {
    origin: { lat: 38.2383, lng: -122.0402 },
    destination: { lat: 38.5593, lng: -121.4237 },
  },
  now: NOW,
  preferences: DEFAULT_PREFERENCES,
};

const flat = (minutes: number) => new FakeBaselineProvider(() => minutes);
const rainAt = (...hours: Array<[string, number]>): WeatherProvider => ({
  getHourly: async () =>
    hours.map(([at, mm]) => ({ at: new Date(at), precipitationMm: mm })),
});

describe('rainDelayFactor', () => {
  it.each([
    [0, 1],
    [0.05, 1],
    [0.1, 1.05],
    [2.4, 1.05],
    [2.5, 1.1],
    [7.5, 1.1],
    [7.6, 1.2],
    [20, 1.2],
  ])('%s mm/h gives %s', (mm, factor) => {
    expect(rainDelayFactor(mm)).toBe(factor);
  });

  it('labels the rain', () => {
    expect(rainLabel(1)).toBeUndefined();
    expect(rainLabel(1.05)).toBe('Light rain');
    expect(rainLabel(1.1)).toBe('Moderate rain');
    expect(rainLabel(1.2)).toBe('Heavy rain');
  });
});

describe('weatherAt', () => {
  const forecast: HourlyWeather[] = [
    { at: new Date('2026-10-21T15:00:00Z'), precipitationMm: 1 },
    { at: new Date('2026-10-21T16:00:00Z'), precipitationMm: 2 },
  ];
  it('finds the hour that contains a time', () => {
    expect(
      weatherAt(forecast, new Date('2026-10-21T15:45:00Z'))?.precipitationMm,
    ).toBe(1);
    expect(
      weatherAt(forecast, new Date('2026-10-21T16:00:00Z'))?.precipitationMm,
    ).toBe(2);
  });
  it('is undefined outside the forecast', () => {
    expect(
      weatherAt(forecast, new Date('2026-10-21T20:00:00Z')),
    ).toBeUndefined();
  });
});

describe('OpenMeteoWeatherProvider', () => {
  // Each value is the rain over the hour before its timestamp.
  const body = {
    hourly: {
      time: [
        '2026-10-21T15:00',
        '2026-10-21T16:00',
        '2026-10-21T17:00',
        '2026-10-21T18:00',
      ],
      precipitation: [0, 3, null, 1],
    },
  };
  const provider = (urls: string[] = []) =>
    new OpenMeteoWeatherProvider('http://meteo.test', async url => {
      urls.push(url);
      return { ok: true, status: 200, json: async () => body };
    });

  it('asks for hourly precipitation in UTC at the point', async () => {
    const urls: string[] = [];
    await provider(urls).getHourly({ lat: 38.4, lng: -121.73 }, NOW, 2);
    expect(urls[0]).toContain('latitude=38.400');
    expect(urls[0]).toContain('longitude=-121.730');
    expect(urls[0]).toContain('hourly=precipitation');
    expect(urls[0]).toContain('timezone=UTC');
  });

  it('shifts each value back to the start of the hour it covers', async () => {
    const hours = await provider().getHourly(
      { lat: 38.4, lng: -121.73 },
      NOW,
      3,
    );
    // The 16:00 stamp is rain over 15:00-16:00, and so on.
    expect(hours.map(h => [h.at.toISOString(), h.precipitationMm])).toEqual([
      ['2026-10-21T15:00:00.000Z', 3],
      ['2026-10-21T16:00:00.000Z', 0],
      ['2026-10-21T17:00:00.000Z', 1],
    ]);
  });

  it('limits the result to the hours asked for', async () => {
    const hours = await provider().getHourly(
      { lat: 38.4, lng: -121.73 },
      NOW,
      1,
    );
    expect(hours).toHaveLength(1);
  });

  it('fails on an HTTP error or an odd response', async () => {
    const down = new OpenMeteoWeatherProvider(
      'http://meteo.test',
      async () => ({
        ok: false,
        status: 429,
        json: async () => ({}),
      }),
    );
    await expect(down.getHourly({ lat: 0, lng: 0 }, NOW, 1)).rejects.toThrow(
      'HTTP 429',
    );
    const odd = new OpenMeteoWeatherProvider('http://meteo.test', async () => ({
      ok: true,
      status: 200,
      json: async () => ({}),
    }));
    await expect(odd.getHourly({ lat: 0, lng: 0 }, NOW, 1)).rejects.toThrow(
      'no hourly',
    );
  });
});

describe('CachedWeatherProvider', () => {
  it('reuses a forecast for nearby points until it expires', async () => {
    let calls = 0;
    let clock = 0;
    const cached = new CachedWeatherProvider(
      {
        getHourly: async () => {
          calls += 1;
          return [];
        },
      },
      1000,
      () => clock,
    );
    await cached.getHourly({ lat: 38.4, lng: -121.7 }, NOW, 6);
    await cached.getHourly({ lat: 38.4004, lng: -121.7004 }, NOW, 6);
    expect(calls).toBe(1);
    clock = 2000;
    await cached.getHourly({ lat: 38.4, lng: -121.7 }, NOW, 6);
    expect(calls).toBe(2);
  });

  it('asks again for a later hour or a different place', async () => {
    let calls = 0;
    const cached = new CachedWeatherProvider({
      getHourly: async () => {
        calls += 1;
        return [];
      },
    });
    await cached.getHourly({ lat: 38.4, lng: -121.7 }, NOW, 6);
    await cached.getHourly(
      { lat: 38.4, lng: -121.7 },
      new Date(NOW.getTime() + 3_600_000),
      6,
    );
    await cached.getHourly({ lat: 39.4, lng: -121.7 }, NOW, 6);
    expect(calls).toBe(3);
  });
});

describe('rain in predictions', () => {
  it('lengthens only the slots that fall in rainy hours', async () => {
    const slots = await predictSlots(request, {
      baseline: flat(30),
      live: new NoLiveConditions(),
      weather: rainAt(['2026-10-21T16:00:00Z', 3]), // moderate: x1.1
    });
    // Slots at 15:00, 15:15, 15:30, 15:45 are dry; 16:00 onward are in the rain.
    expect(slots.slice(0, 4).map(s => s.driveMinutes)).toEqual([
      30, 30, 30, 30,
    ]);
    expect(slots[4].driveMinutes).toBe(33);
    expect(slots[4].weatherFactor).toBe(1.1);
    expect(slots[0].weatherFactor).toBe(1);
  });

  it('predicts normally when the forecast is missing or fails', async () => {
    const failing: WeatherProvider = {
      getHourly: () => Promise.reject(new Error('rate limited')),
    };
    for (const weather of [failing, new NoWeather(), undefined]) {
      const slots = await predictSlots(request, {
        baseline: flat(30),
        live: new NoLiveConditions(),
        weather,
      });
      expect(slots.every(s => s.driveMinutes === 30)).toBe(true);
    }
  });

  it('queries the forecast at the middle of the trip', async () => {
    const points: Array<{ lat: number; lng: number }> = [];
    await predictSlots(request, {
      baseline: flat(30),
      live: new NoLiveConditions(),
      weather: {
        getHourly: async point => {
          points.push(point);
          return [];
        },
      },
    });
    expect(points[0].lat).toBeCloseTo(38.3988);
    expect(points[0].lng).toBeCloseTo(-121.73195);
  });
});

describe('verdict notes', () => {
  const slot = (
    offset: number,
    driveMinutes: number,
    weatherFactor = 1,
  ): SlotPrediction => {
    const departAt = addMinutes(NOW, offset);
    return {
      departAt,
      driveMinutes,
      arriveAt: addMinutes(departAt, driveMinutes),
      confidence: 'High',
      confidenceReason: 'x',
      weatherFactor,
    };
  };

  it('has no notes on an ordinary dry day', () => {
    const verdict = decide([slot(0, 30), slot(15, 30)], request);
    expect(verdict.notes).toEqual([]);
  });

  it('warns about rain when leaving now is rainy', () => {
    const verdict = decide([slot(0, 33, 1.1), slot(15, 33, 1.1)], request);
    expect(verdict.notes).toEqual([
      'Moderate rain is expected, so drive times include extra delay.',
    ]);
  });

  it('warns about rain at the recommended time too', () => {
    const slots = [slot(0, 60), slot(15, 55), slot(30, 40), slot(45, 30, 1.2)];
    const verdict = decide(slots, {
      ...request,
      preferences: { ...DEFAULT_PREFERENCES, goal: 'minimize_time' },
    });
    expect(verdict.action).toBe('wait');
    expect(verdict.waitMinutes).toBe(45);
    expect(verdict.notes).toEqual([
      'Heavy rain is expected, so drive times include extra delay.',
    ]);
  });

  it('mentions a holiday', () => {
    // Veterans Day 2026 is a Wednesday.
    const veterans = new Date('2026-11-11T17:00:00Z');
    const verdict = decide([slot(0, 30), slot(15, 30)], {
      ...request,
      now: veterans,
    });
    expect(verdict.notes).toEqual([
      'Today is Veterans Day, so traffic may differ from a normal day.',
    ]);
  });

  it('includes the notes end to end', async () => {
    const { verdict } = await getVerdict(request, {
      baseline: flat(30),
      live: new NoLiveConditions(),
      weather: rainAt(['2026-10-21T15:00:00Z', 1]), // light
    });
    expect(verdict.notes).toEqual([
      'Light rain is expected, so drive times include extra delay.',
    ]);
  });
});
