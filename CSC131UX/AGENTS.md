# Working conventions for the WAIT IT OUT UX prototype

Read this before extending the app. Steps 0001 to 0008 built the standalone prototype; stages
S1 to S3 connected it to the team backend, which is now the normal flow, with the prototype's
simulation kept as the explicit Demo data mode.
The leave-home formula and the commute provider contract are in `docs/COMMUTE_ESTIMATION.md`;
the reminder boundary and server-side monitoring are in `docs/REMINDERS.md`; what the app asks
the backend, what it sends, how it is configured, and what has and has not been verified are
in `docs/BACKEND_INTEGRATION.md`.

## Layout rules
- Reusable code goes in `Packages/WaitItOutUX/Sources/WaitItOutUX/`; tests in
  `Packages/WaitItOutUX/Tests/WaitItOutUXTests/`. Membership is by folder.
- The host (`WaitItOutUXPrototype/`) stays thin: the entry point, `AppDependencies` (with
  `AppComposition`), `AppDelegate`, `SystemPushRegistrar`, the partial `Info.plist`, and the
  entitlements file. New services are composed in `AppDependencies` and injected into
  `WaitItOutModel`; decisions belong in the package, where they are tested (see "Host rules").
- Any new host or UI-test Swift file must be added to `project.pbxproj`; run
  `python3 scripts/check_project_structure.py` afterwards (0 errors required).
- Do not create a second app target, a second project, or a second shared state object.

## Code rules
- No force unwraps, `fatalError`, TODO/FIXME markers, or inert placeholder controls.
- Keep date math pure (`WeekCalculator` style) and read time only through `WallClock`.
- Declare every view that reads `WaitItOutModel` `@MainActor` (the iOS 17 SDK isolates only
  `body`, so helpers and bindings would otherwise touch the main-actor model from a
  nonisolated context). The app struct, root view, and the three tab screens already do.
- UI mutations happen on the main actor; storage work runs through async protocol methods.
- Label every simulated value (DemoBadge or explicit text). Never imply live traffic or
  real notification delivery for a simulated value. A backend recommendation names its source
  exactly as the backend reported it (`RecommendationSource.label`); live traffic is claimed
  only when the backend said it had it (see "Backend integration rules").
- Preview fixtures live in `PreviewFixtures.swift` and are never used by the host.
- The structural checker counts braces and parentheses per Swift file, including inside
  strings and comments. Avoid interval notation such as a bracket paired with a parenthesis
  in Swift sources; write "half-open" instead.

## Activity domain rules (from step 0002)
- `Activity` never stores a departure or leave-home time. Step 0005 derives it from
  `idealArrival` and a commute estimate and shows it read-only.
- Validate through `ActivityValidator` (all issues at once, each with a field and message)
  before any write; `WaitItOutModel.saveActivity` already does. Repositories stay dumb.
- Repeating activities must include the weekday of `start`; the stored start is the first
  occurrence. There is no end date and no per-occurrence exception.
- Expand occurrences only through `OccurrenceExpander` and resolve wall times only through
  `LocalTimeResolver`; do not add 86 400-second multiples or call `Calendar.date(from:)`
  for recurring times. The DST policy (repeated time: first occurrence; skipped time: first
  instant after the gap) is documented in `LocalTime.swift` and the README.
- `OccurrenceID` (activity id plus local start day) is the identity later steps key on for
  details, reminders, and previews. Do not invent a second occurrence identity.
- Occurrence inclusion covers ideal arrival through end. Calendar code that wants only the
  activity block should use `activityInterval` or `activityIntersects(_:)`.
- Sample activities are `SampleActivities` only: fixed ids, `source == .sample`, titles that
  say "Sample", loaded and cleared solely by the explicit Settings actions. Never seed them
  on launch.
- New activities default to `WaitItOutModel.campusTimeZone` and `campusDestination` (the campus
  id with the campus set in Settings; step 0006); keep `timeZoneIdentifier` on every activity.

## Calendar rules (from step 0003)
- Compute every on-grid position through `DayTimelineLayout` (offsets, hour rows, clipping),
  `OverlapLayout` (columns), and `DaySchedule.make` (blocks and arrival markers). Views only
  place what those return. Drag creation and resizing in 0004 should convert gestures with
  `DayTimelineLayout.date(atOffset:)` and snap in the domain, not in the view.
- Blocks cover start to end only. Ideal arrival stays a separate marker; the calculated
  departure of 0005 should be another read-only marker or detail line, never a block resize.
- The selected day (`WaitItOutModel.selectedDay`, `selectDay(_:)`, `selectDay(at:)`) and the
  grid scroll row (`calendarScrollHour`) live in the model so they survive tab switches. Do not
  add a second selection or scroll state in a view.
