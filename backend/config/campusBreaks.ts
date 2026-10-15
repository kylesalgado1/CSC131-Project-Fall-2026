import { promises as fs } from 'fs';
import path from 'path';
import { CampusBreak } from '../prediction/calendar';

export const DEFAULT_CAMPUS_BREAKS_FILE = path.join(
  __dirname,
  'campus-breaks.json',
);

/** True for a real calendar day written as YYYY-MM-DD, so not 2027-02-30. */
const isRealDate = (iso: string): boolean => {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) {
    return false;
  }
  const [year, month, day] = match.slice(1).map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
};

/**
 * Checks a list of campus breaks, such as spring break, read from JSON. Each
 * is `{ "name": "...", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" }`, both
 * days included. Throws a message saying which entry is wrong.
 */
export function parseCampusBreaks(json: unknown): CampusBreak[] {
  if (!Array.isArray(json)) {
    throw new Error('Campus breaks must be a list.');
  }
  return json.map((entry, i) => {
    const where = `Campus break ${i + 1}`;
    const { name, start, end } = (entry ?? {}) as Record<string, unknown>;
    if (typeof name !== 'string' || name.trim() === '') {
      throw new Error(`${where} needs a name.`);
    }
    if (typeof start !== 'string' || !isRealDate(start)) {
      throw new Error(`${where} ("${name}") needs a start like 2027-03-22.`);
    }
    if (typeof end !== 'string' || !isRealDate(end)) {
      throw new Error(`${where} ("${name}") needs an end like 2027-03-26.`);
    }
    if (end < start) {
      throw new Error(`${where} ("${name}") ends before it starts.`);
    }
    return { name: name.trim(), start, end };
  });
}

/** Reads the campus breaks file. A missing file means no breaks. */
export async function loadCampusBreaks(
  file: string = DEFAULT_CAMPUS_BREAKS_FILE,
): Promise<CampusBreak[]> {
  let text: string;
  try {
    text = await fs.readFile(file, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return [];
    }
    throw error;
  }
  try {
    return parseCampusBreaks(JSON.parse(text));
  } catch (error) {
    throw new Error(`${file}: ${(error as Error).message}`);
  }
}
