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

const minutesBetween = (a: Date, b: Date): number =>
  Math.round((b.getTime() - a.getTime()) / 60_000);

const plural = (n: number, unit: string): string =>
  `${n} ${unit}${n === 1 ? '' : 's'}`;

const toOption = (slot: SlotPrediction): DepartureOption => ({
  departAt: slot.departAt,
  arriveAt: slot.arriveAt,
  driveMinutes: slot.driveMinutes,
});

/**
 * Turns predicted slots (slot 0 is "leave now") and the user's preferences
 * into a stay-or-go answer. Pure: no clock, network or storage access.
 */
export function decide(slots: SlotPrediction[], request: TripRequest): Verdict {
  const { now, preferences } = request;
  const { arriveBy: deadline } = preferences;
  const leaveNow = slots[0];
  const later = slots.slice(1);
  const waitOf = (s: SlotPrediction) => minutesBetween(now, s.departAt);
  const savedBy = (s: SlotPrediction) => leaveNow.driveMinutes - s.driveMinutes;
  const delayOf = (s: SlotPrediction) => waitOf(s) - savedBy(s);

  const build = (
    chosen: SlotPrediction,
    reason: string,
    extra: Partial<Verdict> = {},
  ): Verdict => {
    const isNow = chosen === leaveNow;
    const worst = [leaveNow, chosen].reduce((a, b) =>
      CONFIDENCE_RANK[b.confidence] < CONFIDENCE_RANK[a.confidence] ? b : a,
    );
    return {
      action: isNow ? 'leave_now' : 'wait',
      waitMinutes: isNow ? 0 : waitOf(chosen),
      reason,
      leaveNow: toOption(leaveNow),
      recommended: toOption(chosen),
      minutesSaved: isNow ? 0 : savedBy(chosen),
      arrivalDelayMinutes: isNow ? 0 : delayOf(chosen),
      confidence: worst.confidence,
      confidenceReason: worst.confidenceReason,
      generatedAt: now,
      ...extra,
    };
  };

  const meetsDeadline = (s: SlotPrediction) =>
    !deadline || s.arriveAt.getTime() <= deadline.getTime();
  const feasible = later.filter(meetsDeadline);

  if (!meetsDeadline(leaveNow)) {
    const earliest = feasible.find(
      s => waitOf(s) <= preferences.maxWaitMinutes,
    );
    if (earliest) {
      return build(
        earliest,
        `Leaving now would make you late. Waiting ${plural(
          waitOf(earliest),
          'minute',
        )} gets you there on time.`,
      );
    }
    const lateBy = minutesBetween(deadline as Date, leaveNow.arriveAt);
    return build(
      leaveNow,
      `Leave now, you may be late by about ${plural(lateBy, 'minute')}.`,
      { lateByMinutes: lateBy },
    );
  }

  const useDelayWeight =
    preferences.goal === 'balance' ||
    (preferences.goal === 'arrive_by' && !deadline);
  const score = (s: SlotPrediction) =>
    useDelayWeight
      ? savedBy(s) - BALANCE_DELAY_WEIGHT * delayOf(s)
      : savedBy(s);

  const best = (pool: SlotPrediction[]): SlotPrediction | undefined =>
    pool
      .filter(
        s =>
          savedBy(s) > 0 &&
          savedBy(s) >= preferences.minSavingsMinutes &&
          score(s) > 0,
      )
      .reduce<SlotPrediction | undefined>(
        (top, s) => (!top || score(s) > score(top) ? s : top),
        undefined,
      );

  const withinMaxWait = feasible.filter(
    s => waitOf(s) <= preferences.maxWaitMinutes,
  );
  const chosen = best(withinMaxWait);
  if (chosen) {
    const delay = delayOf(chosen);
    let arrival = 'you arrive at the same time';
    if (delay > 0) {
      arrival = `you arrive ${plural(delay, 'minute')} later`;
    } else if (delay < 0) {
      arrival = `you arrive ${plural(-delay, 'minute')} earlier`;
    }
    return build(
      chosen,
      `Wait ${plural(waitOf(chosen), 'minute')}: you'll save ${plural(
        savedBy(chosen),
        'minute',
      )} in traffic and ${arrival}.`,
    );
  }

  if (best(feasible)) {
    return build(
      leaveNow,
      `Waiting longer than your ${plural(
        preferences.maxWaitMinutes,
        'minute',
      )} maximum would help, but no shorter wait saves enough.`,
    );
  }

  const hours = Math.round(
    minutesBetween(now, slots[slots.length - 1].departAt) / 60,
  );
  return build(
    leaveNow,
    `Traffic won't improve much in the next ${plural(hours, 'hour')}.`,
  );
}
