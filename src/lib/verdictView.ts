import { Verdict } from '../api/types';
import { formatDuration, formatTime, plural } from './format';

type TimeOptions = { locale?: string; timeZone?: string };

/**
 * True when the user cannot leave until later, so the earliest departure is
 * not now. "Now" and "wait 60 minutes" then mean nothing, and times are used.
 */
export function startsLater(verdict: Verdict): boolean {
  return (
    Date.parse(verdict.leaveNow.departAt) - Date.parse(verdict.generatedAt) >=
    60_000
  );
}

/** The answers the main screen can give. */
export function headline(verdict: Verdict, timeOptions?: TimeOptions): string {
  switch (verdict.action) {
    case 'leave_now':
      return startsLater(verdict)
        ? `Leave at ${formatTime(verdict.leaveNow.departAt, timeOptions)}`
        : 'Leave now';
    case 'no_rush':
      return 'No need to leave yet';
    case 'leave_later':
      return `Leave at ${formatTime(
        verdict.recommended.departAt,
        timeOptions,
      )}`;
    default:
      return startsLater(verdict)
        ? `Wait until ${formatTime(verdict.recommended.departAt, timeOptions)}`
        : `Wait ${plural(verdict.waitMinutes, 'minute')}`;
  }
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
  timeOptions?: TimeOptions,
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
  if (verdict.action === 'no_rush') {
    return []; // nothing to compare: the answer is that there is no rush
  }
  const now = view(
    startsLater(verdict) ? 'Earliest' : 'Leave now',
    verdict.leaveNow,
    verdict.action === 'leave_now',
  );
  if (verdict.action === 'leave_now') {
    return [now];
  }
  const title =
    verdict.action === 'leave_later' ? 'Leave later' : headline(verdict);
  return [now, view(title, verdict.recommended, true)];
}

/** The numbers behind a wait: minutes saved in the car and arriving later. */
export function tradeoffLines(verdict: Verdict): string[] {
  // A planned departure hours away is not a trade of time for time.
  if (verdict.action !== 'wait') {
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

/** Lines under the answer: room before the deadline, and the latest time to go. */
export function deadlineLines(
  verdict: Verdict,
  timeOptions?: TimeOptions,
): string[] {
  const { deadline } = verdict;
  if (!deadline) {
    return [];
  }
  const arrive = formatTime(verdict.recommended.arriveAt, timeOptions);
  const by = formatTime(deadline.arriveBy, timeOptions);
  const lines = [
    deadline.marginMinutes <= 0
      ? `You would arrive ${arrive}, right at your ${by} deadline.`
      : `You would arrive ${arrive}, ${formatDuration(
          deadline.marginMinutes,
        )} before your ${by} deadline.`,
  ];
  const latest = deadline.latestDeparture;
  const gap = latest
    ? (Date.parse(latest.departAt) - Date.parse(verdict.recommended.departAt)) /
      60_000
    : 0;
  if (latest && gap >= CHANGE_THRESHOLD_MINUTES) {
    lines.push(
      `Latest you can leave and still make it: ${formatTime(
        latest.departAt,
        timeOptions,
      )}.`,
    );
  }
  return lines;
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
  timeOptions?: TimeOptions,
): string | undefined {
  if (!previous) {
    return undefined;
  }
  if (next.action === 'no_rush') {
    // The recommended time just follows the clock, so only a flip is news.
    return previous.action === 'no_rush'
      ? undefined
      : 'Update: your deadline is far off, so there is no need to leave yet.';
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
    return startsLater(next)
      ? `Update: traffic changed, so you should leave at ${when}.`
      : 'Update: traffic changed, so you should leave now.';
  }
  if (next.action === 'leave_later' && flipped) {
    return `Update: the plan changed, so the best time to leave is ${when}.`;
  }
  return shift < 0 || flipped
    ? `Update: the best time to leave is now ${when}, ${
        shift < 0 ? 'earlier' : 'later'
      } than before.`
    : `Update: the best time to leave moved later, to ${when}.`;
}
