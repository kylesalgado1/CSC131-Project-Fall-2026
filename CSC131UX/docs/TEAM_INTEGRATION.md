# Integrating WAIT IT OUT into the team app

This guide is for the team that adds the WAIT IT OUT feature to its existing iOS app. Every
type, method, and file named here exists in this repository after stage S3. Nothing here
names a team API or a backend endpoint: where the team's own code goes, the text says so in
words, and code sketches use Xcode placeholders such as `<#team schedule store#>`. The
requests the backend adapter makes are listed in [`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md).

**Status, plainly.** Steps 0001 to 0008 were written without a Mac. Since stage S1 the project
is built and its tests run on a Mac with Xcode; the README's "Validation status" says exactly
what ran. The host in this repository now composes the team backend (stage S3): leave-home
times, the Map's route, and server-side leave-home alerts come from it, and the labeled test
provider and the in-app reminder previews remain as the explicit Demo data mode. That
composition was exercised against scripted transports, an unreachable address, and a
stand-in server on the same machine. It has **not** been run against a deployed backend, and
push notifications have not been received on any device or simulator. Storage is still two
JSON files of the app's own.

## 1. What to take, and what to leave

Take the local Swift package `Packages/WaitItOutUX` (library product `WaitItOutUX`). It holds
every domain value, service protocol, the shared feature state, and every SwiftUI screen.

Leave behind:

- `WaitItOutUXPrototype/` (the `@main` host, its `AppDependencies` composition root, the
  `AppDelegate` and `SystemPushRegistrar` that connect the system's notification and push APIs
  to the package, the partial `Info.plist`, and the entitlements file; read them as a working
  example of the host side described in sections 5 and 8),
- `WaitItOutUXPrototype.xcodeproj` and its scheme,
- `WaitItOutUXPrototypeUITests/` (they launch the prototype host by its accessibility
  identifiers; reuse them as a script for the team's own UI tests if useful).

Do not copy the prototype's `@main` app into the team app, and do not add a second app target,
a second Xcode project, or a second shared state object. Add the package to the team's
existing project (File > Add Package Dependencies > Add Local, or copy the folder into the
team repository and reference it the same way) and link the `WaitItOutUX` product to the team's
existing app target. The package's unit tests (`WaitItOutUXTests`) come along and run in any
scheme that lists them as testables, with an iOS simulator destination.

## 2. Requirements

| Item | Value | Where it is set |
| --- | --- | --- |
| Minimum deployment target | iOS 17.0 | `Package.swift` (`.iOS(.v17)`) |
| Swift tools version | 5.9 (Xcode 15.0 or newer) | `Package.swift` |
| Language mode | Swift 5 | Package default for tools 5.9 |
| Apple frameworks used | SwiftUI, Observation, MapKit, CoreLocation (coordinate types only), CoreGraphics (`CGFloat` geometry in the pure `Calendar/` layout code), Foundation, `os` (`OSAllocatedUnfairLock`), Accessibility, Security (the Keychain credential store), CryptoKit (a digest of the trips last sent), UIKit (only `UIApplication.openSettingsURLString` for the "Open Settings" button) | `import` lines in the sources |
| Third-party dependencies | None | `Package.swift` |
| Permissions requested | The package itself asks for nothing and names no notification API. With a `LiveBackend` in Live mode it asks the host's `PushRegistering` adapter for notification permission, only when the user turns leave-home reminders on or taps Allow Notifications. No location or calendar permission, and no privacy usage strings | Checked by `scripts/check_project_structure.py` |
| Host capabilities for Live mode | Push Notifications (the `aps-environment` entitlement), outgoing network access to the backend (https, or plain http only on the local network through `NSAllowsLocalNetworking`), the Keychain. No background mode | The host's entitlements and Info.plist; see [`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md) |

An app whose deployment target is below iOS 17 cannot link the package as it is; the package
uses `@Observable`, the iOS 17 `Map` content builder, and other iOS 17 SwiftUI APIs.

## 3. Entry points

### The whole feature: `WaitItOutRootView`

```swift
import WaitItOutUX

WaitItOutRootView(model: model)   // model: WaitItOutModel, created once (section 4)
```

`WaitItOutRootView` is a `TabView` with exactly three tabs in the product order, Map,
Calendar, Settings (`PrototypeTab.displayOrder`), bound to `model.selectedTab`. It also does the
lifecycle work for the feature:

