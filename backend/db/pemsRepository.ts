import { CampusBreak } from '../prediction/calendar';
import {
  aggregateProfiles,
  AggregateOptions,
} from '../prediction/providers/pems/aggregate';
import {
  PemsObservation,
  PemsStation,
  ProfileRow,
} from '../prediction/providers/pems/types';
import { Database, Queryable } from './db';

const chunk = <T>(items: T[], size: number): T[][] => {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
};

export async function upsertStations(
  db: Queryable,
  stations: PemsStation[],
): Promise<void> {
  if (stations.length === 0) {
    return;
  }
  await db.query(
    `INSERT INTO pems_stations
            (id, freeway, direction, length_miles, latitude, longitude)
     SELECT * FROM unnest($1::int[], $2::text[], $3::text[], $4::numeric[],
                          $5::float8[], $6::float8[])
     ON CONFLICT (id) DO UPDATE SET
       freeway = EXCLUDED.freeway,
       direction = EXCLUDED.direction,
       length_miles = EXCLUDED.length_miles,
       latitude = EXCLUDED.latitude,
       longitude = EXCLUDED.longitude`,
    [
      stations.map(s => s.id),
      stations.map(s => s.freeway),
      stations.map(s => s.direction),
      stations.map(s => s.lengthMiles),
      stations.map(s => s.latitude),
      stations.map(s => s.longitude),
    ],
  );
}

/**
 * Inserts readings, replacing any already stored for the same station and
 * time, so loading the same file twice is harmless. Stations must exist.
 */
export async function insertObservations(
  db: Queryable,
  observations: PemsObservation[],
): Promise<void> {
  // One statement cannot update the same row twice, so keep the last reading
  // for each station and time.
  const unique = new Map<string, PemsObservation>();
  for (const o of observations) {
    unique.set(`${o.stationId}|${o.localDate}|${o.minuteOfDay}`, o);
  }
  const rows = [...unique.values()];
  if (rows.length === 0) {
    return;
  }
  await db.query(
    `INSERT INTO pems_observations
            (station_id, observed_on, minute_of_day, avg_speed_mph,
             total_flow, pct_observed)
     SELECT * FROM unnest($1::int[], $2::date[], $3::smallint[], $4::real[],
                          $5::int[], $6::real[])
     ON CONFLICT (station_id, observed_on, minute_of_day) DO UPDATE SET
       avg_speed_mph = EXCLUDED.avg_speed_mph,
       total_flow = EXCLUDED.total_flow,
       pct_observed = EXCLUDED.pct_observed`,
    [
      rows.map(o => o.stationId),
      rows.map(o => o.localDate),
      rows.map(o => o.minuteOfDay),
      rows.map(o => o.avgSpeedMph),
      rows.map(o => (o.totalFlow === null ? null : Math.round(o.totalFlow))),
      rows.map(o => o.pctObserved),
    ],
  );
}

export interface ObservationQuery {
  stationIds: number[];
  /** Inclusive local dates, YYYY-MM-DD. */
  from: string;
  to: string;
}

/** Stored readings for some stations over a date range, oldest first. */
export async function getObservations(
  db: Queryable,
  { stationIds, from, to }: ObservationQuery,
): Promise<PemsObservation[]> {
  const { rows } = await db.query<{
    station_id: number;
    local_date: string;
    minute_of_day: number;
    avg_speed_mph: number;
    total_flow: number | null;
    pct_observed: number | null;
  }>(
    `SELECT station_id,
            to_char(observed_on, 'YYYY-MM-DD') AS local_date,
            minute_of_day,
            avg_speed_mph::float8 AS avg_speed_mph,
            total_flow,
            pct_observed::float8 AS pct_observed
       FROM pems_observations
      WHERE station_id = ANY($1::int[])
        AND observed_on BETWEEN $2::date AND $3::date
      ORDER BY station_id, observed_on, minute_of_day`,
    [stationIds, from, to],
  );
  return rows.map(r => ({
    stationId: r.station_id,
    localDate: r.local_date,
    minuteOfDay: r.minute_of_day,
    avgSpeedMph: r.avg_speed_mph,
    totalFlow: r.total_flow,
    pctObserved: r.pct_observed,
  }));
}

async function insertProfiles(
  db: Queryable,
  profiles: ProfileRow[],
): Promise<void> {
  if (profiles.length === 0) {
    return;
  }
  await db.query(
    `INSERT INTO baseline_profiles
            (station_id, day_type, bucket, avg_speed_mph, sample_count,
             observed_share, free_flow_mph)
     SELECT * FROM unnest($1::int[], $2::text[], $3::smallint[], $4::real[],
                          $5::int[], $6::real[], $7::real[])`,
    [
      profiles.map(p => p.stationId),
      profiles.map(p => p.dayType),
      profiles.map(p => p.bucket),
      profiles.map(p => p.avgSpeedMph),
      profiles.map(p => p.sampleCount),
      profiles.map(p => p.observedShare),
      profiles.map(p => p.freeFlowMph ?? 0),
    ],
  );
}

export interface RebuildOptions extends AggregateOptions {
  /** Defaults to every station that has readings. */
  stationIds?: number[];
  campusBreaks?: CampusBreak[];
  /** Stations processed per round trip. */
  batchSize?: number;
}

/**
 * Recomputes baseline profiles from the stored readings, replacing whatever
 * profiles those stations had. Returns the number of profile rows written.
 */
export async function rebuildProfiles(
  db: Database,
  options: RebuildOptions = {},
): Promise<number> {
  const { stationIds, batchSize = 25, ...aggregate } = options;
  const ids =
    stationIds ??
    (
      await db.query<{ station_id: number }>(
        'SELECT DISTINCT station_id FROM pems_observations ORDER BY 1',
      )
    ).rows.map(r => r.station_id);

  let written = 0;
  for (const batch of chunk(ids, batchSize)) {
    const observations = await getObservations(db, {
      stationIds: batch,
      from: '0001-01-01',
      to: '9999-12-31',
    });
    const profiles = aggregateProfiles(observations, aggregate);
    await db.transaction(async tx => {
      await tx.query(
        'DELETE FROM baseline_profiles WHERE station_id = ANY($1::int[])',
        [batch],
      );
      await insertProfiles(tx, profiles);
    });
    written += profiles.length;
  }
  return written;
}
