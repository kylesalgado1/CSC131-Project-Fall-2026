/**
 * Recomputes baseline profiles from the readings already in the database,
 * without importing anything. Run it after changing how profiles are built.
 *
 *   npm run rebuild-profiles -- --min-observed 0
 *
 * Optional: --min-observed <0-100> (default 50), --break "name,start,end"
 * (repeatable). Needs DATABASE_URL.
 */
import { parseArgs } from 'util';
import { runMigrations } from '../db/migrate';
import { rebuildProfiles } from '../db/pemsRepository';
import { databaseFromEnv } from '../db/pool';
import { parseCampusBreak } from './campusBreak';

async function main() {
  const { values } = parseArgs({
    options: {
      'min-observed': { type: 'string', default: '50' },
      break: { type: 'string', multiple: true },
    },
  });
  const db = databaseFromEnv();
  try {
    await runMigrations(db);
    const written = await rebuildProfiles(db, {
      minPctObserved: Number(values['min-observed']),
      campusBreaks: (values.break ?? []).map(parseCampusBreak),
    });
    console.log(`Rebuilt ${written} baseline profile rows`);
  } finally {
    await db.close();
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
