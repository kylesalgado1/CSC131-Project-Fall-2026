import { sampleResponse, SampleKind } from '../samples';

const NOW = new Date('2026-10-21T14:00:00Z');
const kinds: SampleKind[] = ['wait', 'leave_now', 'late'];

describe.each(kinds)('sample "%s"', kind => {
  const { verdict, slots } = sampleResponse(kind, NOW);

  it('has 13 slots, 15 minutes apart, starting now', () => {
    expect(slots).toHaveLength(13);
    slots.forEach((slot, i) => {
      expect(Date.parse(slot.departAt)).toBe(NOW.getTime() + i * 15 * 60_000);
    });
    expect(verdict.generatedAt).toBe(NOW.toISOString());
  });

  it('has arrival times equal to departure plus drive time', () => {
    for (const slot of [...slots, verdict.leaveNow, verdict.recommended]) {
      expect(Date.parse(slot.arriveAt) - Date.parse(slot.departAt)).toBe(
        slot.driveMinutes * 60_000,
      );
    }
  });

  it('adds up: savings are the drive-time difference, delay is wait minus savings', () => {
    expect(verdict.minutesSaved).toBe(
      verdict.leaveNow.driveMinutes - verdict.recommended.driveMinutes,
    );
    expect(verdict.arrivalDelayMinutes).toBe(
      verdict.action === 'wait'
        ? verdict.waitMinutes - verdict.minutesSaved
        : 0,
    );
  });

  it('recommends the departure it says it does', () => {
    expect(Date.parse(verdict.recommended.departAt)).toBe(
      NOW.getTime() + verdict.waitMinutes * 60_000,
    );
  });
});

describe('sample states', () => {
  it('wait waits and mentions the wait in its reason', () => {
    const { verdict } = sampleResponse('wait', NOW);
    expect(verdict.action).toBe('wait');
    expect(verdict.reason).toContain(`Wait ${verdict.waitMinutes} minutes`);
    expect(verdict.reason).toContain(`save ${verdict.minutesSaved} minutes`);
    expect(verdict.notes.length).toBeGreaterThan(0);
  });

  it('leave_now leaves now with high confidence', () => {
    const { verdict } = sampleResponse('leave_now', NOW);
    expect(verdict).toMatchObject({
      action: 'leave_now',
      waitMinutes: 0,
      confidence: 'High',
    });
  });

  it('late is a late arrival with low confidence', () => {
    const { verdict } = sampleResponse('late', NOW);
    expect(verdict.lateByMinutes).toBeGreaterThan(0);
    expect(verdict.reason).toContain(`${verdict.lateByMinutes} minutes`);
    expect(verdict.confidence).toBe('Low');
  });

  it('follows the clock it is given', () => {
    const later = new Date(NOW.getTime() + 3_600_000);
    expect(sampleResponse('wait', later).verdict.leaveNow.departAt).toBe(
      later.toISOString(),
    );
  });
});
