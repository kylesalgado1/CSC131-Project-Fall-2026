import { promises as fs } from 'fs';
import path from 'path';
import { Database } from './db';

export const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

/**
 * Applies any `.sql` file in the directory that has not been applied yet, in
 * filename order. Each file runs in its own transaction. Returns the files it
 * applied.
 */
export async function runMigrations(
  db: Database,
  dir: string = MIGRATIONS_DIR,
): Promise<string[]> {
  await db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )
  `);
  const { rows } = await db.query<{ version: string }>(
    'SELECT version FROM schema_migrations',
  );
  const applied = new Set(rows.map(r => r.version));

  const files = (await fs.readdir(dir)).filter(f => f.endsWith('.sql')).sort();
  const ran: string[] = [];
  for (const file of files) {
    if (applied.has(file)) {
      continue;
    }
    const sql = await fs.readFile(path.join(dir, file), 'utf8');
    await db.transaction(async tx => {
      await tx.exec(sql);
      await tx.query('INSERT INTO schema_migrations (version) VALUES ($1)', [
        file,
      ]);
    });
    ran.push(file);
  }
  return ran;
}
