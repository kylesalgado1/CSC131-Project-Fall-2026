import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { allText, hasText, press } from '../../testing';
import { TimeLimitsCard } from '../TimeLimitsCard';

const NOW = new Date(2026, 9, 21, 7, 0, 0, 0);

function render(
  props: Partial<React.ComponentProps<typeof TimeLimitsCard>> = {},
) {
  const onEditLeaveAfter = jest.fn();
  const onEditLeaveBy = jest.fn();
  const onEditArriveBy = jest.fn();
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(
      <TimeLimitsCard
        onEditLeaveAfter={onEditLeaveAfter}
        onEditLeaveBy={onEditLeaveBy}
        onEditArriveBy={onEditArriveBy}
        now={() => NOW}
        {...props}
      />,
    );
  });
  return {
    root: renderer.root,
    onEditLeaveAfter,
    onEditLeaveBy,
    onEditArriveBy,
  };
}

describe('TimeLimitsCard', () => {
  it('shows "Any time" for all three until a time is set', () => {
    const { root } = render();
    expect(allText(root).filter(t => t === 'Any time')).toHaveLength(3);
    expect(allText(root)).toEqual(
      expect.arrayContaining(['Leave after', 'Leave by', 'Arrive by']),
    );
  });

  it('shows the times that are set', () => {
    const { root } = render({
      leaveAfter: { hour: 14, minute: 0 },
      leaveBy: { hour: 17, minute: 30 },
      arriveBy: { hour: 18, minute: 45 },
    });
    expect(allText(root)).toEqual(
      expect.arrayContaining(['2:00 PM', '5:30 PM', '6:45 PM']),
    );
    expect(allText(root)).not.toContain('Any time');
    expect(hasText(root, 'tomorrow')).toBe(false);
  });

  it('says tomorrow when a time has already passed today', () => {
    const { root } = render({ arriveBy: { hour: 6, minute: 0 } });
    expect(allText(root)).toContain('6:00 AM');
    expect(allText(root)).toContain('tomorrow');
  });

  it('says a leave-after time that has passed is ignored, not tomorrow', () => {
    const { root } = render({ leaveAfter: { hour: 6, minute: 0 } });
    expect(allText(root)).toContain('6:00 AM');
    expect(allText(root)).toContain('passed, ignored');
    expect(hasText(root, 'tomorrow')).toBe(false);
  });

  it('shows a leave-after time still ahead as today', () => {
    const { root } = render({ leaveAfter: { hour: 14, minute: 0 } });
    expect(hasText(root, 'ignored')).toBe(false);
    expect(hasText(root, 'tomorrow')).toBe(false);
  });

  it('opens the right chooser from each row', () => {
    const { root, onEditLeaveAfter, onEditLeaveBy, onEditArriveBy } = render();
    press(root, 'Leave after');
    expect(onEditLeaveAfter).toHaveBeenCalledTimes(1);
    expect(onEditLeaveBy).not.toHaveBeenCalled();
    press(root, 'Leave by');
    expect(onEditLeaveBy).toHaveBeenCalledTimes(1);
    expect(onEditArriveBy).not.toHaveBeenCalled();
    press(root, 'Arrive by');
    expect(onEditArriveBy).toHaveBeenCalledTimes(1);
  });
});
