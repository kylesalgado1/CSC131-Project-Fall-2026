import { ScrollView } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { pressExact } from '../../testing';
import { ITEM_HEIGHT, WheelColumn } from '../WheelColumn';

const ITEMS = ['1', '2', '3', '4', '5', '6'];

function render(selectedIndex = 1, onChange = jest.fn()) {
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(
      <WheelColumn
        label="Hour"
        items={ITEMS}
        selectedIndex={selectedIndex}
        onChange={onChange}
        width={80}
      />,
    );
  });
  const scroll = renderer.root.findByType(ScrollView);
  const scrollTo = jest
    .spyOn(scroll.instance as unknown as { scrollTo: () => void }, 'scrollTo')
    .mockImplementation(() => undefined);
  const event = (y: number, velocity?: number) => ({
    nativeEvent: {
      contentOffset: { x: 0, y },
      velocity: velocity === undefined ? undefined : { x: 0, y: velocity },
    },
  });
  return { root: renderer.root, scroll, scrollTo, onChange, event };
}

describe('WheelColumn', () => {
  it('starts with the chosen value under the band', () => {
    const { scroll } = render(3);
    expect(scroll.props.contentOffset).toEqual({ x: 0, y: 3 * ITEM_HEIGHT });
    expect(scroll.props.snapToInterval).toBe(ITEM_HEIGHT);
  });

  it('moves to the chosen value once its contents are measured, which Android needs', () => {
    const { scroll, scrollTo } = render(2);
    act(() => scroll.props.onContentSizeChange());
    expect(scrollTo).toHaveBeenCalledWith({
      y: 2 * ITEM_HEIGHT,
      animated: false,
    });
  });

  it('settles on the nearest value when a scroll ends, and says which', () => {
    const { scroll, scrollTo, onChange, event } = render(1);
    act(() => scroll.props.onMomentumScrollEnd(event(3 * ITEM_HEIGHT + 10)));
    expect(onChange).toHaveBeenCalledWith(3);
    expect(scrollTo).toHaveBeenCalledWith({
      y: 3 * ITEM_HEIGHT,
      animated: true,
    });
  });

  it('rounds to whichever value is nearer', () => {
    const { scroll, onChange, event } = render(0);
    act(() =>
      scroll.props.onMomentumScrollEnd(
        event(2 * ITEM_HEIGHT + ITEM_HEIGHT * 0.4),
      ),
    );
    expect(onChange).toHaveBeenLastCalledWith(2);
    act(() =>
      scroll.props.onMomentumScrollEnd(
        event(2 * ITEM_HEIGHT + ITEM_HEIGHT * 0.6),
      ),
    );
    expect(onChange).toHaveBeenLastCalledWith(3);
  });

  it('never goes past either end, however far it was thrown', () => {
    const { scroll, onChange, event } = render(2);
    act(() => scroll.props.onMomentumScrollEnd(event(-500)));
    expect(onChange).toHaveBeenLastCalledWith(0);
    act(() => scroll.props.onMomentumScrollEnd(event(99_999)));
    expect(onChange).toHaveBeenLastCalledWith(ITEMS.length - 1);
  });

  it('snaps back without announcing a change when it stops on the value it had', () => {
    const { scroll, scrollTo, onChange, event } = render(2);
    act(() => scroll.props.onMomentumScrollEnd(event(2 * ITEM_HEIGHT + 5)));
    expect(onChange).not.toHaveBeenCalled();
    expect(scrollTo).toHaveBeenCalledWith({
      y: 2 * ITEM_HEIGHT,
      animated: true,
    });
  });

  it('settles after a slow drag that leaves go with no momentum', () => {
    const { scroll, onChange, event } = render(0);
    act(() => scroll.props.onScrollEndDrag(event(4 * ITEM_HEIGHT, 0)));
    expect(onChange).toHaveBeenCalledWith(4);
  });

  it('waits for the momentum to end after a flick, instead of settling mid-scroll', () => {
    const { scroll, onChange, event } = render(0);
    act(() => scroll.props.onScrollEndDrag(event(4 * ITEM_HEIGHT, 2.5)));
    expect(onChange).not.toHaveBeenCalled();
  });

  it('chooses a value that is tapped, and scrolls to it', () => {
    const { root, scrollTo, onChange } = render(0);
    pressExact(root, '5');
    expect(onChange).toHaveBeenCalledWith(4);
    expect(scrollTo).toHaveBeenCalledWith({
      y: 4 * ITEM_HEIGHT,
      animated: true,
    });
  });

  it('can be adjusted by a screen reader', () => {
    const { scroll, onChange } = render(2);
    expect(scroll.props.accessibilityRole).toBe('adjustable');
    expect(scroll.props.accessibilityLabel).toBe('Hour');
    expect(scroll.props.accessibilityValue).toEqual({ text: '3' });
    act(() =>
      scroll.props.onAccessibilityAction({
        nativeEvent: { actionName: 'increment' },
      }),
    );
    expect(onChange).toHaveBeenLastCalledWith(3);
    act(() =>
      scroll.props.onAccessibilityAction({
        nativeEvent: { actionName: 'decrement' },
      }),
    );
    expect(onChange).toHaveBeenLastCalledWith(1);
  });

  it('stays within its values when adjusted past an end', () => {
    const first = render(0);
    act(() =>
      first.scroll.props.onAccessibilityAction({
        nativeEvent: { actionName: 'decrement' },
      }),
    );
    expect(first.onChange).toHaveBeenLastCalledWith(0);
    const last = render(ITEMS.length - 1);
    act(() =>
      last.scroll.props.onAccessibilityAction({
        nativeEvent: { actionName: 'increment' },
      }),
    );
    expect(last.onChange).toHaveBeenLastCalledWith(ITEMS.length - 1);
  });
});
