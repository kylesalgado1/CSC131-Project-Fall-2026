import { CachedPlaceSearch } from '../cachedPlaces';
import { Place, PlaceSearch, SearchError } from '../types';

describe('CachedPlaceSearch', () => {
  const place: Place = { id: 'a', name: 'A', address: 'A St', lat: 1, lng: 2 };
  const counting = () => {
    const calls: Array<[string, unknown]> = [];
    const inner: PlaceSearch = {
      search: async (query, near) => {
        calls.push([query, near]);
        return [place];
      },
    };
    return { inner, calls };
  };

  it('answers a repeat of the same search without asking again', async () => {
    const { inner, calls } = counting();
    const cached = new CachedPlaceSearch(inner);
    await cached.search('Sac State', { lat: 38.2383, lng: -122.0402 });
    await cached.search('  sac state ', { lat: 38.2391, lng: -122.0399 }); // same words, ~100 m away
    expect(calls).toHaveLength(1);
    expect(calls[0][0]).toBe('Sac State');
  });

  it('asks again for different words or a different town', async () => {
    const { inner, calls } = counting();
    const cached = new CachedPlaceSearch(inner);
    await cached.search('sac', { lat: 38.2, lng: -122 });
    await cached.search('sacr', { lat: 38.2, lng: -122 });
    await cached.search('sac', { lat: 37.7, lng: -122.4 });
    await cached.search('sac');
    expect(calls).toHaveLength(4);
  });

  it('asks again once the answer is stale', async () => {
    let clock = 0;
    const { inner, calls } = counting();
    const cached = new CachedPlaceSearch(inner, 1000, () => clock);
    await cached.search('sac');
    clock = 2000;
    await cached.search('sac');
    expect(calls).toHaveLength(2);
  });

  it('does not remember a failure', async () => {
    let attempts = 0;
    const cached = new CachedPlaceSearch({
      search: async () => {
        attempts += 1;
        if (attempts === 1) {
          throw new SearchError('down');
        }
        return [place];
      },
    });
    await expect(cached.search('sac')).rejects.toThrow('down');
    expect(await cached.search('sac')).toEqual([place]);
  });
});
