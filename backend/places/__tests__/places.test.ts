import { FetchLike } from '../../util/http';
import { TomTomClient } from '../../prediction/providers/routing/tomtom';
import { TomTomPlaces } from '../tomtomPlaces';
import { SearchError } from '../types';

type Hit = {
  id?: string;
  poi?: { name: string };
  address?: { freeformAddress: string };
  position?: { lat: number; lon: number };
};

const hit = (over: Hit = {}): Hit => ({
  id: 'id-1',
  address: { freeformAddress: '6000 J Street, Sacramento, CA 95819' },
  position: { lat: 38.56, lon: -121.42 },
  ...over,
});

function fakeTomTom(results: Hit[], status = 200) {
  const urls: URL[] = [];
  const fetchFn: FetchLike = async raw => {
    urls.push(new URL(raw));
    return { ok: status < 400, status, json: async () => ({ results }) };
  };
  const client = new TomTomClient('SECRETKEY', fetchFn, {
    minIntervalMs: 0,
    sleep: async () => undefined,
  });
  return { client, urls };
}

describe('TomTomClient.search', () => {
  it('asks for places as they are typed, in the US, with a location hint', async () => {
    const { client, urls } = fakeTomTom([hit()]);
    await client.search("raley's & co #1", { lat: 38.2383, lng: -122.0402 }, 4);
    const url = urls[0];
    expect(url.pathname).toBe(
      `/search/2/search/${encodeURIComponent("raley's & co #1")}.json`,
    );
    expect(url.searchParams.get('typeahead')).toBe('true');
    expect(url.searchParams.get('limit')).toBe('4');
    expect(url.searchParams.get('countrySet')).toBe('US');
    expect(url.searchParams.get('lat')).toBe('38.2383');
    expect(url.searchParams.get('lon')).toBe('-122.0402');
  });

  it('leaves the location hint out when there is none', async () => {
    const { client, urls } = fakeTomTom([hit()]);
    await client.search('sacramento');
    expect(urls[0].searchParams.has('lat')).toBe(false);
  });

  it('reads places, dropping any without a position or an address', async () => {
    const { client } = fakeTomTom([
      hit({ poi: { name: 'Sac State' } }),
      hit({ id: 'no-position', position: undefined }),
      hit({ id: 'no-address', address: undefined }),
    ]);
    const found = await client.search('sac');
    expect(found).toEqual([
      {
        id: 'id-1',
        poiName: 'Sac State',
        address: '6000 J Street, Sacramento, CA 95819',
        position: { lat: 38.56, lng: -121.42 },
      },
    ]);
  });

  it('fails without the key in the message', async () => {
    const { client } = fakeTomTom([], 500);
    const error = await client.search('sac').catch((e: Error) => e);
    expect((error as Error).message).toBe('TomTom request failed: HTTP 500');
    expect((error as Error).message).not.toContain('SECRETKEY');
  });
});

describe('TomTomPlaces', () => {
  it('shows a business by its name and an address by its first line', async () => {
    const { client } = fakeTomTom([
      hit({
        id: 'a',
        poi: { name: 'California State University, Sacramento' },
      }),
      hit({
        id: 'b',
        address: { freeformAddress: '700 Main Street, Suisun City, CA 94585' },
        position: { lat: 38.24, lon: -122.04 },
      }),
    ]);
    const places = await new TomTomPlaces(client).search('sac');
    expect(places).toEqual([
      {
        id: 'a',
        name: 'California State University, Sacramento',
        address: '6000 J Street, Sacramento, CA 95819',
        lat: 38.56,
        lng: -121.42,
      },
      {
        id: 'b',
        name: '700 Main Street',
        address: '700 Main Street, Suisun City, CA 94585',
        lat: 38.24,
        lng: -122.04,
      },
    ]);
  });

  it('drops duplicates and keeps at most five', async () => {
    const many = Array.from({ length: 12 }, (_, i) =>
      hit({
        id: `p${i}`,
        poi: { name: `Place ${i % 8}` },
        position: { lat: 38 + (i % 8) * 0.01, lon: -121 },
      }),
    );
    const places = await new TomTomPlaces(fakeTomTom(many).client).search(
      'place',
    );
    expect(places).toHaveLength(5);
    expect(new Set(places.map(p => p.name)).size).toBe(5);
  });

  it('asks for a few more than it keeps, to leave room for duplicates', async () => {
    const { client, urls } = fakeTomTom([hit()]);
    await new TomTomPlaces(client).search('sac');
    expect(urls[0].searchParams.get('limit')).toBe('8');
  });

  it('gives a failure of the service as a search error', async () => {
    const { client } = fakeTomTom([], 503);
    await expect(new TomTomPlaces(client).search('sac')).rejects.toBeInstanceOf(
      SearchError,
    );
  });
});
