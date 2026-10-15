import { FetchLike } from '../../../util/http';
import { metersToMiles } from '../../../util/geo';
import { formatWithOffset } from '../../calendar';
import { LatLng, Route } from '../../types';
import { RoutePath, RoutePathProvider, RoutingError } from './types';

interface TomTomResponse {
  routes?: Array<{
    summary: {
      lengthInMeters: number;
      travelTimeInSeconds: number;
      trafficDelayInSeconds?: number;
      noTrafficTravelTimeInSeconds?: number;
      historicTrafficTravelTimeInSeconds?: number;
      liveTrafficIncidentsTravelTimeInSeconds?: number;
    };
    legs: Array<{ points: Array<{ latitude: number; longitude: number }> }>;
  }>;
}

export interface TomTomRoute {
  /** The driving path, start to end. */
  points: LatLng[];
  distanceMiles: number;
  /** Travel time with no traffic at all. */
  noTrafficMinutes: number;
  /**
   * With a departure time: the typical time for that day and hour, from
   * historical traffic. Without one: the time with traffic right now.
   */
  travelMinutes: number;
}

export interface TomTomOptions {
  baseUrl?: string;
  /** Minimum gap between requests; the free tier rate limits bursts. */
  minIntervalMs?: number;
  /** Extra attempts after a 429, with a growing wait between them. */
  maxRetries?: number;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

/**
 * TomTom's Routing API. Requests are sent one at a time, spaced out, and
 * retried when TomTom says "too many requests". Errors never include the URL,
 * because the URL carries the API key.
 */
export class TomTomRoutingClient {
  private chain: Promise<unknown> = Promise.resolve();
  private lastSentAt = -Infinity;
  private readonly baseUrl: string;
  private readonly minIntervalMs: number;
  private readonly maxRetries: number;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(
    private readonly apiKey: string,
    private readonly fetchFn: FetchLike = url => fetch(url),
    options: TomTomOptions = {},
  ) {
    this.baseUrl = options.baseUrl ?? 'https://api.tomtom.com';
    this.minIntervalMs = options.minIntervalMs ?? 250;
    this.maxRetries = options.maxRetries ?? 2;
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? (ms => new Promise(r => setTimeout(r, ms)));
  }

  /** Route with traffic. Pass `departAt` for a prediction for that time. */
  route({ origin, destination }: Route, departAt?: Date): Promise<TomTomRoute> {
    const params = new URLSearchParams({
      key: this.apiKey,
      traffic: 'true',
      travelMode: 'car',
      routeType: 'fastest',
      computeTravelTimeFor: 'all',
    });
    if (departAt) {
      params.set('departAt', formatWithOffset(departAt));
    }
    const where = `${origin.lat},${origin.lng}:${destination.lat},${destination.lng}`;
    const url = `${this.baseUrl}/routing/1/calculateRoute/${where}/json?${params}`;
    return this.enqueue(async () => parseRoute(await this.request(url)));
  }

  /** Runs tasks strictly in order, and keeps going after one fails. */
  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run = this.chain.then(task, task);
    this.chain = run.catch(() => undefined);
    return run;
  }

  private async request(url: string): Promise<TomTomResponse> {
    for (let attempt = 0; ; attempt++) {
      const wait = this.lastSentAt + this.minIntervalMs - this.now();
      if (wait > 0) {
        await this.sleep(wait);
      }
      this.lastSentAt = this.now();
      const res = await this.fetchFn(url);
      if (res.status === 429 && attempt < this.maxRetries) {
        await this.sleep(1000 * 2 ** attempt);
        continue;
      }
      if (!res.ok) {
        throw new RoutingError(`TomTom request failed: HTTP ${res.status}`);
      }
      return (await res.json()) as TomTomResponse;
    }
  }
}

function parseRoute(body: TomTomResponse): TomTomRoute {
  const route = body.routes?.[0];
  if (!route) {
    throw new RoutingError('TomTom found no route');
  }
  const { summary } = route;
  return {
    points: route.legs.flatMap(leg =>
      leg.points.map(p => ({ lat: p.latitude, lng: p.longitude })),
    ),
    distanceMiles: metersToMiles(summary.lengthInMeters),
    noTrafficMinutes:
      (summary.noTrafficTravelTimeInSeconds ?? summary.travelTimeInSeconds) /
      60,
    travelMinutes: summary.travelTimeInSeconds / 60,
  };
}

/** Route paths, and the no-traffic time, from TomTom. */
export class TomTomPathProvider implements RoutePathProvider {
  constructor(private readonly client: TomTomRoutingClient) {}

  async getPath(route: Route): Promise<RoutePath> {
    const { points, distanceMiles, noTrafficMinutes } = await this.client.route(
      route,
    );
    return { points, distanceMiles, freeFlowMinutes: noTrafficMinutes };
  }
}
