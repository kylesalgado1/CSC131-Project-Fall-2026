import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';
import { defaultBaseUrl } from './src/api/baseUrl';
import { Attribution } from './src/components/Attribution';
import { Notice } from './src/components/Notice';
import { SettingsPanel } from './src/components/SettingsPanel';
import { useTheme } from './src/components/theme';
import { VerdictCard } from './src/components/VerdictCard';
import { useVerdict, VerdictSource } from './src/hooks/useVerdict';
import { formatTime } from './src/lib/format';
import { DEFAULT_SETTINGS, VerdictSettings } from './src/lib/request';
import { DEMO_TRIPS } from './src/trips';

interface Props {
  /** For tests. */
  baseUrl?: string;
  fetchFn?: typeof fetch;
}

function Screen({ baseUrl = defaultBaseUrl(), fetchFn }: Props) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [tripId, setTripId] = useState(DEMO_TRIPS[0].id);
  const [source, setSource] = useState<VerdictSource>('live');
  const [settings, setSettings] = useState<VerdictSettings>(DEFAULT_SETTINGS);
  const trip = DEMO_TRIPS.find(t => t.id === tripId) ?? DEMO_TRIPS[0];

  const state = useVerdict({ source, trip, settings, baseUrl, fetchFn });
  const { response, loading, refreshing, error, updatedAt, change } = state;

  return (
    <ScrollView
      style={{ backgroundColor: theme.background }}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + 12, paddingBottom: insets.bottom + 32 },
      ]}
      refreshControl={
        <RefreshControl
          refreshing={refreshing && !loading}
          onRefresh={state.refresh}
        />
      }
    >
      <Text style={[styles.title, { color: theme.text }]}>Wait It Out</Text>
      <Text style={[styles.subtitle, { color: theme.muted }]}>
        {trip.label}
      </Text>

      {source !== 'live' ? (
        <Notice kind="info" title="Sample data">
          This is a made-up answer to show what the screen looks like. It is not
          live traffic.
        </Notice>
      ) : null}

      {change ? (
        <Notice kind="update" title="Advice changed">
          {change}
        </Notice>
      ) : null}

      {error && !response ? (
        <Notice kind="error" title="Something went wrong">
          {error.message}
        </Notice>
      ) : null}

      {loading && !error ? (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.loadingText, { color: theme.muted }]}>
            Checking traffic for the next three hours...
          </Text>
        </View>
      ) : null}

      {response ? (
        <View style={styles.verdict}>
          <VerdictCard verdict={response.verdict} />
        </View>
      ) : null}

      {response && error ? (
        <Notice kind="error" title="Could not refresh">
          {`${error.message} Showing the last answer.`}
        </Notice>
      ) : null}

      {updatedAt ? (
        <View style={styles.footer}>
          <Text style={[styles.updated, { color: theme.muted }]}>
            Updated {formatTime(updatedAt)}
            {source === 'live' ? ' · refreshes every 5 minutes' : ''}
          </Text>
          <Pressable
            accessibilityRole="button"
            onPress={state.refresh}
            disabled={refreshing}
          >
            <Text style={[styles.refresh, { color: theme.accent }]}>
              {refreshing ? 'Refreshing...' : 'Refresh now'}
            </Text>
          </Pressable>
        </View>
      ) : null}

      {response && source === 'live' ? <Attribution /> : null}

      <SettingsPanel
        tripId={tripId}
        onTripChange={setTripId}
        source={source}
        onSourceChange={setSource}
        settings={settings}
        onSettingsChange={setSettings}
      />

      {source === 'live' ? (
        <Text style={[styles.server, { color: theme.muted }]}>
          Server: {baseUrl}
        </Text>
      ) : null}
    </ScrollView>
  );
}

export default function App(props: Props) {
  const theme = useTheme();
  return (
    <SafeAreaProvider>
      <StatusBar style={theme.dark ? 'light' : 'dark'} />
      <Screen {...props} />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  content: { paddingHorizontal: 18 },
  title: { fontSize: 28, fontWeight: '800', letterSpacing: -0.4 },
  subtitle: { fontSize: 16, marginTop: 2, marginBottom: 6 },
  loading: { alignItems: 'center', paddingVertical: 36 },
  loadingText: { marginTop: 10, fontSize: 14 },
  verdict: { marginTop: 14 },
  footer: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: 12,
  },
  updated: { fontSize: 13, flex: 1 },
  refresh: { fontSize: 14, fontWeight: '700' },
  server: { fontSize: 12, marginTop: 28 },
});
