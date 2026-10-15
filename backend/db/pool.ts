import { readFileSync } from 'fs';
import { Pool, PoolClient } from 'pg';
import { Database, Queryable } from './db';

const wrap = (client: Pool | PoolClient): Queryable => ({
  async query(text, params) {
    // `pg` types its rows as `any`; callers state the row shape they expect.
    const result = await client.query(text, params as unknown[] | undefined);
    return { rows: result.rows };
  },
  async exec(sql) {
    await client.query(sql);
  },
});

export interface SslConfig {
  ca: string;
}

/**
 * Optional CA certificate for verified TLS, e.g. Supabase's. Set
 * DATABASE_SSL_CA to the certificate file's path and leave `sslmode` off
 * the connection string, because `pg` lets the string override this.
 * Without it, TLS follows the connection string's `sslmode`.
 */
export function sslFromEnv(env = process.env): SslConfig | undefined {
  const caPath = env.DATABASE_SSL_CA;
  return caPath ? { ca: readFileSync(caPath, 'utf8') } : undefined;
}

export function createPgDatabase(
  connectionString: string,
  ssl?: SslConfig,
): Database {
  const pool = new Pool({ connectionString, ssl });
  return {
    ...wrap(pool),
    async transaction(fn) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const result = await fn(wrap(client));
        await client.query('COMMIT');
        return result;
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    },
    close: () => pool.end(),
  };
}

export function databaseFromEnv(env = process.env): Database {
  const url = env.DATABASE_URL;
  if (!url) {
    throw new Error(
      'DATABASE_URL is not set, e.g. postgres://user:pass@localhost:5432/waitout',
    );
  }
  return createPgDatabase(url, sslFromEnv(env));
}
