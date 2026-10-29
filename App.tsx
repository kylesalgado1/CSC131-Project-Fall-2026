import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
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
import { LatLng } from './src/api/types';
import { Attribution } from './src/components/Attribution';
import { Collapsible } from './src/components/Collapsible';
import { DemoPanel } from './src/components/DemoPanel';
import { EmptyState } from './src/components/EmptyState';
import { Notice } from './src/components/Notice';
import { PlaceSearchModal } from './src/components/PlaceSearchModal';
import { PreferencesPanel } from './src/components/PreferencesPanel';
import { useTheme } from './src/components/theme';
import { TimeLimits } from './src/components/TimeLimits';
import { TripCard } from './src/components/TripCard';
import { VerdictCard } from './src/components/VerdictCard';
import { WaitPlan } from './src/components/WaitPlan';
import { useTrip } from './src/hooks/useTrip';
import { useVerdict, VerdictSource } from './src/hooks/useVerdict';
import { formatTime } from './src/lib/format';
import { DEFAULT_SETTINGS, VerdictSettings } from './src/lib/request';
import { summarizeSettings } from './src/lib/settingsSummary';
import { lastKnownLocation } from './src/location/currentLocation';
import { LocationError } from './src/location/errors';
import { startLabel, swapped } from './src/trip/types';

interface Props {
  /** For tests. */
  baseUrl?: string;
  fetchFn?: typeof fetch;
  locate?: () => Promise<LatLng>;
}

function Screen({ baseUrl = defaultBaseUrl(), fetchFn, locate }: Props) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const { trip, recents, ready, setFrom, setTo, swap } = useTrip();
  const [source, setSource] = useState<VerdictSource>('live');
  const [settings, setSettings] = useState<VerdictSettings>(DEFAULT_SETTINGS);
  const [picking, setPicking] = useState<'from' | 'to' | undefined>();
  // Where the phone last was, used to rank place search results.
  const [located, setLocated] = useState<LatLng | undefined>();

  useEffect(() => {
    lastKnownLocation().then(position => {
      if (position) {
        setLocated(current => current ?? position);
      }
    });
  }, []);

  const state = useVerdict({
    source,
    trip,
    settings,
    baseUrl,
    fetchFn,
    locate,
    onLocated: setLocated,
  });
  const { response, loading, refreshing, error, updatedAt, change } = state;
  const near =
    located ?? (trip.from.kind === 'place' ? trip.from.place : trip.to);
  const live = source === 'live';
  const locationError = error instanceof LocationError ? error : undefined;

  return (
    <ScrollView
      style={{ backgroundColor: theme.background }}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + 12, paddingBottom: insets.bottom + 32 },
      ]}
      keyboardShouldPersistTaps="handled"
      refreshControl={
        <RefreshControl
          refreshing={refreshing && !loading}
          onRefresh={state.refresh}
        />
      }
    >
      <Text style={[styles.title, { color: theme.text }]}>Wait It Out</Text>
      <Text style={[styles.subtitle, { color: theme.muted }]}>
        Know when to leave
      </Text>

      <TripCard
        fromLabel={startLabel(trip.from)}
        fromIsCurrent={trip.from.kind === 'current'}
        locating={state.locating}
        toLabel={trip.to?.name}
        onPressFrom={() => setPicking('from')}
        onPressTo={() => setPicking('to')}
        onSwap={swapped(trip) ? swap : undefined}
      />

      <TimeLimits
        leaveBy={settings.leaveBy}
        arriveBy={settings.arriveBy}
        onChange={(field, time) =>
          setSettings(current => ({ ...current, [field]: time }))
        }
      />

      {!live ? (
        <Notice kind="info" title="Sample data">
          This is a made-up answer to show what the screen looks like. It is not
          live traffic, and it ignores the trip above.
        </Notice>
      ) : null}

      {change ? (
        <Notice kind="update" title="Advice changed">
          {change}
        </Notice>
      ) : null}

      {locationError ? (
        <Notice
          kind="error"
          title="Can't find your location"
          actions={[
            ...(locationError.problem === 'denied'
              ? [
                  {
                    label: 'Open Settings',
                    onPress: () => Linking.openSettings(),
                  },
                ]
              : []),
            {
              label: 'Choose a starting address',
              onPress: () => setPicking('from'),
            },
            { label: 'Try again', onPress: state.refresh },
          ]}
        >
          {locationError.message}
        </Notice>
      ) : error ? (
        <Notice
          kind="error"
          title={response ? 'Could not refresh' : 'Something went wrong'}
        >
          {response
            ? `${error.message} Showing the last answer.`
            : error.message}
        </Notice>
      ) : null}

      {!ready ? (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.accent} />
        </View>
      ) : live && !trip.to ? (
        <EmptyState
          onChooseDestination={() => setPicking('to')}
          onPick={setTo}
        />
      ) : loading && !error ? (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.loadingText, { color: theme.muted }]}>
            {state.locating
              ? 'Finding your location...'
              : 'Checking traffic for the next three hours...'}
          </Text>
        </View>
      ) : null}

      {response ? (
        <View style={styles.verdict}>
          <VerdictCard verdict={response.verdict} />
          <WaitPlan
            verdict={response.verdict}
            baseUrl={baseUrl}
            located={located}
            locate={locate}
            fetchFn={fetchFn}
          />
        </View>
      ) : null}

      {updatedAt ? (
        <View style={styles.footer}>
          <Text style={[styles.updated, { color: theme.muted }]}>
            Updated {formatTime(updatedAt)}
            {live ? ' · refreshes every 5 minutes' : ''}
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
      {response && live ? <Attribution /> : null}

      <Collapsible title="Preferences" summary={summarizeSettings(settings)}>
        <PreferencesPanel settings={settings} onChange={setSettings} />
      </Collapsible>

      <Collapsible
        title="Demo options"
        summary={live ? 'Live traffic' : 'Showing a sample'}
      >
        <DemoPanel source={source} onChange={setSource} />
      </Collapsible>

      {live ? (
        <Text style={[styles.server, { color: theme.muted }]}>
          Server: {baseUrl}
        </Text>
      ) : null}

      <PlaceSearchModal
        visible={picking !== undefined}
        mode={picking ?? 'to'}
        onClose={() => setPicking(undefined)}
        onPick={place => {
          if (picking === 'from') {
            setFrom({ kind: 'place', place });
          } else {
            setTo(place);
          }
          setPicking(undefined);
        }}
        onPickCurrent={() => {
          setFrom({ kind: 'current' });
          setPicking(undefined);
        }}
        recents={recents}
        baseUrl={baseUrl}
        near={near}
        fetchFn={fetchFn}
      />
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
  title: { fontSize: 30, fontWeight: '800', letterSpacing: -0.5 },
  subtitle: { fontSize: 16, marginTop: 2 },
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
