# Commute estimation and leave-home times (steps 0005-0007, stages S1-S3)

This note explains how the app arrives at a read-only leave-home time, and the boundary a
provider implements. There are two sources, and the screens say which one is in use:

- **Live (the normal flow since stage S3).** The team backend decides the departure
  (`BackendCommuteProvider`); the app shows its recommendation as given, with the traffic
  source the backend named. See "Backend recommendations" below.
- **Demo (explicit).** `TestCommuteProvider`: the Settings test duration shaped by a
  deterministic scenario (Normal, Slow, Unavailable, or Error), labeled as simulated. It is
  not measured traffic. This is the standalone prototype, unchanged; the formula below
  applies only to it and to any other provider that returns a travel time.

Step 0005 introduced the formula, the boundary, and the result states; step 0006 added the
home origin to every request, the `refreshing` state, estimate freshness, Try Again for
failures only, and the scenarios; stage S1 added backend recommendations; stage S3 composed
them in the host.

## The formula

```
leave home = ideal arrival - travel time
```

- The **ideal arrival** is what the user set second, after the activity's start and end. It
  already includes study, parking, and buffer time, so nothing else is subtracted.
- The activity's **start is never used**. A 9:00 class with an 8:15 ideal arrival and a
  60-minute commute leaves at 7:15, not 8:00.
- The subtraction is in **elapsed time** (`Date` minus seconds), not wall-clock arithmetic. A
  12:30 AM arrival with 60 minutes of travel leaves at 11:30 PM the previous day, and a trip
  across a daylight-saving change takes exactly the travel time (the clock times may then be
  two hours or zero hours apart; the UI says so).
- The result is **never stored** on an `Activity` and is never an input. It is recalculated
  whenever an input changes and shown read-only.

`DepartureCalculator.leaveHome(idealArrival:travelTime:)` is the pure formula;
`DepartureCalculation.make(idealArrival:estimate:)` validates a provider estimate and applies it.

## The boundary: `CommuteEstimating`

```swift
public protocol CommuteEstimating: Sendable {
    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse
}
```

**Request** (`CommuteRequest`):

| Field | Meaning |
| --- | --- |
| `occurrenceID` | The occurrence the trip serves (activity id plus local start day). For correlation only. |
| `origin` | `CommutePlace`: the home set in Settings, a name and a WGS-84 coordinate (step 0006). Valid by construction, so it needs no check. |
| `destination` | `Destination`: stable id, name, WGS-84 coordinate. For a campus activity (destination id `demo-campus`) it is the campus currently set in Settings, resolved when the request is made, not the copy stored on the activity. |
| `arriveBy` | The ideal campus arrival. Estimate a trip that arrives by this instant. |

Home and campus are typed in Settings (no location permission, geocoding, or network
lookup). The provider receives only these two places and the arrival; the activity's start
is deliberately absent.

**Response** (`CommuteEstimateResponse`):

- `.estimate(CommuteEstimate)` with
  - `travelTime` (seconds, raw; the app validates it),
  - `sourceLabel` (short words shown next to every leave-home time; must not be empty),
  - `estimatedAt` (when the estimate was made, from the provider's injected clock; the app
    shows its age and refreshes it when it is stale),
  - `isSimulated` (`true` adds a TEST DATA badge; a live provider sets `false`).
- `.unavailable(message:)` when the provider works but has no estimate for the trip (no
  route, outside coverage). The message is shown as is, without Try Again (step 0006); a
  simulated answer must say so.
- `.recommendation(DepartureRecommendation)` (stage S1): a complete backend decision, shown as
  is with no local arithmetic. See "Backend recommendations" below.
- `.notYet(message:askAgainAt:)` (stage S1): nothing can be recommended yet and that changes at
  a known time. The message is shown as is, without Try Again, and the model asks again once
  the clock reaches `askAgainAt`.
- **Throw** for real failures (network, service, authorization). The app shows a generic
  error with Try Again and never shows a guessed time. A thrown `CommuteProviderFailure`
  (stage S1) gets its own sentence instead of the generic one.

**Rules a provider must follow**

1. Estimate travel time only. Do not add or subtract study, parking, or buffer time.
2. Be callable concurrently and off the main actor. The model calls the provider from
   background tasks, one per occurrence in the planning horizon plus one for the editor.
