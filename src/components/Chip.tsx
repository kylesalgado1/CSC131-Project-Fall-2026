import { Pressable, StyleSheet, Text } from 'react-native';
import { useTheme } from './theme';

interface Props {
  label: string;
  selected: boolean;
  onPress: () => void;
}

/** A pill that is either on or off, for picking one of a few options. */
export function Chip({ label, selected, onPress }: Props) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={onPress}
      style={[
        styles.chip,
        { backgroundColor: selected ? theme.accent : theme.chip },
      ]}
    >
      <Text
        style={[
          styles.label,
          { color: selected ? theme.onAccent : theme.text },
        ]}
      >
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  chip: {
    borderRadius: 999,
    paddingHorizontal: 14,
    paddingVertical: 8,
    marginRight: 8,
    marginBottom: 8,
  },
  label: { fontSize: 14, fontWeight: '600' },
});