- `.task`: `await model.loadStoredState()`, which loads the stored settings and then the
  stored schedule exactly once even when a notification response asks for the same load at
  the same moment. Loading the schedule recalculates leave-home times and reconciles reminders.
- `.onChange(of: scenePhase)`: `model.appDidBecomeActive()` when the scene becomes active,
  which re-plans leave-home times and checks the reminder adapter again.
- `.preferredColorScheme(model.preferences.appearance.colorScheme)`: the Settings appearance.

Use it when the feature can own a whole scene or a full-screen destination of the team app.

### The three screens in the team's own tab bar

`MapScreen(model:)`, `CalendarScreen(model:)`, and `SettingsScreen(model:)` are public since
step 0008. Each brings its own `NavigationStack`, so give each one a tab of the team's existing
`TabView` rather than pushing it onto another navigation stack. When the screens are used
without `WaitItOutRootView`, the team's root view takes over the root view's three duties:

```swift
// In the team's root view, which already owns its TabView and scene handling:
.task {
    await model.loadStoredState()   // settings, then the schedule; single-flight
}
.onChange(of: scenePhase) { _, phase in
    if phase == .active { model.appDidBecomeActive() }
}
```

The feature switches tabs by setting `model.selectedTab`: the Map's "Add Activity"
(`startCalendarSetup()`) and "Open Calendar" go to `.calendar`, and the Map's and Calendar's
"Edit in Settings" / "Open Settings" go to `.settings`. Bind the team's tab selection to it,
for example with a `Binding` whose getter and setter translate between the team's own tab
value and `PrototypeTab`, so those buttons keep working. If the team does not show the
Settings screen, provide the same settings elsewhere (see section 9) and expect those buttons
to select a tab that is not shown until they are mapped.

## 4. The shared state owner: `WaitItOutModel`

`WaitItOutModel` is `@MainActor @Observable public final class`. Exactly one instance serves
all three screens; it is the only place feature state lives. Create it once in the team's
composition root, keep it alive for the scene (for example in `@State` of the `App` or of the
root view), and pass the same instance to every screen.

```swift
public init(
    clock: any WallClock,
    preferencesStore: any PreferencesStoring,
    activityRepository: any ActivityRepository,
    commuteEstimator: (any CommuteEstimating)? = nil,      // nil: TestCommuteProvider
    reminderScheduler: (any ReminderScheduling)? = nil,    // nil: PreviewReminderScheduler
    weekCalculator: WeekCalculator,
    sampleCampus: SampleLocation,
    sampleHome: SampleLocation = .demoHome,
    prototypeInfo: PrototypeInfo,
    liveBackend: LiveBackend? = nil,                       // nil: the standalone prototype
    initialTab: PrototypeTab = .map
)
```

Pass the team's own `commuteEstimator` and `reminderScheduler`: the `nil` defaults are the
labeled prototype implementations. Since stage S1 there is a second way to supply live data:
pass a `LiveBackend` (section 6). The backend's recommendations are then the normal flow, and
`commuteEstimator` and `reminderScheduler` serve only the explicit Demo data mode
(`UserPreferences.dataMode`, changed through `setDataMode(_:)`).

What the model owns, and how it changes:

| State | Meaning | Changed only through |
| --- | --- | --- |
| `activities`, `activitiesStatus`, `activityStorageIssue` | The schedule exactly as the repository last returned it | `loadActivities()`, `saveActivity(_:)`, `deleteActivity(id:)`, `saveDraft()`, `deleteDraftActivity()`, the sample actions, `retryLoadingStorage()`, `setAsideUnreadableStorage()` |
| `preferences`, `preferencesStatus`, `preferencesStorageIssue` | `UserPreferences`: appearance, places, reminder wish, prototype test values | `loadPreferences()` and the setters (`setAppearance`, `applyPlaceInput`, `setPlace`, `resetPlacesToSample`, `setRemindersEnabled`, `setTestCommuteDuration`, `setTestCommuteScenario`, ...) |
| `editSession` | The one pending `ActivityDraft` (create, edit, or calendar adjustment) | `beginNewActivity()`, `beginNewActivity(spanning:)`, `beginEditing(activityID:)`, `beginAdjusting(activityID:)`, `updateDraft`, `replaceDraft`, `saveDraft()`, `cancelDraft()`, `deleteDraftActivity()` |
| `departures`, `draftDeparture` | Leave-home calculations for the saved occurrences of the next 7 days and for the draft | `refreshDepartures()`, `retryDepartures()`, and internally on every reload, draft change, and settings change |
| `routeState` | What the Map draws between home and campus: the schematic line, or a driving route a `RouteProviding` supplied (stage S1) | Internally after the settings load, a place change, a data-source change, and in the foreground |
| `reminderSync`, `reminderPreviews`, `reminderPlan` | What the reminder adapter holds and what should exist | Reconciliation after every change, `retryReminders()`, `appDidBecomeActive()` |
| `selectedTab`, `visibleWeek`, `selectedDay`, `calendarScrollHour` | Navigation state that survives tab switches | `selectedTab` and `calendarScrollHour` directly; week and day through `showPreviousWeek()`, `showNextWeek()`, `showCurrentWeek()`, `selectDay(_:)`, `selectDay(at:)` |

