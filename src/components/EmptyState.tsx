import { StyleSheet, Text, View } from 'react-native';
import { Place } from '../api/types';
import { QUICK_PICKS } from '../trip/quickPicks';
import { Chip } from './Chip';
import { useTheme } from './theme';

interface Props {
  onChooseDestination: () => void;
  onPick: (place: Place) => void;
}

/** What a new user sees before choosing a destination. */
export function EmptyState({ onChooseDestination, onPick }: Props) {
  const theme = useTheme();
  return (
    <View
      style={[
        styles.box,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <Text style={[styles.title, { color: theme.text }]}>
        Where are you going?
      </Text>
      <Text style={[styles.text, { color: theme.muted }]}>
        Choose a destination and Wait It Out will tell you whether to leave now
        or wait, and what it saves you.
      </Text>
      <View style={styles.chips}>
        <Chip
          label="Search for a place"
          selected
          onPress={onChooseDestination}
        />
        {QUICK_PICKS.map(place => (
          <Chip
            key={place.id}
            label={place.name}
            selected={false}
            onPress={() => onPick(place)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  box: { borderWidth: 1, borderRadius: 16, padding: 18, marginTop: 14 },
  title: { fontSize: 22, fontWeight: '800' },
  text: { fontSize: 15, lineHeight: 22, marginTop: 6, marginBottom: 14 },
  chips: { flexDirection: 'row', flexWrap: 'wrap' },
});
