import { minutesBetween } from '../util/time';
import { HORIZON_MINUTES, MAX_PLAN_MINUTES } from './predict';
import { rainLabel } from './providers/weather';
import {
  Confidence,
  DepartureOption,
  Goal,
  Preferences,
  SlotPrediction,
  TripRequest,
  Verdict,
} from './types';

/**
 * With an Arrive by goal but no deadline, a minute of added arrival delay
 * costs this fraction of a minute saved in the car. A wait is only worth it
 * when saved time outweighs the weighted delay.
 */
export const ARRIVAL_DELAY_WEIGHT = 0.5;

/**
 * When a far-off deadline is planned for, aim to arrive this many minutes
 * early rather than at the last possible moment.
 */
export const PLAN_BUFFER_MINUTES = 10;
/** For the fastest-drive plan, drive times this close count as equal. */
const PLAN_TIE_MINUTES = 2;
/**
 * With a deadline and steady traffic, leaving now is only advised when the
 * time left before the latest departure is shorter than this. With more
 * slack than this, the answer is that there is no rush.
 */
export const NO_RUSH_SLACK_MINUTES = 30;

const CONFIDENCE_RANK: Record<Confidence, number> = {
  High: 2,
  Medium: 1,
  Low: 0,
};

const plural = (n: number, unit: string): string =>
  `${n} ${unit}${n === 1 ? '' : 's'}`;

/** "45 minutes", "1 hour", "2 hr 15 min". */
const duration = (minutes: number): string => {
  if (minutes < 60) {
    return plural(minutes, 'minute');
  }
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest === 0 ? plural(hours, 'hour') : `${hours} hr ${rest} min`;
};

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
function notesFor(leaveNow: SlotPrediction, chosen: SlotPrediction): string[] {
  const notes: string[] = [];
  if (leaveNow.holiday) {
    notes.push(
      `Today is ${leaveNow.holiday}, so traffic may differ from a normal day.`,
    );
  } else if (chosen.holiday) {
    notes.push(
      `Leaving then falls on ${chosen.holiday}, so traffic may differ from a normal day.`,
    );
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
    notes: notesFor(leaveNow, chosen),
    generatedAt: now,
    ...extra,
  };
}

/**
 * The departure to recommend for a far-off deadline, from the options that
 * arrive in time with room to spare: the latest one, or for a least-driving
 * goal the one with the shortest drive if it saves enough over leaving now.
 */
function planFor(
  options: SlotPrediction[],
  leaveNow: SlotPrediction,
  minSavings: number,
  goal: Goal,
): SlotPrediction | undefined {
  if (goal !== 'minimize_time') {
    return options[options.length - 1];
  }
  const shortest = Math.min(...options.map(s => s.driveMinutes));
  const best = options.filter(
    s => s.driveMinutes <= shortest + PLAN_TIE_MINUTES,
  );
  const pick = best[best.length - 1];
  return pick && leaveNow.driveMinutes - pick.driveMinutes >= minSavings
    ? pick
    : undefined;
}

/** Everything the decision steps need, worked out once per decision. */
interface Decision {
  now: Date;
  preferences: Preferences;
  slots: SlotPrediction[];
  leaveNow: SlotPrediction;
  deadline?: Date;
  leaveBy?: Date;
  maxWaitMinutes?: number;
  minSavingsMinutes: number;
  /**
   * The last departure that still makes the deadline, when the forecast runs
   * past it so we can tell it is the last.
   */
  latest?: SlotPrediction;
  /** Later departures that arrive in time. */
  feasible: SlotPrediction[];
  timing(slot: SlotPrediction): Timing;
  arrivesInTime(slot: SlotPrediction): boolean;
  departsInTime(slot: SlotPrediction): boolean;
  withinMaxWait(slot: SlotPrediction): boolean;
  waitAllowed(slot: SlotPrediction): boolean;
  /** The answer for a chosen departure, with the deadline's details added. */
  verdict(
    chosen: SlotPrediction,
    reason: string,
    extra?: Partial<Verdict>,
  ): Verdict;
  /** No departure is worth recommending; here is the window to leave in. */
  noRush(reason: string, windowEnd: SlotPrediction): Verdict;
}

