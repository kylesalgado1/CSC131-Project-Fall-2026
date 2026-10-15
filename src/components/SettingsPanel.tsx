import { StyleSheet, Text, TextInput, View } from 'react-native';
import { Goal } from '../api/types';
import { parseArriveBy } from '../lib/arriveBy';
import { formatDuration } from '../lib/format';
import { VerdictSettings } from '../lib/request';
import { SAMPLE_LABELS, SampleKind } from '../samples';
import { DEMO_TRIPS } from '../trips';
import { VerdictSource } from '../hooks/useVerdict';
import { Chip } from './Chip';
import { useTheme } from './theme';

const GOALS: Array<{ goal: Goal; label: string }> = [
  { goal: 'balance', label: 'Balanced' },
  { goal: 'minimize_time', label: 'Least driving' },
  { goal: 'arrive_by', label: 'Arrive by' },
];
const MAX_WAITS = [30, 60, 90, 120, 180];
const MIN_SAVINGS = [5, 10, 15];

interface Props {
  tripId: string;
  onTripChange: (id: string) => void;
  source: VerdictSource;
  onSourceChange: (source: VerdictSource) => void;
  settings: VerdictSettings;
  onSettingsChange: (settings: VerdictSettings) => void;
}

function Group({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  const theme = useTheme();
  return (
    <View style={styles.group}>
      <Text style={[styles.groupTitle, { color: theme.muted }]}>{title}</Text>
      <View style={styles.chips}>{children}</View>
    </View>
  );
}

/**
 * Where the trip and preferences are set. Trip setup (Epic 3) and
 * preferences (Epic 6) belong to other epics, so these are plain stand-ins
 * that let the answer be tried out.
 */
export function SettingsPanel({
  tripId,
  onTripChange,
  source,
  onSourceChange,
  settings,
  onSettingsChange,
}: Props) {
  const theme = useTheme();
  const set = (patch: Partial<VerdictSettings>) =>
    onSettingsChange({ ...settings, ...patch });
  const arriveBy = parseArriveBy(settings.arriveByText, new Date());
  const sources: VerdictSource[] = ['live', 'wait', 'leave_now', 'late'];

  return (
    <View>
      <Group title="TRIP">
        {DEMO_TRIPS.map(trip => (
          <Chip
            key={trip.id}
            label={trip.label}
            selected={trip.id === tripId}
            onPress={() => onTripChange(trip.id)}
          />
        ))}
      </Group>

      <Group title="DATA">
        {sources.map(s => (
          <Chip
            key={s}
            label={
              s === 'live'
                ? 'Live traffic'
                : `Sample: ${SAMPLE_LABELS[s as SampleKind]}`
            }
            selected={s === source}
            onPress={() => onSourceChange(s)}
          />
        ))}
      </Group>

      <Group title="WHAT MATTERS TO ME">
        {GOALS.map(({ goal, label }) => (
          <Chip
            key={goal}
            label={label}
            selected={settings.goal === goal}
            onPress={() => set({ goal })}
          />
        ))}
      </Group>

      <Group title="LONGEST I WILL WAIT">
        {MAX_WAITS.map(minutes => (
          <Chip
            key={minutes}
            label={formatDuration(minutes)}
            selected={settings.maxWaitMinutes === minutes}
            onPress={() => set({ maxWaitMinutes: minutes })}
          />
        ))}
      </Group>

      <Group title="ONLY WAIT IF IT SAVES AT LEAST">
        {MIN_SAVINGS.map(minutes => (
          <Chip
            key={minutes}
            label={`${minutes} min`}
            selected={settings.minSavingsMinutes === minutes}
            onPress={() => set({ minSavingsMinutes: minutes })}
          />
        ))}
      </Group>

      <View style={styles.group}>
        <Text style={[styles.groupTitle, { color: theme.muted }]}>
          ARRIVE BY (OPTIONAL)
        </Text>
        <TextInput
          accessibilityLabel="Arrive by time"
          value={settings.arriveByText}
          onChangeText={arriveByText => set({ arriveByText })}
          placeholder="e.g. 8:30 AM"
          placeholderTextColor={theme.muted}
          autoCapitalize="none"
          autoCorrect={false}
          style={[
            styles.input,
            {
              color: theme.text,
              borderColor: theme.border,
              backgroundColor: theme.card,
            },
          ]}
        />
        {arriveBy.kind === 'invalid' ? (
          <Text style={[styles.error, { color: theme.confidence.Low }]}>
            Try a time like 8:30 AM or 17:45.
          </Text>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  group: { marginTop: 18 },
  groupTitle: {
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.8,
    marginBottom: 8,
  },
  chips: { flexDirection: 'row', flexWrap: 'wrap' },
  input: {
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 10,
    fontSize: 16,
  },
  error: { fontSize: 13, marginTop: 6 },
});
