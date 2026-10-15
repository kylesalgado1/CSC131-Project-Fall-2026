import { StyleSheet, Text, View } from 'react-native';
import { Goal } from '../api/types';
import { formatDuration } from '../lib/format';
import { VerdictSettings } from '../lib/request';
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
  settings: VerdictSettings;
  onChange: (settings: VerdictSettings) => void;
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
 * What the user cares about: the goal, how long they will wait, and how much
 * a wait must save. A stand-in for the preferences screen (Epic 6).
 */
export function PreferencesPanel({ settings, onChange }: Props) {
  const set = (patch: Partial<VerdictSettings>) =>
    onChange({ ...settings, ...patch });

  return (
    <View>
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
    </View>
  );
}

const styles = StyleSheet.create({
  group: { marginTop: 14 },
  groupTitle: {
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.8,
    marginBottom: 8,
  },
  chips: { flexDirection: 'row', flexWrap: 'wrap' },
});
