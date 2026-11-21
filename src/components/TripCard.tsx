import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useTheme } from './theme';

interface Props {
  fromLabel: string;
  /** True when the start is the phone's position. */
  fromIsCurrent: boolean;
  /** True while waiting for the phone to say where it is. */
  locating: boolean;
  toLabel?: string;
  onPressFrom: () => void;
  onPressTo: () => void;
  /** Absent when there is nothing sensible to swap. */
  onSwap?: () => void;
}

/** Where from and where to, with one tap on either to change it. */
export function TripCard({
  fromLabel,
  fromIsCurrent,
  locating,
  toLabel,
  onPressFrom,
  onPressTo,
  onSwap,
}: Props) {
  const theme = useTheme();
  return (
    <View
      style={[
        styles.card,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Start: ${fromLabel}. Tap to change.`}
        onPress={onPressFrom}
        style={styles.row}
      >
        <View style={[styles.dot, { backgroundColor: theme.tone.go }]} />
        <View style={styles.text}>
          <Text style={[styles.label, { color: theme.muted }]}>FROM</Text>
          <Text numberOfLines={1} style={[styles.value, { color: theme.text }]}>
            {fromLabel}
          </Text>
        </View>
        {fromIsCurrent && locating ? (
          <ActivityIndicator color={theme.accent} style={styles.spinner} />
        ) : null}
      </Pressable>

      <View style={[styles.divider, { backgroundColor: theme.border }]} />

      <Pressable
        accessibilityRole="button"
        accessibilityLabel={
          toLabel
            ? `Destination: ${toLabel}. Tap to change.`
            : 'Choose a destination.'
        }
        onPress={onPressTo}
        style={styles.row}
      >
        <View style={[styles.square, { backgroundColor: theme.tone.late }]} />
        <View style={styles.text}>
          <Text style={[styles.label, { color: theme.muted }]}>TO</Text>
          <Text
            numberOfLines={1}
            style={[
              styles.value,
              { color: toLabel ? theme.text : theme.muted },
            ]}
          >
            {toLabel ?? 'Where are you going?'}
          </Text>
        </View>
      </Pressable>

      {onSwap ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Swap start and destination"
          onPress={onSwap}
          style={[styles.swap, { backgroundColor: theme.chip }]}
        >
          <Text style={[styles.swapText, { color: theme.text }]}>⇅</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { borderWidth: 1, borderRadius: 16, marginTop: 12 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 14,
    paddingLeft: 16,
    paddingRight: 64,
  },
  dot: { width: 12, height: 12, borderRadius: 6, marginRight: 14 },
  square: { width: 12, height: 12, borderRadius: 2, marginRight: 14 },
  text: { flex: 1 },
  label: { fontSize: 11, fontWeight: '700', letterSpacing: 0.8 },
  value: { fontSize: 17, fontWeight: '600', marginTop: 2 },
  spinner: { marginLeft: 8 },
  divider: { height: StyleSheet.hairlineWidth, marginLeft: 42 },
  swap: {
    position: 'absolute',
    right: 14,
    top: '50%',
    marginTop: -20,
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  swapText: { fontSize: 20 },
});
