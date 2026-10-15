import { Queryable } from '../../../db/db';
import { DayType } from '../../calendar';
import { ProfileStore } from './store';
import { ProfileRow } from './types';

/** Reads baseline profiles from the `baseline_profiles` table. */
export class PgProfileStore implements ProfileStore {
  constructor(private readonly db: Queryable) {}

  async getProfiles(
    stationIds: number[],
    dayType: DayType,
    bucket: number,
  ): Promise<ProfileRow[]> {
    if (stationIds.length === 0) {
      return [];
    }
    const { rows } = await this.db.query<{
      station_id: number;
      day_type: DayType;
      bucket: number;
      avg_speed_mph: number;
      sample_count: number;
      observed_share: number;
    }>(
      `SELECT station_id, day_type, bucket,
              avg_speed_mph::float8 AS avg_speed_mph, sample_count,
              observed_share::float8 AS observed_share
         FROM baseline_profiles
        WHERE station_id = ANY($1::int[]) AND day_type = $2 AND bucket = $3`,
      [stationIds, dayType, bucket],
    );
    return rows.map(r => ({
      stationId: r.station_id,
      dayType: r.day_type,
      bucket: r.bucket,
      avgSpeedMph: r.avg_speed_mph,
      sampleCount: r.sample_count,
      observedShare: r.observed_share,
    }));
  }
}
