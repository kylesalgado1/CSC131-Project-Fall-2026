// Runs with Node's built-in test runner (`npm test` in backend/), not Jest:
// PGlite, the in-memory Postgres these tests use, cannot load inside Jest.
import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { promises as fs } from 'fs';
import os from 'os';
import path from 'path';
import { gzipSync } from 'zlib';
import { Database } from '../db';
import { importPemsFile } from '../importPems';
import { runIngest } from '../ingest';
import { runMigrations } from '../migrate';
import {
  getObservations,
  insertObservations,
  rebuildProfiles,
  upsertStations,
} from '../pemsRepository';
import { createPgliteDatabase } from '../pglite';
import { sslFromEnv } from '../pool';
import {
  inCorridor,
  parseStationMetadata,
  SUISUN_TO_SAC_STATE,
} from '../../prediction/providers/pems/metadata';
import { PgProfileStore } from '../../prediction/providers/pems/pgStore';
import { PgStationSource } from '../../prediction/providers/routing/pathResolver';
import {
  PemsBaselineProvider,
  RouteResolver,
} from '../../prediction/providers/pems/provider';
import {
  PemsObservation,
  PemsStation,
} from '../../prediction/providers/pems/types';

const ROUTE = {
  origin: { lat: 38.24, lng: -122.04 },
  destination: { lat: 38.56, lng: -121.42 },
};

const closeTo = (actual: number, expected: number, tolerance = 0.01) =>
  assert.ok(
    Math.abs(actual - expected) <= tolerance,
    `${actual} is not within ${tolerance} of ${expected}`,
  );

const station = (id: number, over: Partial<PemsStation> = {}): PemsStation => ({
  id,
  freeway: '80',
  direction: 'E',
  lengthMiles: 1,
  latitude: 38.4,
  longitude: -121.9,
  ...over,
});

const obs = (over: Partial<PemsObservation> = {}): PemsObservation => ({
  stationId: 101,
  localDate: '2026-10-14', // Wednesday
  minuteOfDay: 8 * 60,
  avgSpeedMph: 60,
  totalFlow: 100,
  pctObserved: 100,
  ...over,
});

/** A PeMS 5-minute line with the columns the importer reads. */
const pemsLine = (
  stationId: number,
  time: string,
  speed: number,
  flow = 100,
  pct = 100,
  date = '10/14/2026',
) =>
  `${date} ${time},${stationId},4,80,E,ML,.4,40,${pct},${flow},.02,${speed},` +
  '10,3,.0017,74.8,1,,,,,0';

const range = (stationIds: number[], from = '2026-10-14', to = from) => ({
  stationIds,
  from,
  to,
});

let db: Database;

beforeEach(async () => {
  db = await createPgliteDatabase();
  await runMigrations(db);
});

afterEach(async () => {
  await db.close();
});

describe('migrations', () => {
  it('creates the PeMS tables and records the migration', async () => {
    const { rows } = await db.query<{ table_name: string }>(
      `SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' ORDER BY table_name`,
    );
    const names = rows.map(r => r.table_name);
    for (const table of [
      'baseline_profiles',
      'ingest_runs',
      'pems_observations',
      'pems_stations',
      'schema_migrations',
    ]) {
      assert.ok(names.includes(table), `missing table ${table}`);
    }
    const applied = await db.query('SELECT version FROM schema_migrations');
    assert.deepEqual(applied.rows, [
      { version: '001_pems_baseline.sql' },
      { version: '002_profile_observed_share.sql' },
      { version: '003_enable_rls.sql' },
      { version: '004_profile_free_flow.sql' },
      { version: '005_trip_monitoring.sql' },
    ]);
  });

  it('turns on row-level security for every table', async () => {
    const { rows } = await db.query<{ relname: string; rls: boolean }>(
      `SELECT c.relname, c.relrowsecurity AS rls
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'r'`,
    );
    assert.ok(rows.length >= 5);
    assert.deepEqual(
      rows.filter(r => !r.rls).map(r => r.relname),
      [],
    );
  });

  it('applies each migration only once', async () => {
    assert.deepEqual(await runMigrations(db), []);
  });
});