function decisionFor(
  slots: SlotPrediction[],
  { now, preferences }: TripRequest,
): Decision {
  const {
    arriveBy: deadline,
    leaveBy,
    maxWaitMinutes,
    minSavingsMinutes,
  } = preferences;
  const leaveNow = slots[0];
  const arrivesInTime = (slot: SlotPrediction) =>
    !deadline || slot.arriveAt.getTime() <= deadline.getTime();
  const lastOnTime = slots.filter(arrivesInTime).pop();
  const latest =
    deadline && lastOnTime && lastOnTime !== slots[slots.length - 1]
      ? lastOnTime
      : undefined;
  const timing = (slot: SlotPrediction) => timingOf(now, leaveNow, slot);
  const withinMaxWait = (slot: SlotPrediction) =>
    maxWaitMinutes === undefined || timing(slot).wait <= maxWaitMinutes;
  const departsInTime = (slot: SlotPrediction) =>
    !leaveBy || slot.departAt.getTime() <= leaveBy.getTime();

  return {
    now,
    preferences,
    slots,
    leaveNow,
    deadline,
    leaveBy,
    maxWaitMinutes,
    minSavingsMinutes,
    latest,
    feasible: slots.slice(1).filter(arrivesInTime),
    timing,
    arrivesInTime,
    departsInTime,
    withinMaxWait,
    waitAllowed: slot => withinMaxWait(slot) && departsInTime(slot),
    verdict(chosen, reason, extra) {
      const built = buildVerdict(now, leaveNow, chosen, reason, extra);
      if (!deadline || !arrivesInTime(chosen)) {
        return built;
      }
      return {
        ...built,
        deadline: {
          arriveBy: deadline,
          marginMinutes: minutesBetween(chosen.arriveAt, deadline),
          ...(latest ? { latestDeparture: toOption(latest) } : {}),
        },
      };
    },
    noRush(reason, windowEnd) {
      return buildVerdict(now, leaveNow, leaveNow, reason, {
        action: 'no_rush',
        notes: [],
        deadline: {
          arriveBy: deadline!,
          marginMinutes: minutesBetween(leaveNow.arriveAt, deadline!),
          latestDeparture: toOption(windowEnd),
        },
      });
    },
  };
}

/** One rule of the decision: an answer, or undefined to try the next rule. */
type Step = (d: Decision) => Verdict | undefined;

/**
 * The best slot among a pool worth waiting for. An Arrive by goal with no
 * deadline to check against trades time saved against arriving later. With a
 * deadline, or for least driving, the goal is just the most time saved,
 * among departures that still arrive in time.
 */
function bestOf(
  d: Decision,
  pool: SlotPrediction[],
): SlotPrediction | undefined {
  const weighsDelay = d.preferences.goal === 'arrive_by' && !d.deadline;
  const score = (slot: SlotPrediction) => {
    const { saved, delay } = d.timing(slot);
    return weighsDelay ? saved - ARRIVAL_DELAY_WEIGHT * delay : saved;
  };
  const worthWaiting = (slot: SlotPrediction) => {
    const { saved } = d.timing(slot);
    return saved > 0 && saved >= d.minSavingsMinutes && score(slot) > 0;
  };
  return pool
    .filter(worthWaiting)
    .reduce<SlotPrediction | undefined>(
      (top, slot) => (!top || score(slot) > score(top) ? slot : top),
      undefined,
    );
}

/**
 * Leaving now misses the deadline: take the earliest wait that makes it, or
 * say how late the user will be.
 */
