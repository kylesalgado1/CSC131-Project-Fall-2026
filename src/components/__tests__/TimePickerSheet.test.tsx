import React from 'react';
import { ScrollView } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
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

const labeled = (root: ReactTestRenderer.ReactTestInstance, label: string) =>
  root.findAll(
    node =>
      node.props.accessibilityLabel === label &&
      typeof node.props.onPress === 'function',
  )[0];

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
      date: '2026-10-21',
    });
  });

  it('can set a time with no scrolling at all', () => {
    const { root, props } = open({ fallback: { hour: 12, minute: 0 } });
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenCalledWith({
      hour: 12,
      minute: 0,
      date: '2026-10-21',
    });
  });

  it('handles midnight and noon', () => {
    const { root, props } = open({ current: { hour: 1, minute: 0 } });
    pressExact(root, '12');
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenLastCalledWith({
      hour: 0,
      minute: 0,
      date: '2026-10-22', // 1:00 AM has passed, so the sheet opens on tomorrow
    });
    pressExact(root, 'PM');
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenLastCalledWith({
      hour: 12,
      minute: 0,
      date: '2026-10-22',
    });
  });

  it('shows the day on a row, and opens a calendar when tapped', () => {
    const { root } = open({ current: { hour: 7, minute: 30 } });
    expect(hasText(root, 'Wed, Oct 21')).toBe(true);
    expect(allText(root)).not.toContain('October 2026');
    press(root, 'Day');
    expect(hasText(root, 'October 2026')).toBe(true);
  });

  it('picks a later day from the calendar and goes back to the wheels', () => {
    const { root, props, wheels } = open({ current: { hour: 7, minute: 30 } });
    press(root, 'Day');
    pressLabeled(root, 'Fri, Oct 23');
    expect(hasText(root, 'October 2026')).toBe(false);
    expect(hasText(root, '7:30 AM Fri, Oct 23')).toBe(true);
    expect(wheels).toHaveLength(3);
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenCalledWith({
      hour: 7,
      minute: 30,
      date: '2026-10-23',
    });
  });

  it('opens the calendar on the month already chosen', () => {
    const { root } = open({
      current: { hour: 9, minute: 0, date: '2026-12-24' },
    });
    expect(hasText(root, 'Thu, Dec 24')).toBe(true);
    press(root, 'Day');
    expect(hasText(root, 'December 2026')).toBe(true);
  });

  it('moves between months, but not before this one or past a year', () => {
    const { root } = open({ current: { hour: 7, minute: 30 } });
    press(root, 'Day');
    expect(labeled(root, 'Previous month').props.disabled).toBe(true);
    pressLabeled(root, 'Next month');
    expect(hasText(root, 'November 2026')).toBe(true);
    pressLabeled(root, 'Previous month');
    expect(hasText(root, 'October 2026')).toBe(true);
    for (let i = 0; i < 11; i++) {
      pressLabeled(root, 'Next month');
    }
    expect(hasText(root, 'September 2027')).toBe(true);
    expect(labeled(root, 'Next month').props.disabled).toBe(true);
  });

  it('does not let a day before today be chosen', () => {
    const { root } = open({ current: { hour: 7, minute: 30 } });
    press(root, 'Day');
    const yesterday = root.findAll(
      node => node.props.accessibilityLabel === 'Tue, Oct 20',
    )[0];
    expect(yesterday.props.disabled).toBe(true);
    const today = root.findAll(
      node => node.props.accessibilityLabel === 'Wed, Oct 21, today',
    )[0];
    expect(today.props.disabled).toBeFalsy();
  });

  it('warns that advice only plans 12 hours ahead for farther times', () => {
    const { root } = open({ current: { hour: 7, minute: 30 } });
    expect(allText(root).join(' ')).not.toMatch(/Advice plans up to/);
    press(root, 'Day');
    pressLabeled(root, 'Fri, Oct 23');
    expect(allText(root).join(' ')).toMatch(/Advice plans up to 12 hours/);
  });

  it('moves a time already past today to tomorrow', () => {
    const { root, props } = open({ current: { hour: 6, minute: 0 } });
    expect(hasText(root, '6:00 AM tomorrow')).toBe(true);
    press(root, 'Set leave by');
    expect(props.onSet).toHaveBeenCalledWith({
      hour: 6,
      minute: 0,
      date: '2026-10-22',
    });
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
