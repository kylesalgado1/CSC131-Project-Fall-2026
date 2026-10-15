import { Queryable } from '../../../db/db';
import { DayType } from '../../calendar';
import { ProfileKey, ProfileStore } from './store';
import { ProfileRow } from './types';

/** Reads baseline profiles from the `baseline_profiles` table. */
export class PgProfileStore implements ProfileStore {
  constructor(private readonly db: Queryable) {}

  async getProfiles(
    stationIds: number[],
    keys: ProfileKey[],
  ): Promise<ProfileRow[]> {
    if (stationIds.length === 0 || keys.length === 0) {
      return [];
    }
    const { rows } = await this.db.query<{
      station_id: number;
      day_type: DayType;
      bucket: number;
      avg_speed_mph: number;
      sample_count: number;
      observed_share: number;
      free_flow_mph: number;
    }>(
      `SELECT p.station_id, p.day_type, p.bucket,
              p.avg_speed_mph::float8 AS avg_speed_mph, p.sample_count,
              p.observed_share::float8 AS observed_share,
              p.free_flow_mph::float8 AS free_flow_mph
         FROM baseline_profiles p
         JOIN unnest($2::text[], $3::smallint[]) AS k(day_type, bucket)
           ON p.day_type = k.day_type AND p.bucket = k.bucket
        WHERE p.station_id = ANY($1::int[])`,
      [stationIds, keys.map(k => k.dayType), keys.map(k => k.bucket)],
    );
    return rows.map(r => ({
      stationId: r.station_id,
      dayType: r.day_type,
      bucket: r.bucket,
      avgSpeedMph: r.avg_speed_mph,
      sampleCount: r.sample_count,
      observedShare: r.observed_share,
      // 0 in the table means the station's free-flow speed is unknown.
      freeFlowMph: r.free_flow_mph > 0 ? r.free_flow_mph : undefined,
    }));
  }
}
