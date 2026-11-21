import { promises as fs } from 'fs';
import os from 'os';
import path from 'path';
import {
  DEFAULT_CAMPUS_BREAKS_FILE,
  loadCampusBreaks,
  parseCampusBreaks,
} from '../campusBreaks';

describe('parseCampusBreaks', () => {
  it('reads a list of breaks', () => {
    expect(
      parseCampusBreaks([
        { name: ' Spring break ', start: '2027-03-22', end: '2027-03-26' },
        { name: 'Closure day', start: '2026-12-24', end: '2026-12-24' },
      ]),
    ).toEqual([
      { name: 'Spring break', start: '2027-03-22', end: '2027-03-26' },
      { name: 'Closure day', start: '2026-12-24', end: '2026-12-24' },
    ]);
  });

  it('accepts February 29th in a leap year', () => {
    expect(
      parseCampusBreaks([
        { name: 'Leap', start: '2028-02-29', end: '2028-02-29' },
      ]),
    ).toHaveLength(1);
  });

  it('accepts an empty list', () => {
    expect(parseCampusBreaks([])).toEqual([]);
  });

  it.each([
    ['not a list', {}, /must be a list/],
    [
      'a missing name',
      [{ start: '2027-03-22', end: '2027-03-26' }],
      /Campus break 1 needs a name/,
    ],
    [
      'a blank name',
      [{ name: ' ', start: '2027-03-22', end: '2027-03-26' }],
      /needs a name/,
    ],
    [
      'a bad start',
      [{ name: 'X', start: '3/22/2027', end: '2027-03-26' }],
      /\("X"\) needs a start/,
    ],
    [
      'a start that is not a real date',
      [{ name: 'X', start: '2027-02-30', end: '2027-03-26' }],
      /needs a start/,
    ],
    [
      'a bad end',
      [{ name: 'X', start: '2027-03-22', end: 'later' }],
      /\("X"\) needs an end/,
    ],
    [
      'an end before the start',
      [{ name: 'X', start: '2027-03-26', end: '2027-03-22' }],
      /ends before it starts/,
    ],
    ['an entry that is not an object', [null], /needs a name/],
  ])('rejects %s', (_label, input, message) => {
    expect(() => parseCampusBreaks(input)).toThrow(message);
  });

  it('says which entry is wrong', () => {
    expect(() =>
      parseCampusBreaks([
        { name: 'Fine', start: '2027-03-22', end: '2027-03-26' },
        { name: 'Broken', start: 'nope', end: '2027-03-26' },
      ]),
    ).toThrow(/Campus break 2 \("Broken"\)/);
  });
});

describe('loadCampusBreaks', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'breaks-'));
  });
  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('reads a file', async () => {
    const file = path.join(dir, 'breaks.json');
    await fs.writeFile(
      file,
      JSON.stringify([{ name: 'B', start: '2027-03-22', end: '2027-03-26' }]),
    );
    expect(await loadCampusBreaks(file)).toEqual([
      { name: 'B', start: '2027-03-22', end: '2027-03-26' },
    ]);
  });

  it('treats a missing file as no breaks', async () => {
    expect(await loadCampusBreaks(path.join(dir, 'nothing.json'))).toEqual([]);
  });

  it('names the file when its contents are wrong', async () => {
    const file = path.join(dir, 'bad.json');
    await fs.writeFile(file, '[{"name":"B","start":"x","end":"y"}]');
    await expect(loadCampusBreaks(file)).rejects.toThrow(
      /bad\.json: Campus break 1/,
    );
    await fs.writeFile(file, '{not json');
    await expect(loadCampusBreaks(file)).rejects.toThrow(/bad\.json/);
  });

  it('ships a default file that the server can start with', async () => {
    const breaks = await loadCampusBreaks(DEFAULT_CAMPUS_BREAKS_FILE);
    expect(Array.isArray(breaks)).toBe(true);
    for (const b of breaks) {
      expect(b.end >= b.start).toBe(true);
    }
  });
});
