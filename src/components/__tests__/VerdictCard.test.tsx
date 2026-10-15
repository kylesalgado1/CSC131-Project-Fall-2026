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
});
