import { DayType } from '../../calendar';
import { ProfileRow } from './types';

export interface ProfileKey {
  dayType: DayType;
  /** 0-95, see BUCKET_MINUTES. */
  bucket: number;
}

/** Where baseline profiles live. Postgres in production, memory in tests. */
export interface ProfileStore {
  /** Profiles for these stations at any of the given day types and buckets. */
  getProfiles(stationIds: number[], keys: ProfileKey[]): Promise<ProfileRow[]>;
}

export class InMemoryProfileStore implements ProfileStore {
  constructor(private readonly rows: ProfileRow[]) {}

  async getProfiles(
    stationIds: number[],
    keys: ProfileKey[],
  ): Promise<ProfileRow[]> {
    const stations = new Set(stationIds);
    const wanted = new Set(keys.map(k => `${k.dayType}|${k.bucket}`));
    return this.rows.filter(
      r => stations.has(r.stationId) && wanted.has(`${r.dayType}|${r.bucket}`),
    );
  }
}
