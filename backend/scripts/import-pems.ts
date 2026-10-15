/**
 * Loads PeMS data for the commute corridor and rebuilds baseline profiles.
 *
 *   npm run import-pems -- \
 *     --meta d04_text_meta_2026_04_08.txt --meta d03_text_meta_2026_09_22.txt \
 *     --data d04_text_station_5min_2026_10_12.txt \
 *     --data d03_text_station_5min_2026_10_12.txt
 *
 * Optional: --min-observed <0-100> (default 50), --break "name,start,end"
 * (repeatable, dates YYYY-MM-DD). Needs DATABASE_URL.
 */
import { promises as fs } from 'fs';
import { parseArgs } from 'util';
import { runIngest } from '../db/ingest';
import { importPemsFile } from '../db/importPems';
import { runMigrations } from '../db/migrate';
import { rebuildProfiles, upsertStations } from '../db/pemsRepository';
import { databaseFromEnv } from '../db/pool';
import {
  inCorridor,
  parseStationMetadata,
  SUISUN_TO_SAC_STATE,
} from '../prediction/providers/pems/metadata';
import { parseCampusBreak } from './campusBreak';

async function main() {
  const { values } = parseArgs({
    options: {
      meta: { type: 'string', multiple: true },
      data: { type: 'string', multiple: true },
      'min-observed': { type: 'string', default: '50' },
      break: { type: 'string', multiple: true },
    },
  });
  if (!values.meta?.length || !values.data?.length) {
    throw new Error('Give at least one --meta and one --data file.');
  }

  const stations = (
    await Promise.all(
      values.meta.map(async f =>
        parseStationMetadata(await fs.readFile(f, 'utf8')),
      ),
    )
  )
    .flat()
    .filter(s => inCorridor(s, SUISUN_TO_SAC_STATE));
  console.log(`${stations.length} corridor stations in the metadata`);

  const db = databaseFromEnv();
  try {
    await runMigrations(db);
    await upsertStations(db, stations);
    const ids = new Set(stations.map(s => s.id));

    for (const file of values.data) {
      const count = await runIngest(db, file, () =>
        importPemsFile(db, file, ids),
      );
      console.log(`${file}: stored ${count} readings`);
    }

    const profiles = await rebuildProfiles(db, {
      stationIds: [...ids],
      minPctObserved: Number(values['min-observed']),
      campusBreaks: (values.break ?? []).map(parseCampusBreak),
    });
    console.log(`Rebuilt ${profiles} baseline profile rows`);
  } finally {
    await db.close();
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