- Read the current time through `WaitItOutModel.currentDate()`; the Calendar's refresh task
  already ticks once a minute while the current week is on screen. Do not add timers elsewhere
  (step 0005 added the Map's equivalent tick for the next-trip card; see below).
- Keep identifiers: day cells `calendar.day.<0-6>`, blocks `calendar.occurrenceBlock`, markers
  `calendar.arrivalMarker`, grid `calendar.timeGrid`, detail sheet `calendar.detailSheet` and
  `calendar.detailDone`. UI tests select Monday and Tuesday by index because "today" varies.
- Keep the detail sheet free of inert controls; 0004 adds Edit and Delete there when they work.
- In the seven-column layout the hour gutter follows `DayTimelineLayout.sharedGutter(for:)` (the
  first 24-hour day), and a column whose rows differ from it (`rowsDiffer(from:)`, the 23- or
  25-hour transition day) labels its own rows inside the column (`DayColumnView.labelsOwnHours`,
  40-point margin). The selected-day layout keeps labeling the selected day's own rows in the
  gutter. Do not relabel rows by wall-clock hour; positions stay proportional to elapsed time.

## Editing rules (from step 0004)
- All edits go through `WaitItOutModel.editSession`, which holds at most one pending
  `ActivityDraft`. Start one with `beginNewActivity()`, `beginNewActivity(spanning:)`,
  `beginEditing(activityID:)`, or `beginAdjusting(activityID:)`; change it with `updateDraft`
  or `replaceDraft`; finish with `saveDraft()` (validates through `ActivityValidator`, then
  at most one repository write; none for an unchanged edit), `cancelDraft()`, or
  `deleteDraftActivity()`. Gesture code computes each update from the occurrence snapshot
  taken when the drag began (`GridDrag.draft`), so updates never accumulate. Do not write
  to the repository from a view or keep a second draft.
- The Calendar draws `calendarActivities` and `visibleWeekOccurrences`, which preview the
  pending draft; Map and Settings read the stored `activities` only.
- Convert gestures only through `GridDrag` (15-minute snap, 10-point `minimumDistance`, day
  and length clamps) and `ActivityDraft.movingOccurrence` / `resizingOccurrence`; never snap
  or clamp in a view. Moves and start resizes keep the arrival lead; an end resize leaves
  the arrival alone. Gestures never change the day.
- The time grid does not scroll while a creation, move, or resize gesture is in progress:
  `DayColumnView` reports each of its gestures through `onGestureActivity` and `TimeGridView`
  applies `.scrollDisabled` (2026-11-02 re-run of step 0004). A new grid gesture must report
  through the same callback.
- Edits and deletes of a repeating activity apply to the whole series ("Edit Series",
  "Delete Series", confirmation dialog). Do not add or simulate single-occurrence exceptions.
- Step 0005 shows the calculated departure as a read-only line in the editor's arrival
  section and in the detail sheet, never as a draft field or editor input.
- New editor fields keep the order: start and end first, ideal arrival second.
- Keep the step 0004 identifiers the UI tests use: `calendar.addActivity`,
  `calendar.emptyAddActivity`, `calendar.openSettings`, `calendar.detailEdit`,
  `calendar.detailDelete`, `calendar.draftBar`, `calendar.draftSummary`, `calendar.draftCancel`,
  `calendar.draftEdit`, `calendar.draftSave`, `calendar.resizeStartHandle`,
  `calendar.resizeEndHandle`, `calendar.notice`, `editor.sheet`, `editor.title`,
  `editor.destination`, `editor.start`, `editor.end`, `editor.duration`, `editor.endNote`,
  `editor.arrival`, `editor.lead`, `editor.arrivalNote`, `editor.repeatToggle`,
  `editor.repeatDay.<0-6>`, `editor.issue`, `editor.failure`, `editor.seriesNote`,
  `editor.cancel`, `editor.save`, and `editor.delete`. `ActivityEditingUITests` repeats these
  strings and the labels "Add Activity", "Edit Series", "Delete Series", and "Enter a title.".

## Commute and departure rules (from step 0005)
- Leave home is `DepartureCalculator`: ideal arrival minus the validated travel time, in elapsed
  seconds. Never subtract study, parking, or buffer time, never use the activity's start, never
  store a departure on `Activity`, and never make it an input. It is shown read-only through
  `DepartureRows` (detail sheet, editor arrival section, Map next-trip card).
- Commute estimates go only through the injected `CommuteEstimating` providers (host:
  `BackendCommuteProvider` for the Live data mode and `TestCommuteProvider` for the Demo data mode, both
  composed in `AppDependencies`). Validate every provider value through
  `DepartureCalculation.make` / `CommuteDuration`; do not trust raw `travelTime`.
- `WaitItOutModel.departures` (saved occurrences in `DepartureHorizon`, 7 days) and
  `draftDeparture` (the editor's preview) are the only departure state. Change them only through
  `refreshDepartures()`, `retryDepartures()`, and `syncDraftDeparture()`; every answer is applied
  only while its entry's token is current. Any new path that changes or ends the draft must call
  `syncDraftDeparture()`, and any new activity reload already refreshes departures.
- When a leave-home time has passed, show the missed-target warning (`DepartureTiming`); never
  replace the time with "now".
- The Settings test duration lives in `UserPreferences.testCommuteDuration` and changes only
  through `setTestCommuteDuration` / `applyTestCommuteMinutes`. Step 0006 replaced the old
  `behavior` setting of `TestCommuteProvider.Configuration` with `scenario`
  (`TestCommuteProvider.Scenario`: Normal, Slow, Unavailable, Error; see the step 0006 rules),
  and every provider settings change goes through `commuteSettingsDidChange()` so results
  recalculate. Step 0006 added the home `origin` to `CommuteRequest`; `arriveBy` stays the
  ideal arrival.
- The Map tab has its own minute tick (`MapScreen.runClock`), like the Calendar's; both call
  `refreshDepartures()`. Since the review fixes the Settings tab has the same tick, only in a
  host with a live backend (`SettingsScreen.runClock`), so that what it says about the server
  stays current and "tried again automatically" is true there too. Do not add other timers.
- Keep the step 0005 identifiers: `map.nextTrip`, `map.nextTripTitle`,
  `map.nextTripAddActivity`, `map.nextTripOpenCalendar`, `settings.testCommuteField`,
  `settings.testCommuteStepper`, `settings.testCommuteIssue`, and the departure rows
  `<prefix>.leaveHome|status|message|source|retry` under `calendar.detailDeparture`,
  `editor.departure`, and `map.nextTripDeparture`. `DepartureUITests` repeats them.

## Map, places, and scenario rules (from step 0006)
- Home and campus are `CommutePlace` values (valid by construction) in `UserPreferences.places`.
  Parse typed text only through `PlaceInput` (strict decimal degrees) and change places only
  through the model's `applyPlaceInput(_:for:)`, `setPlace(_:for:)`, and `resetPlacesToSample()`,
  which persist the preferences and recalculate. No location permission, geocoding, or network lookup.
- Campus activities (destination id `sampleCampus.destinationID`, `demo-campus`) resolve
  through `resolvedDestination(_:)` when a request is made and when a screen shows them. Never
  rewrite stored destinations when the campus changes; the stored copy is a snapshot.
- Every `CommuteRequest` carries `origin` (the home). Build requests through the model's
  `commuteRequest(for:)` helpers so the origin and the resolved destination are always set.
- Scenarios exist only as `TestCommuteProvider.Scenario`, stored in
  `UserPreferences.testCommuteScenario` and changed only through `setTestCommuteScenario(_:)`
  and `resetPrototypeTesting()`. Never branch on the scenario in a view; views only label it
  (Demo estimate label, simulation line, Prototype information). Behavior comes from the
  provider's answers.
- Try Again is offered only for failures (`DepartureState.isRetryable`: `.error`, and since
  stage S1 a kept out-of-date recommendation, `.stale`); `.unavailable` explains itself without
  a retry.
- Re-asking the same trip (scenario or duration change, stale estimate) shows
  `.refreshing(earlier)`, marked out of date in every view and never presented as current; a
  changed trip starts from `.loading`. Handle `.refreshing` (and `.stale`, stage S1) in every
  new switch over `DepartureState`.
- Judge estimate age only through `EstimateFreshness` (`lifetime` 10 minutes, `needsRefresh`);
  the existing minute ticks drive refreshes. Do not add timers.
- Compute the Map camera only through `MapCameraFit.region(fitting:)` (padding 1.6x, minimum
  span 0.02 degrees, antimeridian-aware, pole-clamped); views only convert the returned region.
- Keep the schematic labels ("Schematic line, not a route" on the map, "schematic connection,
  not a driving route" in the places card), the "Demo estimate" label, and the TEST DATA and
  SAMPLE badges. Real route geometry may replace the `MapPolyline` input only when a provider
  supplies it (see `docs/COMMUTE_ESTIMATION.md`). Keep the trip summary in plain SwiftUI cards
  in the bottom inset so it survives missing tiles.
- Settings section order is Appearance, Sample schedule, Prototype information, Home and
  campus, then Prototype testing last, because the launch UI tests read the top sections
  without scrolling. Add new sections below the existing ones.
- Keep the step 0006 identifiers: `map.demoEstimateLabel`, `map.placesCard`,
  `map.place.home|campus`, `map.schematicNote`, `map.nextTripSimulation`, `map.openSettings`,
  `map.demoStatus`, `map.recenterButton`, `settings.place.home|campus`, `settings.resetPlaces`,
  `settings.testScenario.<normal|slow|unavailable|error>`, `settings.testScenarioDescription`,
  `settings.resetTesting`, and `placeEditor.sheet|name|latitude|longitude|issue|useSample|cancel|save`.
  `MapScenarioUITests` repeats them.
- Step 0007 persists `UserPreferences` as a whole (appearance, test duration, scenario, places,
  and the reminder fields) through `PreferencesStoring`; its tolerant decoding falls back per
  field and per place. Never persist a departure result, and in particular never store
  `.loading` or `.refreshing` as a result; recalculate after launch.

## Persistence and reminder rules (from step 0007)
- The host composes `FileActivityRepository` and `FilePreferencesStore` on
  `PrototypeStorageLocation.applicationSupport(folderName:)`; previews and unit tests keep the
  in-memory stores. All file work goes through the injected `FileAccessing` inside the stores'
  actors; never touch files from a view or the main actor.
- Stored files are `VersionedJSONFile` envelopes (`schemaVersion`, `kind`, `payload`). A new
  stored field either decodes tolerantly or bumps `StorageSchema.currentVersion` with a
  conversion in `VersionedJSONFile.decode`. Store only committed activities and preferences:
  never drafts, departures, estimates, reminder previews, or delivery status.
- Writes are atomic and update the in-memory copy only after success. While a file is
  unreadable the store refuses writes (`unreadableDataProtected`); only the explicit, confirmed
  `setAsideUnreadableStorage()` (Keep a Copy and Start Over) renames it, never deletes it.
  Surface problems through `activityStorageIssue` / `preferencesStorageIssue` and the existing
  `activitiesStatus` / `preferencesStatus` messages.
- UI tests set `WAIT_IT_OUT_STORAGE_FOLDER` (`PrototypeStorageLocation.folderEnvironmentKey`) to a
  fresh name in setUp; every new UI test file must do the same, and must choose its composition
  with `WAIT_IT_OUT_DATA_MODE` (see "Host rules").
- Local reminders go only through the injected `ReminderScheduling` adapter (host:
  `PreviewReminderScheduler`); this is the Demo data mode and every host without a live backend.
  With the live backend in use the server sends the alerts and this adapter is not used at all
  (see "Trip monitoring rules"). The model alone decides what should exist: `ReminderPlan.make`
  (saved occurrences in `DepartureHorizon` that have not started, `.success` only, due at the
  leave-home time and after now, at most `ReminderPlan.maximumCount`), then
  `ReminderChanges.between` against what the adapter reports. Key reminders by `OccurrenceID`
  only. Every path that changes departures already calls `reconcileReminders()`; new triggers
  call it too (force for user actions, launch, and foreground). Do not add timers.
- The wish (`UserPreferences.leaveHomeRemindersEnabled`) and the delivery state (`reminderSync`,
  `reminderPreviews`) stay separate; never store delivery state. Show every reminder with
  `ReminderPreviewView`, which always prints `reminderDelivery.disclosure` ("Preview only - no
  system notification will be sent."). Never word a preview as a notification, never request
  notification permission for a preview (the Demo data mode asks for none; in Live mode it is
  requested only through `TripMonitoring`, see "Trip monitoring rules"), and handle every
  `ReminderPreview` and `ReminderGap` case.
- The failure simulation exists only in `PreviewReminderScheduler` and is changed only through
  `setSimulatesReminderFailure(_:)` and `resetPrototypeTesting()`; views only label it.
- Settings section order is now Appearance, Sample schedule, Prototype information, Home and
  campus, Leave-home reminders, Saved data, Data source (stage S3, only when the host passed a
  `LiveBackend`), then Prototype testing last (only in the Demo data mode).
- Keep the step 0007 identifiers: `settings.remindersToggle`, `settings.reminderFailureToggle`,
  the reminder parts `<prefix>.time|title|message|disclosure|status|retry` under `reminders`
  (Settings) and `map.reminder` (Map card), `settings.storageIssue`, `settings.storageRetry`,
  `settings.storageStartOver`, `settings.storageMessage`, and `settings.storageLocation`.
  `PersistenceReminderUITests` repeats them.

## Handoff rules (from step 0008)
- `docs/TEAM_INTEGRATION.md` is the team handoff. Keep it in step with the real public API:
  `WaitItOutRootView(model:)`, the public `MapScreen`, `CalendarScreen`, and `SettingsScreen`
  (`init(model:)`), `WaitItOutModel.init`, and the boundary protocols. It names package types
  only, never a team API or a backend endpoint; the endpoints the backend adapter calls are
  listed in one place, `docs/BACKEND_INTEGRATION.md`.
- `scripts/check_project_structure.py` also enforces the product contract (tab order, no
  departure property, no location or calendar permission APIs, network and notification APIs
  only in their allow-listed files, no Calculate control, no privacy strings, Swift-only
  sources, the storage folder and the data mode for every application a UI test creates,
  hygiene in package tests). Keep 0 errors. The allow-lists are exact repo-relative files, and
  the checker fails when an allow-listed file is missing or when any other host or package
  source names the API (comments are ignored; "//" inside a string literal is not a comment):
  - the system networking session and the types named after it (its configuration, its
    tasks): only `Packages/WaitItOutUX/Sources/WaitItOutUX/Backend/URLSessionTransport.swift`
    (stage S1);
  - the system notification center, its framework import, and the authorization request: only
    `WaitItOutUXPrototype/AppDelegate.swift` and `WaitItOutUXPrototype/SystemPushRegistrar.swift`
    (stage S3);
  - the application singleton, and in the host any call that registers with the push
    service: only `WaitItOutUXPrototype/SystemPushRegistrar.swift`;
  - loading the contents of a URL (`Data(contentsOf:)` and its relatives): only
    `Packages/WaitItOutUX/Sources/WaitItOutUX/Persistence/FileAccessing.swift`, for files;
  - the other ways onto the network (the Network framework, web views, `AsyncImage`, raw
    streams and sockets): nowhere.
  The package's unit tests may not name the networking session at all, and among the UI tests
  only `WaitItOutUXPrototypeUITests/LiveModeUITests.swift` may (its probe of the opt-in fixture
  server on this machine). Do not widen the allow-lists: new network code goes through
  `HTTPTransport` and `BackendClient`, and new notification code through `PushRegistering` and
  the model.
- The checker also reads the host's `Info.plist` and entitlements (stage S3): no
  `*UsageDescription` key, no `UIBackgroundModes`, `NSAppTransportSecurity` with nothing but
  `NSAllowsLocalNetworking`, a default server address that is https or on this machine, no
  entitlement other than `aps-environment`, and `SystemPushRegistrar.apnsEnvironment` agreeing
  with that entitlement. Every build configuration of the app target has to name both files.
  No `DEVELOPMENT_TEAM` and no provisioning profile may be written into the project. A
  simulator build needs no team. A device build takes its team from Xcode or an `xcodebuild`
  argument, and because of the push entitlement that has to be a team whose App ID has the
  Push Notifications capability (an Apple Developer Program team; a free personal team cannot
  sign this project for a device).
- `EndToEndDemoTests` walks the demo path; extend it rather than adding a parallel flow test.
  `DemoAccessibilityUITests` (pbxproj ids ...1C file ref / ...29 build file) runs at an
  accessibility text size.
- The README's "Manual demo checklist" and "Where each demo requirement is covered" table
  must stay accurate when behavior changes.
- A simulated time keeps its label in every state that shows it, including `.refreshing`
  (TEST DATA badge on screen, "Simulated test data, not live traffic" when spoken).
- A sheet root that carries an identifier the UI tests wait for (`editor.sheet`,
  `calendar.detailSheet`, `placeEditor.sheet`) is `.accessibilityElement(children: .contain)`
  first, so the identifier never replaces its controls' own (2026-11-02 re-run of step 0008).
- UI tests replace a field's text after tapping its trailing edge
  (`coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))`), never its center: the
  minutes and coordinate fields are right-aligned.

## Backend integration rules (from stage S1)
- The host may pass a `LiveBackend` to `WaitItOutModel.init`. Without one the model behaves
  exactly as the standalone prototype (previews, unit tests, and the host's
  `WAIT_IT_OUT_DATA_MODE=demo` composition do this; the host's normal composition passes one).
  With one, `UserPreferences.dataMode` chooses the source: `.live` (default) is the team backend,
  `.demo` is the explicit, labeled demo on `TestCommuteProvider`. Read the choice only through
  `hasLiveBackend` / `usesLiveBackend`; `usesTestCommute` is false while live.
- Every request starts from `activeCommuteEstimator`, so live mode never calls the demo provider
  and demo mode never calls the backend. A failed live request is never replaced by a simulated
  value. Change the source only through `setDataMode(_:)` and `applyBackendAddress(_:)`; both end
  in `dataSourceDidChange()`, which cancels every request and clears every result first, so a
  different source starts from `.loading`, never `.refreshing`.
- The backend decides the departure. A `.recommendation` answer goes through
  `DepartureCalculation.make(idealArrival:recommendation:)`, which copies the recommended
  departure and never calls `DepartureCalculator`. Never compute arrival minus travel time, add a
  buffer, or replace the time with "now" for a backend answer, and never show the local "may miss"
  warning for one: the backend's `lateBy` is the only lateness statement.
- Handle every `DepartureState` case in new switches, including `.stale(calculation, failure)`:
  the last recommendation kept after a failed refresh. It is never `calculation`, is always shown
  "out of date" with Try Again, and earns no reminder. `.unavailable(.notYetPlannable)` is not a
  failure and has no Try Again; the model asks again when its `askAgainAt` passes.
- Automatic retries exist only with the live backend and only for transient failures
  (`CommuteProviderFailure.Kind.isTransient`), on the existing minute ticks with the
  `DepartureRetry` backoff (1, 2, then 5 minutes). Do not add timers. The demo provider's errors
  still wait for Try Again.
- Judge the age of a recommendation only through `EstimateFreshness` (`lifetime(for:at:)`,
  `needsRefresh(_:at:askedAt:)`): 30 minutes when the departure is more than 3 hours away;
  otherwise `nearLifetime`, one backend slot of 15 minutes less half a tick, counted from when
  the model asked (`DepartureEntry.attemptedAt`), so consecutive asks land one slot apart on
  the backend's grid and the time moves only when traffic does; a fixed 5 minutes for "leave
  now"; a hand-over 60 seconds after a planned time passed; and not at all for a monitored
  plan while its departure is ahead. Do not shorten `nearLifetime` or measure it from the
  answer's arrival: either brings back a leave-home time that flaps by up to 15 minutes. A
  demo estimate keeps `lifetime`, 10 minutes.
- The editor's preview goes through `draftCommuteRequest(for:at:)`: with the live backend a
  repeating draft whose first occurrence has passed asks about its next upcoming occurrence
  (`draftPreviewOccurrence`, shown with `DepartureWording.nextOccurrenceNote`, identifier
  `editor.departure.occurrence`), and a request caused by a draft change waits
  `liveDraftDebounce` (0.6 seconds). The demo preview asks about the first occurrence at once;
  tests pin both.
- The backend's `reason` sentence is relative to when it was written. Show it only through
  `OccurrenceFormatter.recommendationReasonText(for:at:)` (two minutes, then the absolute margin).
- Sentences that depend on the data mode live in pure helpers so both wordings are tested:
  `DepartureWording` (detail footer, editor arrival footer, Try Again hint) and `MapRouteText`
  (route label, places note, status). The demo wording is pinned byte for byte; do not edit it.
- Wire spellings never leave `Backend/`: `BackendWire.swift` holds the JSON shapes and
  `BackendCommuteProvider` / `BackendRouteProvider` map actions, confidence, and sources
  explicitly. An unknown action is `.invalidResponse`; an unknown source is "unknown", not a
  failure. Errors are told apart by the body's `error` code before the status. Never log bodies,
  coordinates, or credentials.
- The Map draws a solid route only for `RouteState.route`; every other state keeps the dashed
  line and all its schematic labels. Change the route only through `refreshRoute()` and the
  helpers in `Map/WaitItOutModel+Route.swift` (token-guarded like departures).
- `UserPreferences.dataMode` is encoded only when it is `.demo` and `backendAddress` only when
  set, so the default settings file keeps exactly its keys (`PersistenceStoreTests` pins them).
- Trip synchronization, notification permission, and push registration follow the "Trip
  monitoring rules (from stage S2)" below; the monitoring screens follow "Live-mode screen rules
  (from stage S3)" and the host follows "Host rules (from stage S3)".
- Keep the new departure identifiers `<prefix>.reason|confidence|notes` next to the step 0005 ones,
  and `editor.departure.occurrence` for the editor's next-occurrence note.
- Backend tests use `Support/TestBackend.swift` (scripted `HTTPTransport`, bodies shaped like the
  real backend's). No test may open a connection.

## Trip monitoring rules (from stage S2)
- With the live backend in use and leave-home reminders on, the server monitors the trips and
  sends the alerts. The app schedules no local reminder in Live mode: `reconcileReminders()`
  first calls `reconcileMonitoring()` and then leaves the `ReminderScheduling` adapter alone,
  except to empty it once after the Demo data mode. In the Demo data mode the adapter works
  exactly as before and the trips are withdrawn from the server. Never run both at once.
- The model alone decides which trips the server monitors: `WaitItOutModel.monitoredTrips(for:
  home:resolve:now:limit:)` (pure: saved occurrences inside `DepartureHorizon` whose ideal arrival
  is ahead and whose resolved destination is usable, built like `commuteRequest(for:)`, ordered by
  arrival, at most 20 or the server's own limit). Key trips by `OccurrenceID` only.
  `MonitoredTrip` values are valid by construction (trimmed, 120 Unicode scalars, never an empty
  title) and carry only what the server uses: the id, the title, the two coordinates, the
  ideal arrival, and the time zone. Do not send anything else about an activity (the start
  time and the destination's name stay on the device), and keep `MonitoringText.dataSentFooter`
  listing exactly what is sent. Every path that changes departures already reconciles; new
  triggers call `reconcileReminders()` too (force for user actions, launch, and foreground). Do
  not add timers.
- The trips are sent only while the app is open, for the next 7 days and at most 20, so alerts
  stop for later trips until the app is opened again. That limit is disclosed in the reminders
  footer (`MonitoringText.coverageSentence`) and in Settings (`monitoringCoverageEnd`,
  `OccurrenceFormatter.monitoringCoverageText`). Do not add background execution to hide it,
  and do not remove the disclosure while the limit exists.
- Nothing is sent before the schedule has been read once, and while it cannot be read the
  status is `.paused` and the server is left untouched. `monitoringStatus` is `.pending` while a set
  is unacknowledged and `.active` only after the server acknowledged exactly the trips wanted
  now; never claim monitoring earlier. Withdrawals (reminders off, Demo mode, a changed server
  address) are real work: `monitoringWithdrawal` and `previousServerMayStillAlert` say when the
  server could not be told. Transient failures are retried on the minute ticks after 60 seconds
  and on every forced call; a server without monitoring (`.unavailableOnServer`) only on a
  forced call (launch, foreground, a toggle) or Try Again; a refused set waits for
  `retryMonitoring()` or a change.
- While saved settings cannot be read (`preferencesStorageIssue`) and the user has not chosen
  the toggle, the data mode, or the address anew in this session, the settings in effect are
  defaults. Monitoring is then paused as `.settingsUnreadable`: nothing is withdrawn,
  synchronized, or released on a default's word.
- The server's two 503 codes are different things (`BackendSession.failure(for:)`):
  `temporarily_unavailable` is transient and always maps to `.server(status:)`;
  `monitoring_unavailable` means the tables are not set up and maps to `.unavailableOnServer`.
  Neither is ever read as "removed".
- A credential is dropped only when the server confirmed the removal (204), no longer knows
  the device (401), or predates the device endpoints (a 404 without the API's `not_found`).
  After any other answer `unregister` throws and keeps it. The fallback is
  `TripMonitoring.withdrawTrips()`, an empty snapshot under the existing credential that never
  registers a device and reports no push token; never use `synchronize([])` to withdraw.
- Servers left behind by an address change are remembered by the credential that is still
  stored for them (`CredentialStoring.origins()`, `TripMonitoring.serversLeftBehind()`), so
  they are found again after a restart; `MonitoringTracking.abandonedServers` is only this
  session's working copy.
- One snapshot, owned by the model. `BackendSession` answers `MonitoredTripSource.answer(for:)` only
  from the last snapshot it returned, only for a plan the server still keeps current, only for
  a trip whose sent trip matches the request exactly, and only while the snapshot is younger
  than `MonitoringSnapshot.lifetime`; it never refreshes by itself. "Current" is the one rule
  `MonitoredTripState.currentPlan(monitorEnabled:at:)`, which the session and the model's
  snapshot comparison both use: the `.monitoring` phase, `monitor.enabled`, not stale, a
  departure still ahead, and no time-to-leave or late alert sent or queued. Change that rule
  in that one place only; a plan that fails it must be handed back to a direct request, never
  shown as the current recommendation. The model refreshes on the minute ticks
  (`monitoringRefreshInterval`) while a trip is planned or monitored, applies every snapshot
  through `applyMonitoringSnapshot(_:)`, and re-asks only the departures whose monitored plan
  changed (`invalidateDepartures(for:)`). Handle `TripMonitoringFailure.reregistered` by
  synchronizing again.
- Snapshot revisions (`BackendSession`): a revision is reused only to resend exactly the body last
  sent under it; any other body gets `max(local, server) + 1`, stored before it is sent. A
  snapshot is acknowledged only when the answer carries the sent revision and exactly the sent
  ids and arrival times. Requests run one after the other in the session's own tasks.
- Credentials are per server origin and live only in the injected `CredentialStoring` (host:
  `KeychainCredentialStore`). Never write the bearer credential to preferences, files, or logs,
  never send it to another origin (requests are pinned to the address their operation started
  with), and never register a device just to read, end, or remove something.
- Delivery wording is honest and lives in pure helpers (`MonitoringObstacle`, `MonitoringText`,
  `OccurrenceFormatter+Monitoring.swift`): alerts are described as active only when
  `monitoringObstacle` is `nil`; otherwise the exact obstacle is named. An alert is "sent" only with
  the server's own stamp, never "delivered"; the server "will try". "I've left" success is
  claimed only after the server answered (`DepartedState`), is sent for the arrival time the
  notification carried so an old notification cannot end a rescheduled trip, and lasts only
  while the server itself reports the trip as left (`pruneDepartedStates`).
- A trip the server reports a problem with (`MonitoringSummary.hasServerProblem`: a
  `lastErrorCode`, or no plan with a `noPlanReason`) is never described as alerted: its line
  comes from `MonitoringText.evaluationFailureSentence(code:)` or the no-plan wording, and the
  sentence above it is "alerts are not active", not "will try to alert". The server's own
  no-plan sentence is repeated only for `DepartureRecommendation.reasonLifetime` after the app
  saw it appear.
- The monitoring lines print a clock time of the server's plan only while the screens take
  their leave-home time from that plan (`MonitoringSummary.showsPlanTimes`); before that they
  are worded relative to "the recommended departure". Never promise a coming alert for a
  departure that has passed, after a late alert, or from a state that could not be read
  again (`isOutOfDate`).
- The package never names the system notification APIs or the application's push
  registration: permission and registration go through `TripMonitoring` and the host's
  `PushRegistering` adapter; the payload's spelling stays in `Backend/TripNotificationPayload.swift`.
  The one application API the package names is `UIApplication.openSettingsURLString`, in
  `Screens/Monitoring/MonitoringStatusView.swift`, for the "Open Settings" button (opened
  through SwiftUI's `openURL`). The host forwards the device token to
  `BackendSession.updateDeviceToken(_:)` and calls `pushRegistrationDidChange()` when it changed.
- A notification is handled with `prepareForNotificationResponse()` (joins the single launch
  load, `loadStoredState()`) and then `handleNotificationAction(tripID:action:arriveBy:)`;
  `openTrip(_:)` sets `tripToPresent` for the Calendar. Never persist monitoring state.
- Monitoring tests use `Support/TestMonitoring.swift` (`RecordingTripMonitor`, `FakePushRegistrar`,
  `HeldTransport`, and `FakeTripServer`, an in-memory stand-in for the backend's device and trip
  endpoints) and `InMemoryCredentialStore`. No test may open a connection or touch the user's
  Keychain items.

## Live-mode screen rules (from stage S3)
- A screen shows a monitoring or data-source state only through the pure presentation types,
  so every sentence is tested: `MonitoringPresentation.make` (through
  `model.monitoringPresentation(formatter:at:isCompact:trip:)`) for `MonitoringStatusView`,
  `BackendConnection.resolve` (through `model.backendConnection`) for the Settings status row,
  `TripPresentationStep.resolve` (through `model.tripPresentationStep`) for the Calendar's
  notification sheet, and `DataSourceWording` / `PrototypeInfo.stepDescription(usesLiveBackend:)`
  / `dataDisclosure(usesLiveBackend:)` for every sentence that would otherwise claim "nothing
  leaves this device", "no network", or an in-app preview. The Demo wording is pinned byte for
  byte; do not edit it.
- In Live mode the reminders section and the Map card show `MonitoringStatusView`; in the Demo
  data mode and in a host without a live backend they show `ReminderPreviewView` exactly as
  before. Never show both, and never show a preview disclosure for a server alert.
- "Connected" is claimed only for a server that answered: the status row is derived from the
  newest answer or failure the model already holds and requests nothing of its own.
- The server's plan lines ("Monitoring starts...", "Heads-up...", "Time-to-leave alert...") are
  listed only while nothing blocks delivery (`MonitoringSummary.listsServerPlan`); under any
  other obstacle only the obstacle is named. Numbers in the reminders footer come from
  `MonitoringLimits`, never from literals.
- The notification-permission buttons appear only after the server answered or failed, and the
  permission is requested only by the reminders toggle and the "Allow Notifications" button.
- "I've Left" (`TripDepartedControl`) is offered only while the trip is monitored or its
  time-to-leave alert was sent, sends the occurrence's own ideal arrival, and claims success
  only from `DepartedState.done`.
- The Calendar consumes `tripToPresent` on appear, on change, and when the schedule loads or
  the editor closes; it presents only while no editor session is open and clears the request
  only after the sheet is set or the trip no longer exists.
- The Map toolbar shows `LiveDataLabel` in Live mode exactly where `DemoEstimateLabel` sits in
  the Demo data mode; never both. Its words are "Team backend": they name where the answers
  come from and must stay true for fixture, historical, and missing data alike, so do not
  word the label after the data's freshness.
- A failure to register with the push service on this device goes into
  `PushDeliveryStatus.registrationFailure` and is worded as this device's
  (`MonitoringText.registrationFailureSentence`); `lastFailure` is the server's own note only.
- Keep the stage S3 identifiers: `map.liveDataLabel`, `settings.dataMode`,
  `settings.backendAddress`, `settings.backendAddressIssue`, `settings.backendStatus`,
  `settings.backendNotice`, the monitoring parts `<prefix>.status|detail|retry|allow|openSettings`
  under `monitoring` (Settings) and `map.monitoring` (Map card), `calendar.detailMonitoring`,
  `calendar.detailLeft`, `calendar.detailLeftStatus`, `map.nextTripLeft`, and
  `map.nextTripLeftStatus`. `LiveModeUITests` repeats the ones it uses.

## Host rules (from stage S3)
- One composition per process: `AppComposition.shared` (in `AppDependencies.swift`) builds the
  model and the `BackendSession` exactly once, and the app's scene and the `AppDelegate` both
  read them there. Never build a second model, and never make notification handling depend on
  a scene or on view construction order.
- `BackendLaunchOptions` (package, pure, tested) decides the composition from the environment
  and the Info.plist. `WAIT_IT_OUT_DATA_MODE=demo` composes the standalone prototype with no
  `LiveBackend` at all: no network client, no Keychain item, and no notification API is touched
  (`AppDelegate` returns early without a session). Any other value, and none, composes the live
  backend with `TestCommuteProvider` and `PreviewReminderScheduler` kept for the Demo data mode
  in Settings. The default server address is `WAIT_IT_OUT_BACKEND_URL`, else the Info.plist key
  `WaitItOutBackendURL`; an unusable environment address means "not configured", never a
  fallback to another server.
- Every application a UI test creates is given `WAIT_IT_OUT_STORAGE_FOLDER` and
  `WAIT_IT_OUT_DATA_MODE` before it is launched (the checker looks at each one, not at the file
  as a whole). The demo tests set `demo` and must keep doing so: their assertions describe the
  deterministic simulation. A test that sets `live` must also set `WAIT_IT_OUT_BACKEND_URL` to a
  loopback address and may name no other server (the checker enforces both), must leave
  reminders off, and must accept every honest outcome that depends on the time of day
  (`LiveModeUITests` accepts three for the next trip: the failed request, the trip beyond the
  forecast, and an ideal arrival that has passed). No test may reach a real server or a
  third-party service.
- The one exception is opt-in: `FixtureBackendEndToEndUITests` (in `LiveModeUITests.swift`)
  runs against the backend's fixture server on this machine and is skipped unless that server
  answers on `127.0.0.1:3100` (`npm run serve:fixture` in `backend/`). Its two tests turn
  leave-home alerts on and allow notifications, because registering and synchronizing is what
  they check, so the app registers with the system's push service as any user's would; no
  test sends anything through that service (the closed-app test's alert is put on the
  simulator with `xcrun simctl push`). The closed-app test, which also needs
  `E2E_CLOSED_APP=1`, makes the only launch without a storage folder and a data mode, because
  a launch by the system carries no environment; it restores the default storage in a
  teardown block, and the checker names that launch in `BARE_UI_TEST_LAUNCHES`. Do not add
  another such launch, and keep screenshots as `XCTAttachment`s, never as files at fixed paths.
  How to run the class is in `docs/BACKEND_INTEGRATION.md`, section 8.
- The `AppDelegate` only forwards. The push token goes to `BackendSession.updateDeviceToken(_:)`
  (a failure to `registrationFailed(_:)`), followed by `model.pushRegistrationDidChange()` only
  when that returned `true`. A notification response is read with
  `TripNotificationPayload.response(userInfo:actionIdentifier:openActionIdentifier:)`; `nil`
  (another sender's notification, a dismissal) does nothing. Otherwise
  `await model.prepareForNotificationResponse()`, then
  `await model.handleNotificationAction(tripID:action:arriveBy:)`, and only then the system's
  completion handler.
- The "I've left" notification action is registered with the `.foreground` option: it opens
  the app, which tells the server and shows the outcome. Do not move that request to the
  background, and do not add `UIBackgroundModes`: the alerts are visible notifications and
  need none.
- `SystemPushRegistrar.apnsEnvironment` follows the signed `aps-environment` entitlement, not
  the build configuration: the one entitlements file says `development`, so the value is
  `"sandbox"` for Debug and Release alike. Change both together for a distribution build (the
  checker compares them).
- `Info.plist` is partial (`GENERATE_INFOPLIST_FILE` stays `YES`): it holds only the default
  server address and `NSAllowsLocalNetworking`, which lets a development server on this
  machine or the local network answer over plain http. Real deployments use https; do not add
  `NSAllowsArbitraryLoads` or exception domains.

## Reporting rules
- This repository may be worked on from a Linux host without Xcode. Record `xcodebuild`
  and XCTest checks as NOT RUN there; only the structural checker and `xmllint` execute.
- Never describe static inspection as a successful build or test run.
- Update the README's "Validation status" table for each step.
- Say exactly which parts of the backend integration ran and against what: a scripted
  transport, bodies captured from the real backend (`RealBackendShapesTests`), a server on
  this machine, the simulator, or a device. Push delivery needs a physical device, a team
  whose App ID has the Push Notifications capability (an Apple Developer Program team), and a
  server with push credentials; until that has been done, record it as NOT RUN
  (`docs/BACKEND_INTEGRATION.md`, "What was verified").
- When the backend's responses change, capture them again and replace the bodies in
  `RealBackendShapesTests` verbatim; never edit a captured body by hand to make a test pass.
