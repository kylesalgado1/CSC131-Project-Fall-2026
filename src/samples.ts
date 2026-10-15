import {
  Confidence,
  DepartureOption,
  Slot,
  Verdict,
  VerdictResponse,
} from './api/types';

export type SampleKind = 'wait' | 'leave_now' | 'late';

export const SAMPLE_LABELS: Record<SampleKind, string> = {
  wait: 'Wait',
  leave_now: 'Leave now',
  late: 'Running late',
};

const MINUTE = 60_000;
const at = (now: Date, minutes: number) =>
  new Date(now.getTime() + minutes * MINUTE).toISOString();

function slotsFor(
  now: Date,
  drives: number[],
  confidence: Confidence,
  confidenceReason: string,
): Slot[] {
  return drives.map((driveMinutes, i) => ({
    departAt: at(now, i * 15),
    driveMinutes,
    arriveAt: at(now, i * 15 + driveMinutes),
    confidence,
    confidenceReason,
  }));
}

const option = (now: Date, wait: number, drive: number): DepartureOption => ({
  departAt: at(now, wait),
  arriveAt: at(now, wait + drive),
  driveMinutes: drive,
});

/**
 * Made-up answers for demos. Real traffic rarely says "wait", so these show
 * every state the screen can be in. Times are relative to `now`, so they
 * always look current.
 */
export function sampleResponse(kind: SampleKind, now: Date): VerdictResponse {
  const base = { generatedAt: now.toISOString() };

  if (kind === 'wait') {
    // Congested for the first hour, then clearing.
    const drives = [70, 66, 60, 52, 44, 39, 38, 38, 38, 38, 38, 38, 38];
    const reason = 'Based on plenty of historical data and live traffic.';
    const verdict: Verdict = {
      ...base,
      action: 'wait',
      waitMinutes: 60,
      reason:
        "Wait 60 minutes: you'll save 32 minutes in traffic and you arrive 28 minutes later.",
      leaveNow: option(now, 0, 70),
      recommended: option(now, 60, 38),
      minutesSaved: 32,
      arrivalDelayMinutes: 28,
      confidence: 'Medium',
      confidenceReason:
        'Part of the history for this route is estimated, not measured.',
      notes: ['Light rain is expected, so drive times include extra delay.'],
    };
    return { verdict, slots: slotsFor(now, drives, 'Medium', reason) };
  }

  if (kind === 'late') {
    const drives = Array(13).fill(62);
    const verdict: Verdict = {
      ...base,
      action: 'leave_now',
      waitMinutes: 0,
      reason: 'Leave now, you may be late by about 35 minutes.',
      leaveNow: option(now, 0, 62),
      recommended: option(now, 0, 62),
      minutesSaved: 0,
      arrivalDelayMinutes: 0,
      lateByMinutes: 35,
      confidence: 'Low',
      confidenceReason: 'An incident on your route could change this estimate.',
      notes: [],
    };
    return {
      verdict,
      slots: slotsFor(now, drives, 'Low', verdict.confidenceReason),
    };
  }

  const drives = [56, 56, 57, 57, 57, 58, 58, 58, 57, 57, 56, 56, 56];
  const verdict: Verdict = {
    ...base,
    action: 'leave_now',
    waitMinutes: 0,
    reason: "Traffic won't improve much in the next 3 hours.",
    leaveNow: option(now, 0, 56),
    recommended: option(now, 0, 56),
    minutesSaved: 0,
    arrivalDelayMinutes: 0,
    confidence: 'High',
    confidenceReason: 'Based on plenty of historical data and live traffic.',
    notes: [],
  };
  return {
    verdict,
    slots: slotsFor(now, drives, 'High', verdict.confidenceReason),
  };
}