3. Honor task cancellation when practical. The model cancels requests whose activity was
   edited or deleted, whose arrival, home, or campus changed, or whose provider settings changed.
4. Do not worry about late answers: the model applies an answer only while its request is
   still current (each request carries a token), so an out-of-order or late answer is dropped.
5. Do not validate for the app. The app rejects zero, negative, nonfinite, and longer-than-
   12-hour travel times, nonfinite timestamps, and empty labels, and shows "estimate not
   usable" instead of a time.
6. Return or throw in bounded time, using your own network timeout. The prototype adds no
   request timeout, so a call that never finishes leaves that trip in the loading (or
   refreshing) state until its inputs change.

## Result states

`DepartureState` is what every screen renders:

| State | When | What the user sees |
| --- | --- | --- |
| `loading` | A request is in flight and there is no earlier answer for this trip | "Calculating the leave-home time…" |
| `refreshing(DepartureCalculation)` | The same trip is asked again after a scenario or duration change or because its estimate is stale (step 0006) | The earlier time marked "out of date" with a spinner and "Out of date: updating the commute estimate from 7:00 AM…"; never shown as current |
| `success(DepartureCalculation)` | Valid estimate | Leave-home time, the formula, the source with estimate time and age, TEST DATA when simulated |
| `unavailable(.noEstimate)` | Provider answered without an estimate | The provider's message; no Try Again |
| `unavailable(.noDestination)` | Activity has no usable destination | Explanation; the provider is not called |
| `unavailable(.activityEnded / .beyondHorizon / .unsavedChanges)` | Not in the planning set | Why there is no time |
| `error(.providerFailed)` | Provider threw | Generic error, Try Again |
| `error(.invalidEstimate)` | Unusable value | "Estimate was not usable (reason)", Try Again |
| `unavailable(.notYetPlannable)` | The provider answered `.notYet` (stage S1) | The provider's message; no Try Again; asked again when its time comes |
| `error(.provider(kind))` | The provider threw a `CommuteProviderFailure` (stage S1) | The kind's own sentence, Try Again |
| `stale(DepartureCalculation, failure)` | A refresh of a backend recommendation failed, or the server reports it out of date (stage S1) | The last recommendation marked "out of date", why it could not be refreshed, Try Again; never shown as current |

- **Try Again only for failures.** `isRetryable` is true for `.error` and `.stale`. Asking again after
  `.unavailable` would give the same answer, and any change to the trip or the provider
  settings recalculates automatically. `retryDepartures()` re-requests only failed entries,
  including the editor's preview.
- **Same trip versus changed trip.** When an entry is asked again for the identical request
  (occurrence, origin, destination, arrival), its earlier calculation is kept as `refreshing`.
  A changed request, such as an arrival edit or a new home or campus, starts from `loading`,
  because the earlier time belongs to another trip.

A calculated time is judged against the injected clock when shown (`timing(at:)`):

- before or at the leave-home time: shown normally;
- after it but before the ideal arrival: "The 7:15 AM leave-home time has passed. Leaving
  now may miss the 8:15 AM arrival target." The time is **not** replaced by "now";
- after the ideal arrival: "The 8:15 AM arrival target has passed."

## Freshness (step 0006)

`EstimateFreshness` is pure; the caller passes `now`.

- `lifetime` is 10 minutes. An estimate whose age (`now` minus `estimatedAt`, never below
  zero) is at least the lifetime is stale.
- `needsRefresh` is true for a successful calculation that is stale **and** whose ideal
  arrival is still ahead. Estimates for trips whose arrival has passed are kept.
- `refreshDepartures()` checks it for every saved occurrence in the horizon, so the Map's
  and Calendar's minute ticks, opening details, and returning to the foreground re-request
  stale estimates; the earlier time stays visible as `refreshing` until the answer arrives.
  The editor's preview is re-requested when the draft or the provider settings change, not by age.
- The source line shows the age: "just now" under a minute, then "12 minutes ago" or
  "1 hour 5 minutes ago".

## Backend recommendations (stage S1; the host's normal flow since stage S3)

