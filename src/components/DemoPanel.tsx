import { StyleSheet, Text, View } from 'react-native';
import { VerdictSource } from '../hooks/useVerdict';
import { SAMPLE_LABELS, SampleKind } from '../samples';
import { Chip } from './Chip';
import { useTheme } from './theme';

const SOURCES: VerdictSource[] = ['live', 'wait', 'leave_now', 'late'];

interface Props {
  source: VerdictSource;
  onChange: (source: VerdictSource) => void;
}

/**
 * Switches between live traffic and made-up answers. Real traffic on the demo
 * commute rarely says "wait", so samples show every state the screen can be in.
 */
export function DemoPanel({ source, onChange }: Props) {
  const theme = useTheme();
  return (
    <View>
      <Text style={[styles.note, { color: theme.muted }]}>
        Samples are made-up answers for showing what the screen looks like. They
        are not live traffic.
      </Text>
      <View style={styles.chips}>
        {SOURCES.map(s => (
          <Chip
            key={s}
            label={
              s === 'live'
                ? 'Live traffic'
                : `Sample: ${SAMPLE_LABELS[s as SampleKind]}`
            }
            selected={s === source}
            onPress={() => onChange(s)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  note: { fontSize: 13, lineHeight: 18, marginBottom: 10 },
  chips: { flexDirection: 'row', flexWrap: 'wrap' },
});
