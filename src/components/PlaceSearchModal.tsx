import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { LatLng, Place } from '../api/types';
import { MIN_QUERY_LENGTH, usePlaceSearch } from '../hooks/usePlaceSearch';
import { QUICK_PICKS } from '../trip/quickPicks';
import { useTheme } from './theme';

interface Props {
  visible: boolean;
  /** Picking a start also offers "use my location". */
  mode: 'from' | 'to';
  onClose: () => void;
  onPick: (place: Place) => void;
  /** Only for choosing a start. */
  onPickCurrent?: () => void;
  recents: Place[];
  baseUrl: string;
  near?: LatLng;
  fetchFn?: typeof fetch;
}

function Heading({ children }: { children: string }) {
  const theme = useTheme();
  return (
    <Text style={[styles.heading, { color: theme.muted }]}>{children}</Text>
  );
}

function Row({
  title,
  subtitle,
  onPress,
  accent,
}: {
  title: string;
  subtitle?: string;
  onPress: () => void;
  accent?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={subtitle ? `${title}, ${subtitle}` : title}
      onPress={onPress}
      style={[styles.row, { borderBottomColor: theme.border }]}
    >
      <Text
        numberOfLines={1}
        style={[styles.rowTitle, { color: accent ? theme.accent : theme.text }]}
      >
        {title}
      </Text>
      {subtitle ? (
        <Text
          numberOfLines={1}
          style={[styles.rowSubtitle, { color: theme.muted }]}
        >
          {subtitle}
        </Text>
      ) : null}
    </Pressable>
  );
}

/**
 * A full-screen sheet for choosing a place: type to search, or pick from the
 * phone's position (for a start), recent places, or a few well-known ones.
 */
export function PlaceSearchModal({
  visible,
  mode,
  onClose,
  onPick,
  onPickCurrent,
  recents,
  baseUrl,
  near,
  fetchFn,
}: Props) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [query, setQuery] = useState('');
  const search = usePlaceSearch(query, { baseUrl, near, fetchFn });
  const typed = query.trim();
  const searching = typed.length >= MIN_QUERY_LENGTH;

  // Start fresh each time the sheet opens.
  useEffect(() => {
    if (visible) {
      setQuery('');
    }
  }, [visible]);

  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={onClose}
    >
      <View
        style={[
          styles.sheet,
          {
            backgroundColor: theme.background,
            paddingTop: Math.max(insets.top, 16),
          },
        ]}
      >
        <View style={styles.header}>
          <Text
            accessibilityRole="header"
            style={[styles.title, { color: theme.text }]}
          >
            {mode === 'from' ? 'Start from' : 'Where to?'}
          </Text>
          <Pressable accessibilityRole="button" onPress={onClose} hitSlop={12}>
            <Text style={[styles.cancel, { color: theme.accent }]}>Cancel</Text>
          </Pressable>
        </View>

        <TextInput
          accessibilityLabel="Search for a place or address"
          autoFocus
          value={query}
          onChangeText={setQuery}
          placeholder="Search for a place or address"
          placeholderTextColor={theme.muted}
          autoCorrect={false}
          clearButtonMode="while-editing"
          returnKeyType="search"
          style={[
            styles.input,
            {
              color: theme.text,
              borderColor: theme.border,
              backgroundColor: theme.card,
            },
          ]}
        />

        <ScrollView
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={{ paddingBottom: insets.bottom + 24 }}
        >
          {mode === 'from' && onPickCurrent ? (
            <Row
              accent
              title="Use my current location"
              subtitle="Follows you while the app is open"
              onPress={onPickCurrent}
            />
          ) : null}

          {searching ? (
            <>
              {search.loading && search.places.length === 0 ? (
                <View style={styles.status}>
                  <ActivityIndicator color={theme.accent} />
                  <Text style={[styles.statusText, { color: theme.muted }]}>
                    Searching...
                  </Text>
                </View>
              ) : null}
              {search.error ? (
                <Text
                  style={[
                    styles.statusText,
                    styles.message,
                    { color: theme.confidence.Low },
                  ]}
                >
                  {`${search.error.message} You can still pick a recent or well-known place below.`}
                </Text>
              ) : null}
              {search.places.map(place => (
                <Row
                  key={place.id}
                  title={place.name}
                  subtitle={place.address}
                  onPress={() => onPick(place)}
                />
              ))}
              {!search.loading &&
              !search.error &&
              search.forQuery === typed &&
              search.places.length === 0 ? (
                <Text
                  style={[
                    styles.statusText,
                    styles.message,
                    { color: theme.muted },
                  ]}
                >
                  {`No matches for "${typed}". Try the full name or a street address.`}
                </Text>
              ) : null}
            </>
          ) : (
            <Text
              style={[
                styles.statusText,
                styles.message,
                { color: theme.muted },
              ]}
            >
              Type at least {MIN_QUERY_LENGTH} letters to search.
            </Text>
          )}

          {!searching || search.error ? (
            <>
              {recents.length > 0 ? <Heading>RECENT</Heading> : null}
              {recents.map(place => (
                <Row
                  key={`recent-${place.id}`}
                  title={place.name}
                  subtitle={place.address}
                  onPress={() => onPick(place)}
                />
              ))}
              <Heading>WELL-KNOWN PLACES</Heading>
              {QUICK_PICKS.map(place => (
                <Row
                  key={place.id}
                  title={place.name}
                  subtitle={place.address}
                  onPress={() => onPick(place)}
                />
              ))}
            </>
          ) : null}
        </ScrollView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  sheet: { flex: 1, paddingHorizontal: 18 },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 12,
  },
  title: { fontSize: 24, fontWeight: '800' },
  cancel: { fontSize: 16, fontWeight: '600' },
  input: {
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 17,
    marginBottom: 6,
  },
  heading: {
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.8,
    marginTop: 20,
    marginBottom: 4,
  },
  row: { paddingVertical: 14, borderBottomWidth: StyleSheet.hairlineWidth },
  rowTitle: { fontSize: 17, fontWeight: '600' },
  rowSubtitle: { fontSize: 14, marginTop: 2 },
  status: { flexDirection: 'row', alignItems: 'center', paddingVertical: 18 },
  statusText: { fontSize: 14, marginLeft: 8 },
  message: { marginLeft: 0, marginTop: 14, lineHeight: 20 },
});