The host composes `BackendCommuteProvider` in `WaitItOutUXPrototype/AppDependencies.swift` and
passes it in a `LiveBackend`, so this is what the running app shows unless the Demo data mode
is chosen under Settings, Data source, or the launch asks for the standalone demo
(`WAIT_IT_OUT_DATA_MODE=demo`). The Map shows "Team backend" where the demo shows "Demo estimate".
The requests behind it and the server address are in
[`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md).

A provider may return a complete decision instead of a travel time. `BackendCommuteProvider`
does: it asks the team backend for a verdict and returns it as a `DepartureRecommendation`
(advice `leaveNow`, `wait`, or `leaveLater`; recommended departure; predicted arrival; the
backend's reason, confidence, and notes; how late or how much to spare; the backend's stamp
and when the device received it; and where the traffic figures came from).

- **No local arithmetic.** `DepartureCalculation.make(idealArrival:recommendation:)` copies the
  recommended departure into `leaveHome` and never calls `DepartureCalculator`. `travelTime` is
  the predicted arrival minus the recommended departure and is used for display only. The app
  adds no buffer; when the backend plans a later departure it keeps its own margin.
- **What the rows show.** The recommended departure ("Leave now, as of 7:20 AM" for
  `leaveNow`); "Predicted arrival 8:00 AM after about 45 minutes of driving" in place of the
  formula; the backend's reason while it is at most two minutes old (it is worded relative to
  when it was written; afterwards only "About 15 minutes to spare before your ideal arrival."
  when there is a margin); the source line, "Live traffic (TomTom) via the team backend, checked
  6:00 AM, just now"; the confidence with its reason; and every note.
- **Sources are named as reported** (`RecommendationSource.label`): "Live traffic (TomTom) via
  the team backend", "Typical traffic (TomTom); live traffic unavailable", "Historical traffic
  (PeMS fallback); TomTom unavailable", "Historical traffic (PeMS)", "Test fixture traffic, not
  live" (with a TEST DATA badge), and "Team backend" when the server reports no source.
- **Lateness comes from the backend.** The local "may miss" warning is never shown for a
  recommendation. When the backend says the ideal arrival can no longer be reached: "Your
  ideal arrival is no longer reachable: leaving now you would arrive about 40 minutes late."
- **A failed refresh keeps the last recommendation**, as `stale`: "Could not refresh since
  6:00 AM: The backend could not be reached. Check the connection. Showing the last
  recommendation, which may be wrong." with Try Again. It is never the current leave-home time
  and earns no reminder. A demo estimate is not kept; its failed refresh is an error, as before.
- **Failure sentences** (`CommuteProviderFailure.Kind`), each followed by "No leave-home time
  is shown." when nothing is kept: no address ("No backend address is set. Add one in Settings,
  Data source."), offline ("The backend could not be reached. Check the connection."), timed
  out ("The backend did not answer in time. It may be waking up; this is retried
  automatically."), routing ("The routing service could not plan this trip right now."), server
  ("The backend had a problem (HTTP 503)."), unreadable ("The backend's answer could not be
  read."), and unauthorized ("The backend did not accept this device.").
- **Automatic retry, live backend only.** Transient failures (offline, timed out, routing,
  HTTP 500 and above) are asked again on the existing minute ticks after 1, 2, and then every
  5 minutes (`DepartureRetry`), and at once when the app returns to the foreground. Other
  failures wait for Try Again or a changed input. Errors of the demo provider are still never
  retried automatically.
- **Not yet.** A trip beyond the backend's planning reach (690 minutes by default) is
  answered without a request: "The traffic forecast reaches about 11.5 hours ahead. A
  leave-home time will appear after <time>." It is asked when it enters the reach. A backend
  "no rush" verdict is shown in the backend's own words with the time it was checked and asked
  again 10 minutes later. No coverage for the route is `unavailable` with the backend's sentence.
- **Freshness** (`EstimateFreshness.lifetime(for:at:)`, `needsRefresh`): 30 minutes while the
  recommended departure is more than 3 hours away; otherwise `nearLifetime`, 14 minutes 30
  seconds counted from when the model asked (`DepartureEntry.attemptedAt`); a fixed 5 minutes
  for `leaveNow`; a planned departure that has passed is asked again once the answer is 60
  seconds old, so the backend can say "leave now" or "late". (A demo estimate keeps the 10
  minutes above.)
- **Why 14 minutes 30 seconds.** Inside three hours the backend's candidate departures are the
  moment it is asked plus whole 15-minute slots, and it recommends the latest one that arrives
  in time. The answer therefore depends on when the question is put: asked every 10 or 11
  minutes, the leave-home time would jump by up to a slot with traffic unchanged. Refreshes
  run on whole-minute ticks, so with this lifetime the fifteenth tick after an ask, exactly
  one slot later, asks again, on the same grid of departures; the time then moves only when
  traffic does, and "Leave now" appears at the departure that was shown. What remains: an ask
  at a moment of its own (the first one, a return to the foreground after the lifetime, Try
  Again, the editor's preview) starts a new grid and can move the time once. Removing that
  would need the backend to accept an anchor for its slots, which is outside this app.
- **Monitored trips (stage S2).** While the server keeps a monitored plan current,
  `BackendCommuteProvider` answers from that plan through its `MonitoredTripSource` instead of
  asking for a new verdict, so the screens and the alerts agree. "Current" is one rule
  (`MonitoredTripState.currentPlan`), and every part of it has to hold: the trip is in its
  monitoring phase; the server says it runs its monitoring worker; the plan is not flagged
  stale; its departure is still ahead; and no time-to-leave or late alert was sent or queued,
  after which the server stops re-checking the trip. The recommendation then has
  `isMonitored == true`, its age is the plan's age on the server's clock, and it is not
  re-asked by age while its departure is ahead: the model asks again when the server's state
  for that trip changes (`invalidateDepartures(for:)`). In every other case the backend is
  asked directly: before monitoring starts, on a server whose worker is off, for a stale
  plan, once the departure has passed, after the "Time to leave" or a late alert, and for a
  trip whose origin, destination, or arrival differs from what the server was sent. So the
  screen then shows the backend's current answer ("Leave now", or that the arrival is no
  longer reachable) and never a plan nobody refreshes. A plan the app could not re-read for
  three minutes (`MonitoringSnapshot.lifetime`), or that a failed synchronization on return
  to the foreground could not confirm, is handed back to a direct request too, and its
  failure keeps the plan as `stale`. Try Again under a plan a monitored-trip source reports
  as stale ("The server could not re-check traffic on schedule.") reads that trip from the
  server again. The planning reach used for "not yet" is the server's own once it reported
  one.
- **The editor's preview** asks about the occurrence the editor shows. With the live backend a
  repeating draft whose first occurrence has passed is asked about through its next upcoming
  occurrence (`draftCommuteRequest(for:at:)`, `draftPreviewOccurrence`), with a note naming
  that arrival, so a series that goes on never reads "The ideal arrival time has passed"; and a
  request caused by a draft change waits `liveDraftDebounce` (0.6 seconds), so a drag asks
  once. The demo preview is unchanged: the first occurrence, asked at once.
- **Data mode.** With a `LiveBackend` the source is `UserPreferences.dataMode`: Live (the
  backend) or Demo (the test provider). `setDataMode(_:)` and `applyBackendAddress(_:)` cancel
  every request and clear every result before asking again, so a value from one source is never
  shown under the other, and a failed live request is never replaced by a simulated value.

## What gets calculated, and when

- **Horizon** (`DepartureHorizon`): saved occurrences that are not over and whose ideal
  arrival through end begins within the next 7 days. In-progress occurrences stay in, so their
  details still explain a missed target. The Map's next trip is the first of these that has
  not started, ordered by ideal arrival.
- **Triggers**: every activity reload (load, save, delete, sample load or clear), a change of
  the Settings test duration or scenario, a change of home or campus, the Calendar's and Map's
  once-a-minute tick (new occurrences enter the horizon and stale estimates refresh), opening a
  detail sheet, returning to the foreground, and every draft change for the editor's preview.
- **Reuse**: an entry whose request (occurrence, origin, destination, arrival) and
  provider-settings revision are unchanged, and whose estimate is not stale, keeps its result,
  so ticks and title edits cost nothing.
- **Cancellation and ordering**: a changed or removed entry cancels its task; answers apply
  only while their token is current.

## Test scenarios (prototype only)

`TestCommuteProvider.Scenario`, chosen in the Settings "Prototype testing" section and stored
in `UserPreferences.testCommuteScenario`. Every scenario is deterministic.

| Scenario | Answer |
| --- | --- |
| Normal | `.estimate` of the test duration, labeled "Test commute (simulated, not live traffic)", after `simulatedDelay` (300 ms in the host). With 60 minutes the sample class leaves at 7:15 AM and the sample lab at 10:15 AM. |
| Slow | `.estimate` of the test minutes times 1.5, rounded up, at most 12 hours, labeled "Test commute, Slow scenario (simulated heavy traffic, not live)", after `slowDelay` (3 s in the host). With 60 minutes: 90 minutes, so 6:45 AM and 9:45 AM. |
| Unavailable | `.unavailable` with a message that names the simulated scenario, after `simulatedDelay`. No Try Again. |
| Error | Throws `TestCommuteProviderError` after `simulatedDelay`. Try Again is offered and keeps failing until another scenario is chosen. |

`setTestCommuteScenario` and `resetPrototypeTesting` call `commuteSettingsDidChange()`,
which pushes the duration and scenario into the provider, bumps the settings revision, and
recalculates everything. Views only label the scenario; they never branch on it.

## Replacing the mock route and commute provider

The prototype host already does this with the team backend: it passes a `LiveBackend` holding
`BackendCommuteProvider` and `BackendRouteProvider`, and keeps `TestCommuteProvider` as
`commuteEstimator:` for the Demo data mode. The steps below describe the other way, a team
provider of travel times passed directly as `commuteEstimator:` without a `LiveBackend`.

The UX stays intact when a team provider replaces the test data; only the composition root
changes.

1. **Estimates.** Implement `CommuteEstimating` in the team app (for example on top of
   MapKit's `MKDirections` or a traffic service), following the rules above. Plan the trip
   from `request.origin.coordinate` (home) to `request.destination.coordinate` (campus) so
   that it arrives by `request.arriveBy` (the ideal arrival), and return only the travel time.
2. **Labels.** Return estimates with `isSimulated` set to `false` and a `sourceLabel` that
   names the real source. Pass the provider as `commuteEstimator:` to `WaitItOutModel(...)`
   in the team's composition root, the counterpart of `AppDependencies.makeGraph()`. Because
   it is not a `TestCommuteProvider`, `usesTestCommute` is false: Settings hides Prototype
   testing, the Map hides the "Demo estimate" label and the next-trip card's TEST DATA badge
   and simulation line, and the source rows drop TEST DATA because `isSimulated` is false.
   The "Commute estimates" row in Prototype information then reads "Injected provider".
3. **Home and campus.** Supply them from the team's own settings, either through a
   `PreferencesStoring` implementation that returns them in `UserPreferences.places`, or by
   mapping the team's own home and campus models into `CommutePlace` at the boundary
   (`CommutePlace(name:coordinate:)` throws for unusable values) and calling
   `setPlace(_:for:)`. Campus activities keep resolving to `places.campus` through the campus
   destination id, so nothing stored has to be rewritten.
4. **Freshness.** Nothing to add: the model already re-requests estimates older than
   `EstimateFreshness.lifetime` (10 minutes) while their arrival is ahead, keyed on
   `estimatedAt`, so set it to when the estimate was actually made. A different lifetime is a
   change to that one constant.
5. **Routes on the map.** Without a route provider the Map draws a schematic straight
   `MapPolyline` between home and campus, labeled as not a route. Since stage S1 a
   `RouteProviding` implementation passed as `LiveBackend.routeProvider` (the package's is
   `BackendRouteProvider`) supplies real geometry: the model publishes it as
   `routeState == .route(geometry)` and only then does the Map draw a solid line, labeled
   "Route via <source>", with the places card naming the source and the road distance. While
   a route loads, when it cannot be loaded, and in the Demo data mode, the dashed line and
   every schematic label stay. The cards, states, and leave-home rows need no change.

## Persistence and reminders (step 0007)

- Departure results are never stored. `activities.json` and `preferences.json` hold only the
  inputs (activities, places, test duration, scenario); every leave-home time is recalculated
  after launch, so a `.loading` or `.refreshing` state can never be mistaken for a saved
  estimate.
- Leave-home reminder previews are derived from these results: only a current `.success`
  calculation whose leave-home time is still ahead produces a reminder, due at that time. A
  `.refreshing` trip keeps an already pending reminder, marked out of date, until the new
  estimate arrives; `.loading`, `.unavailable`, `.error`, and a kept out-of-date recommendation
  (`.stale`) produce none and the preview says why. See [`REMINDERS.md`](REMINDERS.md).
- The data mode and the server address typed in Settings are inputs and are stored
  (`dataMode` only when it is Demo, `backendAddress` only when set); recommendations are not.
