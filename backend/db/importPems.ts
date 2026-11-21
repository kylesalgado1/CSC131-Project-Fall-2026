import { createReadStream } from 'fs';
import { createInterface } from 'readline';
import { createGunzip } from 'zlib';
import { parsePemsLine } from '../prediction/providers/pems/parse';
import { PemsObservation } from '../prediction/providers/pems/types';
import { Queryable } from './db';
import { insertObservations } from './pemsRepository';

export interface ImportOptions {
  /** Readings per INSERT. */
  batchSize?: number;
}

/**
 * Streams a PeMS station 5-minute file (plain or .gz) into the database,
 * keeping only the given stations. Files are large, so nothing is held in
 * memory beyond one batch. Returns how many readings were stored.
 */
export async function importPemsFile(
  db: Queryable,
  filePath: string,
  stationIds: Set<number>,
  { batchSize = 5000 }: ImportOptions = {},
): Promise<number> {
  const raw = createReadStream(filePath);
  const input = filePath.endsWith('.gz') ? raw.pipe(createGunzip()) : raw;
  raw.on('error', error => input.destroy(error));

  let batch: PemsObservation[] = [];
  let stored = 0;
  const flush = async () => {
    await insertObservations(db, batch);
    stored += batch.length;
    batch = [];
  };

  const lines = createInterface({ input, crlfDelay: Infinity });
  for await (const line of lines) {
    const obs = parsePemsLine(line);
    if (obs && stationIds.has(obs.stationId)) {
      batch.push(obs);
      if (batch.length >= batchSize) {
        await flush();
      }
    }
  }
  await flush();
  return stored;
}
