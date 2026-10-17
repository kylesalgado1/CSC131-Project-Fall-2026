import { matchAliases, normalize } from '../aliases';

const names = (query: string) => matchAliases(query).map(p => p.name);

describe('normalize', () => {
  it('lower-cases and drops punctuation', () => {
    expect(normalize("  Sac. State's  ")).toBe('sac state s');
    expect(normalize('SoFi-Stadium')).toBe('sofi stadium');
  });
});

describe('matchAliases', () => {
  it('finds Sac State however people say it', () => {
    for (const typed of [
      'sac state',
      'Sac State',
      'csus',
      'CSUS',
      'cal state sac',
      'sacramento state',
      'Sacramento State University',
      'csu sacramento',
    ]) {
      expect(names(typed)).toEqual(['Sacramento State']);
    }
  });

  it('matches as the name is typed, from three letters', () => {
    expect(names('sac st')).toEqual(['Sacramento State']);
    expect(names('csu')).toEqual(['Sacramento State']);
    expect(names('ucl')).toEqual(['UCLA']);
    expect(names('sof')).toEqual(['SoFi Stadium']);
  });

  it('does not match on one or two letters, or on random text', () => {
    expect(names('s')).toEqual([]);
    expect(names('sa')).toEqual([]);
    expect(names('pizza')).toEqual([]);
    expect(names('')).toEqual([]);
  });

  it('lists a place once even when several of its names match', () => {
    // "sac state", "sacramento state" and "sacramento airport" all start with "sac".
    const found = names('sac');
    expect(found.filter(n => n === 'Sacramento State')).toHaveLength(1);
    expect(found).toContain('Sacramento International Airport (SMF)');
  });

  it('knows a short name exactly, even under three letters', () => {
    expect(names('usc')).toEqual(['University of Southern California']);
    expect(names('sfo')).toEqual(['San Francisco International Airport (SFO)']);
  });

  it('gives each place a stable id, a street address and coordinates', () => {
    const [place] = matchAliases('ucla');
    expect(place).toMatchObject({
      id: 'alias-ucla',
      name: 'UCLA',
      lat: expect.any(Number),
      lng: expect.any(Number),
    });
    expect(place.address).toMatch(/Los Angeles/);
  });

  it('does not run on to a longer search the user is typing', () => {
    expect(names('ucla library')).toEqual([]);
  });
});