describe('stations and observations', () => {
  it('upserts stations without duplicating them', async () => {
    await upsertStations(db, [station(101), station(102)]);
    await upsertStations(db, [station(101, { freeway: '50' })]);
    const { rows } = await db.query<{ id: number; freeway: string }>(
      'SELECT id, freeway FROM pems_stations ORDER BY id',
    );
    assert.deepEqual(rows, [
      { id: 101, freeway: '50' },
      { id: 102, freeway: '80' },
    ]);
  });

  it('stores readings and replaces a reading for the same time', async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [obs({ avgSpeedMph: 60 })]);
    await insertObservations(db, [obs({ avgSpeedMph: 40 })]);
    const stored = await getObservations(db, range([101]));
    assert.equal(stored.length, 1);
    closeTo(stored[0].avgSpeedMph, 40);
  });

  it('keeps the last of two identical keys in one batch', async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [
      obs({ avgSpeedMph: 60 }),
      obs({ avgSpeedMph: 50 }),
    ]);
    const stored = await getObservations(db, range([101]));
    assert.deepEqual(
      stored.map(o => o.avgSpeedMph),
      [50],
    );
  });

  it('rejects readings for an unknown station', async () => {
    await assert.rejects(insertObservations(db, [obs()]));
  });

  it('queries by station and time range', async () => {
    await upsertStations(db, [station(101), station(102)]);
    await insertObservations(db, [
      obs({ stationId: 101, localDate: '2026-10-13' }),
      obs({ stationId: 101, localDate: '2026-10-14' }),
      obs({ stationId: 101, localDate: '2026-10-15' }),
      obs({ stationId: 102, localDate: '2026-10-14' }),
    ]);
    const stored = await getObservations(
      db,
      range([101], '2026-10-14', '2026-10-15'),
    );
    assert.deepEqual(
      stored.map(o => [o.stationId, o.localDate]),
      [
        [101, '2026-10-14'],
        [101, '2026-10-15'],
      ],
    );
  });

  it('keeps missing flow and coverage as null', async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [obs({ totalFlow: null, pctObserved: null })]);
    const [stored] = await getObservations(db, range([101]));
    assert.equal(stored.totalFlow, null);
    assert.equal(stored.pctObserved, null);
  });
});