const missesDeadline: Step = d => {
  const { deadline, leaveNow } = d;
  if (!deadline || d.arrivesInTime(leaveNow)) {
    return undefined;
  }
  const onTime = d.feasible.find(d.waitAllowed);
  if (onTime) {
    return d.verdict(
      onTime,
      `Leaving now would make you late. Waiting ` +
        `${plural(d.timing(onTime).wait, 'minute')} gets you there on time.`,
    );
  }
  const lateBy = minutesBetween(deadline, leaveNow.arriveAt);
  return d.verdict(
    leaveNow,
    `Leave now, you may be late by about ${plural(lateBy, 'minute')}.`,
    { lateByMinutes: lateBy },
  );
};

/**
 * A deadline past the end of the forecast cannot be planned yet. Saying
 * "leave now" would be wrong, since there is no reason to go early, so say
 * that there is no rush and when a plan will be possible.
 */
const deadlineTooFar: Step = d => {
  const { now, deadline, leaveNow } = d;
  if (
    !deadline ||
    d.latest ||
    !d.arrivesInTime(leaveNow) ||
    minutesBetween(now, deadline) <= HORIZON_MINUTES
  ) {
    return undefined;
  }
  const planAfter = Math.max(
    0,
    minutesBetween(now, deadline) - MAX_PLAN_MINUTES - leaveNow.driveMinutes,
  );
  return buildVerdict(
    now,
    leaveNow,
    leaveNow,
    `Your deadline is ${duration(minutesBetween(now, deadline))} away, ` +
      `too far ahead to plan a departure. There is no need to leave yet. ` +
      `A plan will appear once the deadline is within ${duration(
        MAX_PLAN_MINUTES,
      )}, in about ${duration(planAfter)}.`,
    { action: 'no_rush', notes: [] },
  );
};

/**
 * A deadline beyond the usual forecast is a question of when to leave, not
 * whether to wait a little, so the answer is a departure time, however far
 * off. The wait limit does not apply; the leave-by time still does.
 */
const plannedDeparture: Step = d => {
  const { now, deadline, leaveNow, latest, leaveBy, minSavingsMinutes } = d;
  if (
    !deadline ||
    !latest ||
    !d.arrivesInTime(leaveNow) ||
    minutesBetween(now, deadline) <= HORIZON_MINUTES
  ) {
    return undefined;
  }
  const goal = d.preferences.goal;
  const early = d.slots
    .slice(1)
    .filter(s => minutesBetween(s.arriveAt, deadline) >= PLAN_BUFFER_MINUTES);
  const options = early.filter(d.departsInTime);
  const planned = planFor(options, leaveNow, minSavingsMinutes, goal);

  if (planned) {
    const wait = d.timing(planned).wait;
    const room = minutesBetween(planned.arriveAt, deadline);
    const held =
      leaveBy &&
      goal !== 'minimize_time' &&
      planned !== early[early.length - 1];
    const reason =
      goal === 'minimize_time'
        ? `Traffic is lightest if you leave in ${duration(wait)}: ` +
          `${plural(planned.driveMinutes, 'minute')} of driving instead ` +
          `of ${leaveNow.driveMinutes}.`
        : `Your deadline is ${duration(minutesBetween(now, deadline))} ` +
          `away, so there is no rush. Leaving in ${duration(wait)} still ` +
          `gets you there with ${duration(room)} to spare.` +
          (held ? ' That is as late as your leave-by time allows.' : '');
    return d.verdict(planned, reason, { action: 'leave_later' });
  }

  // The least-driving goal found nothing that saves enough, but waiting would
  // save a little: leaving now is not better, so say there is no rush and
  // give the window rather than "Leave now".
  const quietest = options.length
    ? Math.min(...options.map(s => s.driveMinutes))
    : undefined;
  const bestSaving =
    quietest === undefined ? 0 : leaveNow.driveMinutes - quietest;
  if (bestSaving > 0) {
    return d.noRush(
      `Waiting would save at most ${plural(bestSaving, 'minute')} of ` +
        `driving, under your ${plural(minSavingsMinutes, 'minute')} ` +
        `minimum, so when you leave hardly matters. Your deadline is ` +
        `${duration(minutesBetween(now, deadline))} away, so there is no ` +
        `need to leave yet.`,
      latest,
    );
  }
  return undefined;
};

