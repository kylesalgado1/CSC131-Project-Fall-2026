import { ReactNode, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useTheme } from './theme';

interface Props {
  title: string;
  /** Shown beside the title while folded away. */
  summary?: string;
  defaultOpen?: boolean;
  children: ReactNode;
}

/** A section that folds away, so rarely used controls do not crowd the screen. */
export function Collapsible({
  title,
  summary,
  defaultOpen = false,
  children,
}: Props) {
  const theme = useTheme();
  const [open, setOpen] = useState(defaultOpen);
  return (
    <View
      style={[
        styles.box,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ expanded: open }}
        accessibilityLabel={`${title}. ${open ? 'Hide' : 'Show'}.`}
        onPress={() => setOpen(o => !o)}
        style={styles.header}
      >
        <View style={styles.headerText}>
          <Text style={[styles.title, { color: theme.text }]}>{title}</Text>
          {!open && summary ? (
            <Text
              numberOfLines={2}
              style={[styles.summary, { color: theme.muted }]}
            >
              {summary}
            </Text>
          ) : null}
        </View>
        <Text style={[styles.chevron, { color: theme.muted }]}>
          {open ? '▾' : '▸'}
        </Text>
      </Pressable>
      {open ? <View style={styles.body}>{children}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { borderWidth: 1, borderRadius: 14, marginTop: 14 },
  header: { flexDirection: 'row', alignItems: 'center', padding: 14 },
  headerText: { flex: 1 },
  title: { fontSize: 16, fontWeight: '700' },
  summary: { fontSize: 13, lineHeight: 18, marginTop: 3 },
  chevron: { fontSize: 18, marginLeft: 10 },
  body: { paddingHorizontal: 14, paddingBottom: 16 },
});