describe('rebuildProfiles', () => {
  const seed = async () => {
    await upsertStations(db, [station(101), station(102)]);
    await insertObservations(db, [
      // Station 101, 08:00 bucket: three weekdays at 60 mph.
      obs({ localDate: '2026-10-14' }),
      obs({ localDate: '2026-10-15' }),
      obs({ localDate: '2026-10-16' }),
      // Same station, weekend.
      obs({ localDate: '2026-10-17', avgSpeedMph: 70 }),
      // Station 102 has only an imputed reading.
      obs({ stationId: 102, pctObserved: 0, avgSpeedMph: 45 }),
    ]);
  };

  it('builds profiles by station, day type and bucket', async () => {
    await seed();
    assert.equal(await rebuildProfiles(db), 2);
    const { rows } = await db.query<{
      station_id: number;
      day_type: string;
      bucket: number;
      avg_speed_mph: number;
      sample_count: number;
      observed_share: number;
    }>(
      `SELECT station_id, day_type, bucket,
              avg_speed_mph::float8 AS avg_speed_mph, sample_count,
              observed_share::float8 AS observed_share
         FROM baseline_profiles ORDER BY station_id, day_type`,
    );
    assert.deepEqual(rows, [
      {
        station_id: 101,
        day_type: 'weekday',
        bucket: 32,
        avg_speed_mph: 60,
        sample_count: 3,
        observed_share: 1,
      },
      {
        station_id: 101,
        day_type: 'weekend',
        bucket: 32,
        avg_speed_mph: 70,
        sample_count: 1,
        observed_share: 1,
      },
    ]);
  });

  it('records estimated readings as unmeasured', async () => {
    await seed();
    await rebuildProfiles(db, { minPctObserved: 0 });
    const { rows } = await db.query<{ station_id: number; share: number }>(
      `SELECT station_id, observed_share::float8 AS share
         FROM baseline_profiles WHERE day_type = 'weekday' ORDER BY 1`,
    );
    assert.deepEqual(rows, [
      { station_id: 101, share: 1 },
      { station_id: 102, share: 0 },
    ]);
  });

  it("stores each station's overnight speed as its free-flow speed", async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [
      obs({ minuteOfDay: 3 * 60, avgSpeedMph: 70 }), // 03:00, overnight
      obs({ minuteOfDay: 3 * 60 + 5, avgSpeedMph: 66 }),
      obs({ minuteOfDay: 3 * 60 + 10, avgSpeedMph: 68 }),
      obs({ minuteOfDay: 8 * 60, avgSpeedMph: 30 }), // rush hour, ignored
    ]);
    await rebuildProfiles(db);
    const rows = await new PgProfileStore(db).getProfiles(
      [101],
      [
        { dayType: 'weekday', bucket: 12 },
        { dayType: 'weekday', bucket: 32 },
      ],
    );
    assert.equal(rows.length, 2);
    // The median of 70, 66 and 68, shared by every profile of the station.
    for (const row of rows) {
      closeTo(row.freeFlowMph ?? 0, 68, 0.01);
    }
  });

  it('leaves free-flow unknown for a station with no overnight data', async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [obs()]); // 08:00 only
    await rebuildProfiles(db);
    const [row] = await new PgProfileStore(db).getProfiles(
      [101],
      [{ dayType: 'weekday', bucket: 32 }],
    );
    assert.equal(row.freeFlowMph, undefined);
  });

  it('lets imputed readings in when the threshold is lowered', async () => {
    await seed();
    assert.equal(await rebuildProfiles(db, { minPctObserved: 0 }), 3);
  });

  it('replaces old profiles instead of adding to them', async () => {
    await seed();
    await rebuildProfiles(db);
    await rebuildProfiles(db);
    const { rows } = await db.query<{ n: string }>(
      'SELECT count(*)::text AS n FROM baseline_profiles',
    );
    assert.equal(rows[0].n, '2');
  });

  it('only touches the stations it is given', async () => {
    await seed();
    await rebuildProfiles(db, { minPctObserved: 0 });
    await db.query('DELETE FROM pems_observations WHERE station_id = 102');
    await rebuildProfiles(db, { stationIds: [101], minPctObserved: 0 });
    const { rows } = await db.query<{ station_id: number }>(
      'SELECT DISTINCT station_id FROM baseline_profiles ORDER BY 1',
    );
    assert.deepEqual(
      rows.map(r => r.station_id),
      [101, 102],
    );
  });

  it('classifies campus breaks as holidays', async () => {
    await seed();
    await rebuildProfiles(db, {
      stationIds: [101],
      campusBreaks: [{ name: 'Break', start: '2026-10-14', end: '2026-10-14' }],
    });
    const { rows } = await db.query<{ day_type: string; n: number }>(
      `SELECT day_type, sample_count AS n FROM baseline_profiles
        ORDER BY day_type`,
    );
    assert.deepEqual(rows, [
      { day_type: 'holiday', n: 1 },
      { day_type: 'weekday', n: 2 },
      { day_type: 'weekend', n: 1 },
    ]);
  });
});

describe('Postgres baseline end to end', () => {
  it('turns stored readings into a route drive time', async () => {
    await upsertStations(db, [station(101), station(102)]);
    await insertObservations(db, [
      obs({ stationId: 101, localDate: '2026-10-14', avgSpeedMph: 60 }),
      obs({ stationId: 101, localDate: '2026-10-15', avgSpeedMph: 60 }),
      obs({ stationId: 102, localDate: '2026-10-14', avgSpeedMph: 30 }),
      obs({ stationId: 102, localDate: '2026-10-15', avgSpeedMph: 30 }),
    ]);
    await rebuildProfiles(db);

    const resolver: RouteResolver = {
      resolve: async () => ({
        segments: [
          { stationId: 101, lengthMiles: 2 },
          { stationId: 102, lengthMiles: 3 },
        ],
        uncoveredMiles: 0,
      }),
    };
    const provider = new PemsBaselineProvider(new PgProfileStore(db), resolver);
    // Wednesday 08:00 Pacific daylight time.
    const result = await provider.getBaseline(
      ROUTE,
      new Date('2026-10-14T15:00:00Z'),
    );
    // 2 miles at 60 mph = 2 min, 3 miles at 30 mph = 6 min.
    closeTo(result.minutes, 8, 0.1);
    assert.equal(result.sampleCount, 2);
    assert.equal(result.observedShare, 1);
  });

  it('returns nothing for an empty station list', async () => {
    assert.deepEqual(
      await new PgProfileStore(db).getProfiles(
        [],
        [{ dayType: 'weekday', bucket: 32 }],
      ),
      [],
    );
  });
});

