# WAIT IT OUT - iOS app (SwiftUI) connected to the team backend

A SwiftUI app (iOS 17+) for the WAIT IT OUT user experience. It began as a self-contained
prototype (steps 0001 to 0008, below) and is now connected to the team backend (stages S1 to
S3):

- **Live data is the normal flow.** Each leave-home time is the backend's traffic-based
  recommendation for the activity's ideal arrival, shown as the backend gave it; the Map draws
  the backend's driving route when it has one; and with leave-home reminders on, the server
  monitors the upcoming trips and sends push alerts. The Map says "Team backend".
- **The Demo data mode is explicit.** Under Settings > Data source the user can choose "Demo
  (simulated)": the standalone prototype exactly as it was, with a simulated test commute, a
  schematic line, and in-app reminder previews, all labeled. A failed live request is never
  replaced by a simulated value.
- **Still not used:** device location, address lookup, and accounts. Home and campus are typed
  in Settings. Notification permission is asked for only when the user turns leave-home
  reminders on in Live mode.

**Current state: backend integration, stage S3 with the review fixes (2026-11-19).** The host
composes the backend adapters, the screens show the live states honestly (loading, current,
refreshing, kept out of date, unavailable, arrival no longer reachable, notifications not
allowed, trips pending or failed, a trip the server cannot plan, a withdrawal the server did
not confirm), and the structural checker confines network and notification APIs to their
allow-listed files. Start with [`docs/BACKEND_INTEGRATION.md`](docs/BACKEND_INTEGRATION.md):
the requests, what is sent, every state and its wording, configuration, and push setup.

**Verified so far, and not.** The build, 845 unit tests, and the UI tests run on a Mac with the
iOS Simulator. The unit tests decode response bodies captured from the real backend code and
one real answer of the deployed backend through the app's own decoding path. In stage S3 the
app was launched in Live mode on the simulator against an address where nothing listens and
against a stand-in server on the same machine. **Not verified by the runs recorded here:** a
request from the app to a running team backend (the end-to-end UI tests against the backend's
fixture server exist but were skipped, because that server was not running), and anything
that needs Apple's push service (no physical device, no delivery through Apple). Details are
in "Validation status" and "Known limitations of the backend integration" below.

The prototype steps were delivered in order (0001 to 0008); the rest of this introduction
describes them, and everything it says still holds in the Demo data mode.

**Step 0008 - verify the standalone demo and prepare the team handoff.** Step 0008
reviewed the whole prototype end to end, fixed the defects listed in "QA review and fixes (step
0008)", added an end-to-end demo test, product-contract checks, and an accessibility-size UI
test, made the three tab screens public for integration, and wrote
[`docs/TEAM_INTEGRATION.md`](docs/TEAM_INTEGRATION.md). Start with the "Manual demo checklist"
below. Earlier steps, in order: step 0007 persisted the prototype and implemented reminder previews (on top of 0001:
Map, Calendar, Settings tabs, demo map, Sunday-Saturday week navigation, appearance setting;
0002: the `Activity` domain with validation, time-zone-aware weekly recurrence with a
documented daylight-saving policy, stable occurrence identities, the `ActivityRepository`
boundary, and the labeled sample schedule; 0003: the day strip, time grid, blocks,
ideal-arrival markers, overlap columns, current-time line, and detail sheet; 0004: Add
Activity, drag creation, the compact editor, block adjustment, and series edit and delete;
and 0005: the `CommuteEstimating` boundary with a labeled `TestCommuteProvider`, a validated
test commute duration in Settings, and the pure calculation **leave home = ideal arrival -
travel time**, shown read-only in Calendar details, the editor, and a next-trip card).
Step 0006 added typed **home and campus** places in Settings (no location permission,
geocoding, or network lookup) and sends the home as the origin of every commute request. It
completed the Map: home and campus pins joined by a dashed line labeled as schematic, not a
route; a camera that fits both; a next-trip card with the event, ideal arrival, read-only
leave-home time, and the estimate's source and age; and an always-visible "Demo estimate"
label. A **Prototype testing** section in Settings switches the test provider between
deterministic Normal, Slow, Unavailable, and Error scenarios. While a new estimate loads, an
earlier time stays visible marked out of date, and only failures offer Try Again. See "Map,
home and campus, and prototype testing (step 0006)" and "Leave-home times (step 0005)" below,
and [`docs/COMMUTE_ESTIMATION.md`](docs/COMMUTE_ESTIMATION.md) for the service contract.

Step 0007 **saves committed activities and settings on the device** as versioned JSON files
in Application Support, behind the existing `ActivityRepository` and `PreferencesStoring`
boundaries, with atomic writes, the previous valid data kept on every failure, and explicit
recovery (Try Again, or Keep a Copy and Start Over) when saved data cannot be read; unreadable
data is never replaced silently. It adds **leave-home reminder previews** behind a new
`ReminderScheduling` boundary: turning reminders on in Settings shows the next reminder's time
and message, labeled "Preview only - no system notification will be sent." Previews follow
every edit, estimate, toggle, relaunch, and return to the foreground, keyed by the stable
occurrence id, with a deterministic failure simulation and Try Again. See "Persistence and
reminder previews (step 0007)" below and [`docs/REMINDERS.md`](docs/REMINDERS.md).

## Directory layout

```
WaitItOutUXPrototype.xcodeproj/        Xcode project (native pbxproj, no generator required)
  xcshareddata/xcschemes/
    WaitItOutUXPrototype.xcscheme      Shared scheme: builds the app, runs both test bundles
WaitItOutUXPrototype/                  Thin app host (target WaitItOutUXPrototype)
  WaitItOutUXPrototypeApp.swift        @main entry point; shows WaitItOutRootView
  AppDependencies.swift                Composition root: the live backend graph or the standalone
                                       demo, and AppComposition (one model and one backend
                                       session per process) (stage S3)
  AppDelegate.swift                    Push token and notification responses, forwarded to the
                                       model; registers the trip notification category (stage S3)
  SystemPushRegistrar.swift            PushRegistering over the system notification permission
                                       and push registration (stage S3)
  Info.plist                           Partial: the default server address and local networking
                                       only; everything else is generated (stage S3)
  WaitItOutUXPrototype.entitlements    aps-environment = development (stage S3)
  Assets.xcassets/                     App icon placeholder and accent color
WaitItOutUXPrototypeUITests/           XCUITest bundle
  LaunchNavigationUITests.swift        Launch, tab navigation, sample schedule, detail sheet
  ActivityEditingUITests.swift         Validation, picker creation, drag creation, series edit
                                       and delete, unsaved-change bar (step 0004)
  DepartureUITests.swift               Map setup action, read-only leave-home lines, Settings
                                       test commute validation, next trip (step 0005)
  MapScenarioUITests.swift             Map demo label, places card and schematic note, scenario
                                       switching with Try Again only for Error, place editor
                                       validation and reset (step 0006)
  PersistenceReminderUITests.swift   Relaunch keeps data, preview-only reminder wording, Try Again (step 0007)
  DemoAccessibilityUITests.swift     Tabs in order, labels, Add Activity and time controls, read-only
                                       leave-home line at an accessibility text size (step 0008)
  LiveModeUITests.swift                The live composition against an unreachable loopback
                                       address: honest failure, no simulated time, and the Demo
                                       data mode switched on and off in Settings (stage S3);
                                       and FixtureBackendEndToEndUITests, opt-in, against the
                                       backend's fixture server on this machine
Packages/WaitItOutUX/                  Local Swift package with all reusable feature code
  Package.swift                        swift-tools-version 5.9, platform iOS 17, Swift 5 mode
  Sources/WaitItOutUX/                 Library target "WaitItOutUX"
    WaitItOutRootView.swift            Public root view (TabView: Map, Calendar, Settings)
    WaitItOutModel.swift               Shared @Observable feature state used by every tab
                                       (visible week, selected day, calendar scroll row, activities)
    WeekCalculator.swift               Pure Sunday-Saturday week math (DST-safe), day ranges and indices
    WeekTitleFormatter.swift           Week and day titles, including VoiceOver forms
    WallClock.swift                    Clock boundary (SystemWallClock, FixedWallClock)
    Preferences.swift                  UserPreferences (appearance, test duration, scenario, places,
                                       reminder wish, reminder failure simulation, data mode,
                                       server address), PreferencesStoring, in-memory store
    SampleLocation.swift               Labeled demo campus and home: coordinate, time zone, destination
    PrototypeTab.swift, PrototypeInfo.swift
    Activities/                        Activity domain (step 0002)
      Activity.swift                   Activity value, ActivitySource
      Destination.swift                GeoCoordinate, DestinationID, Destination
      Weekday.swift                    Sunday-first weekday enum with localized names
      LocalTime.swift                  LocalDate, WallTime, LocalDateTime, LocalTimeResolver (DST policy)
      ActivityValidator.swift          Pure validation: issues, fields, messages
      ActivityOccurrence.swift         OccurrenceID and ActivityOccurrence
      OccurrenceExpander.swift         Pure, bounded expansion of activities into occurrences
      ActivityRepository.swift         ActivityRepository protocol, InMemoryActivityRepository
      SampleActivities.swift           The two labeled sample classes with fixed ids
      OccurrenceFormatter.swift        Time range, arrival, repeat, and VoiceOver text
      CountPhrase.swift                "1 activity" / "2 activities" helper
    Calendar/                          Pure calendar geometry (step 0003)
      DayTimelineLayout.swift          Hour rows per day (23/24/25), date-to-offset, interval clipping
      OverlapLayout.swift              Side-by-side columns for overlapping intervals
      DaySchedule.swift                Blocks, arrival markers, and scroll hint for one day
      CalendarLayoutMode.swift         Selected-day versus seven-column choice; block text levels
      GridDrag.swift                   Snapping, creation intervals, move/resize clamps, DraftPreview
    Editing/                           Drafts and editing state (step 0004)
      ActivityDraft.swift              Editable copy of an activity; editor and gesture operations
      ActivityEditSession.swift        Pending draft, mode, commit state, visible issues
      WaitItOutModel+Editing.swift     Begin, update, save, cancel, and delete a draft
      OccurrenceFormatter+Editing.swift  Editor and unsaved-change bar text
    Commute/                           Commute estimates and leave-home times (step 0005)
      CommuteDuration.swift            Validated travel time (1 s to 12 h), Settings minutes parser
      CommuteEstimating.swift          Protocol, CommuteRequest (origin, destination, arriveBy),
                                       CommuteEstimate, response (estimate, recommendation,
                                       unavailable, not yet), CommuteProviderFailure, contract
      DepartureRecommendation.swift    Backend recommendation, advice, confidence, source (stage S1)
      DepartureWording.swift           Mode-dependent explanations: demo formula or team backend
      TestCommuteProvider.swift        Labeled simulated provider: duration, scenario (Normal, Slow,
                                       Unavailable, Error), delays
      DepartureCalculation.swift       Pure formula, calculation, timing, result states (incl. refreshing
                                       and a kept out-of-date recommendation)
      DepartureHorizon.swift           7-day planning set and the next trip (pure)
      EstimateFreshness.swift          Estimate age and lifetimes: 10 minutes for the demo, and
                                       the backend's rhythm for recommendations, one 15-minute
                                       slot apart for a nearby departure (step 0006, stage S1, pure)
      WaitItOutModel+Departures.swift  Refresh, draft preview, stale-answer protection, freshness,
                                       kept recommendations, automatic retry with backoff,
                                       Settings duration and scenario
      OccurrenceFormatter+Departure.swift  Leave-home, formula, source and age, simulation, warning text
    Places/                            Home and campus (step 0006)
      CommutePlace.swift               PlaceRole, PlaceIssue, CommutePlace (valid by construction),
                                       CommutePlaces (tolerant decoding, sample pair)
      PlaceInput.swift                 Typed name and strict decimal-degree parsing and validation
      WaitItOutModel+Places.swift      Places, campus resolution, apply/set/reset, request building
    Map/                               Pure map geometry (step 0006) and the route state (stage S1)
      MapCameraFit.swift               CoordinateRegion, camera fit, distance and midpoint helpers
      RouteGeometry.swift              RouteGeometry, RouteProviding, RouteState, MapRouteText
      WaitItOutModel+Route.swift       Token-guarded route request for home to campus
    Backend/                           Team backend adapter (stage S1)
      BackendConfiguration.swift       Server address: default, Settings override, validation
      HTTPTransport.swift              The one network boundary
      URLSessionTransport.swift        Production transport; the only file that may name the
                                       system networking session
      BackendWire.swift                JSON shapes and ISO-8601 dates of the wire contract
      BackendClient.swift              Requests, status and error mapping
      BackendCommuteProvider.swift     CommuteEstimating over the backend's verdict
      BackendRouteProvider.swift       RouteProviding over the backend's route geometry
      BackendSession.swift             TripMonitoring over the backend's device and trip
                                       endpoints: registration, snapshot revisions, push
                                       reporting, monitored answers (stage S2)
      CredentialStore.swift            CredentialStoring, StoredCredential, in-memory and
                                       Keychain stores, one credential per server origin (stage S2)
      TripNotificationPayload.swift    The trip notification's payload keys and category (stage S2)
                                       and how a notification response is read (stage S3)
      LiveBackend.swift                What the host passes to run on the backend
      BackendLaunchOptions.swift       What the host reads at launch: the composition and the
                                       default server address (stage S3, pure)
      BackendConnection.swift          The Settings connection status, derived from answers and
                                       failures already on screen (stage S3, pure)
      DataSourceWording.swift          Settings sentences that differ between Live and Demo
                                       (stage S3, pure)
      WaitItOutModel+DataSource.swift  Data mode, server address, source changes
    Monitoring/                        Server-side trip monitoring (stage S2)
      TripMonitoring.swift             The boundary: MonitoredTrip, trip states, snapshot,
                                       TripMonitoring, MonitoredTripSource, PushRegistering
      MonitoringStatus.swift           MonitoringStatus, DepartedState, MonitoringWithdrawal,
                                       MonitoringObstacle, MonitoringSummary, MonitoringText
      WaitItOutModel+Monitoring.swift  Wanted trips, reconciliation, refresh, withdrawal,
                                       permission, "I've left", notification handling
      OccurrenceFormatter+Monitoring.swift  Monitoring lines and the status line
      MonitoringPresentation.swift     What the monitoring views show in each state, and when the
                                       Calendar presents a notification's trip (stage S3, pure)
    Persistence/                       Saved activities and settings (step 0007)
      FileAccessing.swift              FileAccessing, LocalFileAccess (atomic writes),
                                       PrototypeStorageLocation (Application Support folder)
      FileStores.swift                 FileActivityRepository and FilePreferencesStore actors
      VersionedJSONFile.swift          Envelope (schemaVersion, kind, payload), StorageSchema,
                                       PersistenceError
      StorageIssue.swift               StorageArea, StorageIssue for the Saved data section
    Reminders/                         Leave-home reminder previews (step 0007)
      ReminderScheduling.swift         Protocol, ReminderDelivery, ScheduledReminder,
                                       PreviewReminderScheduler (in-app only, failure simulation)
      ReminderPlan.swift               Pure plan, ReminderGap, ReminderChanges, ReminderSyncState,
                                       ReminderPreview
      WaitItOutModel+Reminders.swift   Reminder wish, reconciliation, Try Again, foreground
      OccurrenceFormatter+Reminders.swift  Reminder time, title, and message text
    Design/                            Spacing, colors, DemoBadge, accessibility IDs
    Screens/                           MapScreen, CalendarScreen, SettingsScreen
      Calendar/                        DayStripView, TimeGridView (+DayColumnView),
                                       OccurrenceBlockView (+ArrivalMarkerView, CurrentTimeLineView),
                                       OccurrenceDetailView, DraftBarView (unsaved-change bar)
      Editor/                          ActivityEditorView, WeekdayRepeatPicker
      Departure/                       DepartureRows: read-only leave-home rows (details, editor, Map)
      Map/                             NextTripCard (next trip or a setup action), MapPlacesCard
                                       (home and campus, schematic note, fit and Settings actions),
                                       DemoEstimateLabel (navigation-bar label in the Demo data
                                       mode), LiveDataLabel (its Live counterpart, stage S3)
      Monitoring/                      MonitoringStatusView (Settings and the Map card in Live
                                       mode) and TripDepartedControl ("I've Left") (stage S3)
      Settings/                        PlaceEditorView (place editor sheet), PlacesSettingsSection
      Reminders/                       ReminderPreviewView (Settings and the Map card; always
                                       prints the preview-only disclosure)
    PreviewFixtures.swift              Preview-only model fixtures (never used by the host)
  Tests/WaitItOutUXTests/              XCTest target "WaitItOutUXTests" (unit tests);
    Support/                           Test doubles: ManualWallClock, ScriptedActivityRepository,
                                       Failing/RecordingPreferencesStore, Scripted/Gated
                                       CommuteEstimator, RecordingReminderScheduler,
                                       InMemoryFileAccess, TestFixtures
                                       step 0006 adds CommutePlaceTests, MapCameraFitTests,
                                       TestCommuteScenarioTests, WaitItOutModelMapTests
                                       step 0007 adds PersistenceStoreTests, ReminderPlanTests,
                                       WaitItOutModelPersistenceTests, WaitItOutModelReminderTests
                                       step 0008 adds EndToEndDemoTests (the whole demo path)
                                       stage S1 adds Support/TestBackend (scripted HTTPTransport,
                                       backend-shaped bodies), DepartureRecommendationTests,
                                       RecommendationTextTests, BackendConfigurationTests,
                                       BackendWireTests, BackendCommuteProviderTests,
                                       BackendRouteProviderTests, WaitItOutModelBackendTests,
                                       WaitItOutModelRouteTests
                                       stage S2 adds Support/TestMonitoring (RecordingTripMonitor,
                                       FakePushRegistrar, HeldTransport, FakeTripServer),
                                       BackendSessionTests, CredentialStoreTests, TripWireTests,
                                       MonitoringTextTests, WaitItOutModelMonitoringTests,
                                       WaitItOutModelLiveMonitoringTests
                                       stage S3 adds MonitoringPresentationTests,
                                       DataSourceWordingTests, BackendConnectionTests,
                                       WaitItOutModelMonitoringScreenTests, BackendLaunchOptionsTests
                                       the review fixes add RealBackendShapesTests (bodies
                                       captured from the real backend, verbatim),
                                       WaitItOutModelMonitoringStateTests, WaitItOutModelLiveDraftTests
scripts/check_project_structure.py     Static consistency and product-contract check (not a build)
docs/                                  Design and handoff documents
  BACKEND_INTEGRATION.md               The backend requests, data sent, states and wording,
                                       configuration, push setup, what was verified (stage S3)
  COMMUTE_ESTIMATION.md                Leave-home formula, the CommuteEstimating contract, and
                                       backend recommendations
  REMINDERS.md                         ReminderScheduling contract, server-side monitoring, and
                                       the local-notification recipe
  TEAM_INTEGRATION.md                  Handoff: entry points, state owner, adapters, schema (step 0008)
AGENTS.md                              Working conventions for later work
```

