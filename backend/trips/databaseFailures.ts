import { Database, Queryable } from '../db/db';
import { errorName } from '../util/errorName';
import {
  ApiError,
  BadRequestError,
  TemporarilyUnavailableError,
} from './errors';

/** PostgreSQL's code for a table that does not exist. */
export const UNDEFINED_TABLE = '42P01';

// PostgreSQL's class for a value it cannot take: text with a NUL in it, a
// date out of range, a number too large for its column.
const DATA_EXCEPTION_CLASS = '22';

const SQL_STATE = /^[0-9A-Z]{5}$/;
// A SQLSTATE, or a code of Node's such as ECONNREFUSED. Nothing longer or
// stranger is repeated in a log.
const LOGGABLE_CODE = /^[A-Z0-9_]{3,32}$/;

const codeOf = (error: unknown): string | undefined => {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === 'string' ? code : undefined;
};

/** The SQLSTATE of a failure, when PostgreSQL itself reported it. */
export function sqlStateOf(error: unknown): string | undefined {
  const code = codeOf(error);
  return code !== undefined && SQL_STATE.test(code) ? code : undefined;
}

/**
 * What a failed database request is to the client that was being served.
 *
 * - PostgreSQL refused a value: the request carried something that cannot be
 *   stored, which is the request's fault (400), and sending it again cannot
 *   help.
 * - Anything else (the connection dropped, the pooler is full, the database
 *   is paused or restarting): the server's trouble, and temporary as far as
 *   anybody can tell (503 temporarily_unavailable). It is never "trip
 *   monitoring is not set up": that is only said when the database answered
 *   that the tables are not there.
 *
 * Only the kind of failure is logged, with PostgreSQL's or Node's code for
 * it: a message can name the database host.
 */
export function databaseFailure(
  error: unknown,
  log: (line: string) => void,
): ApiError {
  if (error instanceof ApiError) {
    return error;
  }
  if (sqlStateOf(error)?.startsWith(DATA_EXCEPTION_CLASS)) {
    return new BadRequestError(
      'The request holds a value the server cannot store.',
    );
  }
  const code = codeOf(error);
  log(
    `Database request failed: ${errorName(error)}${
      code !== undefined && LOGGABLE_CODE.test(code) ? ` ${code}` : ''
    }`,
  );
  return new TemporarilyUnavailableError();
}

/**
 * The same database, with every failure of its own turned into the answer a
 * client should get (see `databaseFailure`). A failure thrown by the caller's
 * own code inside a transaction is passed on as it is.
 */
export function guardDatabase(
  db: Database,
  log: (line: string) => void,
): Database {
  const fail = (error: unknown): never => {
    throw databaseFailure(error, log);
  };
  const guard = (queryable: Queryable): Queryable => ({
    async query<R extends object>(text: string, params?: unknown[]) {
      try {
        return await queryable.query<R>(text, params);
      } catch (error) {
        return fail(error);
      }
    },
    async exec(sql) {
      try {
        await queryable.exec(sql);
      } catch (error) {
        fail(error);
      }
    },
  });
  return {
    ...guard(db),
    async transaction(fn) {
      // What the caller's own code threw, as opposed to connecting,
      // beginning, committing or rolling back.
      let thrown: { error: unknown } | undefined;
      try {
        return await db.transaction(async tx => {
          try {
            return await fn(guard(tx));
          } catch (error) {
            thrown = { error };
            throw error;
          }
        });
      } catch (error) {
        if (thrown && thrown.error === error) {
          throw error;
        }
        return fail(error);
      }
    },
    close: () => db.close(),
  };
}
