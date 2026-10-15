import { databaseFromEnv } from '../db/pool';
import { runMigrations } from '../db/migrate';

async function main() {
  const db = databaseFromEnv();
  try {
    const ran = await runMigrations(db);
    console.log(ran.length ? `Applied: ${ran.join(', ')}` : 'Up to date.');
  } finally {
    await db.close();
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