/** The best wait that is allowed and saves enough. */
const bestWait: Step = d => {
  const chosen = bestOf(d, d.feasible.filter(d.waitAllowed));
  return chosen ? d.verdict(chosen, waitReason(d.timing(chosen))) : undefined;
};

/** A wait would help, but the user's own limits rule it out. */
const waitBlocked: Step = d => {
  if (d.leaveBy && bestOf(d, d.feasible.filter(d.withinMaxWait))) {
    return d.verdict(
      d.leaveNow,
      'Waiting longer would save more, but that is past your leave-by time.',
    );
  }
  if (d.maxWaitMinutes !== undefined && bestOf(d, d.feasible)) {
    return d.verdict(
      d.leaveNow,
      `Waiting longer than your ${plural(d.maxWaitMinutes, 'minute')} ` +
        'maximum would help, but no shorter wait saves enough.',
    );
  }
  return undefined;
};

/**
 * With a deadline, the time left before the latest departure, and how much
 * heavier traffic gets over it. Undefined without a deadline, or when a
 * leave-by time cuts the window short.
 */
function leaveWindow(d: Decision) {
  const { now, deadline, latest, leaveBy, leaveNow } = d;
  if (
    !deadline ||
    !latest ||
    (leaveBy && leaveBy.getTime() < latest.departAt.getTime())
  ) {
    return undefined;
  }
  const worstLater = Math.max(
    ...d.slots
      .filter(s => s.departAt.getTime() <= latest.departAt.getTime())
      .map(s => s.driveMinutes),
  );
  return {
    windowEnd: latest,
    slack: minutesBetween(now, latest.departAt),
    worstLater,
    heavierLater: worstLater - leaveNow.driveMinutes,
  };
}

/**
 * Steady traffic and a deadline with room to spare: leaving now is not
 * better than leaving later, so say there is no rush and give the window.
 */
const steadyTraffic: Step = d => {
  const window = leaveWindow(d);
  if (
    !window ||
    window.slack < NO_RUSH_SLACK_MINUTES ||
    window.heavierLater >= d.minSavingsMinutes
  ) {
    return undefined;
  }
  return d.noRush(
    `Traffic is steady, so waiting will not cut your driving much. ` +
      `You have ${duration(window.slack)} before you need to leave to make ` +
      `your deadline, so there is no need to go yet.`,
    window.windowEnd,
  );
};

/** Traffic gets noticeably heavier before the deadline: go now. */
const trafficBuilds: Step = d => {
  const window = leaveWindow(d);
  if (!window || window.heavierLater < d.minSavingsMinutes) {
    return undefined;
  }
  return d.verdict(
    d.leaveNow,
    `Traffic builds later, up to ${plural(window.worstLater, 'minute')} of ` +
      `driving instead of ${d.leaveNow.driveMinutes}, so leaving now is best.`,
  );
};

/** The rules, tried in order. The first that has an answer wins. */
const STEPS: Step[] = [
  missesDeadline,
  deadlineTooFar,
  plannedDeparture,
  bestWait,
  waitBlocked,
  steadyTraffic,
  trafficBuilds,
];

/**
 * Turns predicted slots (slot 0 is "leave now") and the user's preferences
 * into a stay-or-go answer. Pure: no clock, network or storage access.
 */
export function decide(slots: SlotPrediction[], request: TripRequest): Verdict {
  const d = decisionFor(slots, request);
  for (const step of STEPS) {
    const answer = step(d);
    if (answer) {
      return answer;
    }
  }
  const hours = Math.round(
    minutesBetween(d.now, slots[slots.length - 1].departAt) / 60,
  );
  return d.verdict(
    d.leaveNow,
    `Traffic won't improve much in the next ${plural(hours, 'hour')}.`,
  );
}
