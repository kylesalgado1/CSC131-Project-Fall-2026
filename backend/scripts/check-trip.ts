/**
 * Compares TomTom's prediction for a trip with this app's own model, using
 * coordinates you give it. Use it to check the numbers against how long the
 * trip really takes. Coordinates are never printed.
 *
 *   npm run check-trip -- --from "38.2383,-122.0402" --to "38.5593,-121.4237"
 *
 * Optional:
 *   --times "07:00,18:00"   departure times on the local clock (default shown)
 *   --round-trip            times at or after 12:00 drive back, to -> from
 *   --date 2026-10-21       the day (default: next Wednesday)
 *
 * Needs TOMTOM_API_KEY in backend/.env. With DATABASE_URL set it also shows
 * the PeMS-based model, which adds PeMS delay to TomTom's no-traffic time.
 *
 * To get coordinates, long-press the spot in a maps app and copy them.
 */
import { parseArgs } from 'util';
import { databaseFromEnv } from '../db/pool';
import {
  CivilDate,
  instantAt,
  localTime,
  parseIso,
  toIso,
} from '../prediction/calendar';
import { PgProfileStore } from '../prediction/providers/pems/pgStore';
import { PemsBaselineProvider } from '../prediction/providers/pems/provider';
import {
  PathRouteResolver,
  PgStationSource,
} from '../prediction/providers/routing/pathResolver';
import { CachedPathProvider } from '../prediction/providers/routing/osrm';
import {
  TomTomPathProvider,
  TomTomRoutingClient,
} from '../prediction/providers/routing/tomtom';
import { Route } from '../prediction/types';
import {
  formatClock,
  nextWednesday,
  parseCoordinate,
  parseTimes,
} from './checkTrip';

const minutes = (value: number) => `${Math.round(value)} min`.padStart(8);

async function main() {
  const { values } = parseArgs({
    options: {
      from: { type: 'string' },
      to: { type: 'string' },
      times: { type: 'string', default: '07:00,18:00' },
      date: { type: 'string' },
      'round-trip': { type: 'boolean', default: false },
    },
  });
  if (!values.from || !values.to) {
    throw new Error(
      'Give --from "lat,lng" and --to "lat,lng". See the top of this file.',
    );
  }
  const apiKey = process.env.TOMTOM_API_KEY;
  if (!apiKey) {
    throw new Error('TOMTOM_API_KEY is not set. Add it to backend/.env.');
  }

  const out: Route = {
    origin: parseCoordinate(values.from, '--from'),
    destination: parseCoordinate(values.to, '--to'),
  };
  const back: Route = { origin: out.destination, destination: out.origin };
  const times = parseTimes(values.times);
  const date: CivilDate = values.date
    ? parseIso(values.date)
    : nextWednesday(new Date());

  const client = new TomTomRoutingClient(apiKey);
  const db = process.env.DATABASE_URL ? databaseFromEnv() : undefined;
  const pems = db
    ? new PemsBaselineProvider(
        new PgProfileStore(db),
        new PathRouteResolver(
          new PgStationSource(db),
          new CachedPathProvider(new TomTomPathProvider(client)),
        ),
      )
    : undefined;

  try {
    const first = await client.route(out);
    console.log(
      `Day: ${toIso(date)} (local time). Trip: ${first.distanceMiles.toFixed(
        1,
      )} miles, ` +
        `TomTom no-traffic time ${Math.round(first.noTrafficMinutes)} min.\n`,
    );
    console.log('depart  direction  TomTom typical  PeMS model');
    for (const minute of times) {
      const reverse = values['round-trip'] && minute >= 12 * 60;
      const route = reverse ? back : out;
      const departAt = instantAt(date, minute);
      const tomtom = await client.route(route, departAt);
      const model = pems && (await pems.getBaseline(route, departAt));
      console.log(
        `${formatClock(localTime(departAt).minuteOfDay)}   ` +
          `${(reverse ? 'back' : 'out').padEnd(9)}  ${minutes(
            tomtom.travelMinutes,
          )}      ` +
          (model ? minutes(model.minutes) : '   (no DATABASE_URL)'),
      );
    }
  } finally {
    await db?.close();
  }
}

main().catch(error => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
