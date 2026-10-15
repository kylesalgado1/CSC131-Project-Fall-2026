import { Verdict } from '../api/types';
import { formatTime, plural } from './format';

/** The two answers the main screen can give. */
export function headline(verdict: Verdict): string {
  return verdict.action === 'leave_now'
    ? 'Leave now'
    : `Wait ${plural(verdict.waitMinutes, 'minute')}`;
}

/** How the screen should feel: calm, informative, or a warning. */
export type Tone = 'go' | 'wait' | 'late';

export function toneOf(verdict: Verdict): Tone {
  if (verdict.lateByMinutes !== undefined) {
    return 'late';
  }
  return verdict.action === 'leave_now' ? 'go' : 'wait';
}

export interface OptionView {
  title: string;
  /** "Leave 7:05 AM" */
  leave: string;
  /** "Arrive 8:12 AM" */
  arrive: string;
  drive: string;
  recommended: boolean;
}

/** Leaving now and, when it differs, the recommended wait, side by side. */
export function optionViews(
  verdict: Verdict,
  timeOptions?: { locale?: string; timeZone?: string },
): OptionView[] {
  const view = (
    title: string,
    option: Verdict['leaveNow'],
    recommended: boolean,
  ): OptionView => ({
    title,
    leave: `Leave ${formatTime(option.departAt, timeOptions)}`,
    arrive: `Arrive ${formatTime(option.arriveAt, timeOptions)}`,
    drive: `${Math.round(option.driveMinutes)} min drive`,
    recommended,
  });
  const now = view(
    'Leave now',
    verdict.leaveNow,
    verdict.action === 'leave_now',
  );
  if (verdict.action === 'leave_now') {
    return [now];
  }
  return [now, view(headline(verdict), verdict.recommended, true)];
}

/** The numbers behind a wait: minutes saved in the car and arriving later. */
export function tradeoffLines(verdict: Verdict): string[] {
  if (verdict.action === 'leave_now') {
    return [];
  }
  const { minutesSaved, arrivalDelayMinutes } = verdict;
  const arrival =
    arrivalDelayMinutes > 0
      ? `Arrive ${plural(arrivalDelayMinutes, 'minute')} later`
      : arrivalDelayMinutes < 0
      ? `Arrive ${plural(-arrivalDelayMinutes, 'minute')} earlier`
      : 'Arrive at the same time';
  return [`Save ${plural(minutesSaved, 'minute')} in the car`, arrival];
}

const CHANGE_THRESHOLD_MINUTES = 5;

/**
 * A message when a refresh moves the recommended departure by 5 minutes or
 * more, or flips between leaving now and waiting. Undefined when it is the
 * same advice as before.
 */
export function departureChange(
  previous: Verdict | undefined,
  next: Verdict,
  timeOptions?: { locale?: string; timeZone?: string },
): string | undefined {
  if (!previous) {
    return undefined;
  }
  const shift =
    (Date.parse(next.recommended.departAt) -
      Date.parse(previous.recommended.departAt)) /
    60_000;
  const flipped = previous.action !== next.action;
  if (!flipped && Math.abs(shift) < CHANGE_THRESHOLD_MINUTES) {
    return undefined;
  }
  const when = formatTime(next.recommended.departAt, timeOptions);
  if (next.action === 'leave_now') {
    return 'Update: traffic changed, so you should leave now.';
  }
  return shift < 0 || flipped
    ? `Update: the best time to leave is now ${when}, ${
        shift < 0 ? 'earlier' : 'later'
      } than before.`
    : `Update: the best time to leave moved later, to ${when}.`;
}
