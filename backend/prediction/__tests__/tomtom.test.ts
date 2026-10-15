import { FetchLike } from '../../util/http';
import {
  TomTomPathProvider,
  TomTomRoutingClient,
} from '../providers/routing/tomtom';
import { RoutingError } from '../providers/routing/types';
import { Route } from '../types';

const KEY = 'SECRETKEY123';
const route: Route = {
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
};

const body = {
  routes: [
    {
      summary: {
        lengthInMeters: 80467.2, // 50 miles
        travelTimeInSeconds: 3540,
        noTrafficTravelTimeInSeconds: 3180,
      },
      legs: [
        {
          points: [
            { latitude: 38.2383, longitude: -122.0402 },
            { latitude: 38.4, longitude: -121.7 },
          ],
        },
        { points: [{ latitude: 38.5593, longitude: -121.4237 }] },
      ],
    },
  ],
};

/** A fake clock: sleeping advances it, so spacing can be checked exactly. */
function fakeEnv(responses: Array<{ status: number; body?: unknown }>) {
  let clock = 0;
  const sent: Array<{ at: number; url: string }> = [];
  const sleeps: number[] = [];
  let next = 0;
  const fetchFn: FetchLike = async url => {
    sent.push({ at: clock, url });
    const r = responses[Math.min(next++, responses.length - 1)];
    return {
      ok: r.status < 400,
      status: r.status,
      json: async () => r.body ?? body,
    };
  };
  const options = {
    now: () => clock,
    sleep: async (ms: number) => {
      sleeps.push(ms);
      clock += ms;
    },
  };
  return { fetchFn, options, sent, sleeps };
}

describe('TomTomRoutingClient', () => {
  it('reads the path, distance and both travel times', async () => {
    const { fetchFn, options } = fakeEnv([{ status: 200 }]);
    const result = await new TomTomRoutingClient(KEY, fetchFn, options).route(
      route,
    );
    expect(result.points).toEqual([
      { lat: 38.2383, lng: -122.0402 },
      { lat: 38.4, lng: -121.7 },
      { lat: 38.5593, lng: -121.4237 },
    ]);
    expect(result.distanceMiles).toBeCloseTo(50);
    expect(result.noTrafficMinutes).toBe(53);
    expect(result.travelMinutes).toBe(59);
  });

  it('asks for traffic and puts a departure time on the local clock', async () => {
    const { fetchFn, options, sent } = fakeEnv([{ status: 200 }]);
    await new TomTomRoutingClient(KEY, fetchFn, options).route(
      route,
      new Date('2026-10-21T14:00:00Z'), // 07:00 Pacific daylight time
    );
    const url = new URL(sent[0].url);
    expect(url.pathname).toBe(
      '/routing/1/calculateRoute/38.2383,-122.0402:38.5593,-121.4237/json',
    );
    expect(url.searchParams.get('traffic')).toBe('true');
    expect(url.searchParams.get('computeTravelTimeFor')).toBe('all');
    expect(url.searchParams.get('departAt')).toBe('2026-10-21T07:00:00-07:00');
    expect(url.searchParams.get('key')).toBe(KEY);
  });

  it('leaves out the departure time when none is given', async () => {
    const { fetchFn, options, sent } = fakeEnv([{ status: 200 }]);
    await new TomTomRoutingClient(KEY, fetchFn, options).route(route);
    expect(new URL(sent[0].url).searchParams.has('departAt')).toBe(false);
  });

  it('spaces requests out', async () => {
    const { fetchFn, options, sent } = fakeEnv([{ status: 200 }]);
    const client = new TomTomRoutingClient(KEY, fetchFn, {
      ...options,
      minIntervalMs: 300,
    });
    await Promise.all([
      client.route(route),
      client.route(route),
      client.route(route),
    ]);
    expect(sent.map(s => s.at)).toEqual([0, 300, 600]);
  });

  it('retries after a rate limit, waiting longer each time', async () => {
    const { fetchFn, options, sent, sleeps } = fakeEnv([
      { status: 429 },
      { status: 429 },
      { status: 200 },
    ]);
    const result = await new TomTomRoutingClient(KEY, fetchFn, {
      ...options,
      minIntervalMs: 0,
    }).route(route);
    expect(result.travelMinutes).toBe(59);
    expect(sent).toHaveLength(3);
    expect(sleeps).toEqual([1000, 2000]);
  });

  it('gives up after its retries with an error that hides the key', async () => {
    const { fetchFn, options, sent } = fakeEnv([{ status: 429 }]);
    const client = new TomTomRoutingClient(KEY, fetchFn, {
      ...options,
      minIntervalMs: 0,
      maxRetries: 1,
    });
    const error = await client.route(route).catch((e: Error) => e);
    expect(error).toBeInstanceOf(RoutingError);
    expect((error as Error).message).toBe('TomTom request failed: HTTP 429');
    expect((error as Error).message).not.toContain(KEY);
    expect(sent).toHaveLength(2);
  });

  it('does not retry other errors', async () => {
    const { fetchFn, options, sent } = fakeEnv([{ status: 403 }]);
    await expect(
      new TomTomRoutingClient(KEY, fetchFn, options).route(route),
    ).rejects.toThrow('HTTP 403');
    expect(sent).toHaveLength(1);
  });

  it('fails clearly when TomTom finds no route', async () => {
    const { fetchFn, options } = fakeEnv([
      { status: 200, body: { routes: [] } },
    ]);
    await expect(
      new TomTomRoutingClient(KEY, fetchFn, options).route(route),
    ).rejects.toThrow('TomTom found no route');
  });

  it('keeps working after one request fails', async () => {
    const { fetchFn, options } = fakeEnv([{ status: 500 }, { status: 200 }]);
    const client = new TomTomRoutingClient(KEY, fetchFn, {
      ...options,
      minIntervalMs: 0,
    });
    const [first, second] = await Promise.allSettled([
      client.route(route),
      client.route(route),
    ]);
    expect(first.status).toBe('rejected');
    expect(second.status).toBe('fulfilled');
  });
});

