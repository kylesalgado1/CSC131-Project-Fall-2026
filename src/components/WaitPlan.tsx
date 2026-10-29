import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { LatLng, Verdict } from '../api/types';
import {
  Spot,
  MAX_SPOT_MILES,
  SPOT_CATEGORIES,
  SpotCategory,
  useNearbySpots,
} from '../hooks/useNearbySpots';
import { formatTime } from '../lib/format';
import {
  closest,
  countdownLabel,
  departureTarget,
  LATEST_REMINDER_LEAD_MINUTES,
  planKind,
  formatDistance,
  mapsUrl,
  REMINDER_LEAD_MINUTES,
  reminderTime,
} from '../lib/waitPlan';
import {
  cancelLeaveReminder,
  scheduleLeaveReminder,
} from '../notifications/leaveReminder';
import { useTheme } from './theme';

interface Reminders {
  schedule(at: Date, body: string): Promise<string>;
  cancel(id: string): Promise<void>;
}

interface Props {
  verdict: Verdict;
  baseUrl: string;
  located?: LatLng;
  locate?: () => Promise<LatLng>;
  fetchFn?: typeof fetch;
  /** For tests. */
  clock?: () => Date;
  openUrl?: (url: string) => Promise<unknown>;
  reminders?: Reminders;
  timeOptions?: { locale?: string; timeZone?: string };
}

const TICK_MS = 30_000;

const nounOf = (spot: Spot) =>
  SPOT_CATEGORIES.find(c => c.id === spot.category)?.noun ?? 'Place';

/**
 * What to do with a wait: a countdown to the time to leave, a reminder for
 * it, and places nearby to spend it at. Shown when the advice is to wait, or
 * that there is no need to leave yet, and not for "Leave now".
 */