describe('PgStationSource', () => {
  it('loads stations and keeps them until the cache expires', async () => {
    await upsertStations(db, [station(101), station(102, { direction: 'W' })]);
    let clock = 0;
    const source = new PgStationSource(db, 1000, () => clock);
    const first = await source.getStations();
    assert.deepEqual(
      first.map(s => [s.id, s.direction, s.lengthMiles]),
      [
        [101, 'E', 1],
        [102, 'W', 1],
      ],
    );
    await upsertStations(db, [station(103)]);
    clock = 500;
    assert.equal((await source.getStations()).length, 2);
    clock = 1500;
    assert.equal((await source.getStations()).length, 3);
  });
});

describe('PgProfileStore batch reads', () => {
  it('fetches several day types and buckets in one query', async () => {
    await upsertStations(db, [station(101)]);
    await insertObservations(db, [
      obs({ minuteOfDay: 8 * 60 }),
      obs({ minuteOfDay: 9 * 60, avgSpeedMph: 40 }),
      obs({ minuteOfDay: 10 * 60, avgSpeedMph: 30 }),
      obs({ localDate: '2026-10-17', avgSpeedMph: 70 }), // Saturday 08:00
    ]);
    await rebuildProfiles(db);
    const rows = await new PgProfileStore(db).getProfiles(
      [101],
      [
        { dayType: 'weekday', bucket: 32 },
        { dayType: 'weekday', bucket: 36 },
        { dayType: 'weekend', bucket: 32 },
      ],
    );
    assert.deepEqual(rows.map(r => [r.dayType, r.bucket]).sort(), [
      ['weekday', 32],
      ['weekday', 36],
      ['weekend', 32],
    ]);
  });
});

describe('importPemsFile', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pems-'));
    await upsertStations(db, [station(101), station(102)]);
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  const lines = [
    pemsLine(101, '08:00:00', 55),
    pemsLine(101, '08:05:00', 50),
    pemsLine(102, '08:00:00', 40),
    pemsLine(999, '08:00:00', 70), // not on the corridor
    'garbage line',
    '10/14/2026 08:10:00,101,4,80,E,ML,.4,40,100,100,.02,,', // blank speed
  ];

  it('stores only the wanted stations and skips unusable lines', async () => {
    const file = path.join(dir, 'd04.txt');
    await fs.writeFile(file, lines.join('\n') + '\n');
    assert.equal(await importPemsFile(db, file, new Set([101, 102])), 3);
    const stored = await getObservations(db, range([101, 102, 999]));
    assert.equal(stored.length, 3);
  });

  it('reads gzip files', async () => {
    const file = path.join(dir, 'd04.txt.gz');
    await fs.writeFile(file, gzipSync(lines.join('\n')));
    assert.equal(await importPemsFile(db, file, new Set([101, 102])), 3);
  });

  it('works across batch boundaries and is safe to repeat', async () => {
    const clock = (i: number) =>
      `${String(8 + Math.floor(i / 12)).padStart(2, '0')}:` +
      `${String((i % 12) * 5).padStart(2, '0')}:00`;
    const many = Array.from({ length: 25 }, (_, i) =>
      pemsLine(101, clock(i), 50 + i),
    );
    const file = path.join(dir, 'many.txt');
    await fs.writeFile(file, many.join('\n'));
    const wanted = new Set([101]);
    assert.equal(await importPemsFile(db, file, wanted, { batchSize: 10 }), 25);
    assert.equal(await importPemsFile(db, file, wanted, { batchSize: 10 }), 25);
    const { rows } = await db.query<{ n: string }>(
      'SELECT count(*)::text AS n FROM pems_observations',
    );
    assert.equal(rows[0].n, '25');
  });

  it('fails clearly when the file does not exist', async () => {
    await assert.rejects(
      importPemsFile(db, path.join(dir, 'missing.txt'), new Set([101])),
      /ENOENT/,
    );
  });
});

