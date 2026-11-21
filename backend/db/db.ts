/**
 * The smallest database surface the backend needs. Production wraps a `pg`
 * Pool; tests wrap PGlite (real Postgres in WebAssembly), so the same SQL
 * runs in both.
 */
export interface QueryResult<R> {
  rows: R[];
}

export interface Queryable {
  query<R extends object = Record<string, unknown>>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<R>>;
  /** Runs one or more statements with no parameters. */
  exec(sql: string): Promise<void>;
}

export interface Database extends Queryable {
  transaction<T>(fn: (tx: Queryable) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
