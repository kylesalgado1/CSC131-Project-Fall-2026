import { DayType } from '../../calendar';
import { ProfileRow } from './types';

/** Where baseline profiles live. Postgres in production, memory in tests. */
export interface ProfileStore {
  getProfiles(
    stationIds: number[],
    dayType: DayType,
    bucket: number,
  ): Promise<ProfileRow[]>;
}

export class InMemoryProfileStore implements ProfileStore {
  constructor(private readonly rows: ProfileRow[]) {}

  async getProfiles(
    stationIds: number[],
    dayType: DayType,
    bucket: number,
  ): Promise<ProfileRow[]> {
    const wanted = new Set(stationIds);
    return this.rows.filter(
      r =>
        wanted.has(r.stationId) && r.dayType === dayType && r.bucket === bucket,
    );
  }
}