## Host versus package boundary

- The **app host** (`WaitItOutUXPrototype`) owns the process entry point, the composition,
  and the two system APIs the package never names: notification permission with push
  registration, and the application delegate's callbacks. `AppDependencies.makeGraph()` chooses
  the concrete clock, preferences store, activity repository, commute provider, reminder
  adapter, calendar, sample campus and home, and bundle info, and, unless the launch asks for
  the standalone demo, the live backend graph. `AppComposition.shared` builds the one shared
  `WaitItOutModel` (and the one `BackendSession`) exactly once per process; every tab and the
  `AppDelegate` read them there. The host decides nothing else: what a launch composes
  (`BackendLaunchOptions`) and what a notification response means
  (`TripNotificationPayload.response`) are pure package code with tests.
- The **package** (`WaitItOutUX`) owns domain values, service protocols, feature state, and
  every SwiftUI screen. It never imports host types. Its public surface is intentionally
  small: `WaitItOutRootView`, the three tab screens (`MapScreen`, `CalendarScreen`,
  `SettingsScreen`, public since step 0008), `WaitItOutModel`, the value types it exposes, and the
  `WallClock`, `PreferencesStoring`, `ActivityRepository`, `CommuteEstimating`,
  `ReminderScheduling`, and `FileAccessing` protocols with their default implementations.
- The team integrates the package and its root view into its own app; the prototype host is
  not meant to be copied.

Integration boundaries present after step 0007:

| Boundary | Protocol | Prototype implementation |
| --- | --- | --- |
| Current time | `WallClock` | `SystemWallClock` (host), `FixedWallClock` (previews/tests) |
| Settings storage | `PreferencesStoring` | `FilePreferencesStore`: `preferences.json` in Application Support (host); `InMemoryPreferencesStore` for previews and tests |
| Activity storage | `ActivityRepository` | `FileActivityRepository`: `activities.json` in Application Support (host); `InMemoryActivityRepository` for previews and tests |
| File I/O for both stores | `FileAccessing` | `LocalFileAccess` (`FileManager`, atomic writes); tests inject an in-memory fake with read, write, and move failures |
| Reminders | `ReminderScheduling` | `PreviewReminderScheduler`: in-app previews only, no permission, no system notification, deterministic failure simulation ([`docs/REMINDERS.md`](docs/REMINDERS.md)) |
| Commute estimation | `CommuteEstimating` | `TestCommuteProvider` (simulated: the Settings test duration shaped by the Prototype testing scenario, Normal, Slow, Unavailable, or Error; labeled TEST DATA) |
| Home and campus | `PreferencesStoring` (`UserPreferences.places`) | Typed `CommutePlace` values entered in Settings and kept by the settings store with the other preferences; the labeled samples until edited. No location permission, geocoding, or network lookup |