Rules that keep the feature correct when it lives inside a bigger app:

- All mutations happen on the main actor; storage, estimates, and reminders run through the
  async protocol methods, which the model calls off the main actor.
- Never write to a repository from a view or from team code that bypasses the model while the
  feature is on screen: the model reloads after its own writes only. If the team changes the
  schedule elsewhere, call `await model.loadActivities()` afterwards so the calendar, leave-home
  times, and reminders follow.
- Leave-home times are derived state. They are never stored, never an input, and never part of
  `Activity`. For a travel-time estimate: **leave home = ideal arrival - travel time**
  (`DepartureCalculator`). For a backend recommendation the recommended departure is shown as
  the backend gave it, with no local arithmetic. Both are read-only through `DepartureRows`.

## 5. Dependency composition

The prototype's composition root is `WaitItOutUXPrototype/AppDependencies.swift`. The team
writes the equivalent in its own app, choosing an implementation for each boundary:

| Boundary | Protocol | Prototype implementation | What the team supplies |
| --- | --- | --- | --- |
| Current time | `WallClock` | `SystemWallClock()` | The same, or the team's clock if it injects one |
| Activities | `ActivityRepository` | `FileActivityRepository` on `activities.json` | An adapter over the team's existing schedule storage (section 7) |
| Settings | `PreferencesStoring` | `FilePreferencesStore` on `preferences.json` | An adapter over the team's settings storage (section 7) |
| File I/O for the JSON stores | `FileAccessing` | `LocalFileAccess()` | Nothing, unless the JSON stores are kept |
| Commute estimates | `CommuteEstimating` | `TestCommuteProvider` (labeled TEST DATA) | A provider over the team's routing or travel-time service (section 6) |
| Live backend (stage S1) | `LiveBackend`: a `CommuteEstimating`, an optional `RouteProviding`, an optional `TripMonitoring`, and the `BackendConfiguration` | `BackendCommuteProvider` and `BackendRouteProvider` on one `BackendClient` with `URLSessionTransport` (stage S3), unless the launch asks for the standalone demo | The same, or the team's own implementations of the protocols |
| Trip monitoring (stage S2) | `TripMonitoring` (and `MonitoredTripSource` for the commute provider) | One `BackendSession(client:credentials:push:clock:)` passed both as `LiveBackend.tripMonitor` and as `BackendCommuteProvider`'s `monitoredTrips` | The same, or the team's own implementation. Besides `synchronize`, `refresh`, `refreshTrip`, `markDeparted`, and `unregister(from:)` it implements `withdrawTrips()` (an empty set under the credential it already has; it must never register a device) and may implement `serversLeftBehind()` (other servers it still holds a credential for; the default is none) |
| Device credential (stage S2) | `CredentialStoring` | `KeychainCredentialStore()` | The same, or a store over the team's secure storage. `load`, `save`, `clear`, and `origins()`, which lists every server origin that still has a credential |
| Notification permission and push registration (stage S2) | `PushRegistering` | `SystemPushRegistrar` in the host: the system notification center and the application's remote-notification registration | The same adapter in the team's host, with `apnsEnvironment` matching the team's signed push entitlement |
| Launch options (stage S3) | `BackendLaunchOptions` | Read from the environment and the Info.plist: whether the backend is composed at all, and the default server address | The team's own configuration; the type is optional |
| Network (stage S1) | `HTTPTransport` | `URLSessionTransport` | The same, or a transport over the team's networking stack |
| Reminders | `ReminderScheduling` | `PreviewReminderScheduler()` (in-app previews only) | An adapter over the team's notification service (section 8) |
| Week math | `WeekCalculator` | `WeekCalculator(calendar: .autoupdatingCurrent)` | The same |
| Campus and home samples | `SampleLocation` | `.demoCampus`, `.demoHome` | The campus id and time zone the feature should use (section 9) |
| About text | `PrototypeInfo` | `PrototypeInfo(infoDictionary: Bundle.main.infoDictionary)` | The same; it only fills the Settings "Prototype information" rows |

