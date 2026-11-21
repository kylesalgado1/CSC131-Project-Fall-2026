import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useTheme } from './theme';

interface Action {
  label: string;
  onPress: () => void;
}

interface Props {
  kind: 'info' | 'update' | 'error';
  title?: string;
  /** Buttons for what the user can do about it. */
  actions?: Action[];
  children: string;
}

/** A short message above or below the answer. */
export function Notice({ kind, title, actions, children }: Props) {
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
      {actions?.length ? (
        <View style={styles.actions}>
          {actions.map(action => (
            <Pressable
              key={action.label}
              accessibilityRole="button"
              onPress={action.onPress}
              hitSlop={6}
            >
              <Text style={[styles.action, { color: theme.accent }]}>
                {action.label}
              </Text>
            </Pressable>
          ))}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { borderWidth: 1.5, borderRadius: 12, padding: 12, marginTop: 12 },
  title: { fontSize: 14, fontWeight: '700', marginBottom: 2 },
  text: { fontSize: 14, lineHeight: 20 },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: 18, marginTop: 10 },
  action: { fontSize: 14, fontWeight: '700' },
});
