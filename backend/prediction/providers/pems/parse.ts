import { PemsObservation } from './types';

// Column order of a PeMS station 5-minute file. These files have no header
// row. Verify against a real download before relying on the importer.
const COL_TIMESTAMP = 0;
const COL_STATION = 1;
const COL_PCT_OBSERVED = 8;
const COL_TOTAL_FLOW = 9;
const COL_AVG_SPEED = 11;
const MIN_COLUMNS = 12;

const TIMESTAMP = /^(\d{2})\/(\d{2})\/(\d{4}) (\d{2}):(\d{2}):\d{2}$/;

const toNumber = (field: string): number | null => {
  if (field.trim() === '') {
    return null;
  }
  const n = Number(field);
  return Number.isFinite(n) ? n : null;
};

/**
 * Parses one line of a PeMS station 5-minute file. Returns null for lines
 * that are malformed or have no usable speed (PeMS leaves speed blank when a
 * station reported nothing).
 */
export function parsePemsLine(line: string): PemsObservation | null {
  const f = line.trim().split(',');
  if (f.length < MIN_COLUMNS) {
    return null;
  }
  const ts = TIMESTAMP.exec(f[COL_TIMESTAMP].trim());
  const stationId = toNumber(f[COL_STATION]);
  const speed = toNumber(f[COL_AVG_SPEED]);
  if (!ts || stationId === null || speed === null || speed <= 0) {
    return null;
  }
  const [, month, day, year, hour, minute] = ts;
  return {
    stationId,
    localDate: `${year}-${month}-${day}`,
    minuteOfDay: Number(hour) * 60 + Number(minute),
    avgSpeedMph: speed,
    totalFlow: toNumber(f[COL_TOTAL_FLOW]),
    pctObserved: toNumber(f[COL_PCT_OBSERVED]),
  };
}

export function parsePemsFile(text: string): PemsObservation[] {
  const out: PemsObservation[] = [];
  for (const line of text.split('\n')) {
    const obs = parsePemsLine(line);
    if (obs) {
      out.push(obs);
    }
  }
  return out;
}
