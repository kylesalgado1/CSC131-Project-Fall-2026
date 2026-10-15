import { StyleSheet, Text, View } from 'react-native';
import { useTheme } from './theme';

interface Props {
  kind: 'info' | 'update' | 'error';
  title?: string;
  children: string;
}

/** A short message above or below the answer. */
export function Notice({ kind, title, children }: Props) {
  const theme = useTheme();
  const color =
    kind === 'error'
      ? theme.confidence.Low
      : kind === 'update'
      ? theme.accent
      : theme.muted;
  return (
    <View
      accessibilityRole={kind === 'error' ? 'alert' : undefined}
      style={[styles.box, { borderColor: color, backgroundColor: theme.card }]}
    >
      {title ? <Text style={[styles.title, { color }]}>{title}</Text> : null}
      <Text style={[styles.text, { color: theme.text }]}>{children}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  box: { borderWidth: 1.5, borderRadius: 12, padding: 12, marginTop: 12 },
  title: { fontSize: 14, fontWeight: '700', marginBottom: 2 },
  text: { fontSize: 14, lineHeight: 20 },
});
