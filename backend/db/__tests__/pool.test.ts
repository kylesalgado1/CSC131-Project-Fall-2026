// Runs with Node's built-in test runner (`npm test` in backend/), not Jest.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { describe, it } from 'node:test';
import { logPoolErrors } from '../pool';

class ConnectionLost extends Error {}

describe('logPoolErrors', () => {
  it('keeps a dropped idle connection from being an unhandled error', () => {
    const pool = new EventEmitter();
    const lines: string[] = [];
    logPoolErrors(pool, line => lines.push(line));
    // Without a listener this would throw, which is what stops a server.
    assert.doesNotThrow(() => pool.emit('error', new ConnectionLost('gone')));
    assert.equal(lines.length, 1);
  });

  it('logs the kind of failure and never its message', () => {
    const pool = new EventEmitter();
    const lines: string[] = [];
    logPoolErrors(pool, line => lines.push(line));
    pool.emit(
      'error',
      new ConnectionLost(
        'connection to db.example.com as postgres:hunter2 terminated',
      ),
    );
    assert.deepEqual(lines, ['Database connection dropped: ConnectionLost']);
  });
});
