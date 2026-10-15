import { MINUTE_MS } from '../../../util/time';
import { TtlCache } from '../../../util/ttlCache';
import { localTime, weekdayOf } from '../../calendar';
import {
  BaselineResult,
  Incident,
  LatLng,
  LiveAdjustment,
  Route,
} from '../../types';
import { BaselineProvider } from '../baseline';
import { LiveConditionsProvider } from '../live';
import { routeKey } from './routeKey';
import { pathProximity } from './routeMatch';
import {
  BoundingBox,
  TomTomIncident,
  TomTomRoute,
  TomTomRoutingClient,
} from './tomtom';
import { RoutePath, RoutePathProvider } from './types';

export interface TomTomTrafficOptions {
  /** How long a "now" route and incident reports are reused. */
  liveTtlMs?: number;
  /**
   * How long typical-traffic predictions are reused. Kept short and in memory
   * only: TomTom's terms on storing responses are not clear for free plans.
   */
  predictionTtlMs?: number;
  /** Predictions are fetched this far apart and interpolated in between. */
  gridMinutes?: number;
  /** TomTom's history is deep and does not say how deep; assume this much. */
  assumedHistoryDays?: number;
  /** An incident this close to the route is on it. */
  incidentRadiusMeters?: number;
  /** TomTom limits a request's area, so a route is covered in boxes. */
  maxIncidentBoxes?: number;
  now?: () => number;
}

/** The largest span of one incident box, about 45 km. */
const MAX_BOX_SPAN_DEGREES = 0.4;
const BOX_PADDING_DEGREES = 0.005;

/**
 * Incidents worth acting on: a moderate or major delay, a closure, or five
 * minutes or more. The many small lane closures TomTom lists do not count.
 */
const isRelevant = (i: TomTomIncident): boolean =>
  i.magnitude >= 2 || i.delayMinutes >= 5;

/** Splits a path into boxes small enough for one incidents request. */
function boxesAlong(points: LatLng[], maxBoxes: number): BoundingBox[] {
  const boxes: BoundingBox[] = [];
  let box: BoundingBox | undefined;
  for (const { lat, lng } of points) {
    const grown = box && {
      minLat: Math.min(box.minLat, lat),
      maxLat: Math.max(box.maxLat, lat),
      minLng: Math.min(box.minLng, lng),
      maxLng: Math.max(box.maxLng, lng),
    };
    if (
      !box ||
      !grown ||
      grown.maxLat - grown.minLat > MAX_BOX_SPAN_DEGREES ||
      grown.maxLng - grown.minLng > MAX_BOX_SPAN_DEGREES
    ) {
      if (box) {
        boxes.push(box);
      }
      box = { minLat: lat, maxLat: lat, minLng: lng, maxLng: lng };
    } else {
      box = grown;
    }
  }
  if (box) {
    boxes.push(box);
  }
  return boxes.slice(0, maxBoxes).map(b => ({
    minLat: b.minLat - BOX_PADDING_DEGREES,
    maxLat: b.maxLat + BOX_PADDING_DEGREES,
    minLng: b.minLng - BOX_PADDING_DEGREES,
    maxLng: b.maxLng + BOX_PADDING_DEGREES,
  }));
}

/**
 * TomTom as the main traffic source. One object serves the route path, the
 * typical drive time for each departure slot, and the live adjustment, and
 * they share short-lived caches so a trip costs few requests.
 *
 * - The "now" route gives the path, the no-traffic time, the time with
 *   traffic right now, and the typical time for right now.
 * - Typical times for later slots come from departure-time predictions on a
 *   coarse grid (every 30 minutes) and are interpolated between.
 * - Live extra delay is how much slower than typical it is right now.
 */
