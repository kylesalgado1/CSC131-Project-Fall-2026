import { Pressable, StyleSheet, Text, View } from 'react-native';
import { ClockTime, dayOf, formatClockTime } from '../lib/clockTime';
import { useTheme } from './theme';

interface Props {
  leaveBy?: ClockTime;
  arriveBy?: ClockTime;
  onEditLeaveBy: () => void;
  onEditArriveBy: () => void;
  /** For tests. */
  now?: () => Date;
}

function Row({
  label,
  time,
  now,
  onPress,
}: {
  label: string;
  time?: ClockTime;
  now: Date;
  onPress: () => void;
}) {
  const theme = useTheme();
  const text = time ? formatClockTime(time) : 'Any time';
  const day = time ? dayOf(time, now) : undefined;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={
        time
          ? `${label} ${text} ${day}. Tap to change.`
          : `${label}: any time. Tap to set.`
      }
      onPress={onPress}
      style={styles.row}
    >
      <Text style={[styles.label, { color: theme.text }]}>{label}</Text>
      <View style={styles.value}>
        <Text
          style={[
            styles.valueText,
            { color: time ? theme.accent : theme.muted },
          ]}
        >
          {text}
        </Text>
        {day && day !== 'today' ? (
          <Text style={[styles.day, { color: theme.muted }]}>{day}</Text>
        ) : null}
        <Text style={[styles.chevron, { color: theme.muted }]}>›</Text>
      </View>
    </Pressable>
  );
}

/** The two time limits: the latest to leave and the latest to arrive. */
export function TimeLimitsCard({
  leaveBy,
  arriveBy,
  onEditLeaveBy,
  onEditArriveBy,
  now = () => new Date(),
}: Props) {
  const theme = useTheme();
  const current = now();
  return (
    <View
      style={[
        styles.card,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <Row
        label="Leave by"
        time={leaveBy}
        now={current}
        onPress={onEditLeaveBy}
      />
      <View style={[styles.divider, { backgroundColor: theme.border }]} />
      <Row
        label="Arrive by"
        time={arriveBy}
        now={current}
        onPress={onEditArriveBy}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  card: { borderWidth: 1, borderRadius: 16, marginTop: 12 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 14,
    paddingHorizontal: 16,
  },
  label: { fontSize: 17, fontWeight: '600' },
  value: { flexDirection: 'row', alignItems: 'center' },
  valueText: { fontSize: 17, fontWeight: '600' },
  day: { fontSize: 13, marginLeft: 6 },
  chevron: { fontSize: 22, marginLeft: 8 },
  divider: { height: StyleSheet.hairlineWidth, marginLeft: 16 },
});
