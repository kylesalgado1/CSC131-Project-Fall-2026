import { useRef } from 'react';
import {
  NativeScrollEvent,
  NativeSyntheticEvent,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useTheme } from './theme';

export const ITEM_HEIGHT = 44;
/** Rows showing at once: the chosen one and two either side. */
const VISIBLE_ROWS = 5;
const PADDING_ROWS = (VISIBLE_ROWS - 1) / 2;

interface Props {
  /** What the wheel is for, read out by a screen reader. */
  label: string;
  items: string[];
  selectedIndex: number;
  onChange: (index: number) => void;
  width: number;
}

/**
 * One scrolling column of a time picker. Flick it and it settles on the
 * nearest value, under the highlighted band; or tap a value to choose it.
 */
export function WheelColumn({
  label,
  items,
  selectedIndex,
  onChange,
  width,
}: Props) {
  const theme = useTheme();
  const scroll = useRef<ScrollView>(null);
  const offsetFor = (index: number) => index * ITEM_HEIGHT;

  const goTo = (index: number, animated: boolean) => {
    scroll.current?.scrollTo({ y: offsetFor(index), animated });
  };

  /** Settles on whichever value the scroll stopped nearest, and says so. */
  const settle = (y: number) => {
    const index = Math.min(
      items.length - 1,
      Math.max(0, Math.round(y / ITEM_HEIGHT)),
    );
    goTo(index, true);
    if (index !== selectedIndex) {
      onChange(index);
    }
  };

  const choose = (index: number) => {
    goTo(index, true);
    onChange(index);
  };

  const onEnd = (event: NativeSyntheticEvent<NativeScrollEvent>) =>
    settle(event.nativeEvent.contentOffset.y);

  return (
    <View style={[styles.wheel, { width }]}>
      <View
        pointerEvents="none"
        style={[
          styles.band,
          { borderColor: theme.border, backgroundColor: theme.chip },
        ]}
      />
      <ScrollView
        ref={scroll}
        accessibilityRole="adjustable"
        accessibilityLabel={label}
        accessibilityValue={{ text: items[selectedIndex] }}
        accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
        onAccessibilityAction={event => {
          const step = event.nativeEvent.actionName === 'increment' ? 1 : -1;
          choose(Math.min(items.length - 1, Math.max(0, selectedIndex + step)));
        }}
        nestedScrollEnabled
        showsVerticalScrollIndicator={false}
        snapToInterval={ITEM_HEIGHT}
        decelerationRate="fast"
        scrollEventThrottle={16}
        // iOS starts in the right place from this; Android needs the scrollTo.
        contentOffset={{ x: 0, y: offsetFor(selectedIndex) }}
        onContentSizeChange={() => goTo(selectedIndex, false)}
        onMomentumScrollEnd={onEnd}
        onScrollEndDrag={event => {
          // A slow drag can stop with no momentum, and then nothing else fires.
          if (Math.abs(event.nativeEvent.velocity?.y ?? 0) < 0.1) {
            onEnd(event);
          }
        }}
        contentContainerStyle={{ paddingVertical: ITEM_HEIGHT * PADDING_ROWS }}
      >
        {items.map((item, index) => (
          <Pressable
            key={item}
            accessibilityElementsHidden
            importantForAccessibility="no"
            onPress={() => choose(index)}
            style={styles.item}
          >
            <Text
              style={[
                styles.itemText,
                index === selectedIndex
                  ? [styles.itemSelected, { color: theme.text }]
                  : { color: theme.muted },
              ]}
            >
              {item}
            </Text>
          </Pressable>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  wheel: { height: ITEM_HEIGHT * VISIBLE_ROWS },
  band: {
    position: 'absolute',
    left: 0,
    right: 0,
    top: ITEM_HEIGHT * PADDING_ROWS,
    height: ITEM_HEIGHT,
    borderRadius: 10,
    borderWidth: 1,
  },
  item: { height: ITEM_HEIGHT, alignItems: 'center', justifyContent: 'center' },
  itemText: { fontSize: 20 },
  itemSelected: { fontWeight: '700', fontSize: 22 },
});
