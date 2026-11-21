import { PGlite } from '@electric-sql/pglite';
import { Database, Queryable } from './db';

type Runner = Pick<PGlite, 'query' | 'exec'>;

const wrap = (runner: Runner): Queryable => ({
  async query(text, params) {
    const result = await runner.query(text, params);
    return { rows: result.rows as never };
  },
  async exec(sql) {
    await runner.exec(sql);
  },
});

/** An in-memory Postgres for tests and local experiments. No server needed. */
export async function createPgliteDatabase(): Promise<Database> {
  const pg = new PGlite();
  await pg.waitReady;
  return {
    ...wrap(pg),
    transaction: fn => pg.transaction(tx => fn(wrap(tx))),
    close: () => pg.close(),
  };
}