A team composition root has the same shape as `AppDependencies.makeGraph()`, which returns the
model together with the `BackendSession` the application delegate needs. Build both once per
process and let the scene and the delegate read the same instances (the prototype does this
in `AppComposition.shared`), so that handling a notification never depends on a scene or on
the order in which views are built. Without the backend it reduces to:

```swift
@MainActor
func makeWaitItOutModel() -> WaitItOutModel {
    let clock = SystemWallClock()
    return WaitItOutModel(
        clock: clock,
        preferencesStore: <#adapter over the team's settings storage#>,
        activityRepository: <#adapter over the team's schedule storage#>,
        commuteEstimator: <#provider over the team's travel-time service#>,
        reminderScheduler: <#adapter over the team's notification service#>,
        weekCalculator: WeekCalculator(calendar: .autoupdatingCurrent),
        sampleCampus: .demoCampus,
        prototypeInfo: PrototypeInfo(infoDictionary: Bundle.main.infoDictionary)
    )
}
```

With the backend, add the live graph and pass it as `liveBackend:`; the two prototype
adapters above then serve only the Demo data mode:

```swift
let configuration = BackendConfiguration(defaultBaseURL: <#the backend's address, or nil#>)
let client = BackendClient(configuration: configuration, transport: URLSessionTransport(), clock: clock)
let session = BackendSession(client: client, credentials: KeychainCredentialStore(),
                             push: <#the host's PushRegistering adapter#>, clock: clock)
let live = LiveBackend(
    commuteEstimator: BackendCommuteProvider(client: client, clock: clock, monitoredTrips: session),
    routeProvider: BackendRouteProvider(client: client),
    tripMonitor: session,            // the same session, on purpose
    configuration: configuration
)
```

Each adapter wraps a service the team app already has; it does not copy data into a second
store. There is one repository per kind of data in the running app.

## 6. Commute estimates and routing

### `CommuteEstimating`

```swift
public protocol CommuteEstimating: Sendable {
    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse
}
```

- `CommuteRequest` carries `occurrenceID`, `origin` (the home, a `CommutePlace`),
  `destination` (the resolved campus, a `Destination`), and `arriveBy` (the ideal arrival). The
  activity's start is deliberately absent.
- Return `.estimate(CommuteEstimate(travelTime:sourceLabel:estimatedAt:isSimulated:))` with the
  door-to-door travel time in seconds, a nonempty label naming the source, when the estimate was
  made, and `isSimulated: false` for real data. Return `.unavailable(message:)` when there is
  simply no estimate (no route, outside coverage). Throw for failures (network, service,
  authorization); the UI then offers Try Again.
- Since stage S1 a provider may instead return `.recommendation(DepartureRecommendation)`: a
  complete decision (recommended departure, predicted arrival, reason, confidence, source) that
  the app shows as is and never recomputes; `.notYet(message:askAgainAt:)` when nothing can be
  recommended yet and that changes at a known time; and it may throw
  `CommuteProviderFailure(kind)` so the failure gets its own sentence and, for transient kinds
  with the live backend, an automatic retry. `BackendCommuteProvider` does all three.
- Never add or subtract study, parking, or buffer time: the ideal arrival already contains it.
- The model validates every answer (`DepartureCalculation.make`: finite, above zero, at most
  12 hours, finite timestamp, nonempty label), cancels superseded requests, and drops late
  answers by token, so a provider does not need to defend against those cases. Honor
  cancellation when practical, and return or throw on your own: the model sets no timeout.

A provider sketch, using only package types:

```swift
import WaitItOutUX

struct <#ProviderName#>: CommuteEstimating {
    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        // Ask the team's travel-time service for a trip from request.origin.coordinate to
        // request.destination.coordinate that arrives by request.arriveBy.
        let seconds: TimeInterval? = <#team travel-time lookup#>
        guard let seconds else {
            return .unavailable(message: "<#why there is no estimate#>")
        }
        return .estimate(CommuteEstimate(
            travelTime: seconds,
            sourceLabel: "<#name of the real source#>",
            estimatedAt: Date(),
            isSimulated: false
        ))
    }
}
```

