import { StyleSheet, Text, View } from 'react-native';
import { Goal } from '../api/types';
import { formatDuration } from '../lib/format';
import { VerdictSettings } from '../lib/request';
import { Chip } from './Chip';
import { useTheme } from './theme';

const GOALS: Array<{ goal: Goal; label: string }> = [
  { goal: 'minimize_time', label: 'Least driving' },
  { goal: 'arrive_by', label: 'Arrive by' },
];
const GOAL_HINT: Record<Goal, string> = {
  minimize_time: 'Waits when traffic clears enough to cut your driving time.',
  arrive_by:
    'With an Arrive by time, leaves as late as still gets you there with a little room to spare.',
};
const MAX_WAITS = [30, 60, 90, 120, 180];
const MIN_SAVINGS = [5, 10, 15];

interface Props {
  settings: VerdictSettings;
  onChange: (settings: VerdictSettings) => void;
}

function Group({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string;
  children: React.ReactNode;
}) {
  const theme = useTheme();
  return (
    <View style={styles.group}>
      <Text style={[styles.groupTitle, { color: theme.muted }]}>{title}</Text>
      <View style={styles.chips}>{children}</View>
      {hint ? (
        <Text style={[styles.hint, { color: theme.muted }]}>{hint}</Text>
      ) : null}
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
      <Group title="WHAT MATTERS TO ME" hint={GOAL_HINT[settings.goal]}>
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
        <Chip
          label="No limit"
          selected={settings.maxWaitMinutes === undefined}
          onPress={() => set({ maxWaitMinutes: undefined })}
        />
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
  hint: { fontSize: 13, lineHeight: 18, marginTop: 8 },
});
