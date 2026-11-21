import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import {
  calendarWeeks,
  dateKey,
  longDay,
  MAX_MONTHS_AHEAD,
  monthTitle,
  parseDateKey,
  WEEKDAY_INITIALS,
} from '../lib/calendarDays';
import { useTheme } from './theme';

interface Props {
  /** The chosen day, "YYYY-MM-DD". The calendar opens on its month. */
  selected: string;
  /** Days before this one cannot be chosen. */
  today: Date;
  onSelect: (key: string) => void;
}

/** A month at a time, with arrows to move between months. */
export function CalendarGrid({ selected, today, onSelect }: Props) {
  const theme = useTheme();
  const first = parseDateKey(selected);
  const startMonth = today.getFullYear() * 12 + today.getMonth();
  const [shown, setShown] = useState(
    Math.max(startMonth, first.getFullYear() * 12 + first.getMonth()),
  );
  const year = Math.floor(shown / 12);
  const month = shown % 12;
  const todayKey = dateKey(today);
  const canGoBack = shown > startMonth;
  const canGoOn = shown < startMonth + MAX_MONTHS_AHEAD - 1;

  const arrow = (
    label: string,
    symbol: string,
    enabled: boolean,
    by: number,
  ) => (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled: !enabled }}
      disabled={!enabled}
      onPress={() => setShown(s => s + by)}
      hitSlop={8}
      style={styles.arrow}
    >
      <Text
        style={[
          styles.arrowText,
          { color: enabled ? theme.accent : theme.border },
        ]}
      >
        {symbol}
      </Text>
    </Pressable>
  );

  return (
    <View>
      <View style={styles.monthRow}>
        {arrow('Previous month', '‹', canGoBack, -1)}
        <Text
          accessibilityRole="header"
          style={[styles.month, { color: theme.text }]}
        >
          {monthTitle(year, month)}
        </Text>
        {arrow('Next month', '›', canGoOn, 1)}
      </View>
      <View style={styles.week}>
        {WEEKDAY_INITIALS.map((initial, i) => (
          <Text
            key={i}
            style={[styles.cell, styles.initial, { color: theme.muted }]}
          >
            {initial}
          </Text>
        ))}
      </View>
      {calendarWeeks(year, month).map((week, w) => (
        <View key={w} style={styles.week}>
          {week.map((cell, i) => {
            if (!cell) {
              return <View key={i} style={styles.cell} />;
            }
            const past = cell.key < todayKey;
            const chosen = cell.key === selected;
            return (
              <Pressable
                key={i}
                accessibilityRole="button"
                accessibilityLabel={`${longDay(parseDateKey(cell.key))}${
                  cell.key === todayKey ? ', today' : ''
                }`}
                accessibilityState={{ disabled: past, selected: chosen }}
                disabled={past}
                onPress={() => onSelect(cell.key)}
                style={styles.cell}
              >
                <View
                  style={[
                    styles.day,
                    chosen && { backgroundColor: theme.accent },
                    !chosen &&
                      cell.key === todayKey && [
                        styles.today,
                        { borderColor: theme.accent },
                      ],
                  ]}
                >
                  <Text
                    style={[
                      styles.dayText,
                      {
                        color: chosen
                          ? theme.onAccent
                          : past
                          ? theme.border
                          : theme.text,
                      },
                      chosen && styles.dayChosen,
                    ]}
                  >
                    {cell.day}
                  </Text>
                </View>
              </Pressable>
            );
          })}
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  monthRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 8,
    marginBottom: 6,
  },
  month: { fontSize: 17, fontWeight: '700' },
  arrow: {
    width: 44,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  arrowText: { fontSize: 28, fontWeight: '600' },
  week: { flexDirection: 'row' },
  cell: {
    flex: 1,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  initial: { fontSize: 13, fontWeight: '600', textAlign: 'center', height: 24 },
  day: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
  },
  today: { borderWidth: 1 },
  dayText: { fontSize: 16 },
  dayChosen: { fontWeight: '700' },
});
