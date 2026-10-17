import { formatDuration } from './format';
import { VerdictSettings } from './request';

const GOAL_LABEL = {
  balance: 'Balanced',
  minimize_time: 'Least driving',
  arrive_by: 'Arrive by',
} as const;

/** One line saying what the preferences are, shown while they are folded away. */
export function summarizeSettings(settings: VerdictSettings): string {
  return [
    GOAL_LABEL[settings.goal],
    settings.maxWaitMinutes === undefined
      ? 'no wait limit'
      : `wait up to ${formatDuration(settings.maxWaitMinutes)}`,
    `only if it saves ${settings.minSavingsMinutes} min`,
  ].join(' · ');
}
