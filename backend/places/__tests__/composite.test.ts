import { CompositePlaceSearch } from '../compositePlaces';
import { CachedPlaceSearch } from '../tomtomPlaces';
import { Place, PlaceSearch, SearchError } from '../types';

const place = (id: string, name: string, lat: number, lng: number): Place => ({
  id,
  name,
  address: `${name}, CA`,
  lat,
  lng,
});

const source = (places: Place[] | Error): PlaceSearch => ({
  search: jest.fn(async () => {
    if (places instanceof Error) {
      throw places;
    }
    return places;
  }),
});

const cafe = (n: number) => place(`c${n}`, `Cafe ${n}`, 38 + n / 10, -121);
const bar = (n: number) => place(`b${n}`, `Bar ${n}`, 37 + n / 10, -122);

describe('CompositePlaceSearch', () => {
  it('puts known short names first, then the search results', async () => {
    const search = new CompositePlaceSearch([source([cafe(1)])]);
    const found = await search.search('csus');
    expect(found.map(p => p.name)).toEqual(['Sacramento State', 'Cafe 1']);
  });

  it('takes the sources in turn so none crowds out the others', async () => {
    const search = new CompositePlaceSearch([
      source([cafe(1), cafe(2), cafe(3)]),
      source([bar(1), bar(2), bar(3)]),
    ]);
    expect((await search.search('zzz')).map(p => p.name)).toEqual([
      'Cafe 1',
      'Bar 1',
      'Cafe 2',
      'Bar 2',
      'Cafe 3',
    ]);
  });

  it('shows five at most, aliases counted', async () => {
    const search = new CompositePlaceSearch([
      source([cafe(1), cafe(2), cafe(3), cafe(4), cafe(5)]),
    ]);
    expect(await search.search('sac')).toHaveLength(5);
  });

  it('drops a result that is the same place as one already listed', async () => {
    const alias = (await new CompositePlaceSearch([]).search('csus'))[0];
    const search = new CompositePlaceSearch([
      source([
        // Same campus, a few metres away, named a little differently.
        place(
          't1',
          'California State University, Sacramento',
          alias.lat + 0.0005,
          alias.lng,
        ),
        // Same name, but a different town far away.
        place('t2', 'Sacramento State', 40, -120),
        cafe(1),
      ]),
      source([place('p1', 'Cafe 1', 38.1, -121)]),
    ]);
    // t1 is the campus again, t2 is far away, and c1 is p1 from the other source.
    expect((await search.search('csus')).map(p => p.id)).toEqual([
      'alias-sac-state',
      'p1',
      't2',
    ]);
  });

  it('keeps a different place that shares only one word with the campus', async () => {
    const alias = (await new CompositePlaceSearch([]).search('csus'))[0];
    const search = new CompositePlaceSearch([
      source([place('lib', 'Sac State Library', alias.lat + 0.001, alias.lng)]),
    ]);
    expect((await search.search('csus')).map(p => p.id)).toEqual([
      'alias-sac-state',
      'lib',
    ]);
  });

  it('keeps going when one source fails', async () => {
    const search = new CompositePlaceSearch([
      source(new SearchError('TomTom is down')),
      source([bar(1)]),
    ]);
    expect((await search.search('zzz')).map(p => p.name)).toEqual(['Bar 1']);
  });

  it('still answers a known name when every source fails', async () => {
    const search = new CompositePlaceSearch([
      source(new SearchError('down')),
      source(new SearchError('also down')),
    ]);
    expect((await search.search('ucla')).map(p => p.name)).toEqual(['UCLA']);
  });

  it('fails only when every source fails and nothing is known', async () => {
    const search = new CompositePlaceSearch([
      source(new SearchError('TomTom is down')),
      source(new SearchError('Photon is down')),
    ]);
    await expect(search.search('zzz')).rejects.toThrow('TomTom is down');
  });

  it('asks every source for the same text and location', async () => {
    const a = source([cafe(1)]);
    const b = source([bar(1)]);
    const near = { lat: 38.2, lng: -122 };
    await new CompositePlaceSearch([a, b]).search('coffee', near);
    expect(a.search).toHaveBeenCalledWith('coffee', near);
    expect(b.search).toHaveBeenCalledWith('coffee', near);
  });

  it('can be cached like any other search', async () => {
    const inner = source([cafe(1)]);
    const cached = new CachedPlaceSearch(new CompositePlaceSearch([inner]));
    await cached.search('coffee');
    await cached.search('Coffee ');
    expect(inner.search).toHaveBeenCalledTimes(1);
  });
});
