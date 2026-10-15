import { Queryable } from './db';

export interface IngestOptions {
  /** Extra attempts after the first failure. */
  retries?: number;
}

/**
 * Runs an ingest job, logging every attempt in `ingest_runs`. A failed
 * attempt is recorded and retried; if every attempt fails the last error is
 * thrown. The job returns how many rows it stored.
 */
export async function runIngest(
  db: Queryable,
  source: string,
  job: () => Promise<number>,
  { retries = 1 }: IngestOptions = {},
): Promise<number> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= retries + 1; attempt++) {
    const { rows } = await db.query<{ id: string }>(
      `INSERT INTO ingest_runs (source, status, attempt)
       VALUES ($1, 'running', $2) RETURNING id`,
      [source, attempt],
    );
    const id = rows[0].id;
    try {
      const count = await job();
      await db.query(
        `UPDATE ingest_runs
            SET status = 'succeeded', finished_at = now(), rows_ingested = $2
          WHERE id = $1`,
        [id, count],
      );
      return count;
    } catch (error) {
      lastError = error;
      await db.query(
        `UPDATE ingest_runs
            SET status = 'failed', finished_at = now(), error = $2
          WHERE id = $1`,
        [id, error instanceof Error ? error.message : String(error)],
      );
    }
  }
  throw lastError;
}
