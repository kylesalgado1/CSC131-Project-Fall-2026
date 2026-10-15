import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { sampleResponse, SampleKind } from '../../samples';
import { allText, hasText, press } from '../../testing';
import { VerdictCard } from '../VerdictCard';

const NOW = new Date('2026-10-21T14:00:00Z'); // 7:00 AM Pacific
const time = { locale: 'en-US', timeZone: 'America/Los_Angeles' };

function render(kind: SampleKind) {
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(
      <VerdictCard
        verdict={sampleResponse(kind, NOW).verdict}
        timeOptions={time}
      />,
    );
  });
  return renderer.root;
}

describe('VerdictCard', () => {
  it('shows a wait: the answer, both choices, the tradeoff and the heads-up', () => {
    const root = render('wait');
    const text = allText(root);
    expect(text).toContain('Wait 60 minutes');
    expect(text).toContain(
      "Wait 60 minutes: you'll save 32 minutes in traffic and you arrive 28 minutes later.",
    );
    // Both choices, with local times.
    expect(text).toEqual(
      expect.arrayContaining(['Leave 7:00 AM', 'Arrive 8:10 AM']),
    );
    expect(text).toEqual(
      expect.arrayContaining(['Leave 8:00 AM', 'Arrive 8:38 AM']),
    );
    expect(text).toContain('Save 32 minutes in the car');
    expect(text).toContain('Arrive 28 minutes later');
    expect(hasText(root, 'Light rain is expected')).toBe(true);
  });

  it('shows leaving now as a single choice with no tradeoff', () => {
    const root = render('leave_now');
    const text = allText(root);
    expect(text.filter(t => t === 'Leave now')).toHaveLength(2); // headline and choice
    expect(hasText(root, "Traffic won't improve much")).toBe(true);
    expect(hasText(root, 'Save ')).toBe(false);
    expect(hasText(root, 'late')).toBe(false);
  });

  it('warns when the user will be late', () => {
    const root = render('late');
    expect(hasText(root, 'You may arrive about 35 minutes late.')).toBe(true);
    expect(
      hasText(root, 'Leave now, you may be late by about 35 minutes.'),
    ).toBe(true);
  });

  it('shows the confidence level and explains it only when tapped', () => {
    const root = render('wait');
    expect(hasText(root, 'Medium confidence')).toBe(true);
    const reason =
      'Part of the history for this route is estimated, not measured.';
    expect(hasText(root, reason)).toBe(false);
    press(root, 'Medium confidence');
    expect(hasText(root, reason)).toBe(true);
    press(root, 'Medium confidence');
    expect(hasText(root, reason)).toBe(false);
  });

  it('labels each confidence level', () => {
    expect(hasText(render('leave_now'), 'High confidence')).toBe(true);
    expect(hasText(render('late'), 'Low confidence')).toBe(true);
  });

  it('shows a planned departure: the time, the room to spare and the latest time to go', () => {
    const base = sampleResponse('leave_now', NOW).verdict;
    const verdict = {
      ...base,
      action: 'leave_later' as const,
      waitMinutes: 240,
      reason: 'Your deadline is 6 hours away, so there is no rush.',
      recommended: {
        departAt: '2026-10-21T18:00:00.000Z',
        arriveAt: '2026-10-21T19:00:00.000Z',
        driveMinutes: 60,
      },
      deadline: {
        arriveBy: '2026-10-21T20:30:00.000Z',
        marginMinutes: 90,
        latestDeparture: {
          departAt: '2026-10-21T19:15:00.000Z',
          arriveAt: '2026-10-21T20:15:00.000Z',
          driveMinutes: 60,
        },
      },
    };
    let renderer!: ReactTestRenderer.ReactTestRenderer;
    act(() => {
      renderer = ReactTestRenderer.create(
        <VerdictCard verdict={verdict} timeOptions={time} />,
      );
    });
    const text = allText(renderer.root);
    expect(text).toContain('Leave at 11:00 AM');
    expect(text).toContain(
      'Your deadline is 6 hours away, so there is no rush.',
    );
    expect(text).toContain(
      'You would arrive 12:00 PM, 1 hr 30 min before your 1:30 PM deadline.',
    );
    expect(text).toContain('Latest you can leave and still make it: 12:15 PM.');
    expect(text).toEqual(expect.arrayContaining(['Leave now', 'Leave later']));
  });

  it('shows the room to spare under "Leave now" too', () => {
    const base = sampleResponse('leave_now', NOW).verdict;
    const verdict = {
      ...base,
      deadline: { arriveBy: '2026-10-21T20:30:00.000Z', marginMinutes: 330 },
    };
    let renderer!: ReactTestRenderer.ReactTestRenderer;
    act(() => {
      renderer = ReactTestRenderer.create(
        <VerdictCard verdict={verdict} timeOptions={time} />,
      );
    });
    expect(allText(renderer.root)).toContain(
      'You would arrive 7:56 AM, 5 hr 30 min before your 1:30 PM deadline.',
    );
  });
});