export class TomTomTraffic
  implements RoutePathProvider, BaselineProvider, LiveConditionsProvider
{
  private readonly liveRoutes: TtlCache<TomTomRoute>;
  private readonly typicalMinutes: TtlCache<number>;
  private readonly incidentReports: TtlCache<TomTomIncident[]>;
  private readonly gridMs: number;
  private readonly assumedHistoryDays: number;
  private readonly incidentRadiusMeters: number;
  private readonly maxIncidentBoxes: number;

  constructor(
    private readonly client: TomTomRoutingClient,
    options: TomTomTrafficOptions = {},
  ) {
    const now = options.now ?? Date.now;
    const liveTtl = options.liveTtlMs ?? 5 * MINUTE_MS;
    this.liveRoutes = new TtlCache(liveTtl, now);
    this.incidentReports = new TtlCache(liveTtl, now);
    this.typicalMinutes = new TtlCache(
      options.predictionTtlMs ?? 30 * MINUTE_MS,
      now,
    );
    this.gridMs = (options.gridMinutes ?? 30) * MINUTE_MS;
    this.assumedHistoryDays = options.assumedHistoryDays ?? 100;
    this.incidentRadiusMeters = options.incidentRadiusMeters ?? 150;
    this.maxIncidentBoxes = options.maxIncidentBoxes ?? 8;
  }

  private liveRoute(route: Route): Promise<TomTomRoute> {
    return this.liveRoutes.get(routeKey(route), () => this.client.route(route));
  }

  async getPath(route: Route): Promise<RoutePath> {
    const { points, distanceMiles, noTrafficMinutes } = await this.liveRoute(
      route,
    );
    return { points, distanceMiles, freeFlowMinutes: noTrafficMinutes };
  }

  async getBaseline(route: Route, departAt: Date): Promise<BaselineResult> {
    return (await this.getBaselines(route, [departAt]))[0];
  }

  async getBaselines(
    route: Route,
    departAts: Date[],
  ): Promise<BaselineResult[]> {
    const slots = departAts.map(at => {
      const lower = Math.floor(at.getTime() / this.gridMs) * this.gridMs;
      return { lower, fraction: (at.getTime() - lower) / this.gridMs };
    });
    const needed = new Set(
      slots.flatMap(({ lower, fraction }) =>
        fraction > 0 ? [lower, lower + this.gridMs] : [lower],
      ),
    );
    const minutes = new Map<number, number>();
    await Promise.all(
      [...needed].map(async ms =>
        minutes.set(ms, await this.typicalAt(route, new Date(ms))),
      ),
    );

    return slots.map(({ lower, fraction }) => {
      const before = minutes.get(lower)!;
      const after = minutes.get(lower + this.gridMs) ?? before;
      return {
        minutes: before + (after - before) * fraction,
        sampleCount: this.assumedHistoryDays,
        observedShare: 1,
      };
    });
  }

  /** Typical drive time for a departure, the same for any date that day. */
  private typicalAt(route: Route, at: Date): Promise<number> {
    const { date, minuteOfDay } = localTime(at);
    const key = `${routeKey(route)}|${weekdayOf(date)}|${minuteOfDay}`;
    return this.typicalMinutes.get(
      key,
      async () => (await this.client.route(route, at)).travelMinutes,
    );
  }

  async getAdjustment(route: Route): Promise<LiveAdjustment> {
    const live = await this.liveRoute(route);
    const extraMinutes =
      live.historicMinutes === undefined
        ? 0
        : Math.max(0, live.travelMinutes - live.historicMinutes);
    return {
      available: true,
      extraMinutes,
      // A failed incidents lookup should not discard the live delay.
      incidents: await this.incidentsAlong(live.points).catch(() => []),
    };
  }

  private async incidentsAlong(path: LatLng[]): Promise<Incident[]> {
    const boxes = boxesAlong(path, this.maxIncidentBoxes);
    const reports = await Promise.all(
      boxes.map(box =>
        this.incidentReports.get(
          [box.minLat, box.minLng, box.maxLat, box.maxLng]
            .map(n => n.toFixed(3))
            .join(','),
          () => this.client.incidents(box),
        ),
      ),
    );
    const onRoute = pathProximity(path, this.incidentRadiusMeters);
    const seen = new Set<string>();
    const incidents: Incident[] = [];
    for (const report of reports.flat()) {
      const duplicate = report.id !== undefined && seen.has(report.id);
      if (duplicate || !isRelevant(report) || !onRoute(report.points)) {
        continue;
      }
      if (report.id !== undefined) {
        seen.add(report.id);
      }
      incidents.push({
        description: report.description,
        road: report.road,
        delayMinutes: report.delayMinutes,
      });
    }
    return incidents;
  }
}