export function WaitPlan({
  verdict,
  baseUrl,
  located,
  locate,
  fetchFn,
  clock = () => new Date(),
  openUrl = url => Linking.openURL(url),
  reminders = { schedule: scheduleLeaveReminder, cancel: cancelLeaveReminder },
  timeOptions,
}: Props) {
  const theme = useTheme();
  const [now, setNow] = useState(clock);
  const [hidden, setHidden] = useState(false);
  const [remind, setRemind] = useState(false);
  const [remindError, setRemindError] = useState<string | undefined>();
  const [openError, setOpenError] = useState(false);
  // Undefined shows every kind of place.
  const [category, setCategory] = useState<SpotCategory | undefined>();

  const kind = planKind(verdict);
  const waiting = kind !== undefined;
  // "No need to leave yet" has a window, not a time: count down to its end.
  const latest = kind === 'window';
  const target = departureTarget(verdict);
  const departAt = target?.departAt;
  const arriveAt = target?.arriveAt;
  const lead = latest ? LATEST_REMINDER_LEAD_MINUTES : REMINDER_LEAD_MINUTES;
  const nearby = useNearbySpots({
    active: waiting && !hidden,
    baseUrl,
    located,
    locate,
    fetchFn,
  });

  useEffect(() => {
    if (!waiting || hidden) {
      return undefined;
    }
    const timer = setInterval(() => setNow(clock()), TICK_MS);
    return () => clearInterval(timer);
    // The clock is fixed for the life of the screen.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [waiting, hidden]);

  // The reminder follows the advice: it moves when the departure moves, and
  // goes away when the advice stops being to wait.
  useEffect(() => {
    if (!waiting || !remind || !departAt || !arriveAt) {
      return undefined;
    }
    const at = reminderTime(departAt, clock(), lead);
    if (!at) {
      return undefined;
    }
    let cancelled = false;
    let id: string | undefined;
    reminders
      .schedule(
        at,
        `${
          latest ? 'Last chance to leave' : 'Leave now'
        } to arrive around ${formatTime(arriveAt, timeOptions)}.`,
      )
      .then(scheduled => {
        if (cancelled) {
          reminders.cancel(scheduled).catch(() => {});
        } else {
          id = scheduled;
          setRemindError(undefined);
        }
      })
      .catch(error => {
        if (!cancelled) {
          setRemindError(
            error instanceof Error ? error.message : String(error),
          );
          setRemind(false);
        }
      });
    return () => {
      cancelled = true;
      if (id) {
        reminders.cancel(id).catch(() => {});
      }
    };
    // The reminders and clock are fixed for the life of the screen.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [waiting, remind, departAt, arriveAt, lead]);

  if (!waiting) {
    return null;
  }

  const chosen = SPOT_CATEGORIES.find(c => c.id === category);
  const shown = closest(nearby.spots, category);

  if (hidden) {
    return (
      <Pressable
        accessibilityRole="button"
        onPress={() => setHidden(false)}
        style={styles.restore}
      >
        <Text style={[styles.link, { color: theme.accent }]}>
          Show the wait plan
        </Text>
      </Pressable>
    );
  }

  const open = async (spot: Spot) => {
    setOpenError(false);
    try {
      await openUrl(mapsUrl(spot, Platform.OS));
    } catch {
      setOpenError(true);
    }
  };

  return (
    <View
      style={[
        styles.card,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <Text
        accessibilityRole="header"
        style={[styles.title, { color: theme.text }]}
      >
        While you wait
      </Text>
      {departAt && arriveAt ? (
        <>
          <Text style={[styles.countdown, { color: theme.tone.wait }]}>
            {countdownLabel(departAt, now, latest)}
          </Text>
          <Text style={[styles.sub, { color: theme.muted }]}>
            {latest
              ? `Any time before ${formatTime(
                  departAt,
                  timeOptions,
                )} works. Leave then and you arrive around ${formatTime(
                  arriveAt,
                  timeOptions,
                )}.`
              : `Leave at ${formatTime(
                  departAt,
                  timeOptions,
                )} and you arrive around ${formatTime(arriveAt, timeOptions)}.`}
          </Text>
          <View style={styles.actions}>
            <Pressable
              accessibilityRole="button"
              accessibilityState={{ selected: remind }}
              onPress={() => setRemind(on => !on)}
              style={[
                styles.button,
                remind
                  ? { backgroundColor: theme.accent, borderColor: theme.accent }
                  : { borderColor: theme.accent },
              ]}
            >
              <Text
                style={[
                  styles.buttonText,
                  { color: remind ? theme.card : theme.accent },
                ]}
              >
                {remind ? 'Reminder on' : `Remind me ${lead} min before`}
              </Text>
            </Pressable>
            <Pressable
              accessibilityRole="button"
              onPress={() => {
                setRemind(false);
                setHidden(true);
              }}
              hitSlop={6}
            >
              <Text style={[styles.link, { color: theme.accent }]}>
                Leave now instead
              </Text>
            </Pressable>
          </View>
          {remindError ? (
            <Text style={[styles.error, { color: theme.confidence.Low }]}>
              {remindError}
            </Text>
          ) : null}
        </>
      ) : null}

      <Text style={[styles.heading, { color: theme.text }]}>
        Places near you
      </Text>
      <View style={styles.chips}>
        {[{ id: undefined, label: 'All' }, ...SPOT_CATEGORIES].map(option => {
          const on = option.id === category;
          return (
            <Pressable
              key={option.label}
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              onPress={() => setCategory(option.id)}
              style={[
                styles.chip,
                on
                  ? { backgroundColor: theme.accent, borderColor: theme.accent }
                  : { borderColor: theme.border },
              ]}
            >
              <Text
                style={[
                  styles.chipText,
                  { color: on ? theme.card : theme.text },
                ]}
              >
                {option.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {nearby.loading ? (
        <ActivityIndicator color={theme.accent} style={styles.loading} />
      ) : nearby.error ? (
        <Text style={[styles.sub, { color: theme.muted }]}>
          Could not look for places. {nearby.error.message}
        </Text>
      ) : shown.length === 0 ? (
        <Text style={[styles.sub, { color: theme.muted }]}>
          {category
            ? `No ${chosen?.label.toLowerCase()} within ${MAX_SPOT_MILES} miles.`
            : `Nothing found within ${MAX_SPOT_MILES} miles.`}
        </Text>
      ) : (
        shown.map(spot => (
          <Pressable
            key={spot.id}
            accessibilityRole="button"
            accessibilityLabel={`${spot.name}, ${formatDistance(
              spot.miles,
            )} away. Open directions`}
            onPress={() => open(spot)}
            style={[styles.spot, { borderTopColor: theme.border }]}
          >
            <View style={styles.spotText}>
              <Text style={[styles.spotName, { color: theme.text }]}>
                {spot.name}
              </Text>
              <Text style={[styles.sub, { color: theme.muted }]}>
                {nounOf(spot)} · {formatDistance(spot.miles)} · {spot.address}
              </Text>
            </View>
            <Text style={[styles.link, { color: theme.accent }]}>
              Directions
            </Text>
          </Pressable>
        ))
      )}
      {openError ? (
        <Text style={[styles.error, { color: theme.confidence.Low }]}>
          Could not open Maps.
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { borderRadius: 18, borderWidth: 1, padding: 18, marginTop: 14 },
  title: { fontSize: 15, fontWeight: '700' },
  countdown: { fontSize: 28, fontWeight: '800', marginTop: 4 },
  sub: { fontSize: 14, lineHeight: 20, marginTop: 4 },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 14,
    gap: 12,
  },
  button: {
    borderWidth: 2,
    borderRadius: 12,
    paddingVertical: 10,
    paddingHorizontal: 14,
  },
  buttonText: { fontSize: 15, fontWeight: '700' },
  link: { fontSize: 15, fontWeight: '700' },
  restore: { marginTop: 12, alignSelf: 'flex-start' },
  error: { fontSize: 14, marginTop: 8 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 10 },
  chip: {
    borderWidth: 1,
    borderRadius: 16,
    paddingVertical: 6,
    paddingHorizontal: 12,
  },
  chipText: { fontSize: 14, fontWeight: '600' },
  heading: { fontSize: 15, fontWeight: '700', marginTop: 20 },
  loading: { marginVertical: 14 },
  spot: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 12,
    marginTop: 8,
    borderTopWidth: 1,
  },
  spotText: { flex: 1 },
  spotName: { fontSize: 16, fontWeight: '600' },
});
