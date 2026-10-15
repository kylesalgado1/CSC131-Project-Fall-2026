import { minutesBetween } from '../util/time';
import { holidayName, LOCAL_TIME_ZONE, localTime } from './calendar';
import { rainLabel } from './providers/weather';
import {
  Confidence,
  DepartureOption,
  SlotPrediction,
  TripRequest,
  Verdict,
} from './types';

/**
 * In balance mode a minute of added arrival delay costs this fraction of a
 * minute saved in the car. A wait is only worth it when saved time outweighs
 * the weighted delay.
 */
export const BALANCE_DELAY_WEIGHT = 0.5;

const CONFIDENCE_RANK: Record<Confidence, number> = {
  High: 2,
  Medium: 1,
  Low: 0,
};

const plural = (n: number, unit: string): string =>
  `${n} ${unit}${n === 1 ? '' : 's'}`;

const toOption = ({
  departAt,
  arriveAt,
  driveMinutes,
}: SlotPrediction): DepartureOption => ({ departAt, arriveAt, driveMinutes });

/** How leaving at a slot compares with leaving now, in whole minutes. */
interface Timing {
  /** Minutes from now until departure. */
  wait: number;
  /** Minutes less spent driving. */
  saved: number;
  /** Minutes later the user arrives. Negative if they arrive earlier. */
  delay: number;
}

function timingOf(
  now: Date,
  leaveNow: SlotPrediction,
  slot: SlotPrediction,
): Timing {
  const wait = minutesBetween(now, slot.departAt);
  const saved = leaveNow.driveMinutes - slot.driveMinutes;
  return { wait, saved, delay: wait - saved };
}

function waitReason({ wait, saved, delay }: Timing): string {
  let arrival = 'you arrive at the same time';
  if (delay > 0) {
    arrival = `you arrive ${plural(delay, 'minute')} later`;
  } else if (delay < 0) {
    arrival = `you arrive ${plural(-delay, 'minute')} earlier`;
  }
  return (
    `Wait ${plural(wait, 'minute')}: you'll save ` +
    `${plural(saved, 'minute')} in traffic and ${arrival}.`
  );
}

/** Holiday and rain warnings shown with the verdict. */
function notesFor(
  now: Date,
  leaveNow: SlotPrediction,
  chosen: SlotPrediction,
): string[] {
  const notes: string[] = [];
  const holiday = holidayName(localTime(now, LOCAL_TIME_ZONE).date);
  if (holiday) {
    notes.push(`Today is ${holiday}, so traffic may differ from a normal day.`);
  }
  const rain = rainLabel(
    Math.max(leaveNow.weatherFactor ?? 1, chosen.weatherFactor ?? 1),
  );
  if (rain) {
    notes.push(`${rain} is expected, so drive times include extra delay.`);
  }
  return notes;
}

function buildVerdict(
  now: Date,
  leaveNow: SlotPrediction,
  chosen: SlotPrediction,
  reason: string,
  extra: Partial<Verdict> = {},
): Verdict {
  const isNow = chosen === leaveNow;
  const { wait, saved, delay } = timingOf(now, leaveNow, chosen);
  // The answer is only as trustworthy as the weaker of the two slots.
  const weakest =
    CONFIDENCE_RANK[chosen.confidence] < CONFIDENCE_RANK[leaveNow.confidence]
      ? chosen
      : leaveNow;
  return {
    action: isNow ? 'leave_now' : 'wait',
    waitMinutes: isNow ? 0 : wait,
    reason,
    leaveNow: toOption(leaveNow),
    recommended: toOption(chosen),
    minutesSaved: isNow ? 0 : saved,
    arrivalDelayMinutes: isNow ? 0 : delay,
    confidence: weakest.confidence,
    confidenceReason: weakest.confidenceReason,
    notes: notesFor(now, leaveNow, chosen),
    generatedAt: now,
    ...extra,
  };
}

/**
 * Turns predicted slots (slot 0 is "leave now") and the user's preferences
 * into a stay-or-go answer. Pure: no clock, network or storage access.
 */
export function decide(slots: SlotPrediction[], request: TripRequest): Verdict {
  const { now, preferences } = request;
  const { arriveBy: deadline, maxWaitMinutes, minSavingsMinutes } = preferences;
  const leaveNow = slots[0];

  const timing = (slot: SlotPrediction) => timingOf(now, leaveNow, slot);
  const verdict = (
    chosen: SlotPrediction,
    reason: string,
    extra?: Partial<Verdict>,
  ) => buildVerdict(now, leaveNow, chosen, reason, extra);
  const arrivesInTime = (slot: SlotPrediction) =>
    !deadline || slot.arriveAt.getTime() <= deadline.getTime();
  const withinMaxWait = (slot: SlotPrediction) =>
    timing(slot).wait <= maxWaitMinutes;

  const feasible = slots.slice(1).filter(arrivesInTime);

  // Leaving now misses the deadline: take the earliest wait that makes it,
  // or say how late the user will be.
  if (deadline && !arrivesInTime(leaveNow)) {
    const onTime = feasible.find(withinMaxWait);
    if (onTime) {
      return verdict(
        onTime,
        `Leaving now would make you late. Waiting ` +
          `${plural(timing(onTime).wait, 'minute')} gets you there on time.`,
      );
    }
    const lateBy = minutesBetween(deadline, leaveNow.arriveAt);
    return verdict(
      leaveNow,
      `Leave now, you may be late by about ${plural(lateBy, 'minute')}.`,
      { lateByMinutes: lateBy },
    );
  }

  // Balance trades time saved against arriving later; the other goals just
  // want the most time saved.
  const weighsDelay =
    preferences.goal === 'balance' ||
    (preferences.goal === 'arrive_by' && !deadline);
  const score = (slot: SlotPrediction) => {
    const { saved, delay } = timing(slot);
    return weighsDelay ? saved - BALANCE_DELAY_WEIGHT * delay : saved;
  };
  const worthWaiting = (slot: SlotPrediction) => {
    const { saved } = timing(slot);
    return saved > 0 && saved >= minSavingsMinutes && score(slot) > 0;
  };
  const bestOf = (pool: SlotPrediction[]) =>
    pool
      .filter(worthWaiting)
      .reduce<SlotPrediction | undefined>(
        (top, slot) => (!top || score(slot) > score(top) ? slot : top),
        undefined,
      );

  const chosen = bestOf(feasible.filter(withinMaxWait));
  if (chosen) {
    return verdict(chosen, waitReason(timing(chosen)));
  }
  if (bestOf(feasible)) {
    return verdict(
      leaveNow,
      `Waiting longer than your ${plural(maxWaitMinutes, 'minute')} maximum ` +
        'would help, but no shorter wait saves enough.',
    );
  }
  const hours = Math.round(
    minutesBetween(now, slots[slots.length - 1].departAt) / 60,
  );
  return verdict(
    leaveNow,
    `Traffic won't improve much in the next ${plural(hours, 'hour')}.`,
  );
}