describe('runIngest', () => {
  const runs = async () =>
    (
      await db.query<{
        status: string;
        attempt: number;
        rows_ingested: number | null;
        error: string | null;
      }>(
        `SELECT status, attempt, rows_ingested, error
           FROM ingest_runs ORDER BY id`,
      )
    ).rows;

  it('logs a successful run', async () => {
    assert.equal(await runIngest(db, 'd04', async () => 42), 42);
    assert.deepEqual(await runs(), [
      { status: 'succeeded', attempt: 1, rows_ingested: 42, error: null },
    ]);
  });

  it('logs a failed attempt and retries once', async () => {
    let calls = 0;
    const count = await runIngest(db, 'd04', async () => {
      calls += 1;
      if (calls === 1) {
        throw new Error('download failed');
      }
      return 7;
    });
    assert.equal(count, 7);
    assert.deepEqual(await runs(), [
      {
        status: 'failed',
        attempt: 1,
        rows_ingested: null,
        error: 'download failed',
      },
      { status: 'succeeded', attempt: 2, rows_ingested: 7, error: null },
    ]);
  });

  it('gives up after the retries and throws the last error', async () => {
    await assert.rejects(
      runIngest(
        db,
        'd04',
        async () => {
          throw new Error('still down');
        },
        { retries: 2 },
      ),
      /still down/,
    );
    assert.deepEqual(
      (await runs()).map(r => [r.status, r.attempt]),
      [
        ['failed', 1],
        ['failed', 2],
        ['failed', 3],
      ],
    );
  });
});

describe('station metadata', () => {
  const header =
    'ID\tFwy\tDir\tDistrict\tCounty\tCity\tState_PM\tAbs_PM\tLatitude\tLongitude\tLength\tType\tLanes\tName\tUser_ID_1\tUser_ID_2\tUser_ID_3\tUser_ID_4';
  const text = [
    header,
    '400000\t101\tS\t4\t41\t52582\t19.23\t459.835\t38.081498\t-122.547963\t.415\tML\t4\tSR-37 conn-s-diag\tDT5A2\tL4-S-27-101-01923\t101482\t424150',
    '311831\t5\tS\t3\t67\t\t10.896\t506.189\t38.409782\t-121.48412\t\tOR\t1\tElk Grove Blvd to 5SB Loop\t1\t\t\t',
    '308511\t50\tE\t3\t17\t\t31.627\t60.162\t38.761062\t-120.569835\t3.134\tML\t2\tSly Park Rd\t1\t\t\t',
    '308599\t80\tE\t3\t113\t\t1\t1\t\t\t1.5\tML\t2\tNo location\t1\t\t\t',
    '308600\t80\tE\t3\t113\t\t1\t1\t38.5\t-121.7\t\tML\t2\tNo length\t1\t\t\t',
    '',
  ].join('\n');

  it('keeps mainline stations that have a location and a length', () => {
    assert.deepEqual(parseStationMetadata(text), [
      {
        id: 400000,
        freeway: '101',
        direction: 'S',
        lengthMiles: 0.415,
        latitude: 38.081498,
        longitude: -122.547963,
      },
      {
        id: 308511,
        freeway: '50',
        direction: 'E',
        lengthMiles: 3.134,
        latitude: 38.761062,
        longitude: -120.569835,
      },
    ]);
  });

  it('rejects a file that is not station metadata', () => {
    assert.throws(
      () => parseStationMetadata('a,b,c\n1,2,3'),
      /Not a PeMS metadata file/,
    );
  });

  it('selects stations by freeway and bounding box', () => {
    const corridor = SUISUN_TO_SAC_STATE;
    assert.equal(inCorridor(station(1, { freeway: '80' }), corridor), true);
    assert.equal(inCorridor(station(1, { freeway: '101' }), corridor), false);
    assert.equal(inCorridor(station(1, { latitude: 37.5 }), corridor), false);
    assert.equal(
      inCorridor(station(1, { longitude: -120.5 }), corridor),
      false,
    );
  });
});

describe('sslFromEnv', () => {
  it('is off unless a CA file is configured', () => {
    assert.equal(sslFromEnv({}), undefined);
  });

  it('reads the CA certificate from the configured path', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'ca-'));
    const file = path.join(dir, 'ca.crt');
    await fs.writeFile(file, 'CERT-CONTENTS');
    try {
      assert.deepEqual(sslFromEnv({ DATABASE_SSL_CA: file }), {
        ca: 'CERT-CONTENTS',
      });
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
});
