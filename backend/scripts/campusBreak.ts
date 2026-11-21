import { CampusBreak } from '../prediction/calendar';

/** Parses a `--break "name,start,end"` argument, dates as YYYY-MM-DD. */
export function parseCampusBreak(spec: string): CampusBreak {
  const [name, start, end] = spec.split(',').map(s => s.trim());
  if (!name || !start || !end) {
    throw new Error(`--break must be "name,start,end", got: ${spec}`);
  }
  return { name, start, end };
}
