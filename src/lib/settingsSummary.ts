import { formatDuration } from './format';
import { VerdictSettings } from './request';

/** One line saying what the preferences are, shown while they are folded away. */
export function summarizeSettings(settings: VerdictSettings): string {
  return [
    settings.maxWaitMinutes === undefined
      ? 'no wait limit'
      : `wait up to ${formatDuration(settings.maxWaitMinutes)}`,
    `only if it saves ${settings.minSavingsMinutes} min`,
  ].join(' · ');
}
