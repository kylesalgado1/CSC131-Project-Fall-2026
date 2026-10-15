import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { allText, hasText, press } from '../../testing';
import { TimeLimitsCard } from '../TimeLimitsCard';

const NOW = new Date(2026, 9, 21, 7, 0, 0, 0);

function render(
  props: Partial<React.ComponentProps<typeof TimeLimitsCard>> = {},
) {
  const onEditLeaveBy = jest.fn();
  const onEditArriveBy = jest.fn();
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(
      <TimeLimitsCard
        onEditLeaveBy={onEditLeaveBy}
        onEditArriveBy={onEditArriveBy}
        now={() => NOW}
        {...props}
      />,
    );
  });
  return { root: renderer.root, onEditLeaveBy, onEditArriveBy };
}

describe('TimeLimitsCard', () => {
  it('shows "Any time" for both until a time is set', () => {
    const { root } = render();
    expect(allText(root).filter(t => t === 'Any time')).toHaveLength(2);
    expect(allText(root)).toEqual(
      expect.arrayContaining(['Leave by', 'Arrive by']),
    );
  });

  it('shows the times that are set', () => {
    const { root } = render({
      leaveBy: { hour: 17, minute: 30 },
      arriveBy: { hour: 18, minute: 45 },
    });
    expect(allText(root)).toEqual(
      expect.arrayContaining(['5:30 PM', '6:45 PM']),
    );
    expect(allText(root)).not.toContain('Any time');
    expect(hasText(root, 'tomorrow')).toBe(false);
  });

  it('says tomorrow when a time has already passed today', () => {
    const { root } = render({ arriveBy: { hour: 6, minute: 0 } });
    expect(allText(root)).toContain('6:00 AM');
    expect(allText(root)).toContain('tomorrow');
  });

  it('opens the right chooser from each row', () => {
    const { root, onEditLeaveBy, onEditArriveBy } = render();
    press(root, 'Leave by');
    expect(onEditLeaveBy).toHaveBeenCalledTimes(1);
    expect(onEditArriveBy).not.toHaveBeenCalled();
    press(root, 'Arrive by');
    expect(onEditArriveBy).toHaveBeenCalledTimes(1);
  });
});
