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

interface TomTomIncidentsResponse {
  incidents?: Array<{
    geometry?: { coordinates: unknown };
    properties: {
      id?: string;
      magnitudeOfDelay?: number;
      delay?: number | null;
      roadNumbers?: string[];
      events?: Array<{ description?: string }>;
    };
  }>;
}

/** A traffic incident reported by TomTom. */
export interface TomTomIncident {
  id?: string;
  description: string;
  road?: string;
  /** The direction of travel in the road label, such as the W in "I-80 W". */
  compass?: 'N' | 'E' | 'S' | 'W';
  /** 0 unknown, 1 minor, 2 moderate, 3 major, 4 closure or other. */
  magnitude: number;
  delayMinutes: number;
  /** Points along the incident, which may be a single point. */
  points: LatLng[];
}

interface TomTomSearchResponse {
  results?: Array<{
    id?: string;
    poi?: { name?: string };
    address?: { freeformAddress?: string };
    position?: { lat: number; lon: number };
  }>;
}

/** A place TomTom found for some typed text. */
export interface TomTomPlace {
  id?: string;
  /** The place's name, when it has one (a business, a campus). */
  poiName?: string;
  /** The full address on one line. */
  address: string;
  position: LatLng;
}

export interface BoundingBox {
  minLat: number;
  minLng: number;
  maxLat: number;
  maxLng: number;
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
  /**
   * Typical traffic for the requested time, from historical data. Without a
   * departure time this is the typical figure for now, which is what live
   * traffic is compared with.
   */
  historicMinutes?: number;
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
 * TomTom's routing, traffic incidents and place search. Requests are sent one
 * at a time, spaced out, and retried when TomTom says "too many requests", so
 * everything shares one rate limit. Errors never include the URL, because the
 * URL carries the API key.
 */
export class TomTomClient {
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
    return this.enqueue(async () =>
      parseRoute(await this.request<TomTomResponse>(url)),
    );
  }

  /**
   * Places matching text as it is being typed. `near` ranks closer places
   * first, which matters a lot: "raleys" finds the local store with it and a
   * street in another state without it.
   */
  search(query: string, near?: LatLng, limit = 5): Promise<TomTomPlace[]> {
    const params = new URLSearchParams({
      key: this.apiKey,
      typeahead: 'true',
      limit: String(limit),
      countrySet: 'US',
      language: 'en-US',
    });
    if (near) {
      params.set('lat', String(near.lat));
      params.set('lon', String(near.lng));
    }
    const url = `${this.baseUrl}/search/2/search/${encodeURIComponent(
      query,
    )}.json?${params}`;
    return this.enqueue(async () =>
      parseSearch(await this.request<TomTomSearchResponse>(url)),
    );
  }

  /** Incidents in a box. TomTom limits how large the box may be. */
  incidents(box: BoundingBox): Promise<TomTomIncident[]> {
    const params = new URLSearchParams({
      key: this.apiKey,
      bbox: `${box.minLng},${box.minLat},${box.maxLng},${box.maxLat}`,
      fields:
        '{incidents{geometry{coordinates},properties{id,magnitudeOfDelay,delay,roadNumbers,events{description}}}}',
      language: 'en-GB',
      timeValidityFilter: 'present',
    });
    const url = `${this.baseUrl}/traffic/services/5/incidentDetails?${params}`;
    return this.enqueue(async () =>
      parseIncidents(await this.request<TomTomIncidentsResponse>(url)),
    );
  }

  /** Runs tasks strictly in order, and keeps going after one fails. */
  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run = this.chain.then(task, task);
    this.chain = run.catch(() => undefined);
    return run;
  }

  private async request<T>(url: string): Promise<T> {
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
      return (await res.json()) as T;
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
    historicMinutes:
      summary.historicTrafficTravelTimeInSeconds === undefined
        ? undefined
        : summary.historicTrafficTravelTimeInSeconds / 60,
  };
}

function parseSearch(body: TomTomSearchResponse): TomTomPlace[] {
  return (body.results ?? []).flatMap(r =>
    r.position && r.address?.freeformAddress
      ? [
          {
            id: r.id,
            poiName: r.poi?.name,
            address: r.address.freeformAddress,
            position: { lat: r.position.lat, lng: r.position.lon },
          },
        ]
      : [],
  );
}

/** GeoJSON gives a point as [lng, lat] and a line as a list of those. */
function pointsOf(coordinates: unknown): LatLng[] {
  if (!Array.isArray(coordinates)) {
    return [];
  }
  if (typeof coordinates[0] === 'number') {
    return [{ lat: coordinates[1] as number, lng: coordinates[0] }];
  }
  return coordinates.flatMap(pointsOf);
}

function parseIncidents(body: TomTomIncidentsResponse): TomTomIncident[] {
  return (body.incidents ?? []).map(({ geometry, properties: p }) => ({
    id: p.id,
    description: (p.events ?? [])
      .map(e => e.description)
      .filter(Boolean)
      .join('; '),
    road: p.roadNumbers?.[0],
    compass: /\s([NESW])$/.exec(p.roadNumbers?.[0] ?? '')?.[1] as
      | TomTomIncident['compass']
      | undefined,
    magnitude: p.magnitudeOfDelay ?? 0,
    delayMinutes: (p.delay ?? 0) / 60,
    points: pointsOf(geometry?.coordinates),
  }));
}

/** Route paths, and the no-traffic time, from TomTom. */
export class TomTomPathProvider implements RoutePathProvider {
  constructor(private readonly client: TomTomClient) {}

  async getPath(route: Route): Promise<RoutePath> {
    const { points, distanceMiles, noTrafficMinutes } = await this.client.route(
      route,
    );
    return {
      points,
      distanceMiles,
      freeFlowMinutes: noTrafficMinutes,
      source: 'tomtom',
    };
  }
}
