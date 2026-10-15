import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Confidence } from '../api/types';
import { useTheme } from './theme';

interface Props {
  confidence: Confidence;
  /** One sentence on why, shown when the badge is tapped. */
  reason: string;
}

/** Story 2-5: High, Medium or Low, and tapping it says why. */
export function ConfidenceBadge({ confidence, reason }: Props) {
  const theme = useTheme();
  const [open, setOpen] = useState(false);
  const color = theme.confidence[confidence];
  return (
    <View>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`${confidence} confidence. Tap for why.`}
        onPress={() => setOpen(o => !o)}
        style={[styles.badge, { borderColor: color }]}
      >
        <View style={[styles.dot, { backgroundColor: color }]} />
        <Text style={[styles.label, { color: theme.text }]}>
          {confidence} confidence
        </Text>
        <Text style={[styles.hint, { color: theme.muted }]}>
          {open ? 'Hide' : 'Why?'}
        </Text>
      </Pressable>
      {open ? (
        <Text style={[styles.reason, { color: theme.muted }]}>{reason}</Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    borderWidth: 1.5,
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  dot: { width: 9, height: 9, borderRadius: 5, marginRight: 8 },
  label: { fontSize: 14, fontWeight: '600' },
  hint: { fontSize: 13, marginLeft: 10 },
  reason: { fontSize: 14, lineHeight: 20, marginTop: 8 },
});
