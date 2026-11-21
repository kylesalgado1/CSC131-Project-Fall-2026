import { PemsStation } from './types';

export interface Corridor {
  /** Route numbers as PeMS prints them. */
  freeways: string[];
  bbox: { minLat: number; minLng: number; maxLat: number; maxLng: number };
}

/**
 * I-80 from Suisun City to Davis and Sacramento, with US-50 and Business 80
 * (route 51) into Sac State, plus SR-12 and I-680 around Fairfield.
 */
export const SUISUN_TO_SAC_STATE: Corridor = {
  freeways: ['80', '50', '51', '12', '680'],
  bbox: { minLat: 38.15, minLng: -122.25, maxLat: 38.7, maxLng: -121.33 },
};

const REQUIRED = [
  'ID',
  'Fwy',
  'Dir',
  'Latitude',
  'Longitude',
  'Length',
  'Type',
];

/**
 * Parses a PeMS station metadata file (tab-separated, header row first).
 * Keeps mainline stations that have a location and a length. Ramps and
 * other station types are dropped.
 */
export function parseStationMetadata(text: string): PemsStation[] {
  const lines = text.split(/\r?\n/);
  const header = lines[0].split('\t').map(h => h.trim());
  const col = (name: string) => header.indexOf(name);
  const missing = REQUIRED.filter(name => col(name) < 0);
  if (missing.length > 0) {
    throw new Error(`Not a PeMS metadata file, missing: ${missing.join(', ')}`);
  }
  const [iId, iFwy, iDir, iLat, iLng, iLen, iType] = REQUIRED.map(col);

  const stations: PemsStation[] = [];
  for (const line of lines.slice(1)) {
    const f = line.split('\t');
    if (f[iType]?.trim() !== 'ML') {
      continue;
    }
    const id = Number(f[iId]);
    const latitude = Number(f[iLat]);
    const longitude = Number(f[iLng]);
    const lengthMiles = Number(f[iLen]);
    if (
      !Number.isInteger(id) ||
      f[iLat].trim() === '' ||
      f[iLng].trim() === '' ||
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      !(lengthMiles > 0)
    ) {
      continue;
    }
    stations.push({
      id,
      freeway: f[iFwy].trim(),
      direction: f[iDir].trim(),
      lengthMiles,
      latitude,
      longitude,
    });
  }
  return stations;
}

export function inCorridor(station: PemsStation, corridor: Corridor): boolean {
  const { minLat, minLng, maxLat, maxLng } = corridor.bbox;
  return (
    corridor.freeways.includes(station.freeway) &&
    station.latitude >= minLat &&
    station.latitude <= maxLat &&
    station.longitude >= minLng &&
    station.longitude <= maxLng
  );
}