No route-display adapter or routing framework was built in step 0006: the Map draws a
schematic straight line between the two configured places, which needs only their
coordinates. How a team provider would supply real route geometry later is described in
[`docs/COMMUTE_ESTIMATION.md`](docs/COMMUTE_ESTIMATION.md) ("Replacing the mock route and
commute provider"). How the team replaces the reminder preview adapter with its notification
service is described in [`docs/REMINDERS.md`](docs/REMINDERS.md).

### Team backend adapter (stage S1)

Stage S1 added the package side of the team backend integration. The standalone demo above
is unchanged and remains available as the Demo data mode; since stage S3 the host passes a
`LiveBackend`, so the backend is the app's normal source (see "Host, screens, and checker
(stage S3)" below).

| Boundary | Protocol or type | Implementation in the package |
| --- | --- | --- |
| Network | `HTTPTransport` | `URLSessionTransport` (ephemeral session, 25 s request and 60 s exchange timeouts, no cookies or cache); tests inject a scripted transport and never open a connection |
| Backend API | `BackendClient` on a `BackendConfiguration` | Requests, the server address (host default plus the Settings override), status and error mapping |
| Departure recommendations | `CommuteEstimating` | `BackendCommuteProvider`: the backend's verdict as a `DepartureRecommendation`, shown as is |
| Route geometry | `RouteProviding` | `BackendRouteProvider`; the Map draws a solid, labeled route only when one arrived |
| Trip monitoring (stage S2) | `TripMonitoring`, `MonitoredTripSource` | `BackendSession`: device registration, trip snapshots, the server's state, "I've left", removal |
| Device credential (stage S2) | `CredentialStoring` | `KeychainCredentialStore` (one item per server origin, this device only); `InMemoryCredentialStore` for previews and tests |
| Notification permission and push registration (stage S2) | `PushRegistering` | None in the package: the host's `SystemPushRegistrar` implements it over the system APIs (stage S3) |

When a host passes `liveBackend:` to `WaitItOutModel.init`, the backend decides every leave-home
time and the app adds no arithmetic or buffer of its own. `TestCommuteProvider` and the reminder
previews then remain only as the explicit Demo data mode (`UserPreferences.dataMode`,
`setDataMode(_:)`). A failed live request is never replaced by a simulated value: the last
recommendation is kept, marked out of date, with Try Again, and transient failures are retried
on the minute ticks. The states and their wording are in
[`docs/COMMUTE_ESTIMATION.md`](docs/COMMUTE_ESTIMATION.md) ("Backend recommendations").

### Trip monitoring (stage S2)

Stage S2 added the package side of server-side leave-home alerts. The host, the monitoring
screens, the Settings "Data source" section, and the checker's notification rules followed in
stage S3 (next section).

- **Who sends alerts.** With the live backend in use and "Remind me when it is time to leave"
  on, the server monitors the upcoming trips and sends the alerts. The app schedules no local
  reminder in Live mode and does not use the preview adapter there; the Demo data mode keeps
  the in-app previews exactly as before and takes the trips off the server.
- **What is sent.** The complete set of upcoming trips (at most 20; saved occurrences of the
  next 7 days whose ideal arrival is ahead): the stable occurrence id, the title, the home and
  destination coordinates, the ideal arrival, and the time zone, under an anonymous
  installation credential kept in the Keychain. That is exactly what the server uses; the
  activity's start time and the destination's name are not sent. Nothing is sent before the
  saved schedule has been read, and nothing while it or the saved settings cannot be read.
- **How far ahead.** The trips are sent only while the app is open (launch, foreground,
  changes), so alerts are set up for the next 7 days as of the last time it was open and stop
  for later trips until it is opened again. Settings says so and names the day.
- **Honest status.** `monitoringStatus` is `pending` until the server acknowledged exactly the
  trips the app wants monitored, then `active`; `failed` with the reason and Try Again; `paused`
  while saved activities cannot be read; `off` otherwise. `monitoringObstacle` names the one thing
  that keeps alerts from being described as active (notifications not allowed or turned off,
  no push credentials on the server, no device token, a server that does not run monitoring or
  only checks while it is awake). A trip the server itself cannot plan or re-check (no traffic
  data for the route, its daily traffic checks used up, a failed check, no departure to
  recommend yet) is named with that reason and is never described as alerted. Turning
  reminders off, choosing Demo, or changing the server address withdraws the installation from
  the server; the credential is dropped only when the server confirmed, and the app says so
  when the server could not be told or did not confirm.
- **One answer everywhere.** While the server keeps a monitored plan current (it is monitoring
  the trip, its worker runs, the plan is not stale, the departure is ahead, and no
  time-to-leave or late alert went out), that plan is the leave-home time on every screen
  (`DepartureRecommendation.isMonitored`), so what the alerts say is what the app shows. The
  model reads the server's state again on the minute ticks and asks again only for the trips
  whose plan changed. In every other case the backend is asked directly, so after the "Time
  to leave" alert, or on a server whose worker is off, the screen shows the backend's current
  answer and never a plan nobody refreshes.
- **"I've left"** ends monitoring for one trip, for exactly the arrival time the user meant;
  success is shown only after the server answered.
- **Notifications.** The host forwards a tapped notification to
  `handleNotificationAction(tripID:action:arriveBy:)` after `prepareForNotificationResponse()`;
  the Calendar presents `tripToPresent`. The package never names the system notification APIs:
  permission and push registration go through the host's `PushRegistering` adapter.

The reconciliation rules are in [`docs/REMINDERS.md`](docs/REMINDERS.md) ("With the team
backend: server-side monitoring").

### Host, screens, and checker (stage S3)

Stage S3 makes the backend the running app's normal flow.

- **Composition.** `AppDependencies.makeGraph()` builds one `BackendClient` on
  `URLSessionTransport`, one `BackendSession` with `KeychainCredentialStore` and
  `SystemPushRegistrar`, `BackendCommuteProvider` (which answers from the session for monitored
  trips), and `BackendRouteProvider`, and passes them to the model as a `LiveBackend`.
  `TestCommuteProvider` and `PreviewReminderScheduler` are still passed, for the Demo data
  mode only. `AppComposition.shared` holds the result for the scene and the `AppDelegate`.
- **Launch options** (`BackendLaunchOptions`, pure). `WAIT_IT_OUT_DATA_MODE=demo` in the launch
  environment composes the standalone prototype with no backend at all; every existing UI test
  sets it, so those tests exercise exactly the deterministic demo they were written for. The
  default server address is `WAIT_IT_OUT_BACKEND_URL` when set, else the Info.plist key
  `WaitItOutBackendURL` (`http://localhost:3000`). An unusable environment address leaves the
  app "Not configured" instead of falling back to another server.
- **Settings.** A "Data source" section after "Saved data" (only with a live backend): the
  "Traffic data" choice between "Live (team backend)" and "Demo (simulated)", the server
  address with inline validation, a connection status that says "Connected" only of a server
  that answered, and a footer listing what is sent. In Live mode the reminders section shows
  the server's monitoring (`MonitoringStatusView`) instead of a preview, and "Saved data" and
  "Prototype information" no longer claim that nothing leaves the device. "Prototype testing"
  appears only in the Demo data mode.
- **Map and Calendar.** "Team backend" in the Map's navigation bar; the next-trip card and the
  Calendar details show the monitoring state for the trip and "I've Left" while the server
  monitors it; a tapped notification opens the trip's details in the Calendar.
- **Notifications.** `AppDelegate` forwards the push token and notification responses to the
  model. The "I've left" action opens the app, which tells the server and shows the outcome;
  nothing is sent from the background and no background mode is declared.
- **Project.** `WaitItOutUXPrototype.entitlements` carries `aps-environment` = `development`, and
  a partial `Info.plist` (merged with the generated one) holds the default server address and
  `NSAllowsLocalNetworking`. No `DEVELOPMENT_TEAM` is set: simulator builds need none. A device
  build does, and because of the entitlement it has to be a team whose App ID has the Push
  Notifications capability (see "Requirements").
- **Checker.** See "Static checks".

| Launch | Composition | What the user sees |
| --- | --- | --- |
| Normal | Live backend, with the demo adapters kept for the Demo data mode | "Team backend" on the Map; Settings has Data source |
| Normal, then Settings > Data source > Demo (simulated) | The same graph; the model uses the demo adapters | The standalone demo, labeled; Prototype testing is back |
| `WAIT_IT_OUT_DATA_MODE=demo` (UI tests) | No backend at all | Exactly the prototype of step 0008; no Data source section |

## Activity domain (step 0002)

### The stored schedule

`Activity` holds a stable `id` (UUID), `title`, `start`, `end`, `idealArrival`, a
`destination` (`Destination`: stable `DestinationID`, name, `GeoCoordinate`), a
`timeZoneIdentifier`, optional `repeatWeekdays` (`Set<Weekday>`, `nil` for one-time), and a
`source` (`user` or `sample`). Start and end are set first, ideal arrival second. **There is
no stored departure or leave-home time**: step 0005 computes it from `idealArrival` and a
commute estimate and shows it read-only (see "Leave-home times (step 0005)"). Ideal arrival already includes any study, parking,
or buffer time; nothing adds to it later.

### Validation (`ActivityValidator`, pure)

`ActivityValidator.issues(in:)` returns every problem at once, each with a user-facing
message and the editor field it belongs to; `validate(_:)` throws `ActivityValidationError`.
Rules:

- title is nonempty after trimming;
- destination has a name and a finite coordinate with latitude in -90...90 and longitude in
  -180...180;
- start, end, and arrival are finite dates; end is after start; duration is at most 24 hours;
- ideal arrival is at or before start and at most 24 hours before it (so arrival on the
  previous date and activities crossing midnight are allowed);
- the time zone identifier is known on the device;
- when repeat days are present they are nonempty and include the weekday of `start` in the
  activity's zone, so the stored start is always the series' first occurrence.

`WaitItOutModel.saveActivity` validates before writing; repositories store what they are
given.

### Weekly repeats and occurrences (`OccurrenceExpander`, pure)

- A repeating activity occurs on each selected weekday from its own first day onward, with
  no end date in this step.
- Each occurrence starts at the stored activity's **wall-clock start time in the activity's
  time zone** on that local day. Days are counted on the calendar, not as multiples of
  86 400 seconds, so weeks containing a daylight-saving transition stay aligned to the clock
  (a 9:00 class is at 9:00 before and after the November transition).
- End and ideal arrival keep the stored activity's **elapsed duration and arrival lead**.
- **Daylight-saving policy** (`LocalTimeResolver`): a wall time that happens twice because
  clocks fell back resolves to its first occurrence; a wall time that never happens because
  clocks sprang forward resolves to the first instant after the gap (02:30 becomes 03:00 on
  that day). The rule is monotonic, so start, end, and arrival never swap order, and an
  activity spanning the transition keeps its duration while its clock-face end time shifts.
- **Identity**: `OccurrenceID` is the activity id plus the local calendar day on which the
  occurrence starts, in the activity's zone (text form `uuid@2026-10-30`). The same
  occurrence has the same id in every expansion and after relaunch.
- **Inclusion**: `occurrences(of:in:)` returns the occurrences whose planned time, ideal
  arrival through end, intersects the requested half-open interval. Overnight activities and
  previous-day arrivals therefore appear in both weeks they touch, once in each. Only the
  days that can intersect the interval are visited; a request longer than 366 days is
  trimmed to its first 366 days.
- Activities with an unknown zone, non-positive duration, or empty repeat set produce no
  occurrences instead of trapping.

### Sample schedule

Settings has two explicit actions under "Sample schedule": **Load sample activities** and
**Clear sample activities**. Samples never appear on their own. They are:

- "Sample morning class": Mon, Wed, Fri 9:00-9:50 AM, ideal arrival 8:15 AM;
- "Sample afternoon lab": Tue, Thu 12:00-5:15 PM, ideal arrival 11:15 AM;

anchored to the Monday and Tuesday of the week containing today, in the sample campus time
zone (`America/Los_Angeles`), at the campus (since step 0006 the campus id resolves to the
campus set in Settings). They have fixed ids and
`source == .sample`, so loading twice adds nothing, and they carry a SAMPLE badge and the
word "Sample" in their titles wherever they show. Clearing removes only activities whose
source is `sample`; the user's own activities, past or future, stay.

### What the Calendar shows

The Calendar reads `WaitItOutModel.visibleWeekOccurrences`, which expands the repository's
current contents for the visible week, and `occurrences(on:)` for one day. Step 0003 renders
them on a time grid; see "Calendar UX (step 0003)" below.

## Calendar UX (step 0003)

### Layout

- **Week header and day strip.** Previous and next week arrows, the week title, and seven
  tappable day cells, Sunday through Saturday. The selected day is filled, today is ringed
  and tinted, and a dot marks days with activity. At accessibility text sizes the strip
  scrolls horizontally so every cell keeps a 44-point target and a readable label.
- **Selected day versus full week.** `CalendarLayoutMode.resolve(availableWidth:isAccessibilitySize:)`
  shows seven columns only when the width fits the hour gutter plus seven 88-point columns
  (668 points: iPad, or large iPhones in landscape) and the text size is not an accessibility
  size. Otherwise the grid shows the selected day's timeline; the strip keeps the whole week
  one tap away. Week arrows keep the same weekday selected; "Today" returns to the current
  week and day and scrolls to the current time.
- **Time grid.** `DayTimelineLayout` gives each day as many hour rows as it has hours: 24
  normally, 25 on the fall-back day, 23 on the spring-forward day. Rows are labeled with the
  wall clock at their own first instant, so the fall-back day shows two "1 AM" rows and the
  spring-forward day has no "2 AM" row. Offsets are proportional to elapsed time, so a block's
  height is its duration (60 points per hour at the default text size, scaled with Dynamic
  Type). Short activities keep a 44-point minimum height; a minimum-height block near
  midnight is shifted up rather than overflowing the column. In the seven-column layout the
  shared gutter follows the first ordinary 24-hour day (`DayTimelineLayout.sharedGutter(for:)`),
  and a 23- or 25-hour transition day, whose rows differ from it (`rowsDiffer(from:)`), labels
  its own rows in a 40-point margin inside its column; its blocks and markers start after the
  margin (added in the 2026-11-02 re-run of step 0003). The selected-day layout always labels
  the selected day's own rows.
- **Blocks.** A block covers the activity only, start to end. It shows the title, a repeat
  glyph, the time range, and (when tall enough) the "Arrive by" line and the SAMPLE badge;
  `BlockDetail.resolve(height:)` picks how much fits. Sample blocks are orange, user blocks
  use the accent color; text stays in the primary color on a translucent tint for contrast in
  light and dark appearance.
- **Ideal arrival.** A separate capsule marker ("Arrive 8:15 AM") sits at the arrival instant
  with a dashed leader down to the block. The block is never stretched to include the lead.
  When only the arrival falls on a day (an activity that starts just after midnight), that day
  shows the marker alone, worded "Arrive 11:45 PM for Sun 12:30 AM start", with a leader to
  the bottom of the day.
- **Overlaps.** `OverlapLayout` assigns side-by-side columns to overlapping intervals; a later
  activity reuses the first column that has ended. Every block stays visible and tappable.
- **Overnight and long activities.** `DayTimelineLayout.frame(for:)` clips an interval to each
  day and flags the clipped edges; the block shows an up or down arrow and the time range
  carries weekdays ("Sat 11:00 PM – Sun 1:00 AM"). The same occurrence id appears on both days.
  A 24-hour activity fills a column.
- **Current time.** A red line marks the current time on today's column. The Calendar reads
  the injected `WallClock` through `WaitItOutModel.currentDate()` and refreshes at the next
  whole minute while the current week is visible, every five minutes otherwise, and only while
  the tab is on screen (the refresh task is cancelled when the tab is hidden). Returning to
  the foreground refreshes immediately.
- **Details.** Tapping a block opens a sheet: date, time, duration, ideal arrival (with its
  date when it differs), lead time, repeat days, destination, time zone, and a SAMPLE note for
  sample content. Step 0004 adds working Edit and Delete buttons (see below) and step 0005 a
  read-only "Leave home" section; there is no departure control.
- **Empty states.** With nothing stored, the grid stays visible and a card over its top offers
  "Add Activity" and "Open Settings" (step 0004; in 0003 the card replaced the grid). With
  activities stored but none on the selected day (or week, in the seven-column layout), a
  note floats over the grid.
- **State across tabs.** The selected day (`WaitItOutModel.selectedDay`) and the hour row
  the grid is scrolled to (`WaitItOutModel.calendarScrollHour`) live in the shared model, so
  switching to Map or Settings and back shows the same week, day, and scroll position.

### Accessibility

- Day cells are buttons labeled "Tuesday, October 27" with the value "Today, 1 activity" and
  the selected trait. The selected-day title is a header with the day's summary.
- Each block is one element whose label reads the title, "sample data" when applicable, the
  time range, the arrival, the repeat days, and any zone note, with the hint "Shows details".
  Each arrival marker is labeled "Ideal arrival 8:15 AM for Sample morning class". The current
  time line is labeled "Current time, 12:00 PM". Hour labels and gridlines are hidden from
  VoiceOver; each day column is a container labeled with the day and its summary.
- Reduced motion disables the week and day change animations. Colors are system semantic
  colors plus the accent and orange tints, so light and dark appearance and increased
  contrast come from the system.

## Creating and editing activities (step 0004)

### Creating

- **Add Activity.** The Calendar toolbar button and the empty-state card both open the editor
  for a new activity on the selected day: it starts at the next whole hour when that day is
  today and at 9:00 AM otherwise, lasts one hour, and has an ideal arrival 30 minutes before
  the start. The toolbar button is disabled while an unsaved change is pending.
- **Press, hold, and drag on empty grid space.** Hold for 0.35 seconds so ordinary swipes keep
  scrolling the grid, then drag; drags shorter than 10 points are ignored. `GridDrag` converts
  the drag through `DayTimelineLayout` and snaps both ends to 15-minute wall-clock marks in the
  calendar's zone. The result is at least 15 minutes long and cannot leave the day it started
  on. Releasing opens the editor with the dragged times. From the moment the hold is
  recognized until the finger lifts, the grid does not scroll.

### The editor

The compact editor keeps one order: title; destination (read-only in the editor; since step
0006 it is the campus set in Settings, with a SAMPLE badge while that is the sample campus);
**1. Activity time** with "Starts" and "Ends" (date and
time each), the duration, and a note when the activity ends the next day; **2. Ideal campus
arrival** with "Arrive by", the lead time before the start, and a note when the arrival falls
on a different day; then **Repeat** with a "Repeat weekly" switch and seven day buttons,
Sunday through Saturday. Changing "Starts" moves "Ends" and "Arrive by" with it, keeping the
duration and the arrival lead. There is no departure or leave-home input: the ideal arrival
already includes any study, parking, or buffer time. Step 0005 adds a read-only "Leave home"
line at the end of the arrival section, calculated from the ideal arrival.

Validation runs through `ActivityValidator` and shows each issue inline under its field. An
empty title is reported after the first Save; time, arrival, and repeat issues show as soon as
they occur.

### Drafts

- Every change edits one pending `ActivityDraft` held by `WaitItOutModel.editSession`; nothing
  is stored until Save. Each Save validates and performs at most one repository write (none
  for an edit that changed nothing). Save is disabled while a save runs, and a second Save
  during a save does nothing. The editor sheet cannot be swiped away, so it ends with Save or Cancel.
- Cancel discards the draft and restores the original activity on the grid.
- If the activity being edited disappears (for example, Settings cleared the samples), the
  draft is discarded and the Calendar shows a notice.

### Adjusting a block

Press and hold a block (0.35 seconds) to adjust it. Dragging the body moves it and keeps its
duration and arrival lead; the top handle resizes the start and moves the arrival with it; the
bottom handle resizes the end and leaves the arrival alone. The original position stays drawn
as a dashed outline, and an unsaved-change bar offers Cancel, Edit Details, and Save. The
handles are VoiceOver adjustable (15 minutes per swipe), and every gesture has an equivalent in
the editor's pickers. Gestures never move an activity to another day; use the editor's dates.
While a block or a handle is being dragged the grid does not scroll, so the timeline stays
put under the finger; it scrolls again as soon as the finger lifts.

### Repeating series

Edits and deletes of a repeating activity always apply to the whole series: the buttons read
"Edit Series" and "Delete Series", the editor shows a series note, and deleting asks for
confirmation. Single-occurrence exceptions are out of scope and never simulated. Turning
repeat off keeps only the first occurrence, and the editor says so. Editing a sample keeps it
a sample with its SAMPLE label. The arrival's date is shown whenever it differs from the
start's.

## Leave-home times (step 0005)

### The calculation

**Leave home = ideal arrival - travel time.** Nothing else is subtracted (the ideal arrival
already includes study, parking, and buffer time), and the activity's start is never used.
`DepartureCalculator` is pure and subtracts elapsed seconds, so:

- the sample class (ideal arrival 8:15 AM) leaves at **7:15 AM** and the sample lab (11:15 AM)
  at **10:15 AM** with the default 60-minute test commute;
- a 12:30 AM arrival leaves at 11:30 PM the previous day, and the date is shown;
- a trip across a daylight-saving change takes exactly the travel time; the UI notes that the
  clock changes during the trip;
- the departure is never stored on an activity and never edited. It is shown read-only.

### Where it shows

- **Calendar details**: a "Leave home" section after "Campus arrival": the time, the formula
  ("Ideal arrival 8:15 AM minus 1 hour of travel"), the source and estimate time with a TEST
  DATA badge, a daylight-saving note when relevant, and a warning when the time has passed.
- **Editor**: a read-only line at the end of "2. Ideal campus arrival" that follows every
  arrival or destination change of the draft before it is saved.
- **Map**: a "Next trip" card for the first saved occurrence that has not started (within the
  next 7 days), with its leave-home time. With nothing stored it offers **Add Activity**, which
  opens the Calendar on today with a new activity; with activities but nothing in the next
  7 days it offers **Open Calendar**.

### States and edge cases

Each calculation is `loading`, `success`, `unavailable`, or `error` (`DepartureState`; step
0006 adds `refreshing`). No destination, no estimate, a provider failure, and an unusable
estimate (zero, negative, nonfinite, or longer than 12 hours; nonfinite timestamp; empty
source label) each show their own sentence and no time. Since step 0006 only errors (a
provider failure or an unusable estimate) offer Try Again; a missing estimate does not. When the leave-home
time has already passed, the app says "Leaving now may miss the 8:15 AM arrival target" and
keeps the calculated time. It never substitutes "now" or implies an on-time arrival.

### Test commute (Settings)

"Test commute duration" takes whole minutes (1 to 720, initially 60) with a stepper. Step
0005 put it in a **Test commute** section labeled TEST DATA; step 0006 moved it into the
**Prototype testing** section at the end of Settings. Input is validated as it is typed; a valid
value applies when you tap Done or leave the field, and an invalid one shows why and keeps
the last valid duration ("Still using 60 minutes"). The duration is part of `UserPreferences`
(session only until step 0007). It is a simulation: in the Normal scenario every trip takes
exactly that long, and the step 0006 scenarios shape it (see below).

### Bounded, current work

`WaitItOutModel` calculates for saved occurrences that are not over and begin within the
next 7 days (`DepartureHorizon`), plus the pending draft. It recalculates after every activity
reload (so arrival, time, destination, and repeat edits and deletions apply), after a test
duration change, after a scenario or home and campus change (step 0006), on the Calendar's
and Map's minute ticks, when details open, and on every draft change. Unchanged requests keep
their result (since step 0006, until the estimate is 10 minutes old while its ideal arrival is
still ahead). Changed or deleted ones cancel their request, and every answer carries a token,
so a slow or out-of-order answer can never overwrite a newer edit. The service contract for
replacing the test provider is in [`docs/COMMUTE_ESTIMATION.md`](docs/COMMUTE_ESTIMATION.md).

## Map, home and campus, and prototype testing (step 0006)

### Home and campus (Settings)

- **Home and campus** is a Settings section placed after "Prototype information". Each row
  shows the place's name, its coordinates with four decimals ("38.5610, -121.4237"), and a
  SAMPLE badge while it holds the labeled sample value; tapping a row opens the place editor.
  **Reset to Sample Locations** restores both samples and is disabled while they are in use.
- The samples are `SampleLocation.demoHome` ("Sample home", 38.4088, -121.3716: a coarse point
  near central Elk Grove, CA, not a real address) and `SampleLocation.demoCampus` ("Sample
  campus", 38.5610, -121.4237, Sacramento State area).
- The **place editor** sheet has a name and latitude and longitude fields in decimal degrees
  (WGS-84). Every issue shows inline under its field as it is typed. Save is enabled only for
  a valid, changed value and applies the whole place at once (`applyPlaceInput`), so a
  half-typed coordinate never reaches a commute request. Cancel discards; the sheet cannot be
  swiped away with unsaved changes. **Use Sample Home** or **Use Sample Campus** fills in the
  sample values; nothing changes until Save.
- Parsing (`PlaceInput.parseDegrees`) is strict: an optional sign, digits, and at most one
  decimal separator, either a period or a single decimal comma. Surrounding spaces are
  ignored and a typographic minus counts as a minus. Exponents, hexadecimal, "nan", "inf",
  degree symbols, and compass letters are rejected. Latitude must be in -90...90 and
  longitude in -180...180 ("Latitude must be between -90 and 90.").
- `CommutePlace` is valid by construction: a nonempty trimmed name and a finite, in-range
  WGS-84 coordinate; decoding validates too. `CommutePlaces` (home and campus, addressed by
  `PlaceRole`) is part of `UserPreferences.places`, so the settings store keeps it with the
  appearance and test settings. Tolerant decoding replaces a missing or unusable stored place
  with its sample and keeps the other one.
- No location permission, device location, geocoding, address search, or network lookup is
  involved.

### Campus activities and the commute request

- Activities store a copy of their destination. An activity whose destination id is the
  campus id (`demo-campus`, the injected `sampleCampus.destinationID`) resolves to the campus
  currently set, both when a request is made and when a screen shows it
  (`WaitItOutModel.resolvedDestination`). Editing the campus therefore re-points every campus
  activity without rewriting storage; the stored copy is only a snapshot. The detail sheet and
  the editor show the resolved campus name.
- `CommuteRequest` gained `origin: CommutePlace`, the home. `destination` is the resolved
  campus and `arriveBy` is still the ideal arrival. A new home or campus is a different trip,
  so every leave-home time and the editor's preview is asked again from the loading state.

### The Map tab

- **Pins and line.** Home and campus are map markers ("Home: Sample home" in teal, "Campus:
  Sample campus" in indigo) joined by a dashed, straight `MapPolyline`. The map labels the line
  "Schematic line, not a route" at its midpoint, and the places card repeats it in words. The
  line ignores roads; it only shows which two places a trip connects.
- **Camera.** `MapCameraFit` (pure) returns the region: the smallest box holding both places,
  taking the short way around the 180th meridian, enlarged 1.6 times (`paddingFactor`), never
  smaller than 0.02 degrees (`minimumSpan`, about 2.2 km of latitude), and kept inside the
  poles. Identical home and campus are centered with the minimum span. The Map fits when it
  opens, re-fits whenever home or campus changes, and on **Show Home and Campus**.
- **Next trip card.** The next saved activity that has not started (within 7 days): its title
  and SAMPLE badge, the event day and start with the ideal arrival ("Monday, November 2: arrive
  by 8:15 AM for the 9:00 AM start"), the read-only leave-home time, the formula ("Ideal
  arrival 8:15 AM minus 1 hour of travel"), the source with the estimate time and age ("Test
  commute (simulated, not live traffic), estimated 12:00 PM, just now", later "12 minutes ago")
  with a TEST DATA badge, and a simulation line ("Test drive 1 hour, Normal scenario"; "Test
  drive 1 hour 30 minutes (1 hour plus 50%), Slow scenario"; "Test drive 1 hour set; Error
  scenario gives no estimate"). An empty schedule still offers Add Activity and a schedule
  with nothing in the next 7 days Open Calendar (step 0005).
- **Places card.** Both places in words with their SAMPLE badges; the note "The dashed line is
  a schematic connection, not a driving route. Straight-line distance ..." (great-circle
  distance in the locale's road unit, about 17.5 km for the samples); whether both pins are in
  view or the map was panned away; **Show Home and Campus**; and **Edit in Settings**, which
  switches to the Settings tab.
- **Demo estimate label.** An always-visible, unobtrusive capsule in the navigation bar while
  the test provider is in use: "Demo estimate", or "Demo estimate · Slow" (and so on) when the
  scenario is not Normal. VoiceOver reads "Demo estimate, Normal scenario. Commute times are
  simulated, not live traffic."
- **Layout.** The two cards sit in a bottom safe-area inset capped at 60% of the screen height
  (and 560 points wide) and scroll when they need more, as at accessibility text sizes, so the
  map stays visible above them. The style menu (Standard, Hybrid, Satellite), compass, and
  scale remain.
- **Without map tiles.** The cards are plain SwiftUI outside the map content, so the trip
  summary, places, and labels stay readable when tiles cannot load. SwiftUI's `Map` has no
  tile-failure callback, so the app cannot detect missing tiles; the places card says that
  tiles need a network connection and that the trip summary works without them.
- The Map's minute tick (`MapScreen.runClock`, from step 0005) also refreshes stale
  estimates. There is no location permission, routing, geocoding, or traffic data.

### Prototype testing (Settings)

The last Settings section, **Prototype testing** with a TEST DATA badge, appears only while
the injected provider is `TestCommuteProvider`. It lists the four scenarios (the selected one
has a checkmark and the selected trait), a "Now simulating: ..." line, the step 0005
**Test commute duration** field and stepper, and **Reset to Normal, 60 Minutes** (disabled at
the defaults). Every scenario is deterministic: the same settings always give the same answer.

| Scenario | Travel time | Answer | Sample leave-home times |
| --- | --- | --- | --- |
| Normal | The test duration | Estimate after `simulatedDelay` (300 ms in the host) | 60 minutes: 7:15 AM (class, 8:15 AM arrival) and 10:15 AM (lab, 11:15 AM arrival) |
| Slow | The test minutes times 1.5, rounded up, at most 12 hours | Estimate after `slowDelay` (3 s in the host); its source label names the Slow scenario | 90 minutes: 6:45 AM and 9:45 AM |
| Unavailable | None | No estimate after `simulatedDelay`, with a message naming the simulated scenario; no Try Again | None |
| Error | None | Throws after `simulatedDelay`; Try Again is offered and keeps failing until another scenario is chosen | None |

The scenario lives in `UserPreferences.testCommuteScenario` (initially Normal).
`setTestCommuteScenario` and `resetPrototypeTesting` store it and call
`commuteSettingsDidChange()`, which pushes the duration and scenario into
`TestCommuteProvider` and recalculates every leave-home time, including the editor's
preview. Views never branch on the scenario; they only label it (the Demo estimate label, the
simulation line, and the "Commute estimates" row in Prototype information). Every difference
on screen comes from the provider's answers.

### Refreshing, retrying, and freshness

- **Refreshing.** When the same trip is asked again (a scenario or duration change, or a stale
  estimate), `DepartureState.refreshing` keeps the earlier time visible as "7:15 AM, out of
  date" with a spinner and "Out of date: updating the commute estimate from 7:00 AM..." until
  the answer arrives. It is never shown as current, and VoiceOver says "out of date". A changed
  trip (an arrival or time edit, a new home or campus) starts from `loading` instead, because
  the earlier time belongs to another trip.
- **Retry only for failures.** `DepartureState.isRetryable` is true only for `.error` (provider
  failure or unusable estimate) and, since stage S1, for a backend recommendation kept after a
  failed refresh (`.stale`). An answer without an estimate explains itself without Try
  Again; any change to the trip or the provider settings recalculates automatically.
- **Freshness.** An estimate older than `EstimateFreshness.lifetime` (10 minutes) is stale.
  While its ideal arrival is still ahead, the next refresh (the Map's or Calendar's minute
  tick, opening details, returning to the foreground) asks again and shows it as refreshing;
  estimates for trips whose arrival has passed are kept. The age reads "just now" under a
  minute, then "N minutes ago".
- **Ordering.** Superseded requests are cancelled and late answers are dropped by token, so a
  Slow answer that arrives after switching back to Normal never overwrites the newer result.

## Persistence and reminder previews (step 0007)

### Saved files

- `Application Support/WaitItOutUX/activities.json` holds every committed activity: title,
  start, end, ideal arrival, destination with coordinates, time zone identifier, repeat
  weekdays, and source (user or sample). Drafts are never saved.
- `Application Support/WaitItOutUX/preferences.json` holds `UserPreferences` as a whole:
  appearance, the test commute duration and scenario, home and campus, the reminder
  preference, and the reminder failure simulation.
- Each file is one envelope, `{"kind": "activities", "payload": ..., "schemaVersion": 1}`
  (`StorageSchema.currentVersion`). Instants are stored as seconds since 2001-01-01 UTC, which
  round-trips exactly; wall-clock meaning comes from each activity's time zone.
- Never stored: leave-home times, commute estimates, loading or refreshing states, reminder
  delivery status, and pending reminders. They are recalculated after every launch.
- The stores are actors (`FileActivityRepository`, `FilePreferencesStore`), so file work runs
  off the main actor. File operations go through the injected `FileAccessing`.

### Failures and recovery

- **Missing file**: an empty schedule or default settings; nothing is written by reading.
- **Write failure** (`writeFailed`): the write is atomic (a temporary file renamed over the
  old one), and the store's in-memory copy changes only after success, so the previous valid
  data stays on disk and on screen. The editor and Settings say the change was not saved.
- **Unreadable file** (damaged JSON, a different kind of document, an undecodable activity,
  a newer `schemaVersion`, or a read error): the app starts with an empty calendar or default
  settings, and Calendar, Map, and Settings say why. The store refuses every write while the
  file is unreadable (`unreadableDataProtected`), so nothing overwrites it silently; reminder
  previews pause. Settings > Saved data offers **Try Again** (reads again) and **Keep a Copy
  and Start Over** (confirmed; renames the file to `activities.unreadable-<seconds>.json` or
  `preferences.unreadable-<seconds>.json` next to it, never deletes it, then continues with an
  empty schedule or the settings in effect, which are saved).
- Inside a readable settings file, each field still falls back on its own (an unknown scenario
  becomes Normal, an invalid duration 60 minutes, an unusable place its sample).

### Reminder previews

- Settings > Leave-home reminders: "Remind me when it is time to leave". The wish is saved;
  the preview below it shows the next reminder's day and time (the calculated leave-home
  time), its title and message, how many more follow in the next 7 days, and "Preview only - no
  system notification will be sent." The Map's trip card shows a compact form while reminders
  are on.
- When there is no preview, it says why: nothing in the next 7 days, the estimate is loading,
  unavailable, or failed, or the leave-home time has passed. A trip being re-estimated keeps
  its preview marked out of date until the new estimate arrives.
- Reconciliation is idempotent and keyed by occurrence id; see
  [`docs/REMINDERS.md`](docs/REMINDERS.md) for the plan, the triggers, and how the team plugs in
  its notification service.
- Prototype testing > "Simulate reminder failure" makes the preview adapter fail every update:
  the preview shows the failure and Try Again, which keeps failing until the simulation is
  turned off. "Reset to Normal, 60 Minutes" also turns it off.

### UI tests and storage

UI tests set the launch environment `WAIT_IT_OUT_STORAGE_FOLDER` to a fresh name, so each
test starts with empty storage in its own Application Support folder, and the relaunch test
launches twice with the same folder. The host validates the name (letters, digits, hyphens,
underscores) and otherwise uses `WaitItOutUX`.

## QA review and fixes (step 0008)

Step 0008 read every source file for compile errors and contract defects (a static review:
no compiler exists on the host that ran it) and fixed what it found:

- **Compile error**: `OverlapLayout.placements(for:)` declared a struct inside a generic
  function, which Swift rejects; it now uses a labeled tuple with the same ordering.
- **Settings data loss**: after a failed settings read at launch, the next setting change could
  re-read the file and overwrite the user's stored settings with defaults plus that change.
  `FilePreferencesStore` now refuses writes while unreadable until Try Again reads it or Keep a
  Copy and Start Over sets it aside.
- **Daylight saving**: an end resize (or a drag too short to count) on a later occurrence of a
  series whose time falls in a skipped or repeated hour could shift the whole series by an
  hour. `ActivityDraft` now keeps the series start when the start did not move.
- **Display edge cases**: the Slow scenario's simulation line no longer claims a full 50% when
  the 12-hour cap applies, and the straight-line distance can no longer become NaN for nearly
  antipodal places.
- **Integration**: `MapScreen`, `CalendarScreen`, and `SettingsScreen` are public with
  `init(model:)`, so the team can use them in its own tab bar (see
  [`docs/TEAM_INTEGRATION.md`](docs/TEAM_INTEGRATION.md)).

New automated checks:

- `EndToEndDemoTests` (unit, 3 tests): the demo path through the shared model over real JSON
  files: empty launch, drag creation through `GridDrag`, ideal arrival, weekly repeat, Save,
  leave-home time in Calendar details and on the Map, reminder preview, Edit Series,
  relaunch, Delete Series, relaunch; the two sample schedules at 60 minutes leaving at 7:15 AM
  and 10:15 AM on both sides of the November daylight-saving change; and no departure field
  on any stored or editable value.
- `DemoAccessibilityUITests` (UI, 1 test): at accessibility text size XL, the three tabs in
  order, the Demo estimate label and next-trip leave-home time, Add Activity with accessible
  start, end, and arrival controls, a read-only leave-home line, and no Calculate button.
- `check_project_structure.py` now also checks the product contract: tabs exactly Map,
  Calendar, Settings; no departure property on `Activity`, `ActivityDraft`, or
  `UserPreferences`; no location, notification, or calendar permission API, `URLSession`, or
  "Calculate" control in the app or package; no privacy usage strings or background modes;
  no C, C++, Objective-C, or Python sources in the app or package; every UI test sets the
  storage folder; and the hygiene rules (TODO, `fatalError`, force unwraps, balanced brackets)
  now cover the package tests too. Each new rule was checked by injecting a violation into a
  temporary copy.

### Step 0008 re-run (2026-11-02)

The re-run gave the SwiftUI screens, `EndToEndDemoTests`, and every UI test the second,
independent static read that the first review could not finish. It confirmed every model
call, binding, `switch`, and identifier those files use against their declarations, and found
no compile error and no query that cannot match. It fixed what it found:

- **Unlabeled simulated value**: while an estimate refreshes, the kept leave-home time now
  shows the TEST DATA badge and its spoken label ends "Simulated test data, not live traffic."
  for a simulated estimate, as the current time already did (`DepartureRows`,
  `staleDepartureAccessibilityLabel`; covered in `DepartureTextTests`).
- **UI test robustness**: the editor, detail, and place editor sheets are now one accessibility
  container each (`.accessibilityElement(children: .contain)`), so the sheet identifier the
  UI tests wait for can never replace the identifiers of the controls inside; and the text
  replacement in `DepartureUITests` and `MapScenarioUITests` taps the field's trailing edge,
  as `ActivityEditingUITests` already did, because a tap in the middle of a right-aligned field
  can put the cursor before the text.
- **Handoff accuracy**: the schema example in `docs/TEAM_INTEGRATION.md` now carries the
  sample class's real instants (9:00 to 9:50 AM, ideal arrival 8:15 AM; the old numbers
  decoded to 10:00, 10:50, and 8:30 AM), the framework list names CoreGraphics, and the
  directory layout above lists the step 0007 `Persistence/` and `Reminders/` folders and tests.

### Where each demo requirement is covered

| Requirement | Automated coverage (written; NOT RUN until a Mac runs them) |
| --- | --- |
| Create and drag a class, ideal arrival, repeat weekdays, save | `EndToEndDemoTests`, `ActivityEditingUITests`, `GridDragTests`, `ActivityDraftTests`, `WaitItOutModelEditingTests` |
| Calculated departure on Map and Calendar | `EndToEndDemoTests`, `DepartureUITests`, `WaitItOutModelDepartureTests`, `WaitItOutModelMapTests` (the Map's next trip and the Calendar's block and detail state agree after an edit, a duration change, a scenario switch, and deleting the next event) |
| Reminder preview, edit, delete, relaunch | `EndToEndDemoTests`, `WaitItOutModelReminderTests` (including a changed estimate that keeps each reminder marked out of date, then moves it in place), `PersistenceReminderUITests`, `WaitItOutModelPersistenceTests` |
| Sample schedules at 60 minutes: 7:15 AM and 10:15 AM | `EndToEndDemoTests`, `WaitItOutModelDepartureTests`, `DepartureUITests` |
| Empty state, invalid inputs | `EndToEndDemoTests`, `WaitItOutModelDepartureTests` (the Map's Add Activity setup action), `ActivityValidatorTests`, `CommuteDurationTests`, `CommutePlaceTests`, `WaitItOutModelEditingTests`, `ActivityEditingUITests`, `DepartureUITests`, `MapScenarioUITests` |
| Overlaps, overnight times, DST | `OverlapLayoutTests`, `DayTimelineLayoutTests`, `DayScheduleTests`, `LocalTimeTests`, `OccurrenceExpanderTests`, `DepartureCalculatorTests`, `GridDragTests`, `WaitItOutModelEditingTests` |
| Storage, estimate, and reminder errors | `PersistenceStoreTests`, `WaitItOutModelPersistenceTests` (including failed writes that keep the last saved schedule, settings, and reminders through a relaunch), `TestCommuteScenarioTests`, `WaitItOutModelMapTests`, `WaitItOutModelReminderTests` |
| Stale async responses | `WaitItOutModelDepartureTests` (out-of-order and stale draft answers, destination edits, a class moved to another day), `WaitItOutModelMapTests` (late answer after a settings change, with its request cancelled; slow answer cancelled; the editor's preview across every scenario), `WaitItOutModelReminderTests` |
| Large text and VoiceOver alternatives | `DemoAccessibilityUITests`, `CalendarLayoutModeTests`; VoiceOver itself is manual (checklist below) |
| No editable departure, Calculate button, permissions, unlabeled data | `EndToEndDemoTests`, `DepartureUITests`, `check_project_structure.py`, `SampleContentTests`, `DepartureTextTests` (a simulated time stays labeled while it refreshes) |

### Where the backend integration is covered

| Requirement | Automated coverage |
| --- | --- |
| The backend decides the departure; no local arithmetic or buffer | `DepartureRecommendationTests`, `BackendCommuteProviderTests`, `WaitItOutModelBackendTests`, `RecommendationTextTests` |
| A failed live request is never replaced by a simulated value | `WaitItOutModelBackendTests`, `LiveModeUITests` (through the real host) |
| Loading, current, refreshing, kept out of date, unavailable, not yet plannable, arrival no longer reachable | `WaitItOutModelBackendTests`, `RecommendationTextTests`, `BackendWireTests` |
| Data mode and server address; the demo unchanged | `BackendConfigurationTests`, `DataSourceWordingTests`, `BackendConnectionTests`, `BackendLaunchOptionsTests`, `LiveModeUITests`; the 21 earlier UI tests and `EndToEndDemoTests` for the demo |
| Route geometry and the schematic fallback | `BackendRouteProviderTests`, `WaitItOutModelRouteTests`, `LiveModeUITests` |
| Trip synchronization, pending, failed, withdrawal, one answer everywhere | `BackendSessionTests`, `TripWireTests`, `WaitItOutModelMonitoringTests`, `WaitItOutModelLiveMonitoringTests` |
| Honest delivery wording, permission states, "I've Left" | `MonitoringTextTests`, `MonitoringPresentationTests`, `WaitItOutModelMonitoringScreenTests` |
| Notification responses, including a dismissal and a cold start | `BackendLaunchOptionsTests` (reading the response), `WaitItOutModelMonitoringTests` (acting on it); the system delivering one is NOT covered |
| Credentials per server, never logged or sent elsewhere | `BackendSessionTests`, `CredentialStoreTests` (the real Keychain test is skipped in the package host; the Keychain store was exercised once by hand in the simulator) |
| No surprise permissions, network and notification APIs confined | `check_project_structure.py` |

## Manual demo checklist

This checklist walks the **Demo data mode**. A normal launch starts in Live mode, so first
open Settings > Data source and choose "Demo (simulated)". (Launching with
`WAIT_IT_OUT_DATA_MODE=demo` in the environment composes the demo alone, as the UI tests do;
Settings then has no Data source section.) The live flow has its own checklist below.

Run on an iOS 17 simulator from a clean checkout (open the project, scheme
WaitItOutUXPrototype, Run). To start from empty data, delete the app from the simulator first.

1. **Launch.** Three tabs, Map, Calendar, Settings, with Settings rightmost. No permission
   alert appears, now or later (in the Demo data mode).
2. **Empty state.** Map: the next-trip card offers Add Activity; Calendar: the grid with an
   Add Activity / Open Settings card; reminders are off.
3. **Create by drag.** Calendar, choose a day in the next 7 days, press and hold free time,
   drag down: a preview follows in 15-minute steps while the grid holds still; release to
   open the editor.
4. **Ideal arrival and repeat.** Enter a title; Starts and Ends come first, then "Arrive by";
   turn on Repeat weekly and add a second day. The arrival section's read-only "Leave home"
   line shows arrival minus 60 minutes, labeled as simulated. There is no departure input
   and no Calculate button. Save.
5. **Calendar and Map.** Tap the block: details show "Leave home" with the formula and a
   TEST DATA badge. Map: the next-trip card shows the same time, the "Demo estimate" label,
   and the schematic line note.
6. **Reminder preview.** Settings > Leave-home reminders, turn it on: the next reminder at
   the leave-home time, with "Preview only - no system notification will be sent."
7. **Edit and delete.** Tap the block > Edit Series, move "Arrive by" 15 minutes earlier,
   Save: leave-home and reminder move with it. Press and hold the block and drag a handle,
   then Save or Cancel in the bar.
8. **Relaunch.** Stop and run again: the activity, repeats, and reminder setting come back;
   times and previews are recalculated. Then Delete Series (with confirmation).
9. **Provided schedules.** Settings > Load sample activities: with the 60-minute test
   commute, the class leaves at **7:15 AM** (arrive 8:15) and the lab at **10:15 AM** (arrive
   11:15), on the Map and in each block's details.
10. **Invalid input and errors.** Empty title, end before start, arrival after start, a repeat
    without the start's weekday; test commute "0" or "abc"; a latitude of 91. Prototype
    testing: Slow (time kept, marked out of date, then 6:45 / 9:45 AM), Unavailable (no retry),
    Error (Try Again), Simulate reminder failure (Try Again).
11. **Overlaps, overnight, DST.** Add two overlapping activities (side-by-side columns), one
    ending after midnight (shown on both days), and look at the week of a clock change.
12. **Large text and VoiceOver.** Settings app > Accessibility > Larger Text at the largest
    size: the Calendar shows one day, cards scroll, nothing essential is cut off. With
    VoiceOver: blocks read title, time, arrival, and repeat; resize handles adjust in
    15-minute steps; Add Activity and the editor pickers replace every gesture.

## Manual live-mode checklist

Steps 1 to 5 need no server. What this stage actually ran is recorded under "Validation
status"; steps 4, 8, and 9 have not been walked by hand.

1. **Launch with no server running.** The Map says "Team backend". The places card says the
   driving route could not be loaded, and the dashed line stays labeled "Schematic line, not a
   route". No permission alert appears.
2. **Load the sample activities** (Settings). On the Map, when the next sample arrival is
   within about 11.5 hours, the next-trip card says "The backend could not be reached. Check
   the connection. No leave-home time is shown." with Try Again; further ahead it says "The
   traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after
   <time>."; and in the 45 minutes between a sample activity's ideal arrival and its start it
   says "The ideal arrival time has passed. No leave-home time is shown." In every case there
   is no time and no TEST DATA badge.
3. **Settings > Data source.** "Traffic data" is "Live (team backend)"; the address field
   shows the built-in address as its placeholder; the status names the server and never says
   "Connected" while nothing has answered.
4. **An unusable address.** Type `http://example.org` and press Return: "Use https for this
   address. Still using <address>." Clear the field to return to the built-in address.
5. **Demo and back.** Choose "Demo (simulated)": the Map shows "Demo estimate" and the
   simulated 7:15 AM or 10:15 AM with TEST DATA, and Prototype testing appears at the end of
   Settings. Choose "Live (team backend)" again: the simulated time is gone.
6. **With the team backend running** at the address in use (on the same Mac for the
   simulator): Try Again, or relaunch. The card shows the recommended departure, the predicted
   arrival, the backend's reason, the traffic source it named, and its confidence; the status
   row reads "Connected to <host>. Last answer <time>."; when the server provides routes the
   line becomes solid and is labeled "Route via <source>".
7. **Leave-home reminders in Live mode.** Turn the toggle on: iOS asks for notification
   permission the first time. The section shows "Waiting for the server to confirm
   monitoring.", then either the sentence that the server will try to alert you or the exact
   obstacle (permission, no push credentials on the server, no device token, a server that is
   not monitoring or only checks while awake), and "Alerts are set up for trips through
   <day>. Open the app again before then to keep them coming."
8. **"I've Left."** Once the server monitors a trip, the Calendar details and the Map card
   offer "I've Left"; afterwards "Marked as left. Monitoring ended for this trip."
9. **Push alerts.** These need a device, a team whose App ID has the Push Notifications
   capability, and a server with push credentials
   ([`docs/BACKEND_INTEGRATION.md`](docs/BACKEND_INTEGRATION.md), "Push setup"). How the app
   shows and handles a visible alert can be tried on the simulator against the backend's
   fixture server (the same document, "End to end against the fixture server").

## Requirements

- macOS with Xcode 15.0 or newer (iOS 17 SDK). Xcode 16 opens the project unchanged. The
  backend integration was built and tested with Xcode 27.2.
- An iOS 17+ simulator. No Apple Developer account, team, or signing credentials are
  needed for simulator builds (signing style is Automatic with no team set). This still holds
  with the push entitlement: a plain simulator build is signed "to run locally".
- For live data, a reachable team backend: on the same Mac for the simulator
  (`http://localhost:3000` is the built-in address), or any https address entered under
  Settings > Data source. Without one the app says so and shows no leave-home time.
- For any build that runs on a physical device: a team whose App ID has the Push
  Notifications capability, which means an Apple Developer Program team. The project carries
  the push entitlement, so a free personal team cannot sign it for a device, even when only
  live recommendations are wanted. No team is written into the project, and none is set up
  here.
- For push alerts: that team, a physical device, and a backend with push credentials.
- No third-party tools. The project file is checked in; nothing generates it.

## Open, build, run

1. Open `WaitItOutUXPrototype.xcodeproj` (double-click, or `open WaitItOutUXPrototype.xcodeproj`).
   Xcode resolves the local package automatically; no network access is required.
2. Select the shared scheme **WaitItOutUXPrototype** and any iPhone simulator (for example
   iPhone 15 or iPhone SE (3rd generation) for the compact layout).
3. Press Run (Cmd-R). Press Cmd-U to run the package unit tests and the UI tests. The app
   starts in **Live mode**: without a backend at the address in use it reports that the backend
   could not be reached. Steps 5, 6, and 8 below describe the **Demo data mode**; choose
   Settings > Data source > "Demo (simulated)" first.
4. To see activities: Settings tab, "Load sample activities", then the Calendar tab.
5. To see leave-home times: with the samples loaded, open the Map tab (next trip) or tap a
   block in the Calendar (Leave home section). Change "Test commute duration" in the
   Prototype testing section at the end of Settings and tap Done to watch every time
   recalculate.
6. To try the scenarios: in Settings, scroll to Prototype testing and choose Slow,
   Unavailable, or Error, then open the Map. Slow keeps the earlier time on screen marked out
   of date for about 3 seconds, then shows 6:45 AM or 9:45 AM; Unavailable explains that there
   is no estimate; only Error offers Try Again, which keeps failing until you choose another
   scenario. "Reset to Normal, 60 Minutes" restores the defaults. To edit home or campus, tap
   its row under Home and campus (the Map's "Edit in Settings" switches to Settings), type a name and
   decimal-degree coordinates, and Save: the Map re-fits both pins and every leave-home time
   recalculates. "Reset to Sample Locations" restores the samples.
7. To see persistence: load the samples, change a setting, then stop the app in Xcode and run
   it again; the schedule and settings are still there.
8. To see reminder previews: with the samples loaded, Settings > Leave-home reminders, turn on
   "Remind me when it is time to leave". The next reminder appears with its time and message,
   and also on the Map. Under Prototype testing, "Simulate reminder failure" shows the failure
   and Try Again; Unavailable or Error explains why no preview can be created.

Command line equivalents (replace the simulator name with one `xcrun simctl list devices` shows):

```sh
xcodebuild -project WaitItOutUXPrototype.xcodeproj -scheme WaitItOutUXPrototype \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project WaitItOutUXPrototype.xcodeproj -scheme WaitItOutUXPrototype \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Run only the package unit tests:

```sh
xcodebuild -project WaitItOutUXPrototype.xcodeproj -scheme WaitItOutUXPrototype \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:WaitItOutUXTests test
```

`swift test` inside `Packages/WaitItOutUX` is not supported: the package uses iOS-only
SwiftUI and MapKit APIs, so run its tests through the app scheme with a simulator destination.

Launch the installed app against a backend on this Mac, or as the standalone demo:

```sh
SIMCTL_CHILD_WAIT_IT_OUT_BACKEND_URL=http://localhost:3000 \
  xcrun simctl launch booted com.waititout.uxprototype

SIMCTL_CHILD_WAIT_IT_OUT_DATA_MODE=demo xcrun simctl launch booted com.waititout.uxprototype
```

The test commands recorded under "Validation status" add `CODE_SIGNING_ALLOWED=NO`. Such a
build cannot use the Keychain on the simulator, so trip monitoring cannot register in it;
build without that setting to try leave-home alerts.

## Adding files in later steps

- Package files: drop them under `Sources/WaitItOutUX/` or `Tests/WaitItOutUXTests/`.
  SwiftPM membership is by folder, so no project edits are needed.
- Host or UI-test files: add them to `project.pbxproj` (PBXFileReference, PBXBuildFile,
  group child, and the target's Sources phase). Run the checker below to confirm membership.
- Every UI test file sets `WAIT_IT_OUT_STORAGE_FOLDER` and `WAIT_IT_OUT_DATA_MODE`. Use `demo`
  for the deterministic prototype; a test that sets `live` must also point
  `WAIT_IT_OUT_BACKEND_URL` at a loopback address and may name no other server.
- Keep decisions out of the host: put them in the package as pure code with unit tests, as
  `BackendLaunchOptions` and `TripNotificationPayload.response` do. The host has no unit-test
  target; it is covered by the build and the UI tests.

## Static checks

```sh
python3 scripts/check_project_structure.py
xmllint --noout WaitItOutUXPrototype.xcodeproj/xcshareddata/xcschemes/WaitItOutUXPrototype.xcscheme
```

The checker confirms that every host Swift file belongs to its target, the package
reference and scheme point at real targets, build settings keep the simulator signing-free,
and no TODO, fatalError, or force-unwrap patterns slipped in. It does not compile anything.

It also confines the APIs that reach outside the app to allow-lists of exact files, requires
each allow-listed file to exist, and refuses the API in every other host or package source:

| API | Allowed only in |
| --- | --- |
| The system networking session and the types named after it (stage S1) | `Packages/WaitItOutUX/Sources/WaitItOutUX/Backend/URLSessionTransport.swift` |
| The system notification center, its framework import, and the authorization request (stage S3) | `WaitItOutUXPrototype/AppDelegate.swift`, `WaitItOutUXPrototype/SystemPushRegistrar.swift` |
| The application singleton, and in the host any registration with the push service | `WaitItOutUXPrototype/SystemPushRegistrar.swift` |
| Loading the contents of a URL (`Data(contentsOf:)` and its relatives) | `Packages/WaitItOutUX/Sources/WaitItOutUX/Persistence/FileAccessing.swift`, for files |
| The Network framework, web views, `AsyncImage`, raw streams and sockets | Nowhere |
| Location and calendar permission APIs, a Calculate control | Nowhere |

Comments are ignored, and "//" inside a string literal is not taken for a comment, so an API
named after a URL on the same line is still seen. The package's unit tests may not name the
networking session at all; among the UI tests only `LiveModeUITests.swift` may, for its probe
of the opt-in fixture server on this machine.

Since stage S3 it reads the host's property lists as well:

- `WaitItOutUXPrototype/Info.plist`: no `*UsageDescription` key, no `UIBackgroundModes`,
  `NSAppTransportSecurity` with nothing but `NSAllowsLocalNetworking`, and a
  `WaitItOutBackendURL` that is https or on this machine, without a path.
- `WaitItOutUXPrototype/WaitItOutUXPrototype.entitlements`: only `aps-environment`, and
  `SystemPushRegistrar.apnsEnvironment` must report the matching push environment
  (`development` with `"sandbox"`, `production` with `"production"`).
- The project may name only those two files (`INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS`), every
  build configuration of the app target has to name both, no other property list may sit in
  the host or UI-test folders, and no development team or provisioning profile may be written
  into the project.
- Every application a UI test creates is given `WAIT_IT_OUT_STORAGE_FOLDER` and
  `WAIT_IT_OUT_DATA_MODE` (`demo` or `live`) before it is launched; a live one also gets
  `WAIT_IT_OUT_BACKEND_URL`, and a UI test file names only loopback addresses. The one launch
  without them, in the opt-in closed-app test, is named in the checker
  (`BARE_UI_TEST_LAUNCHES`).

These are text and property-list checks. They show that the rules hold in the files, not
that the app behaves: a passing run is not a build or a test pass.

## Validation status

| Step | Environment | Executed | Not executed |
| --- | --- | --- | --- |
| 0001 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, screenshots |
| 0002 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, screenshots |
| 0003 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, previews, screenshots, VoiceOver and large-text manual checks |
| 0004 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, previews, screenshots, gesture, VoiceOver and large-text manual checks |
| 0005 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the new departure tests), simulator launch, previews, screenshots, VoiceOver and large-text manual checks |
| 0006 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the new step 0006 tests `CommutePlaceTests`, `MapCameraFitTests`, `TestCommuteScenarioTests`, `WaitItOutModelMapTests`, and `MapScenarioUITests`), simulator launch, previews, screenshots, map tile and offline behavior, camera framing with the bottom inset, VoiceOver and large-text manual checks |
| 0007 | Linux host without Xcode | `check_project_structure.py` (0 errors), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the new step 0007 tests `PersistenceStoreTests`, `ReminderPlanTests`, `WaitItOutModelPersistenceTests`, `WaitItOutModelReminderTests`, and `PersistenceReminderUITests`), simulator launch and relaunch, previews, screenshots, file behavior on a device (atomic replace, Application Support location), VoiceOver and large-text manual checks |
| 0008 | Linux host without Xcode | `check_project_structure.py` (0 errors, 0 warnings, including the new product-contract rules, each also confirmed to fail on an injected violation), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the new `EndToEndDemoTests` and `DemoAccessibilityUITests`), simulator launch from a clean checkout and relaunch, the manual demo checklist, previews, screenshots, VoiceOver and large-text manual checks |
| 0001 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0001 deliverables on the finished prototype without changing code: project, local package reference, scheme (app, `WaitItOutUXTests`, `WaitItOutUXPrototypeUITests`), iOS 17.0 target, signing-free simulator settings, `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, screenshots |
| 0002 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0002 deliverables on the finished prototype without changing code: the `Activities/` domain (`Activity` with no departure field, `Destination` and `GeoCoordinate`, `Weekday`, `LocalDate`/`WallTime`/`LocalTimeResolver` with the documented DST policy, `ActivityValidator`, `OccurrenceID` and `OccurrenceExpander`, `ActivityRepository` with `InMemoryActivityRepository`, `SampleActivities` with the M/W/F and T/Th schedule), the model's `saveActivity`, `loadSampleActivities`, `clearSampleActivities`, and `visibleWeekOccurrences`, the Settings Load and Clear sample actions, and the six step 0002 unit test files (75 test methods, all still NOT RUN here); re-derived the 29 fixture instants and the day counts used by `OccurrenceExpanderTests`, `LocalTimeTests`, and `SampleActivitiesTests` with Python `zoneinfo` (0 mismatches); `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme. Since step 0007 the host injects the file-backed repository; the in-memory one remains for previews and tests | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, screenshots |
| 0003 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0003 deliverables on the finished prototype: the pure `Calendar/` layer (`DayTimelineLayout`, `OverlapLayout`, `DaySchedule`, `CalendarLayoutMode`, `BlockDetail`), the Calendar screens (week header and day strip, time grid and day columns, blocks and arrival markers, current-time line, detail sheet, empty states, Today, the minute tick while the current week is on screen, selection and scroll state in the model), the six previews, and the six step 0003 unit test files (49 test methods before this re-run, all still NOT RUN here); re-derived every numeric expectation of `DayTimelineLayoutTests`, `OverlapLayoutTests`, `DayScheduleTests`, and `CalendarLayoutModeTests` plus the epoch instants of `WaitItOutModelCalendarTests` and `CalendarFormattingTests` with an independent Python model of the layout code on Python `zoneinfo` (118 checks, 0 mismatches; script kept outside the repo). One code change: in the seven-column layout the 23- or 25-hour transition day now labels its own hour rows inside its column (`DayTimelineLayout.sharedGutter(for:)`, `rowsDiffer(from:)`, `DayColumnView.labelsOwnHours`), closing the gutter limitation noted after step 0008, with one new unit test in `DayTimelineLayoutTests` (50 methods now); `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI), simulator launch, the "Calendar - week grid, landscape" preview on a daylight-saving week, screenshots, VoiceOver and large-text manual checks |
| 0004 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0004 deliverables on the finished prototype: the `Editing/` layer (`ActivityDraft`, `ActivityEditSession`, `WaitItOutModel+Editing` with one pending draft, a single write per Save, and Cancel restoring the original), `GridDrag` and `DraftPreview`, the compact editor (title, the campus destination, "1. Activity time" before "2. Ideal campus arrival", Repeat, inline `ActivityValidator` issues, the arrival day note, no departure input), Add Activity, press-and-hold creation, block moves and resize handles with VoiceOver adjustments, the unsaved-change bar, Edit Series and Delete Series with confirmation, and the four step 0004 unit test files plus `ActivityEditingUITests` (81 unit test methods and 6 UI tests before this re-run, all still NOT RUN here); re-derived the expectations of the new tests with an independent Python model on `zoneinfo` (24 checks, 0 mismatches; script kept outside the repo). One code change: the time grid now stops scrolling while a creation, move, or resize gesture is in progress (`DayColumnView.onGestureActivity`, `TimeGridView` `.scrollDisabled`), so a dragged block or handle cannot slide with the scroll view. Six new unit tests in `WaitItOutModelEditingTests` (22 methods now): changed repeat days of a series, repeat turned off, invalid end, arrival, and repeat days refused on Save and then saved once, an overnight activity from the editor drawn on both days, a block moved past midnight, and an arrival moved onto the previous day; `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the six new tests), simulator launch, previews, screenshots, gesture checks on a device or simulator (including the new scroll lock), VoiceOver and large-text manual checks |
| 0005 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0005 deliverables on the finished prototype: the `CommuteEstimating` boundary (`CommuteRequest` with the home origin, the resolved destination, and the ideal arrival; `CommuteEstimate` with travel time, source label, estimate time, and the simulated flag; `.unavailable`; a thrown error for failures), `TestCommuteProvider` (60 minutes by default, stamped by the injected clock), `CommuteDuration` validation, the pure `DepartureCalculator` and `DepartureCalculation.make`, `DepartureState` (loading, success, unavailable, error, and refreshing since step 0006), `DepartureHorizon` (7 days), the model's token-guarded refresh, cancellation, and editor preview, the read-only `DepartureRows` in Calendar details, the editor, and the Map's next-trip card with its Add Activity setup action, the labeled Settings test duration, the missed-target warning, and `docs/COMMUTE_ESTIMATION.md` against the code; the six step 0005 unit test files (90 test methods before this re-run) and `DepartureUITests` (3 UI tests), all still NOT RUN here. Re-derived 526 expectations of those files and of the sample-schedule test in `EndToEndDemoTests`, plus 11 for the new tests, with an independent Python model on `zoneinfo` (0 mismatches; 5 deliberately wrong expectations were all caught; scripts kept outside the repo). No production code change. Three new unit tests in `WaitItOutModelDepartureTests` (23 methods now): the Map's Add Activity on an empty schedule (the Calendar on today, a new activity in the editor, its read-only preview kept and judged a missed target, and only a tab switch while a change is pending); a destination edit (the preview and the saved trip start again from loading, superseded requests are cancelled, 8:15 AM minus 20 minutes = 7:55 AM); and a class moved to another day with repeat days added (the old occurrence and its request are dropped, Tuesday and Thursday leave at 7:15 AM, the next trip follows). Two assertions that could never fail now check the timing and the spoken missed-target label, and the `.refreshing` message is covered (`DepartureCalculatorTests`, `DepartureTextTests`); `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the three new tests and the changed assertions), simulator launch, previews, screenshots, VoiceOver and large-text manual checks |
| 0006 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0006 deliverables on the finished prototype: the Map tab built around the saved next trip (event day and start, ideal arrival, read-only leave-home time with its formula, the test drive and scenario line, the estimate's source and age), the always-visible "Demo estimate" label, home and campus markers joined by the dashed straight line labeled "Schematic line, not a route", the pure `MapCameraFit` camera, the trip and places cards outside the map content (they stay readable without tiles), the Settings Home and campus rows and place editor (`PlaceInput` strict decimal degrees, inline issues, Save only for a valid change, Use Sample, Reset to Sample Locations), Prototype testing (Normal, Slow, Unavailable, and Error injected through `TestCommuteProvider` and applied by `commuteSettingsDidChange()`, `.refreshing` keeping the earlier time marked out of date, Try Again only for `.error`, `EstimateFreshness`), and the provider replacement notes in `docs/COMMUTE_ESTIMATION.md` and `docs/TEAM_INTEGRATION.md` against the code; the four step 0006 unit test files (45 test methods before this re-run) and `MapScenarioUITests` (3 UI tests), all still NOT RUN here. Re-derived 324 expectations of those four files with an independent Python model of the production code (0 mismatches; 5 deliberately wrong expectations were all caught; scripts kept outside the repo). No production code change. Three weak tests in `WaitItOutModelMapTests` were fixed: the Map and Calendar consistency test compared the Map's next trip with the very call that produced it, so it could not fail; it now finds the block through the Calendar's own path (`selectDay`, `occurrences(on:)`) and checks that it equals the Map's trip (so its detail sheet reads the same state, which must be the stored calculation) after an edit, a duration change, a scenario switch (including the out-of-date time while the Slow answer is pending), and deleting the next event, which must also leave the Calendar. The Slow cancellation test switched back before any Slow request had started, so it passed even without cancellation; it now holds the in-flight Slow requests and asserts that switching back cancels them and ends their 5-second pause early. The freshness test now checks synchronously that a 9-minute-old estimate is kept. The late-answer test now also asserts that the superseded request is cancelled. One new test (11 methods now): the editor's leave-home preview follows Slow (out of date, then 6:45 AM), Error (Try Again asks again and keeps failing), Unavailable (no Try Again, nothing asked again), and Reset (7:15 AM) without editing the draft; `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the new and changed `WaitItOutModelMapTests`), simulator launch, previews, screenshots, map tiles and offline behavior, camera framing with the bottom inset, VoiceOver and large-text manual checks |
| 0007 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0007 deliverables on the finished prototype: JSON persistence behind the existing boundaries (`FileActivityRepository` and `FilePreferencesStore` actors over the injected `FileAccessing`, atomic writes in `LocalFileAccess`, Application Support through `PrototypeStorageLocation` with the validated `WAIT_IT_OUT_STORAGE_FOLDER` override, the `VersionedJSONFile` envelope with schema version 1, damaged, newer-format, read, and write failures, writes refused while a file is unreadable, Try Again and the confirmed Keep a Copy and Start Over that renames and never deletes, tolerant per-field settings decoding, departures and reminders never stored), the `ReminderScheduling` boundary with `PreviewReminderScheduler` (in-app only, no permission, the "Preview only - no system notification will be sent." disclosure wherever a reminder shows, deterministic failure simulation and Try Again), `ReminderPlan`, `ReminderChanges`, and `ReminderPreview` (saved trips within 7 days that have not started, current estimates only, due after now, at most 20, keyed by `OccurrenceID`, every gap explained), the reconciliation triggers (save, edit, delete, estimates, toggles, launch and relaunch, foreground), the separate wish and delivery state, the Settings Leave-home reminders and Saved data sections, the Map's compact preview, and `docs/REMINDERS.md` against the code; the four step 0007 unit test files (78 test methods before this re-run) and `PersistenceReminderUITests` (3 UI tests), all still NOT RUN here. The key date expectations (the five sample leave-home times, the 25-trip and 20-reminder bound, passed and falling-due reminders) were re-checked by hand; an independent Python re-derivation was started but stopped by a usage limit before it reported, so it is not counted. No production code change. Two new tests: `WaitItOutModelPersistenceTests` (11 methods now) makes writes fail after the samples, the reminder wish, and the settings were saved, and checks that saving, deleting, and a setting change are refused with their messages, both files stay byte-for-byte unchanged, the calendar and its five reminder previews stay on the last saved schedule, a relaunch reads exactly that data, and the next save after writing works again is stored; `WaitItOutModelReminderTests` (17 methods now) switches to a 45-minute test commute and checks that each of the five reminders is kept, marked out of date, while the trips are asked again, then moves to 7:30 AM or 10:30 AM in place with the same occurrence ids, no duplicates, and nothing cancelled on the way. Docs: `docs/REMINDERS.md` now says what reconciliation does while the settings file cannot be read (defaults apply, so reminders count as off), and a new known limitation notes that Settings has no minute tick; `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the two new tests), simulator launch and relaunch, previews, screenshots, file behavior on a device (atomic replace, Application Support location, the renamed backup), VoiceOver and large-text manual checks |
| 0008 (re-run, 2026-11-02) | Linux host without Xcode (`xcodebuild`, `swift`, `xcrun`, `plutil` absent) | Re-verified the step 0008 deliverables on the finished prototype: the clean-checkout launch path (thin `@main` host, `AppDependencies.makeModel()`, `WaitItOutRootView` loading settings and then activities and re-planning on foreground), the local package reference (`Packages/WaitItOutUX`), the iOS 17.0 deployment target, signing-free simulator settings, the shared scheme (app, `WaitItOutUXTests`, `WaitItOutUXPrototypeUITests`), and no user data or build products in the checkout; `docs/TEAM_INTEGRATION.md` against the code (every type, method, protocol requirement, initializer, and test double it names exists with that signature); the manual demo checklist against the screens' labels; the known limitations. An independent static read of all 18 screen files, `EndToEndDemoTests` (3 tests), and all six UI test files (21 UI tests) checked every model call, binding, `switch`, identifier, and element type against its declaration and found no compile error, no query that cannot match, and no assertion that cannot fail; the 7:15 AM and 10:15 AM sample departures at 60 minutes were re-checked by hand against `SampleActivities` (ideal arrivals 8:15 AM and 11:15 AM). Re-ran the product-contract injection: 13 violations, each injected alone into a temporary copy outside the repo (tab order, a departure property on `Activity` and on `ActivityDraft`, a Calculate button, notification and location permission APIs, `URLSession`, a privacy usage string, a Python file in the package, a UI test without the storage folder, a force unwrap and a TODO in package tests, a host file outside its target), all caught; the clean copy passes. Fixes: the out-of-date leave-home time shown while an estimate refreshes keeps its TEST DATA badge and spoken "Simulated test data" (`DepartureRows`, `OccurrenceFormatter.staleDepartureAccessibilityLabel`, three new assertions in `DepartureTextTests`; 474 unit test methods in total, unchanged); the editor, detail, and place editor sheets are each one accessibility container, so their identifiers cannot replace their controls' identifiers; `DepartureUITests` and `MapScenarioUITests` replace text after tapping the right-aligned field's trailing edge; `docs/TEAM_INTEGRATION.md` schema instants corrected (they decoded to 10:00, 10:50, and 8:30 AM instead of 9:00, 9:50, and 8:15 AM) and CoreGraphics listed; README directory layout gains `Persistence/`, `Reminders/`, `Screens/Reminders/`, and the test doubles. `check_project_structure.py` (0 errors, 0 warnings; 68 package sources, 43 package tests), `xmllint` on the scheme | `xcodebuild build`, `xcodebuild test` (unit + UI, including the changed `DepartureTextTests`, `DepartureUITests`, and `MapScenarioUITests`), simulator launch from a clean checkout and relaunch, the manual demo checklist, previews, screenshots, VoiceOver and large-text manual checks |
| Backend integration, stage S1 (2026-11-19) | Mac with Xcode 27.2 (Swift 6.4.2, Swift 5 language mode), iOS Simulator | Package side of the team backend integration: `DepartureRecommendation` and the `.recommendation` / `.notYet` answers, `CommuteProviderFailure`, the `.stale` and `.notYetPlannable` states, backend-aware `EstimateFreshness`, automatic retry with backoff, `DataMode` and the server address in `UserPreferences`, `BackendConfiguration`, `HTTPTransport` / `URLSessionTransport`, `BackendClient`, `BackendCommuteProvider`, `BackendRouteProvider`, `LiveBackend`, the route state, the recommendation rows and mode-dependent wording, and the `TripMonitoring` declarations. The host still passes no `LiveBackend`, so the running app is the unchanged demo. Executed: `check_project_structure.py` (0 errors, 0 warnings; 82 package sources, 52 package tests; the new networking allow-list was also confirmed, in a scratch copy, to fail on the session named in another package file, in a host file, and on a missing transport file); `xcodebuild test -only-testing:WaitItOutUXTests` on the iPhone 17 simulator with `CODE_SIGNING_ALLOWED=NO`: 587 unit tests, 0 failures (the 474 earlier tests unchanged and passing, plus 113 new ones in `DepartureRecommendationTests`, `RecommendationTextTests`, `BackendConfigurationTests`, `BackendWireTests`, `BackendCommuteProviderTests`, `BackendRouteProviderTests`, `WaitItOutModelBackendTests`, and `WaitItOutModelRouteTests`, all against a scripted transport with no network); a UI-test subset on the iPhone 18 Pro simulator (`DemoAccessibilityUITests`, `DepartureUITests`, `LaunchNavigationUITests`, `MapScenarioUITests`: 12 tests, 7 passed and 5 failed, the same 7 and the same 5 with the same failure messages as the run on the unmodified project) | The other two UI test classes (`ActivityEditingUITests`, `PersistenceReminderUITests`), any request to a real backend or third-party service, the app running in Live mode (no host composes it yet), a device build, previews, screenshots, VoiceOver and large-text manual checks of the new recommendation rows and the route line |
| Backend integration, stage S2 (2026-11-19) | Mac with Xcode 27.2 (Swift 6.4.2, Swift 5 language mode), iOS Simulator | Package side of server-side trip monitoring: `BackendSession` (device registration, snapshot revisions, push reporting, monitored answers, one credential and one state per server origin), `CredentialStoring` with the in-memory and Keychain stores, the device and trip wire shapes, `TripNotificationPayload`, `MonitoredTrip` valid by construction, `MonitoringStatus` / `MonitoringObstacle` / `MonitoringSummary` / `MonitoringText`, the model's `reconcileMonitoring` (wanted trips, pending until acknowledged, retry, pause, withdrawal, refresh, re-resolving only changed departures), notification permission and push plumbing, "I've left", `openTrip`, `handleNotificationAction`, `prepareForNotificationResponse`, and `loadStoredState`. In Live mode the preview reminder adapter is no longer used. The host still passes no `LiveBackend`, so the running app is the unchanged demo. Executed: `check_project_structure.py` (0 errors, 0 warnings; 88 package sources, 59 package tests); `xcodebuild test -only-testing:WaitItOutUXTests` on the iPhone 17 simulator with `CODE_SIGNING_ALLOWED=NO`: 716 unit tests, 0 failures, 1 skipped (the 587 earlier tests unchanged and passing, plus 129 new ones in `BackendSessionTests` (50), `CredentialStoreTests` (6), `TripWireTests` (10), `MonitoringTextTests` (12), `WaitItOutModelMonitoringTests` (39), and `WaitItOutModelLiveMonitoringTests` (12), all against scripted transports and an in-memory stand-in for the backend's device and trip endpoints, with no network). Two batches of deliberately wrong code (11 small changes: the revision rule, the supersede rule, the old-server withdrawal, the load guard, the Live-mode reminder rule, the snapshot lifetime, the phase rule, the removal call, the old-address guard, the changed-trip rule, and the pending-after-an-outdated-acknowledgement rule) made the tests that cover each rule fail, except the last, which only shortens a state no screen can observe; the changes were reverted | The system Keychain: `CredentialStoreTests.testTheSystemKeychainStoresReplacesAndDeletes` is skipped on this test host (status -34018, no entitlement without an application host), so `SystemKeychain` has not run; the UI tests (not part of this stage); any request to a real backend, the push service, or a third-party service; the app running in Live mode (no host composes it yet); a device build; real notification permission, device tokens, and notification delivery; previews, screenshots, VoiceOver and large-text manual checks |
| Backend integration, stage S3 (2026-11-19) | Mac with Xcode 27.2 (Swift 5 language mode), iOS Simulator (iPhone 17) | The screens, the host, and the checker for the backend integration. Package: `MonitoringPresentation` and `MonitoringStatusView`, `TripDepartedControl`, `BackendConnection`, `DataSourceWording`, `LiveDataLabel`, the Settings "Data source" section and the mode-dependent wording, the Calendar's notification sheet, `BackendLaunchOptions`, and `TripNotificationPayload.response`. Host: `AppDependencies.makeGraph()` with `AppComposition`, `AppDelegate`, `SystemPushRegistrar`, the partial `Info.plist`, the entitlements file, and their project registration. UI tests: every existing test launches the standalone demo composition (`WAIT_IT_OUT_DATA_MODE=demo`); new `LiveModeUITests`. Executed: `check_project_structure.py` (0 errors, 0 warnings; 94 package sources, 64 package tests; its new rules were also confirmed, in a scratch copy, to fail on each of 22 injected violations: notification APIs outside the two allow-listed files, a missing allow-listed file, usage descriptions, background modes, arbitrary loads, an unsafe default address, a malformed plist, extra or mismatched entitlements, UI tests without a data mode or naming a real server, stray property lists, the networking session in the host, a hard-coded team); `xcodebuild test -only-testing:WaitItOutUXTests` with `CODE_SIGNING_ALLOWED=NO`: 776 unit tests, 0 failures, 1 skipped (the 716 tests of stage S2 unchanged and passing, plus 46 for the screens in `MonitoringPresentationTests`, `DataSourceWordingTests`, `BackendConnectionTests`, and `WaitItOutModelMonitoringScreenTests`, and 14 in `BackendLaunchOptionsTests`; no existing unit test was edited, and the six existing UI test files each gained only the launch-environment line that selects the demo composition); `xcodebuild test -only-testing:WaitItOutUXPrototypeUITests` with `CODE_SIGNING_ALLOWED=NO`, run twice with the same outcome: 23 UI tests, 15 passed and 8 failed. Of the 21 earlier UI tests the same 13 pass and the same 8 fail, with the same failure messages, as on the unmodified project (that baseline ran on the iPhone 18 Pro simulator; the 8 are `ActivityEditingUITests.testEditCancelAndDeleteSeries`, both `DepartureUITests` that type into the test commute field, `LaunchNavigationUITests.testTappingABlockShowsDetailsWithEditAndDelete`, `MapScenarioUITests.testMapShowsDemoLabelPlacesAndSchematicNote` and `testScenariosRecalculateAutomaticallyAndOnlyErrorOffersTryAgain`, and `PersistenceReminderUITests.testEnablingRemindersShowsPreviewOnly` and `testReminderFailureSimulationOffersTryAgain`); both new `LiveModeUITests` pass. `xcodebuild build` for the simulator with signing left on and no team: BUILD SUCCEEDED, signed to run locally, with the push entitlement and the merged Info.plist. That build was launched on the simulator in Live mode with nothing listening at its server address (the Map showed "Live data", "The backend could not be reached. Check the connection. No leave-home time is shown." with Try Again, and the route failure with the schematic label; no permission alert), and against a throwaway stand-in server on the same Mac that answers with fixture values (a recommendation was shown as given, labeled as fixture data; with reminders on the app registered once, synchronized its trips, reused its Keychain credential after a relaunch, and removed itself when reminders were off) | Any request to the team backend, deployed or local; anything involving Apple's push service (no notification permission was granted, so no device token, no push report with a token, and no received, tapped, or answered notification: the `AppDelegate` token and response handlers and the permission request have never been called by the system); a physical device; a build signed with a team; a Release or distribution build; background delivery and a cold start from a notification; turning reminders on by tapping the toggle in Live mode (the saved setting was edited between launches instead); typing a server address by hand; the 8 UI tests that fail were not repaired; previews, VoiceOver and large-text manual checks of the new screens |
| Backend integration, review fixes (2026-11-19) | Mac with Xcode 27.2 (Swift 5 language mode), iOS Simulator (iPhone 17) | Fixes from an adversarial review of stages S1 to S3. Package: `EstimateFreshness.nearLifetime` (a nearby departure is asked again one backend slot after it was asked); `MonitoredTripState.currentPlan` (the server's plan is shown only while the server keeps it current) used by `BackendSession.answer(for:)` and the model; the two 503 codes; `unregister` keeping the credential unless the removal is confirmed; `TripMonitoring.withdrawTrips()` and `serversLeftBehind()`, `CredentialStoring.origins()`; `MonitoringStatus.settingsUnreadable`; per-trip server problems, the coverage line, the local push registration failure, and the reworked alert lines in `MonitoringSummary`, `MonitoringText`, `MonitoringPresentation`, and `OccurrenceFormatter+Monitoring`; trips sent without a start time and a destination name; the editor's next-occurrence preview and its debounce; the Settings minute tick; the Map label "Team backend". UI tests: `LiveModeUITests` accepts every honest outcome; `FixtureBackendEndToEndUITests` keeps its screenshots as attachments and restores the default storage. Checker: the tightened rules in "Static checks". Executed: `check_project_structure.py` (0 errors, 0 warnings; 94 package sources, 67 package tests; in 12 scratch copies with injected violations every one produced an error, and the clean copy passed: the application singleton and a push registration in another host file, the networking session after a URL string on the same line and its configuration type in a package source, a UI test application created without its storage folder and data mode, a live one without a server address, the session in a unit test and in another UI test file, the Info.plist or the entitlements missing from the Release configuration only, the Network framework, `NWConnection`, `Data(contentsOf:)`, and `AsyncImage` together in a package source, and the named bare launch removed without its entry); `xcodebuild test -only-testing:WaitItOutUXTests` with `CODE_SIGNING_ALLOWED=NO`: 845 unit tests, 0 failures, 1 skipped (the real-Keychain test). Of the 776 tests of stage S3, these were changed because the intended behaviour changed: the near-departure lifetime in `DepartureRecommendationTests`, `BackendConnectionTests`, and two `WaitItOutModelBackendTests`; a monitored plan after its departure (`DepartureRecommendationTests`); a stale server plan is no longer answered (`BackendSessionTests`, `WaitItOutModelLiveMonitoringTests`); the trip body and `MonitoredTrip` without start and destination name (`BackendSessionTests`, `TripWireTests`, `WaitItOutModelMonitoringTests`); the local registration failure (`BackendSessionTests`); the withdrawal fallback, the forced retry of a server without monitoring, and the footer (`WaitItOutModelMonitoringTests`, `WaitItOutModelMonitoringScreenTests`); the planned-phase lines, the footers, and a recorded departure that no longer outlives the server's phase (`MonitoringTextTests`, `MonitoringPresentationTests`, `DataSourceWordingTests`). New: `RealBackendShapesTests` (14), `WaitItOutModelMonitoringStateTests` (14), `WaitItOutModelLiveDraftTests` (6), and tests added to the existing files. Five of the new regression tests were also run with their fix disabled and failed as they should. `xcodebuild test -only-testing:WaitItOutUXPrototypeUITests` with `CODE_SIGNING_ALLOWED=NO`, one complete run: 25 UI tests, 15 passed, 8 failed, 2 skipped. The 13 earlier tests that pass on the unmodified project pass, the same 8 fail with the same messages, both `LiveModeUITests` pass, and the 2 `FixtureBackendEndToEndUITests` were skipped because no fixture server was running | Any request from the app to a running backend in this stage (the fixture end-to-end tests were skipped; the bodies decoded by `RealBackendShapesTests` were captured beforehand and supplied as files); the closed-app notification test; anything through Apple's push service; a physical device; a build signed with a team; the `CODE_SIGN_ENTITLEMENTS` override for a personal team mentioned in the docs; `SystemKeychain`'s listing of accounts (its test is skipped in this test host); manual checks of the changed screens, VoiceOver, and large text; the 8 UI tests that fail were not repaired |

The rows up to "0008 (re-run, 2026-11-02)" record work done on a host without Xcode: for
those steps nothing was compiled or run at the time. From stage S1 on, the project is built
and its tests run on a Mac, and each row says exactly what ran. Eight of the 21 UI tests
written during the prototype steps fail on that Mac setup; they had never been run before,
their failures have the same messages on the unmodified project, and they have not been
repaired. The
expected instants in the step 0002 tests were derived with an independent tz database
(Python `zoneinfo`) and must agree with Foundation on the Mac; a disagreement there points
at the resolver policy, not at the fixtures.

## What step 0007 shows

- **Settings**, in order: Appearance, Sample schedule, Prototype information, Home and campus,
  Leave-home reminders (toggle and preview), Saved data (where data lives; Try Again and Keep a
  Copy and Start Over only while something cannot be read), and Prototype testing last (now
  with "Simulate reminder failure").
- **Map**: the next-trip card ends with the compact reminder preview while reminders are on.
- **Relaunch**: activities, repeats, time zones, destinations, home and campus, appearance,
  the test duration and scenario, the reminder preference, and the failure simulation come
  back; leave-home times and reminder previews are recalculated.
- Previews to check on a Mac: "Reminder preview - on, sample schedule" and "Reminder preview -
  simulated failure".

## What step 0006 shows

- **Map**: home and campus pins joined by a dashed straight line labeled "Schematic line, not
  a route", a camera fitted to both, the "Demo estimate" label in the navigation bar, the next
  trip card (event day and start, ideal arrival, read-only leave-home time, formula, source with
  estimate time and age, test drive and scenario line), and the places card (both places,
  schematic note with the straight-line distance, Show Home and Campus, Edit in Settings), or
  Add Activity / Open Calendar when there is nothing to plan.
- **Settings**, in order: Appearance, Sample schedule, Prototype information (now with "Home
  and campus" and "Commute estimates" rows), Home and campus (two rows that open the place
  editor, Reset to Sample Locations), and Prototype testing last (four scenarios, the "Now
  simulating" line, the test commute duration field and stepper, Reset to Normal, 60 Minutes).
- **Calendar**: everything from 0005 (week header and day strip, time grid, blocks, arrival
  markers, Add Activity, drag creation, the editor, block adjustment, Edit and Delete with
  whole-series confirmation, the read-only "Leave home" section in details and line in the
  editor). The destination shows the campus set in Settings, leave-home rows show the
  estimate's age and the out-of-date state, and Try Again appears only after a failure. Blocks
  are unchanged: the departure is never a block or a resize.

Manual checks to run on a Mac (previews are provided for each): "Calendar - empty",
"Calendar - sample schedule", "Calendar - crowded, overlaps, overnight" (three overlapping
Friday activities, a 15-minute check-in, an overnight Saturday session, an all-day Sunday
event), "Calendar - week grid, landscape", "Calendar - large text" (accessibility 3), and
"Calendar - dark", plus the editor previews "Editor - new activity" and "Editor - sample
series" (whole-series wording, SAMPLE note, Delete Series, leave-home line), the step 0005
previews "Detail - sample class" (Leave home section), "Map - empty schedule", "Map - next
trip, sample schedule", and "Map - large text" (cards scroll within their 60% cap), and the
step 0006 previews "Map - Slow scenario" (90-minute drive and Slow labels), "Map - Unavailable
scenario" (no estimate, no Try Again), "Map - estimate failed" (Error scenario with Try Again),
and "Place editor - sample home". Preview providers answer without a delay, so the loading and
out-of-date states appear only in the running app (300 ms, or 3 seconds for Slow). The crowded
fixture lives in `PreviewFixtures.swift` and every title says "Preview"; the host never loads
it. Gesture checks that only a device or simulator can confirm: press and hold a free time and
drag (a creation preview follows the finger in 15-minute steps), quick swipes still scroll the
grid, press and hold a block then drag it or its handles, the grid holds still during each of
those drags and scrolls again afterwards (the scroll lock added in the 2026-11-02 re-run of
step 0004), and VoiceOver swipes on a handle change it by 15 minutes. Map checks for step 0006: both pins stay clear of the bottom cards
after a fit, Show Home and Campus re-frames after panning, the cards stay readable with the
network off (tiles missing), and VoiceOver reads the pins, the Demo estimate label, and an
out-of-date time as such.

## Known limitations of the backend integration (stage S3)

- **Field-level agreement with the backend is tested against captured answers, not a running
  server.** `RealBackendShapesTests` decodes, through the app's production path, response
  bodies captured from the real backend code (every device, trip, verdict, and route answer,
  and the push payload) and one real answer of the deployed backend, embedded verbatim; all
  of them decode and map as intended. The automated tests still make no request to a running
  backend: the unit tests use scripted transports, and the end-to-end UI tests against the
  backend's fixture server are opt-in and are skipped when that server is not running.
- **Alerts reach 7 days ahead, counted from the last time the app was open.** The server holds
  only the trips it was sent (at most 20, the next 7 days), and the app sends them only while
  it is open; it has no background mode, and the alerts do not wake it. A repeating activity
  therefore stops getting alerts when the app is not opened for a week, and a weekly class
  gets next week's alert only if the app is opened after this week's ideal arrival. Settings
  says so and names the day alerts are set up through. A real fix needs the recurrence rule
  on the server or a background refresh; neither exists.
- **A nearby leave-home time can still move once when it is asked at a moment of its own.**
  Inside three hours the backend's candidate departures depend on when it is asked. The
  minute ticks ask exactly one 15-minute slot apart, so the time holds still while traffic
  does, but the first ask, a return to the foreground after the lifetime, Try Again, and the
  editor's preview each start a new grid and can move the time by up to a slot. Removing
  that needs an anchor parameter on the backend's verdict request.
- **Push alerts are unverified end to end.** Nothing in this repository has obtained a device
  token or received a notification. It needs an Apple Developer Program team, a device, and a
  server with push credentials ([`docs/BACKEND_INTEGRATION.md`](docs/BACKEND_INTEGRATION.md)).
- **The built-in server address is `http://localhost:3000`.** It suits a backend on the same
  Mac as the simulator. On a device it reaches nothing; enter the server's address under
  Settings > Data source.
- **Every build from this project uses the sandbox push environment**, Debug and Release
  alike, because the one entitlements file says `development`. A distribution build needs the
  entitlement and `SystemPushRegistrar.apnsEnvironment` changed together.
- **A build made with `CODE_SIGNING_ALLOWED=NO` cannot use the Keychain** on the simulator, so
  trip monitoring ends in "Trips could not be synchronized: this device's server credential
  could not be read or saved." Recommendations still work. Build normally to try alerts.
- **"I've left" on a notification opens the app.** That is deliberate: the request is made by
  the visible app, with its outcome on screen.
- **Alerts depend on the server being awake.** A server that sleeps when idle can check
  traffic only while it runs; the app says so when the server reports it.
- **The planning reach is about 11.5 hours.** A trip further ahead has no leave-home time yet
  and says when one will appear.
- **A server whose trip tables are not set up** answers "monitoring_unavailable"; the app
  says "This server does not support trip monitoring yet." and asks again only when it is
  opened or brought to the foreground, when the toggle changes, or on Try Again.
- **A withdrawal the server did not confirm keeps the credential.** Turning alerts off is
  immediate for the user, but the server is called "told" only after it confirmed; until then
  Settings says it may still send alerts and when that is tried again.
- **Unreadable settings pause monitoring.** The app then cannot know whether alerts were on
  or which server was chosen, so it changes nothing on any server and says that alerts may
  still arrive, until the settings can be read or a choice is made in Settings.
- **The connection status is derived, not measured:** it reflects the newest answer or
  failure already on screen and makes no request of its own. A failed route request is not
  counted, and neither is anything the app says by itself without a request.
- **The system Keychain's listing of stored credentials is not covered by an automated
  test:** the one test that uses the real Keychain is skipped in the package's test host.
  The rest of the credential store, including which origins it names, is tested against a
  stand-in.
- **The Map's toolbar label** has little room on the iOS 27 simulator: "Team backend" keeps
  its width, but the Demo data mode's "Demo estimate" capsule is cut down to its icon there
  (its spoken label and the TEST DATA badges are unaffected).
- **Eight earlier UI tests fail** on the Mac setup used here (see "Validation status"); they
  were not repaired in this work.
- The live UI tests accept every honest outcome for the next sample trip (the failed request,
  the trip beyond the forecast, an ideal arrival that has just passed), because which one
  shows depends on the time of day.
- **The end-to-end UI tests against the fixture server are opt-in** and turn alerts on; the
  closed-app one launches in the app's default storage and restores it afterwards (see
  [`docs/BACKEND_INTEGRATION.md`](docs/BACKEND_INTEGRATION.md), section 8).

## Known limitations after step 0008

- Steps 0001 to 0008 were delivered without compiling or running anything; the step 0008
  review and its 2026-11-02 re-run were careful static reads. Since stage S1 the project is
  built and its unit and UI tests run on a Mac (see "Validation status"): the unit tests pass,
  and 8 of the 21 UI tests of those steps fail there. On-device behavior is still unverified.
- Remaining integration work: a run against the deployed backend, push delivery on a device,
  and mapping to the team's storage and models
  ([`docs/TEAM_INTEGRATION.md`](docs/TEAM_INTEGRATION.md), section 11).
- "Sample schedule" and "Prototype information" are always shown in Settings.
- All user-facing text is English.

- No single-occurrence exceptions: edits and deletes of a repeating activity apply to the
  whole series.
- Drag creation, moving, and resizing stay within one day and snap to 15 minutes; use the
  editor's dates and pickers for anything else.
- There is one campus: every activity goes to the campus set in Settings, and the editor
  shows it read-only.
- The campus time zone stays `America/Los_Angeles` (from the sample campus) regardless of the
  campus coordinates; moving the campus elsewhere does not change any time zone.
- No geocoding or address search: home and campus are typed as decimal-degree coordinates.
- The Map's line is schematic and straight. It ignores roads, and a home and campus on either
  side of the 180th meridian get a line drawn the long way around, although the camera and the
  line's label take the short way.
- Map tile failures cannot be detected: SwiftUI's `Map` reports none. The cards stay readable
  and say that tiles need a network connection.
- Camera framing with the bottom safe-area inset is unverified on a device or simulator: the
  fit is computed for both places, and whether both pins always stay clear of tall cards has
  not been checked.
- In the Demo data mode, travel times come only from the labeled test provider, which
  ignores the coordinates: moving home farther away does not change the simulated time. Slow is a fixed +50% (rounded
  up to whole minutes, at most 12 hours), not traffic.
- The Error scenario never recovers on Try Again; it keeps failing until another scenario is
  chosen.
- Leave-home times are calculated for the next 7 days only. Details further ahead say so, and
  ended occurrences say they are over.
- In the Demo data mode the freshness lifetime is fixed at 10 minutes
  (`EstimateFreshness.lifetime`). Only saved occurrences refresh by age; the editor's preview
  is asked again when the draft or the provider settings change. There is still no request
  timeout for an injected provider, so it must return or throw on its own (see
  docs/COMMUTE_ESTIMATION.md).
- In the Demo data mode the editor's leave-home line describes the series' first occurrence
  as the editor shows it; its missed-target warning appears only when that occurrence is
  still ahead. With the live backend a series whose first occurrence has passed is previewed
  through its next upcoming occurrence, with a note that says so.
- Add Activity for today (including the Map's empty-schedule action) proposes the next whole
  hour with the ideal arrival 30 minutes earlier, so with the 60-minute test commute the new
  activity's leave-home time has already passed when the editor opens. The read-only line
  keeps that time and shows the missed-target warning until the times are changed; other
  days start at 9:00 AM.
- The departure and map scenario UI tests set `TZ=America/Los_Angeles` and an en_US locale and
  accept either sample as the next trip, because the day they run varies. Four of them fail on
  the Mac setup used for the backend integration (see "Validation status").
- The editing UI tests drive the compact pickers through picker wheels and force an en_US
  locale; five of the six pass on that setup.
- In the seven-column layout during a daylight-saving week, the transition day labels its own
  rows inside its column, so that day's blocks are 40 points narrower than its neighbors' and
  its labels sit beside the blocks rather than in the shared gutter. The selected-day layout
  always labels that day's own rows in the gutter.
- In the Demo data mode reminders are in-app previews only. Nothing is delivered when the
  app is closed, and the preview adapter keeps reminders in memory, so they are recreated
  after each relaunch.
- Reminders are due exactly at the leave-home time; there is no separate "remind me earlier"
  setting.
- Settings has no minute tick of its own (only the Map and the Calendar's current week
  refresh every minute), so while Settings stays on screen, a reminder preview whose time
  passes is still shown until another change redraws it, the Map or Calendar is opened, or the
  app returns to the foreground.
- Storage format 1 is the first; there is no older format to migrate. A newer format is
  refused with an explanation rather than read partially.
- Keep a Copy and Start Over keeps the unreadable file next to the saved data but offers no
  way to export or open it from the app.
- The reminder failure simulation is saved with the other Prototype testing values, so it is
  still on after a relaunch until it is turned off or reset.
- UI tests leave one small storage folder per test in the simulator app's container; deleting
  the app from the simulator removes them.
- Repeating activities have no end date.
- If the calendar's zone differs from the campus zone, Add Activity takes the selected day in
  the calendar's zone and its times in the campus zone, and a drag that would move an
  occurrence onto another campus-zone day is ignored. Both zones are the same in the prototype.
- A save whose write succeeds but whose reload fails is reported as a failure; retrying
  stores the same id again, so nothing is duplicated.