When an estimator other than `TestCommuteProvider` is injected, `usesTestCommute` is false:
Settings hides "Prototype testing", the Map hides the "Demo estimate" label and the simulation
line, and the TEST DATA badges disappear because `isSimulated` is false. The full contract,
result states, and freshness rules are in [`COMMUTE_ESTIMATION.md`](COMMUTE_ESTIMATION.md).

### Routing and the map line

Without a route provider the Map draws a dashed, straight `MapPolyline` between home and campus,
labeled "Schematic line, not a route". Since stage S1 there is a route boundary:

```swift
public protocol RouteProviding: Sendable {
    func route(from origin: GeoCoordinate, to destination: GeoCoordinate) async throws -> RouteGeometry
}
```

Pass an implementation as `LiveBackend.routeProvider` (the package's is `BackendRouteProvider`).
The model asks it for home to campus and publishes `routeState`; only `.route(RouteGeometry)`
is drawn as a solid line labeled "Route via <source>", with the camera fitted to its points
(`MapCameraFit.region(fitting:)`). While a route is loading, when it cannot be loaded, and in
the Demo data mode the dashed line and every schematic label stay, so a straight line is never
presented as a route. The cards and the leave-home rows need no change. Turn-by-turn navigation is out of scope; to hand a trip to the
team's navigation, read `NextTrip.occurrence` and `model.places` and call the team's own
navigation from a new button.

## 7. Activities and settings storage

### `ActivityRepository`

```swift
public protocol ActivityRepository: Sendable {
    var persistenceDescription: String { get }
    func fetchAll() async throws -> [Activity]
    func upsert(_ activities: [Activity]) async throws
    func delete(ids: Set<UUID>) async throws
    func setAsideUnreadableData() async throws -> String?   // default: nil
}
```

- The model validates with `ActivityValidator` before every write and reloads with `fetchAll()`
  after every write. The repository stores what it is given and returns it unchanged.
- An adapter over the team's storage converts at the boundary, in both directions. It is the
  only place that knows both type families; the package never imports team types, and team
  fields are not added to `Activity`.
- Throw from any method to report a failure; the model keeps the last good schedule on screen
  and shows a message. `setAsideUnreadableData()` exists for the JSON store's recovery and can
  keep its default `nil` when the team's storage has no such state.

Field mapping for `Activity` (what the adapter must produce and accept):

| `Activity` field | Type | Mapping notes |
| --- | --- | --- |
| `id` | `UUID` | Stable for the life of the activity. Reminders and leave-home results key on `OccurrenceID` = this id plus the local start day, so a changing id duplicates reminders. If the team's ids are not UUIDs, keep a lookup table in the adapter. |
| `title` | `String` | Nonempty after trimming. |
| `start`, `end` | `Date` | The first occurrence. End after start, at most 24 hours long; overnight is allowed. |
| `idealArrival` | `Date` | At or before `start`, at most 24 hours before it. Already includes study, parking, and buffer time. |
| `destination` | `Destination` (`id`, `name`, `coordinate`) | Use the campus id (`sampleCampus.destinationID`) for campus activities: they then resolve to the campus set in Settings through `resolvedDestination(_:)`. |
| `timeZoneIdentifier` | `String` | The zone whose wall clock the schedule follows; repeats keep the wall-clock start in this zone across daylight-saving changes. |
| `repeatWeekdays` | `Set<Weekday>?` | `nil` for one-time. When present: nonempty and containing the weekday of `start`. Weekly only; no end date and no per-occurrence exceptions. |
| `source` | `ActivitySource` | `.user` for everything from the team app. `.sample` is reserved for the prototype's sample schedule. |

Never map a departure or leave-home time into or out of `Activity`; if the team's model stores
one, leave it untouched in the adapter or derive it from the package's calculation. To check
team records before handing them over, `ActivityValidator.issues(in:)` lists every problem
with its field and message.

### `PreferencesStoring`

```swift
public protocol PreferencesStoring: Sendable {
    var persistenceDescription: String { get }
    func loadPreferences() async throws -> UserPreferences?   // nil: nothing saved yet
    func savePreferences(_ preferences: UserPreferences) async throws
    func setAsideUnreadableData() async throws -> String?     // default: nil
}
```

`UserPreferences` holds `appearance`, `places` (home and campus as `CommutePlaces`),
`leaveHomeRemindersEnabled` (the user's wish), and three prototype test values
(`testCommuteDuration`, `testCommuteScenario`, `simulatesReminderFailure`) that only matter
with `TestCommuteProvider` and `PreviewReminderScheduler`. An adapter can build
`UserPreferences` from the team's own settings plus defaults (`UserPreferences()` has every
default) and save only the fields the team keeps. Places convert with
`CommutePlace(name:coordinate:)`, which throws for an empty name or an unusable coordinate.

### Keeping the prototype's JSON stores instead

If the team keeps the prototype's storage for a while, compose `FileActivityRepository` and
`FilePreferencesStore` with a `PrototypeStorageLocation` (for example
`PrototypeStorageLocation.applicationSupport()` for `Application Support/WaitItOutUX`). The
schema:

```json
{
  "kind" : "activities",
  "payload" : [
    {
      "destination" : {
        "coordinate" : { "latitude" : 38.561, "longitude" : -121.4237 },
        "id" : "demo-campus",
        "name" : "Sample campus"
      },
      "end" : 815334600,
      "id" : "5A170002-0000-4000-8000-0000000000A1",
      "idealArrival" : 815328900,
      "repeatWeekdays" : [ 2, 4, 6 ],
      "source" : "sample",
      "start" : 815331600,
      "timeZoneIdentifier" : "America/Los_Angeles",
      "title" : "Sample morning class"
    }
  ],
  "schemaVersion" : 1
}
```

- One envelope per file: `schemaVersion` (`StorageSchema.currentVersion`, 1), `kind`
  (`"activities"` or `"preferences"`), and `payload`. Keys are sorted and pretty-printed.
- Dates are seconds since 2001-01-01 00:00 UTC (the `JSONEncoder` default), so instants
  round-trip exactly. In the example, the sample morning class loaded in the week of
  1 November 2026 starts at 815331600 (Monday 2 November, 9:00 AM PST), ends at 815334600
  (9:50 AM), and has its ideal arrival at 815328900 (8:15 AM). `Weekday` is stored as its raw
  value, 1 = Sunday through 7 = Saturday; `repeatWeekdays` is a set, so its order in the file
  is not fixed, and it is omitted for one-time activities.
- The preferences payload is `UserPreferences`: `appearance` (`"system"`, `"light"`,
  `"dark"`), `places` (`home` and `campus`, each `name` and `coordinate`),
  `leaveHomeRemindersEnabled`, `testCommuteDuration` (seconds), `testCommuteScenario`
  (`"normal"`, `"slow"`, `"unavailable"`, `"error"`), and `simulatesReminderFailure`. Decoding
  is tolerant per field: a missing or unusable value falls back to its default.
- Never stored: drafts, leave-home times, estimates, loading or refreshing states, reminder
  previews, and delivery status.
- A newer `schemaVersion` or a damaged file is reported and never overwritten; only the
  confirmed "Keep a Copy and Start Over" renames it (`<name>.unreadable-<seconds>.json`). A
  future format bumps `StorageSchema.currentVersion` and converts older payloads in
  `VersionedJSONFile.decode`.

To move existing JSON data into the team's storage, read it once through
`FileActivityRepository.fetchAll()` and `FilePreferencesStore.loadPreferences()` and hand the
values to the team adapters; then stop composing the JSON stores so there is one repository.

## 8. Reminders

```swift
public protocol ReminderScheduling: Sendable {
    var delivery: ReminderDelivery { get }                       // .inAppPreview or .systemNotification
    func pendingReminders() async throws -> [ScheduledReminder]
    func schedule(_ reminders: [ScheduledReminder]) async throws // add or replace by id
    func cancelReminders(withIDs ids: Set<OccurrenceID>) async throws
}
```

The model alone decides which reminders should exist (`ReminderPlan.make`: saved occurrences
of the next 7 days that have not started, current estimates only, due at the leave-home time
and after now, at most 20) and reconciles the adapter against what it reports
(`ReminderChanges.between`), keyed by `OccurrenceID`. `ScheduledReminder.identifier`
(`leave-home.<occurrence id>`) is ready to use as a system notification identifier.

The prototype's `PreviewReminderScheduler` sends nothing and requests no permission; every
preview says "Preview only - no system notification will be sent." A team adapter returns
`.systemNotification`, requests notification authorization at a moment the team chooses (for
example when the user turns reminders on; the package never asks), and throws when
authorization is denied so the UI shows the failure and Try Again. The step-by-step mapping
onto the system notification center is in [`REMINDERS.md`](REMINDERS.md).

### Server-side alerts in Live mode (stage S2)

With a `LiveBackend` that carries a `TripMonitoring` service and the data mode Live, the
`ReminderScheduling` adapter is not used: the server monitors the trips and sends the alerts,
and the same Settings toggle is the wish. The model keeps the service in line with the wanted
trips (`reconcileMonitoring`, sharing every reminder trigger) and publishes `monitoringStatus`,
`monitoredTrips`, `pushDelivery`, `monitorHealth`, `monitoringLimits`, `notificationPermission`,
`monitoringWithdrawal`, `previousServerMayStillAlert`, and `departedStates`; none of it is stored.
A `MonitoredTrip` carries only what the server uses: the occurrence id, the title, the home
and destination coordinates, the ideal arrival, and the time zone. The trips are sent only
while the app is open, for the next 7 days (at most 20), so alerts for later trips need the
app to be opened again (`monitoringCoverageEnd`); a team that needs more has to add a
recurrence rule on the server or a background refresh, neither of which exists here.

What a host does (the prototype host does all of it in `AppDependencies.swift`,
`AppDelegate.swift`, and `SystemPushRegistrar.swift`):

1. Implement `PushRegistering` (`authorizationStatus()`, `requestPermission()`,
   `registerForRemoteNotifications()`, `apnsEnvironment`) over the system APIs. The package
   never names them. Provisional and ephemeral authorizations count as allowed.
   `apnsEnvironment` is exactly `"sandbox"` or `"production"` and follows the signed
   `aps-environment` entitlement, not the build configuration.
2. Create one `BackendSession` and pass it as the trip monitor and as the commute provider's
   monitored-trip source.
3. At launch, set the notification-center delegate and register the category
   `TripNotificationPayload.categoryIdentifier` with one action,
   `TripNotificationPayload.leftActionIdentifier` titled `leftActionTitle`, with the foreground
   option, so "I've left" opens the app and the app tells the server with visible feedback.
4. Forward the device token: `session.updateDeviceToken(_:)` (or `registrationFailed(_:)`); when
   it returns `true`, call `model.pushRegistrationDidChange()`.
5. For a notification response, read it with
   `TripNotificationPayload.response(userInfo:actionIdentifier:openActionIdentifier:)`, passing
   the system's identifier for tapping the notification itself. `nil` means there is nothing
   to do (another sender's notification, or a dismissal). Otherwise
   `await model.prepareForNotificationResponse()`, then
   `await model.handleNotificationAction(tripID:action:arriveBy:)`, and only then the system's
   completion handler. The Calendar presents `model.tripToPresent` itself
   (`model.tripPresentationStep`) and clears it.
6. Show trip notifications that arrive while the app is open (banner, list, and sound).
7. Launch through `model.loadStoredState()`, which `WaitItOutRootView` already does.
8. Declare the Push Notifications capability. No background mode is needed.

The screens (stage S3) show all of this through pure presentation types, so every sentence is
tested: `model.monitoringPresentation(formatter:at:isCompact:trip:)` (a `MonitoringPresentation`:
the delivery sentence, the lines under it, and which of Try Again, Allow Notifications, and
Open Settings are offered) drawn by `MonitoringStatusView` in the Settings reminders section
and on the Map card; `model.backendConnection` (a `BackendConnection`) for the Settings "Data
source" status row; `DataSourceWording` and `PrototypeInfo.stepDescription(usesLiveBackend:)` /
`dataDisclosure(usesLiveBackend:)` for the sentences that differ between the data modes; and
`TripDepartedControl` for "I've Left" in the Calendar details and on the Map card. They act
through `setRemindersEnabled(_:)`, `requestNotificationPermission()`, `retryReminders()` (which
is `retryMonitoring()` in Live mode), `markDeparted(_:arriveBy:)`, `setDataMode(_:)`, and
`applyBackendAddress(_:)`. The rules are in [`REMINDERS.md`](REMINDERS.md) ("With the team
backend: server-side monitoring"), and the states and their wording in
[`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md).

## 9. Sample data and prototype-only content

- **Sample schedule.** `SampleActivities` builds the two labeled samples (fixed ids ending in
  `A1` and `A2`, `source == .sample`, titles beginning "Sample"). They are stored only by the
  explicit Settings action `loadSampleActivities()` and removed only by
  `clearSampleActivities()`, which deletes nothing but `.sample` activities. Nothing seeds them
  on launch, so a team adapter never receives them unless a user taps "Load sample activities".
- **Sample places.** `SampleLocation.demoHome` and `.demoCampus` are labeled coarse demo
  points. Settings shows them with a SAMPLE badge until the user edits them;
  `isSamplePlace(_:)` tells whether a place is still a sample.
- **Campus identity and time zone.** `sampleCampus` supplies the campus destination id
  (`demo-campus`), which campus activities use to resolve to the campus currently set, and
  the campus time zone new activities default to (`campusTimeZone`, `America/Los_Angeles`).
  Pass a `SampleLocation` with the team's campus id and time zone to change both; keep the id
  stable, because stored campus activities refer to it.
- **Preview fixtures.** `PreviewFixtures.swift` exists only for SwiftUI previews; the host never
  uses it and the team app should not either.
- **Prototype-only Settings sections.** "Prototype testing" appears only while the test
  provider is the source in use (the Demo data mode, or a host without a `LiveBackend`), and the
  reminder failure switch only while the reminder adapter is `PreviewReminderScheduler`. "Data
  source" (the data mode, the server address, and the connection status) appears only when the
  host passed a `LiveBackend`. "Sample schedule" and "Prototype information" are
  always shown in `SettingsScreen` today; hiding them in a production build is remaining work
  (section 11).

## 10. Integration checklist

1. Add `Packages/WaitItOutUX` to the team project and link the `WaitItOutUX` product to the
   existing app target; confirm the target's deployment target is iOS 17.0 or newer.
2. Write the adapters (sections 6 to 8) in the team app, converting team models at the
   boundary, and compose one `WaitItOutModel` in the team's composition root.
3. Show `WaitItOutRootView(model:)`, or the three public screens inside the team's tab bar with
   the launch and activation calls from section 3 and the tab-selection binding.
4. Run the package tests (`WaitItOutUXTests`) in the team scheme; adapter tests can reuse the
   doubles in `Tests/WaitItOutUXTests/Support/` (for example `RecordingReminderScheduler`,
   `InMemoryFileAccess`, `ManualWallClock`) as patterns.
5. Walk the README's "Manual demo checklist" against the team build, with the team adapters in
   place of the labeled test provider and preview adapter.

## 11. Remaining integration work

What is done, and what is still open:

- **Travel estimates and routes from the backend**: done in the package (stage S1) and
  composed by the prototype host (stage S3). Open: a run against a deployed backend. So far
  the app has only talked to scripted transports and a stand-in server on the same machine.
- **Notification authorization and delivery**: the package side (stage S2), the monitoring
  screens, and the host's `PushRegistering` adapter and application delegate (stage S3) are
  done. Open: everything that needs Apple's push service, which is a signed build with an
  Apple Developer Program team, a server with push credentials, and a device. No device token
  was obtained and no notification was received or tapped in any run; the steps are in
  [`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md) ("Push setup"). A team that prefers local
  notifications instead writes a `ReminderScheduling` adapter.
- **A distribution build**: the entitlements file says `aps-environment` = `development` and the
  host reports the sandbox push environment for every configuration. A TestFlight or App Store
  build needs both changed together.
- **Mapping to the team's storage and models**: `ActivityRepository` and `PreferencesStoring`
  adapters over the team's storage, the id mapping, and any migration of prototype JSON data.
- **Navigation and Settings fit**: binding the team's tab selection to `model.selectedTab`,
  deciding where the feature's settings live, and hiding the "Sample schedule" and "Prototype
  information" sections in production builds.
- **One campus**: every activity goes to the single campus in Settings; several campuses or
  free destinations need a destination picker and model changes.
- **Localization**: user-facing strings are English literals in the package.
- **Verification on Apple platforms**: the build and the unit and UI tests now run on a Mac
  (README, "Validation status"; 8 of the 21 original UI tests fail on that setup for reasons
  that predate the backend work). Still not done: previews, VoiceOver, and large-text checks
  of the new screens, and any run on a physical device.
