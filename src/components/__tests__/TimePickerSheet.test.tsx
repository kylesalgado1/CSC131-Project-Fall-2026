import React from 'react';
import { ScrollView } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { ClockTime } from '../../lib/clockTime';
import {
  allText,
  hasText,
  press,
  pressExact,
  pressLabeled,
} from '../../testing';
import { ITEM_HEIGHT } from '../WheelColumn';
import { TimePickerSheet } from '../TimePickerSheet';

jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);

const NOW = new Date(2026, 9, 21, 7, 0, 0, 0);
type Props = React.ComponentProps<typeof TimePickerSheet>;

function open(over: Partial<Props> = {}) {
  const props: Props = {
    visible: true,
    title: 'Leave by',
    explanation: 'The latest you want to be on the road.',
    fallback: { hour: 7, minute: 30 },
    onSet: jest.fn(),
    onClear: jest.fn(),
    onClose: jest.fn(),
    now: () => NOW,
    ...over,
  };
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(<TimePickerSheet {...props} />);
  });
  // Looked up each time: opening the sheet again replaces the wheels.
  const wheelsNow = () => renderer.root.findAllByType(ScrollView);
  const wheels = wheelsNow();
  const selected = (i: number) => wheelsNow()[i].props.accessibilityValue.text;
  return {
    root: renderer.root,
    props,
    renderer,
    wheels,
    selected,
    rerender: (next: Partial<Props>) =>
      act(() => renderer.update(<TimePickerSheet {...props} {...next} />)),
  };
}

describe('TimePickerSheet', () => {
  it('has three wheels: hour, minute and AM or PM', () => {
    const { wheels } = open();
    expect(wheels.map(w => w.props.accessibilityLabel)).toEqual([
      'Hour',
      'Minute',
      'AM or PM',
    ]);
  });

  it('starts on the suggested time when nothing is set', () => {
    const { selected, root } = open({ fallback: { hour: 17, minute: 45 } });
    expect([selected(0), selected(1), selected(2)]).toEqual(['5', '45', 'PM']);
    expect(hasText(root, '5:45 PM today')).toBe(true);
  });

  it('starts on the time already set, not the suggestion', () => {
    const { selected } = open({
      current: { hour: 6, minute: 5 },
      fallback: { hour: 17, minute: 45 },
    });
    expect([selected(0), selected(1), selected(2)]).toEqual(['6', '05', 'AM']);
  });

  it('says what the time is for, and which day it will mean', () => {
    const { root } = open({
      title: 'Arrive by',
      explanation: 'The latest you need to get there.',
      current: { hour: 6, minute: 0 },
    });
    expect(allText(root)).toContain('Arrive by');
    expect(hasText(root, 'The latest you need to get there.')).toBe(true);
    expect(hasText(root, '6:00 AM tomorrow')).toBe(true); // already past at 7:00
  });

  it('follows the wheels, by tapping or scrolling', () => {
    const { root, wheels, selected } = open({
      current: { hour: 7, minute: 30 },
    });
    pressExact(root, '9');
    pressExact(root, 'PM');
    act(() =>
      wheels[1].props.onMomentumScrollEnd({
        nativeEvent: { contentOffset: { x: 0, y: 11 * ITEM_HEIGHT } },
      }),
    );
    expect([selected(0), selected(1), selected(2)]).toEqual(['9', '55', 'PM']);
    expect(hasText(root, '9:55 PM today')).toBe(true);
  });

  it('hands back the chosen time when set', () => {
    const { root, props } = open({ current: { hour: 7, minute: 30 } });
    pressExact(root, '8');
    pressExact(root, '15');
    pressExact(root, 'PM');
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenCalledWith({
      hour: 20,
      minute: 15,
    } as ClockTime);
  });

  it('can set a time with no scrolling at all', () => {
    const { root, props } = open({ fallback: { hour: 12, minute: 0 } });
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenCalledWith({ hour: 12, minute: 0 });
  });

  it('handles midnight and noon', () => {
    const { root, props } = open({ current: { hour: 1, minute: 0 } });
    pressExact(root, '12');
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenLastCalledWith({ hour: 0, minute: 0 });
    pressExact(root, 'PM');
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenLastCalledWith({ hour: 12, minute: 0 });
  });

  it('offers "Any time" only when a time is set, and clears it', () => {
    expect(allText(open().root)).not.toContain('Any time');
    const { root, props } = open({ current: { hour: 7, minute: 30 } });
    press(root, 'Any time');
    expect(props.onClear).toHaveBeenCalledTimes(1);
    expect(props.onSet).not.toHaveBeenCalled();
  });

  it('closes without changing anything on Cancel or a tap outside', () => {
    const { root, props } = open({ current: { hour: 7, minute: 30 } });
    pressExact(root, '9');
    press(root, 'Cancel');
    pressLabeled(root, 'Close without changing');
    expect(props.onClose).toHaveBeenCalledTimes(2);
    expect(props.onSet).not.toHaveBeenCalled();
  });

  it('forgets half-made choices each time it opens', () => {
    const { rerender, root, selected } = open({
      current: { hour: 7, minute: 30 },
    });
    pressExact(root, '11');
    expect(selected(0)).toBe('11');
    rerender({ visible: false });
    rerender({ visible: true });
    expect(selected(0)).toBe('7');
  });

  it('shows nothing when not visible', () => {
    expect(allText(open({ visible: false }).root)).toEqual([]);
  });
});