describe('TomTomRoutingClient incidents', () => {
  const incident = (road: string[] | undefined) => ({
    geometry: { coordinates: [[-121.9, 38.4]] },
    properties: {
      id: 'x',
      magnitudeOfDelay: 3,
      delay: 600,
      roadNumbers: road,
      events: [{ description: 'Accident' }],
    },
  });
  const read = async (road: string[] | undefined) => {
    const { fetchFn, options, sent } = fakeEnv([
      { status: 200, body: { incidents: [incident(road)] } },
    ]);
    const [parsed] = await new TomTomRoutingClient(
      KEY,
      fetchFn,
      options,
    ).incidents({
      minLat: 38,
      minLng: -122,
      maxLat: 39,
      maxLng: -121,
    });
    return { parsed, url: new URL(sent[0].url) };
  };

  it('asks for a box in longitude, latitude order', async () => {
    const { url } = await read(['I-80 W']);
    expect(url.pathname).toBe('/traffic/services/5/incidentDetails');
    expect(url.searchParams.get('bbox')).toBe('-122,38,-121,39');
    expect(url.searchParams.get('timeValidityFilter')).toBe('present');
  });

  it('reads the incident, with coordinates as latitude and longitude', async () => {
    const { parsed } = await read(['I-80 W']);
    expect(parsed).toMatchObject({
      id: 'x',
      description: 'Accident',
      road: 'I-80 W',
      magnitude: 3,
      delayMinutes: 10,
      points: [{ lat: 38.4, lng: -121.9 }],
    });
  });

  it.each([
    [['I-80 W'], 'W'],
    [['CA-113 S'], 'S'],
    [['I-80 Bus E'], 'E'],
    [['I-80'], undefined],
    [['I-80 Bus'], undefined],
    [['SR-12 West'], undefined],
    [[], undefined],
    [undefined, undefined],
  ])('reads the direction from %p as %p', async (road, compass) => {
    expect((await read(road)).parsed.compass).toBe(compass);
  });
});

describe('TomTomPathProvider', () => {
  it("returns the path with TomTom's no-traffic time as free-flow", async () => {
    const { fetchFn, options } = fakeEnv([{ status: 200 }]);
    const path = await new TomTomPathProvider(
      new TomTomRoutingClient(KEY, fetchFn, options),
    ).getPath(route);
    expect(path.points).toHaveLength(3);
    expect(path.distanceMiles).toBeCloseTo(50);
    expect(path.freeFlowMinutes).toBe(53);
  });
});
