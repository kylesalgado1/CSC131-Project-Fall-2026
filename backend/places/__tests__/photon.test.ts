import { FetchLike } from '../../util/http';
import { PhotonPlaces } from '../photonPlaces';
import { SearchError } from '../types';

type Feature = {
  geometry?: { coordinates?: [number, number] };
  properties?: Record<string, unknown>;
};

const feature = (over: Feature = {}): Feature => ({
  geometry: { coordinates: [-121.4237, 38.5593] },
  properties: {
    osm_id: 42,
    osm_type: 'W',
    name: 'California State University, Sacramento',
    street: 'J Street',
    housenumber: '6000',
    city: 'Sacramento',
    state: 'California',
    postcode: '95819',
    countrycode: 'US',
  },
  ...over,
});

function fakePhoton(features: Feature[], status = 200) {
  const urls: URL[] = [];
  const fetchFn: FetchLike = async raw => {
    urls.push(new URL(raw));
    return { ok: status < 400, status, json: async () => ({ features }) };
  };
  return { fetchFn, urls };
}

describe('PhotonPlaces', () => {
  it('asks for a few extra places, in English, near the phone', async () => {
    const { fetchFn, urls } = fakePhoton([feature()]);
    await new PhotonPlaces('https://photon.test', fetchFn).search('sac state', {
      lat: 38.2383,
      lng: -122.0402,
    });
    const url = urls[0];
    expect(url.origin).toBe('https://photon.test');
    expect(url.pathname).toBe('/api/');
    expect(url.searchParams.get('q')).toBe('sac state');
    expect(url.searchParams.get('lang')).toBe('en');
    expect(url.searchParams.get('lat')).toBe('38.2383');
    expect(url.searchParams.get('lon')).toBe('-122.0402');
    expect(Number(url.searchParams.get('limit'))).toBeGreaterThan(5);
  });

  it('leaves the location out when there is none', async () => {
    const { fetchFn, urls } = fakePhoton([feature()]);
    await new PhotonPlaces('https://photon.test', fetchFn).search('sac');
    expect(urls[0].searchParams.has('lat')).toBe(false);
  });

  it('reads a place: name, one-line address, coordinates and a stable id', async () => {
    const { fetchFn } = fakePhoton([feature()]);
    const [place] = await new PhotonPlaces(
      'https://photon.test',
      fetchFn,
    ).search('sac');
    expect(place).toEqual({
      id: 'photon-W42',
      name: 'California State University, Sacramento',
      address: '6000 J Street, Sacramento, California 95819',
      lat: 38.5593,
      lng: -121.4237,
    });
  });

  it('names an address by its street when it has no name', async () => {
    const { fetchFn } = fakePhoton([
      feature({
        properties: {
          osm_id: 7,
          osm_type: 'N',
          housenumber: '733',
          street: 'Whispering Bay Lane',
          city: 'Suisun City',
          state: 'California',
          countrycode: 'US',
        },
      }),
    ]);
    const [place] = await new PhotonPlaces(
      'https://photon.test',
      fetchFn,
    ).search('733 whispering');
    expect(place.name).toBe('733 Whispering Bay Lane');
    expect(place.address).toBe(
      '733 Whispering Bay Lane, Suisun City, California',
    );
  });

  it('drops places outside the US, or without a position or a name', async () => {
    const { fetchFn } = fakePhoton([
      feature({ properties: { name: 'UCLA', countrycode: 'MX', osm_id: 1 } }),
      feature({ geometry: undefined }),
      feature({ properties: { countrycode: 'US', city: 'Davis', osm_id: 2 } }),
      feature(),
    ]);
    const places = await new PhotonPlaces(
      'https://photon.test',
      fetchFn,
    ).search('x');
    expect(places.map(p => p.id)).toEqual(['photon-W42']);
  });

  it('returns at most five places', async () => {
    const many = Array.from({ length: 12 }, (_, i) =>
      feature({
        properties: {
          osm_id: i,
          osm_type: 'N',
          name: `Cafe ${i}`,
          countrycode: 'US',
        },
        geometry: { coordinates: [-121 - i / 100, 38] },
      }),
    );
    const { fetchFn } = fakePhoton(many);
    expect(
      await new PhotonPlaces('https://photon.test', fetchFn).search('cafe'),
    ).toHaveLength(5);
  });

  it('says it failed on an error status, or when it cannot be reached', async () => {
    const down = fakePhoton([], 503);
    await expect(
      new PhotonPlaces('https://photon.test', down.fetchFn).search('x'),
    ).rejects.toThrow(new SearchError('Photon request failed: HTTP 503'));
    const unreachable: FetchLike = async () => {
      throw new TypeError('network down');
    };
    await expect(
      new PhotonPlaces('https://photon.test', unreachable).search('x'),
    ).rejects.toBeInstanceOf(SearchError);
  });
});
