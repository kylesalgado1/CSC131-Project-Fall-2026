import { useState } from 'react';
import { Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { dateKey, dayName, longDay } from '../lib/calendarDays';
import {
  ClockTime,
  formatClockTime,
  fromWheels,
  MINUTE_STEP,
  resolveTime,
  toWheels,
} from '../lib/clockTime';
import { CalendarGrid } from './CalendarGrid';
import { useTheme } from './theme';
import { WheelColumn } from './WheelColumn';

const HOURS = Array.from({ length: 12 }, (_, i) => String(i + 1));
const MINUTES = Array.from({ length: 60 / MINUTE_STEP }, (_, i) =>
  String(i * MINUTE_STEP).padStart(2, '0'),
);
const PERIODS = ['AM', 'PM'];
/** The advice plans this far ahead at most; farther times are still saved. */
const PLAN_HOURS = 12;

interface Props {
  visible: boolean;
  /** "Leave by" or "Arrive by". */
  title: string;
  /** One line on what the time does. */
  explanation: string;
  /** The time already set, if any. */
  current?: ClockTime;
  /** Where the wheels start when nothing is set. */
  fallback: ClockTime;
  onSet: (time: ClockTime) => void;
  /** Removes the limit. Only offered when one is set. */
  onClear: () => void;
  onClose: () => void;
  /** For tests. */
  now?: () => Date;
}

/** The wheels and buttons. Created fresh each time the sheet opens. */
function SheetBody({
  title,
  explanation,
  current,
  fallback,
  onSet,
  onClear,
  onClose,
  now = () => new Date(),
}: Omit<Props, 'visible'>) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [draft, setDraft] = useState(() => {
    const start = current ?? fallback;
    return {
      ...toWheels(start),
      dayKey: dateKey(resolveTime(start, now())),
    };
  });
  // What the wheels mean right now. A time already past today means tomorrow.
  const moment = resolveTime(
    { ...fromWheels(draft), date: draft.dayKey },
    now(),
  );
  const time: ClockTime = {
    hour: moment.getHours(),
    minute: moment.getMinutes(),
    date: dateKey(moment),
  };
  const farOff = moment.getTime() - now().getTime() > PLAN_HOURS * 60 * 60_000;

  return (
    <View style={styles.fill}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Close without changing"
        onPress={onClose}
        style={styles.backdrop}
      />
      <View
        style={[
          styles.sheet,
          {
            backgroundColor: theme.card,
            paddingBottom: Math.max(insets.bottom, 16) + 8,
          },
        ]}
      >
        <View style={styles.header}>
          <Text
            accessibilityRole="header"
            style={[styles.title, { color: theme.text }]}
          >
            {title}
          </Text>
          <Pressable accessibilityRole="button" onPress={onClose} hitSlop={12}>
            <Text style={[styles.cancel, { color: theme.accent }]}>Cancel</Text>
          </Pressable>
        </View>
        <Text style={[styles.explanation, { color: theme.muted }]}>
          {explanation}
        </Text>

        <Pressable
          accessibilityRole="button"
          accessibilityLabel={`Day: ${longDay(moment)}. Tap to ${
            calendarOpen ? 'hide' : 'show'
          } the calendar.`}
          accessibilityState={{ expanded: calendarOpen }}
          onPress={() => setCalendarOpen(open => !open)}
          style={[
            styles.dayRow,
            { backgroundColor: theme.chip, borderColor: theme.border },
          ]}
        >
          <Text style={[styles.dayLabel, { color: theme.muted }]}>Day</Text>
          <Text style={[styles.dayValue, { color: theme.accent }]}>
            {longDay(moment)}
          </Text>
          <Text style={[styles.dayChevron, { color: theme.muted }]}>
            {calendarOpen ? '▴' : '▾'}
          </Text>
        </Pressable>

        {calendarOpen ? (
          <CalendarGrid
            selected={time.date as string}
            today={now()}
            onSelect={dayKey => {
              setDraft(d => ({ ...d, dayKey }));
              setCalendarOpen(false);
            }}
          />
        ) : (
          <View style={styles.wheels}>
            <WheelColumn
              label="Hour"
              items={HOURS}
              selectedIndex={draft.hour12 - 1}
              onChange={index => setDraft(d => ({ ...d, hour12: index + 1 }))}
              width={84}
            />
            <WheelColumn
              label="Minute"
              items={MINUTES}
              selectedIndex={Math.round(draft.minute / MINUTE_STEP)}
              onChange={index =>
                setDraft(d => ({ ...d, minute: index * MINUTE_STEP }))
              }
              width={84}
            />
            <WheelColumn
              label="AM or PM"
              items={PERIODS}
              selectedIndex={draft.pm ? 1 : 0}
              onChange={index => setDraft(d => ({ ...d, pm: index === 1 }))}
              width={84}
            />
          </View>
        )}

        <Text style={[styles.preview, { color: theme.text }]}>
          {formatClockTime(time)} {dayName(moment, now())}
        </Text>
        {farOff ? (
          <Text style={[styles.note, { color: theme.muted }]}>
            Advice plans up to {PLAN_HOURS} hours ahead. It sharpens as this
            time gets closer.
          </Text>
        ) : null}

        <Pressable
          accessibilityRole="button"
          onPress={() => onSet(time)}
          style={[styles.primary, { backgroundColor: theme.accent }]}
        >
          <Text style={[styles.primaryText, { color: theme.onAccent }]}>
            Set {title.toLowerCase()}
          </Text>
        </Pressable>
        {current ? (
          <Pressable
            accessibilityRole="button"
            onPress={onClear}
            style={styles.secondary}
          >
            <Text style={[styles.secondaryText, { color: theme.accent }]}>
              Any time
            </Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

/**
 * A sheet for choosing a day and time from a calendar and three wheels: hour,
 * minute and AM or PM. Replaces typing the time in.
 */
export function TimePickerSheet({ visible, ...body }: Props) {
  return (
    <Modal
      visible={visible}
      transparent
      animationType="slide"
      onRequestClose={body.onClose}
    >
      <SheetBody {...body} />
    </Modal>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1, justifyContent: 'flex-end' },
  backdrop: { ...StyleSheet.absoluteFill, backgroundColor: 'rgba(0,0,0,0.4)' },
  sheet: {
    borderTopLeftRadius: 22,
    borderTopRightRadius: 22,
    paddingHorizontal: 20,
    paddingTop: 18,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  title: { fontSize: 22, fontWeight: '800' },
  cancel: { fontSize: 16, fontWeight: '600' },
  explanation: { fontSize: 14, lineHeight: 20, marginTop: 4 },
  dayRow: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderRadius: 12,
    paddingVertical: 12,
    paddingHorizontal: 14,
    marginTop: 12,
  },
  dayLabel: { fontSize: 15, fontWeight: '600', flex: 1 },
  dayValue: { fontSize: 17, fontWeight: '700' },
  dayChevron: { fontSize: 14, marginLeft: 8 },
  wheels: {
    flexDirection: 'row',
    justifyContent: 'center',
    marginTop: 12,
    gap: 4,
  },
  preview: {
    fontSize: 17,
    fontWeight: '600',
    textAlign: 'center',
    marginTop: 10,
    marginBottom: 14,
  },
  note: {
    fontSize: 13,
    lineHeight: 18,
    textAlign: 'center',
    marginTop: -8,
    marginBottom: 14,
  },
  primary: { borderRadius: 14, paddingVertical: 14, alignItems: 'center' },
  primaryText: { fontSize: 17, fontWeight: '700' },
  secondary: { paddingVertical: 14, alignItems: 'center' },
  secondaryText: { fontSize: 16, fontWeight: '600' },
});
