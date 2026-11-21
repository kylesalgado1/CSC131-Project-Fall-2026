# Backend integration (stages S1 to S3)

How the WAIT IT OUT app uses the team backend: which requests it makes, what it sends, the
states it can be in and the words it uses for them, how it is configured, what push
notifications need before they can work, and what was and was not verified. The package
types behind all of this are described in [`TEAM_INTEGRATION.md`](TEAM_INTEGRATION.md),
[`COMMUTE_ESTIMATION.md`](COMMUTE_ESTIMATION.md), and [`REMINDERS.md`](REMINDERS.md); this is the
one document that names the backend's endpoints.

**Status, plainly.** The app is composed with the backend and is built and tested against
scripted transports and an in-memory stand-in for the server. Its decoding is also tested
against response bodies captured from the real backend code and one real answer of the
deployed backend, embedded verbatim (`RealBackendShapesTests`). The automated tests make no
request to a deployed backend, to the push service, or to any third-party service, and nothing
ran on a physical device. Read "What was verified" at the end before relying on any part of
this.

## 1. The two data modes

| | Live (the normal flow) | Demo (explicit) |
| --- | --- | --- |
| Leave-home time | The backend's recommended departure, shown as given. The app adds no arithmetic and no buffer | Ideal arrival minus the simulated test commute, labeled TEST DATA |
| Map line | The backend's driving route when it has one; otherwise the dashed schematic line, labeled | The dashed schematic line, labeled |
| Leave-home reminders | The server monitors the trips and sends push alerts | In-app previews only; nothing is delivered |
| Network | Requests to the server address in use | None |
| Notification permission | Asked only when reminders are turned on or "Allow Notifications" is tapped | Never asked |
| Map label | "Team backend" (it names where the answers come from, whatever they are: live traffic, typical or historical traffic, a test fixture, or nothing yet) | "Demo estimate" |

Live is the default. Demo is chosen under **Settings > Data source > Traffic data**, is stored
with the other settings, and is always labeled. A failed live request is never replaced by a
simulated value: the screen says what failed, keeps the last recommendation marked out of
date when there is one, and offers Try Again.

A third arrangement exists for tests only: launched with `WAIT_IT_OUT_DATA_MODE=demo`, the
host composes the standalone prototype with no backend at all, so Settings has no Data source
section and no network, Keychain, or notification code runs. Every existing UI test uses it.

## 2. Requests the app makes

All bodies are JSON, all times ISO-8601 in UTC. Errors are told apart by the body's `error`
code before the HTTP status. Bodies, coordinates, and credentials are never logged.

| Request | When | Sent | Used for |
| --- | --- | --- | --- |
| `POST /verdict` | A saved trip or the editor's preview needs a leave-home time and its ideal arrival is within the server's planning horizon (11.5 hours unless the server says otherwise) | Home coordinates, destination coordinates, the ideal arrival (`arriveBy`) | The recommendation: when to leave, the predicted arrival, the reason, confidence, notes, lateness, and the traffic source |
| `POST /route` | The Map needs the line from home to campus | The two coordinates | The driving route's points, distance, and source |
| `POST /devices` | The first time trips are synchronized with a server | `platform: ios` | An anonymous installation id and its credential |
| `PUT /devices/me/push` | The push token or the notification permission changed | The push token (or none), the push environment, whether notifications are allowed | Whether the server can reach this device |
| `PUT /trips` | Leave-home reminders are on and the set of upcoming trips changed, or is confirmed again | A revision number and the complete set of upcoming trips (see "What is sent") | Server-side monitoring and its state |
| `GET /trips` | On the screens' minute ticks (Map, Calendar, and Settings) while a trip is planned or monitored | Nothing | The server's current plan and alert state |
| `GET /trips/:id` | A trip was opened from a notification, or Try Again was tapped under a plan the server itself could not refresh | Nothing | That trip's current state |
| `POST /trips/:id/departed` | "I've Left" | The arrival time the user meant | Ending the monitoring of that trip |
| `DELETE /devices/me` | Reminders turned off, the Demo data mode chosen, or the server address changed, and only when this installation has a credential for that server | Nothing | Removing the installation and its trips from that server. If that fails, an empty `PUT /trips` under the same credential at least stops the alerts; that request never registers a device and reports no push token |

The device and trip requests carry `Authorization: Bearer <credential>`. `/verdict` and
`/route` are unauthenticated. The app does not call the backend's place search or health
endpoints: home and campus are typed in Settings.

A server that predates these endpoints answers 404 without the backend's `not_found` code;
the app then says the server does not support the feature (no route: the schematic line;
no monitoring: "This server does not support trip monitoring yet.") and does not retry by
itself. Leave-home recommendations keep working against such a server, with the traffic
source shown as unknown.

Two answers with HTTP 503 are told apart by their code:

| Code | Meaning | What the app does |
| --- | --- | --- |
| `temporarily_unavailable` | The server cannot answer just now (for example it cannot reach its database) | A passing failure: retried on the minute ticks with the usual backoff. Never read as "not supported", and a removal answered with it is not done |
| `monitoring_unavailable` | The server's trip tables are not set up yet | "This server does not support trip monitoring yet." Not retried on the ticks; asked again when the app is opened or brought to the foreground, by the reminders toggle, and by Try Again. A removal answered with it is not done either: it says nothing about what the server still holds |

**When a credential is dropped.** Only when the server confirmed the removal (204), no longer
knows the device (401), or predates the device endpoints (the 404 above, where there is
nothing to remove). After any other answer the credential stays in the Keychain, the
withdrawal is reported as not confirmed, and it is tried again: on the minute ticks after a
passing failure, otherwise when the app is opened again or Try Again is tapped. A server left
behind by a changed address is found again after a restart through the credential that is
still stored for it.

## 3. What is sent, and what is not

- **For a recommendation:** the home and destination coordinates set in Settings and the
  activity's ideal arrival. Nothing identifies the installation.
- **For the route:** the same two coordinates.
- **With leave-home reminders on:** the upcoming trips (at most 20, or the server's own limit
  when it is lower; saved occurrences of the next 7 days whose ideal arrival is ahead), each
  with an id the app makes up for the occurrence (the activity's random id and the local
  date), its title, the home and destination coordinates, the ideal arrival, and the time
  zone, under an anonymous installation id. Titles are trimmed and cut to 120 Unicode scalars.
  So that the server can reach the device, it also gets the push token, the push environment,
  and whether notifications are allowed. This is exactly what the server uses; the activity's
  start time and the destination's name, which the contract would accept, are not sent.
- **Never:** the device's location (the app reads none), an account, a name, an e-mail
  address, the saved schedule beyond the upcoming trips, or anything while the saved schedule
  cannot be read.

The installation's credential is kept in this device's Keychain (service
`com.waititout.backend`, one item per server address, not synchronized to other devices). It
is never written to the settings file or a log and is never sent to another server address:
every request is pinned to the address its operation started with.

**How far ahead alerts reach.** The server holds only the trips it was sent, and the app sends
them only while it is open: at launch, on return to the foreground, and when the schedule or
a setting changes. Nothing is sent while the app is closed (no background mode is declared,
and the alerts are visible notifications that do not wake the app). So alerts are set up for
the trips of the next 7 days (at most 20) as of the last time the app was open, and they stop
for later trips, including later occurrences of a repeating activity, until the app is opened
again. Settings says so in the reminders footer and names the day ("Alerts are set up for
trips through <day>. Open the app again before then to keep them coming.").

**Retention.** Trips are removed from the server after they end. Turning reminders off,
choosing the Demo data mode, or changing the server address deletes this installation's data
from the server that held it; when that server cannot be told or does not confirm, the app
says so ("The previous server may still send alerts for a while.", or "The server could not
be told to stop (...)") and tries again as described above.

## 4. States and their wording

### Leave-home time (Map card, Calendar details, editor)

| State | What is shown |
| --- | --- |
| Asking | "Calculating the leave-home time…" |
| Current recommendation | The time ("Leave now, as of <time>" for a leave-now answer), the predicted arrival, the backend's reason for two minutes and then the absolute margin, the source as the backend named it, the confidence, and the backend's notes. Live traffic is claimed only when the backend had it; fixture data is labeled TEST DATA |
| Refreshing an older recommendation | The earlier time marked "out of date" and "Out of date: checking the backend again…" |
| Kept after a failed refresh | The earlier time marked "out of date", "Could not refresh since <time>: <what failed> Showing the last recommendation, which may be wrong.", and Try Again |
| Failed, nothing to keep | The failure sentence followed by "No leave-home time is shown.", and Try Again |
| Arrival no longer achievable | The backend's lateness, as "Your ideal arrival is no longer reachable: leaving now you would arrive about <duration> late."; the app adds no "may miss" warning of its own |
| Too far ahead to plan | "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after <time>." No Try Again; the app asks when that time comes |
| No traffic data for the route | "There is not enough traffic data for this route yet. No leave-home time is shown." |

Failure sentences: "No backend address is set. Add one in Settings, Data source." / "The
backend could not be reached. Check the connection." / "The backend did not answer in time.
It may be waking up; this is retried automatically." / "The routing service could not plan
this trip right now." / "The backend had a problem (HTTP <status>)." / "The backend's answer
could not be read." Failures that can clear by themselves (no connection, a timeout, a server
error) are retried on the screens' minute ticks after 1, 2, then 5 minutes.

**How often a recommendation is asked again.** A departure more than 3 hours ahead: every 30
minutes. A nearer one: exactly 15 minutes after it was last asked, which is one of the
backend's slots, so consecutive answers come from the same grid of candidate departures and
the time on screen moves only when traffic does (asked at arbitrary moments it would jump by
up to a slot). "Leave now": after 5 minutes. A planned departure that has passed: once it is
a minute old, so the backend can say "leave now" or how late. An ask at a moment of its own
(the first one, a return to the foreground, Try Again, the editor's preview) starts a new grid
and can move the time once.

**Whose answer a screen shows.** With leave-home alerts on, the server's own plan for a trip is
shown instead of a direct answer only while the server keeps that plan current: the trip is
in its monitoring phase, the server runs its monitoring worker, the plan is not flagged stale,
its departure is still ahead, and no time-to-leave or late alert was sent or queued. In every
other case the backend is asked directly, so after the "Time to leave" alert, on a server
whose worker is off, and once the departure has passed, the screen shows the backend's
current answer ("Leave now", or that the arrival is no longer reachable) and never a plan
nobody refreshes.

**The editor's preview.** It asks about the occurrence the editor shows. For a repeating
activity whose first occurrence has passed it asks about the next upcoming occurrence instead
and says so ("The first occurrence has passed, so the leave-home time below is for the next
one: arrive by <day and time>."). A request caused by a change in the editor is sent 0.6
seconds after the last change, so a drag asks once.

### Server address and connection (Settings > Data source)

| State | Status row |
| --- | --- |
| Demo data mode | "Not in use: the Demo data mode is on." |
| No address | "Not configured. Enter a server address to use live data." |
| Address set, nothing answered yet | "Using <host>. No answer has arrived yet." |
| The newest thing known is an answer | "Connected to <host>. Last answer <time>." Only answers that came over the network count: what the app says by itself without a request (an ideal arrival that has passed, a trip beyond the forecast) is not a contact |
| The newest thing known is a failure | "The last request to <host> failed (<time>). <what failed>" |

The row is derived from the answers and failures already on screen; nothing is requested for
it, so "Connected" is said only of a server that answered. An address that cannot be used is
reported under the field with what stays in effect, for example "Use https for this address.
Still using http://localhost:3000."

### Leave-home alerts (Settings > Leave-home reminders, and the Map card)

| State | What is shown |
| --- | --- |
| Reminders off | "Leave-home alerts are off. Turn them on to have the server watch your upcoming trips and try to alert you when it is time to leave." |
| Waiting for the server | "Waiting for the server to confirm monitoring." with a progress indicator |
| Active, nothing in the way | "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed." In Settings: "The server confirmed <n> trips at <time>." and "Alerts are set up for trips through <day>. Open the app again before then to keep them coming." Then the next monitored trip's lines (below) |
| The server reports a problem with a trip | Instead of the sentence above: "Alerts are not active for this trip right now." (Map card, Calendar details) or "The server confirmed your trips, but alerts are not active for the next one right now." / "... for <n> of them right now." (Settings), followed by the trip's own line: "The server has no traffic data for this route, so it cannot plan or alert for this trip." / "The server has used up its traffic checks for today, so this trip is not being re-checked. A time-to-leave alert is still sent from the last plan, if there is one." / "The server could not check traffic for this trip just now. It keeps trying." / for a trip without a plan, the server's own sentence for two minutes after it was seen to appear, then "The server has no departure to recommend for this trip yet." |
| Permission not asked yet | "Notifications have not been allowed for this app yet." with Allow Notifications |
| Permission denied | "Notifications are off for <app name>. Turn them on in iOS Settings to get alerts." with Open Settings |
| Server cannot push | "The server has no push credentials, so alerts cannot be delivered." |
| No device token on the server | "This device is not registered for push notifications yet." When registering failed on this device, Settings adds "This device could not register for push notifications (<the system's reason>)."; the server's own note about a failed send keeps its own sentence, "The server's last attempt to reach this device failed (<reason>)." |
| Server not running monitoring | "This server is not running trip monitoring." |
| Server only checks while awake | "This server only checks traffic while it is awake, so alerts can be late or missing when the app is closed." |
| Synchronization failed | "Trips could not be synchronized: <reason>." or "The server did not accept these trips: <message>" or "This server does not support trip monitoring yet.", with Try Again |
| Saved activities unreadable | "Saved activities could not be read, so trip monitoring is paused. Nothing was changed on the server." |
| Saved settings unreadable | "Saved settings could not be read, so nothing was changed on the server. If leave-home alerts were on, the server may still send them." The app neither withdraws the installation nor synchronizes on the word of default settings until the settings can be read again or the user chooses the toggle, the data mode, or the address anew |
| Alerts off, the server not yet told | "Telling the server to stop monitoring…", then nothing, or "The server could not be told to stop (<reason>), so it may still send alerts for a while." ending "This is tried again automatically." for a passing failure and "It is tried again when you tap Try Again or open the app again." otherwise, with Try Again |

**One trip's lines.** Before the server monitors a trip the screens ask the backend directly,
so the server's own stored times are not printed beside that answer; its alerts are described
relative to the departure instead: "Monitoring starts about 2 hours before the recommended
departure." / "Heads-up about 90 minutes before the recommended departure." / "Time-to-leave
alert at the recommended departure." Once it monitors the trip: "Monitoring started <time>." /
"Heads-up about <time>." or "Heads-up sent <time>." / "Time-to-leave alert at the recommended
departure, currently <time>." The "currently" line is printed only for a departure that is
still ahead. Afterwards it reads "Time-to-leave alert sent <time>.", "Time-to-leave alert
queued; not sent yet.", or "The recommended departure, <time>, has passed; no time-to-leave
alert is recorded as sent." After a late alert ("Late alert sent <time>.") and while the
server's plan cannot meet the arrival ("No time-to-leave alert while the arrival time cannot
be met.") no time-to-leave alert is promised. When the server's state could not be read again
for three minutes: "The server's plan for this trip was last read <time>, so its alert times
are not shown until it is read again."

Alerts are described as active only when none of these obstacles applies. An alert is "sent"
only with the server's own stamp, which means the push service accepted it; the app never
says "delivered". Under any obstacle other than the awake-only server, the plan lines are
hidden so they cannot read like alerts that will arrive. The lead times in the lines and in
the section's footer come from the server's own limits (2 hours, 90 minutes, and 5 minutes
unless the server reports others). The footer also says how far ahead alerts reach (see "What
is sent").

### "I've Left"

Offered in the Calendar details and on the Map card while the server monitors the trip or has
sent its time-to-leave alert. "Telling the server…", then "Marked as left. Monitoring ended
for this trip." only after the server answered; "This trip was rescheduled; monitoring
continues for the new time." when the arrival time no longer matches; "Could not tell the
server you left; it may still send alerts for this trip." with Try Again after a failure.
"Marked as left" lasts only while the server itself reports the trip as left: after the
activity is rescheduled, or the device is registered anew, the server monitors the trip
again, the sentence goes, and "I've Left" is offered for the new time.

## 5. Notifications

- **Category and action.** The host registers the category `WAIT_IT_OUT_TRIP` with one action,
  `WAIT_IT_OUT_LEFT` ("I've left"), at launch in the live composition.
- **"I've left" opens the app.** The action is registered with the `.foreground` option, so
  tapping it brings the app to the front, and the app then tells the server and shows the
  outcome on the trip's details. Nothing is sent from the background, where a request to a
  sleeping server could fail unseen, and success is never assumed.
- **Tapping a notification** opens the Calendar on the trip's day with its details. A
  notification for a trip that is no longer in the calendar leaves a notice instead.
- **A cold start works the same way.** The model and the backend session are built once per
  process (`AppComposition`), independent of any scene; the response handler first joins the
  launch load of settings and schedule, then acts, and tells the system it is done only after
  the outcome is recorded.
- **A dismissed notification, or one from another sender, does nothing.**
- **While the app is open** a trip notification is still shown (banner, list, and sound).
- **The arrival time travels with the notification.** "I've left" is sent for the arrival time
  in the notification's payload, so an old notification cannot end the monitoring of a trip
  that was rescheduled since.
- **No background mode** is declared: the alerts are visible notifications and need none.

## 6. Configuration

| Setting | Where | Meaning |
| --- | --- | --- |
| Server address (user) | Settings > Data source > Server address | Overrides the built-in address; empty returns to it. Stored with the settings |
| Server address (build) | `WaitItOutUXPrototype/Info.plist`, key `WaitItOutBackendURL` | The built-in address: `http://localhost:3000`, a development server on the same machine as the simulator |
| `WAIT_IT_OUT_BACKEND_URL` | Launch environment | Replaces the built-in address for one launch. An unusable value leaves the app "Not configured" rather than falling back to another server |
| `WAIT_IT_OUT_DATA_MODE` | Launch environment | `demo` composes the standalone prototype with no backend (UI tests). Anything else, or nothing, composes the live backend |
| `WAIT_IT_OUT_STORAGE_FOLDER` | Launch environment | A separate storage folder, as before |

Addresses follow one rule everywhere (`BackendConfiguration.parse`): https, or plain http only
for `localhost`, a `.local` name, or an IP address; no path, query, or sign-in details. The
Info.plist allows local networking (`NSAllowsLocalNetworking`) and nothing else, so plain http
to a public host is refused by the system as well. **A real deployment uses https**; set its
address in Settings or in the Info.plist key.

On a physical device `localhost` is the device itself, so the built-in address reaches
nothing there: enter the server's address in Settings.

From the command line, against a server on this Mac:

```sh
xcrun simctl boot "iPhone 17"
xcodebuild build -project WaitItOutUXPrototype.xcodeproj -scheme WaitItOutUXPrototype \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath <derived data>
xcrun simctl install booted <derived data>/Build/Products/Debug-iphonesimulator/WaitItOutUXPrototype.app
SIMCTL_CHILD_WAIT_IT_OUT_BACKEND_URL=http://localhost:3000 \
  xcrun simctl launch booted com.waititout.uxprototype
```

## 7. Push setup (not done here)

**Which builds need a team.** A simulator build needs no Apple Developer team, and none is
written into the project. A build for a physical device does: the project carries the push
entitlement (`aps-environment`), so it can be signed only with a team whose App ID for this
bundle identifier has the Push Notifications capability. That means an Apple Developer
Program team; a free personal team cannot create such a profile, so with one the device build
stops at signing, even if only live recommendations are wanted. (Building without the
entitlement, for example by overriding `CODE_SIGN_ENTITLEMENTS` to empty on the command line,
should allow a personal team at the price of no alerts; this was not tried here.)

These steps have **not** been carried out or verified in this repository:

1. **An Apple Developer Program team.** Choose it in Xcode under Signing & Capabilities for
   the app target, or pass `DEVELOPMENT_TEAM=<team id> -allowProvisioningUpdates` to
   `xcodebuild`. Do not commit it: the structural checker refuses a team or a provisioning
   profile in the project file.
2. **A bundle identifier the team owns**, with the Push Notifications capability. The project
   uses `com.waititout.uxprototype` and already carries the entitlement
   (`WaitItOutUXPrototype.entitlements`, `aps-environment` = `development`), so automatic signing
   can create the profile. If the identifier changes, the server's push topic must change
   with it.
3. **An APNs authentication key** (.p8) from the same developer account, with its key id.
4. **The server's push settings**: the key, the key id, the team id, and the bundle id, plus
   the migration that creates the device and trip tables and the monitoring worker turned on.
   The variable names and their meaning are in the backend's own `.env.example`
   (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` or
   `APNS_PRIVATE_KEY_FILE`, `MONITOR`, `MONITOR_ALWAYS_ON`, `MONITOR_TICK_SECRET`). The key is
   a secret and belongs in no repository.
5. **A physical device** signed with that team, reachable server address entered in Settings,
   reminders turned on, and notifications allowed.

**The push environment follows the entitlement, not the build configuration.** The single
entitlements file says `development`, so every build made from this project, Debug or
Release, gets sandbox device tokens, and `SystemPushRegistrar.apnsEnvironment` reports
`"sandbox"` for both. A distribution build (TestFlight, App Store) needs the entitlement
changed to `production` **and** `apnsEnvironment` changed to `"production"` in the same change;
`scripts/check_project_structure.py` fails when the two disagree.

A server that sleeps when idle can only check traffic while it is awake. The app says so
("alerts can be late or missing when the app is closed") whenever the server reports that its
monitoring is not dependable.

## 8. End to end against the fixture server (opt-in)

`FixtureBackendEndToEndUITests` (in `WaitItOutUXPrototypeUITests/LiveModeUITests.swift`) drives
the real app over real HTTP against the backend's fixture server: the real routes and decision
code with simulated traffic and a recording push sender, all on this machine. Both tests are
skipped unless that server answers on `127.0.0.1:3100`, so an ordinary test run never needs it.

1. In the repository's `backend` folder: `npm run serve:fixture` (it listens on port 3100).
2. Run the class:

   ```sh
   xcodebuild test -project WaitItOutUXPrototype.xcodeproj -scheme WaitItOutUXPrototype \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -only-testing:WaitItOutUXPrototypeUITests/FixtureBackendEndToEndUITests
   ```

   Build with signing left on (no `CODE_SIGNING_ALLOWED=NO`): the app needs the Keychain for
   its server credential.

- `testBackendRecommendationReachesTheMapAndTripsReachTheServer` loads the samples, expects
  the backend's leave-home time on the Map labeled as test fixture traffic and the backend's
  route, turns leave-home alerts on, allows notifications, and expects the trips to reach the
  server. It skips itself when the next sample trip has no leave-home time at that hour
  (beyond the forecast, or its ideal arrival has just passed).
- `testClosedAppShowsAPushedAlertAndTappingItOpensTheTrip` additionally needs
  `E2E_CLOSED_APP=1` in the test runner's environment and someone to send the alert: it sets
  the app up in its default storage, closes it, prints `E2E_READY_FOR_PUSH`, and waits up to
  three minutes for a notification that names "Sample morning class". Send the payload the
  fixture server recorded (its `payload` object, saved to a file) with
  `xcrun simctl push booted com.waititout.uxprototype <file>`. Tapping the alert must open
  the trip's details with the same leave-home time the Map showed. Two screenshots are kept
  with the test results as attachments. Afterwards the test puts the default storage back
  (alerts off, samples cleared, the typed address removed).

These two tests are the only UI tests that turn alerts on (so the app registers with the
system's push service like any user's would) and the closed-app test is the only one that
launches in the app's default storage; see AGENTS.md, "Host rules". They check how the app
shows and handles a visible push, not delivery by Apple's push service.

## 9. What was verified, and what was not

Recorded on 2026-11-19, on a Mac with Xcode 27.2 and the iOS Simulator (iPhone 17). Nothing
here was run on a physical device. The first part records the review fixes, the newest
state of the code; the rest records stage S3 as it was run then, with the numbers of that
time.

**Review fixes: run, with these results**

- **Structural checker:** 0 errors and 0 warnings. Its tightened rules were tried in 12
  scratch copies with injected violations (the application singleton and a push registration
  in another host file; the networking session after a URL string on the same line, and its
  configuration type; a UI test application without its storage folder and data mode, and a
  live one without a server address; the session in a unit test and in another UI test file;
  the Info.plist or the entitlements missing from the Release configuration only; the Network
  framework, `Data(contentsOf:)`, and `AsyncImage` in a package source; the named bare launch
  removed without its entry). Every one produced an error, and the clean copy passed.
- **Unit tests** (`xcodebuild test -only-testing:WaitItOutUXTests`, `CODE_SIGNING_ALLOWED=NO`):
  845 tests, 0 failures, 1 skipped (the real-Keychain test, which cannot run in the package's
  test host). None opens a connection.
- **The real backend's answers decode.** `RealBackendShapesTests` embeds, verbatim, response
  bodies captured from the real backend code: four verdicts (leave later, leave now, late, no
  rush), a refused verdict request, a route, registration, the push report, a first and a
  repeated trip snapshot, a revision conflict, the trip list, one trip, a missing trip, "I've
  left" accepted and superseded, an unknown device, an unknown route, and the push payload;
  and one real answer of the team's currently deployed backend, which has no `source` field.
  Each goes through the same code as in the app (`BackendClient`, `BackendCommuteProvider`,
  `BackendRouteProvider`, `BackendSession`, `TripNotificationPayload`), and the mapped values
  are asserted: actions, times, lateness, margins, phases, limits, push status, monitor
  health, alert states, and error kinds. All 14 tests passed without a change to the decoding
  code. The bodies were captured before this stage and supplied as files; no request was made
  to a backend while these tests ran.
- **UI tests** (`-only-testing:WaitItOutUXPrototypeUITests`, `CODE_SIGNING_ALLOWED=NO`), one
  complete run: 25 tests, 15 passed, 8 failed, 2 skipped. The 13 earlier tests that pass on the
  unmodified project pass; the same 8 fail with the same messages (they had never been run
  before the integration started, and their failures are not caused by it); both
  `LiveModeUITests` pass; the 2 `FixtureBackendEndToEndUITests` were skipped because no fixture
  server was running.
- **Regression tests against their fixes.** Five of the new tests were also run with the
  matching fix switched off (the 15-minute rhythm, the rule for whose plan a screen shows, and
  the hand-back of an unconfirmed plan after a failed synchronization); all five failed, and
  pass with the fixes in place.

**Review fixes: not run**

- **The end-to-end tests against the fixture server** (section 8), including the closed-app
  notification test, and with them any request from the app to a running backend in this
  stage. Their code was changed here (screenshots as attachments, restoring the default
  storage, skipping when the next trip has no leave-home time) and compiles; it was not
  executed.
- **`SystemKeychain`'s listing of stored accounts**, which is how a server left behind is found
  after a restart on a real device. The logic around it is tested against a stand-in Keychain;
  the system call itself is covered only by the real-Keychain test, which is skipped in this
  test host.
- **The Settings minute tick, the editor's next-occurrence note, and the new sentences on
  screen**, by hand or by a UI test. They are covered by unit tests of the model and the pure
  presentation code.
- **The backend's two 503 codes against a real server.** The app's handling follows the
  agreed contract (`temporarily_unavailable`, `monitoring_unavailable`) and is tested with
  scripted answers; the backend side of that change was made in parallel and has not been
  run together with the app.
- Everything listed under "Not run" below, except that the wire format is now also covered
  by the captured bodies.

**Stage S3: run, with these results**

- **Structural checker:** `python3 scripts/check_project_structure.py` reports 0 errors and 0
  warnings. In a scratch copy, 22 violations were injected one at a time (a notification API
  in another host file and in the package, a missing allow-listed file, a usage description,
  a background mode, arbitrary loads, a public plain-http or path-carrying default address, a
  malformed Info.plist, an extra entitlement, the entitlement and the reported push
  environment disagreeing either way, a UI test without or with an unknown data mode, a live
  UI test naming a real server or no server, a second property list, the Info.plist not named
  or another one named by the project, the networking session in the host, a hard-coded
  team); each produced an error and the clean copy passed again.
- **Unit tests** (`xcodebuild test -only-testing:WaitItOutUXTests`, `CODE_SIGNING_ALLOWED=NO`):
  776 tests, 0 failures, 1 skipped. All of them use scripted transports or the in-memory
  stand-in for the server; none opens a connection. The skipped test is the real-Keychain
  test, which cannot run in the package's test host.
- **UI tests** (`-only-testing:WaitItOutUXPrototypeUITests`, `CODE_SIGNING_ALLOWED=NO`): 23
  tests, 15 passed and 8 failed. The 21 tests that existed before the integration run in the
  standalone demo composition and behave exactly as they did on the unmodified project: the
  same 13 pass and the same 8 fail with the same messages (they had never been run before the
  integration started, and their failures are not caused by it). The 2 new `LiveModeUITests`
  pass: launched in the live composition against a loopback port where nothing listens, the
  app shows "Live data", says the route could not be loaded and keeps the schematic label,
  shows no leave-home time and nothing simulated for the next trip, names the server without
  calling it connected, and brings the labeled simulation back only while the Demo data mode
  is chosen in Settings.
- **A simulator build with signing left on** (no `CODE_SIGNING_ALLOWED=NO`, no team): BUILD
  SUCCEEDED, signed "to run locally". The entitlements file and the partial Info.plist need no
  team for the simulator; the built Info.plist carries the generated keys plus
  `WaitItOutBackendURL` and `NSAllowsLocalNetworking`.
- **That build launched on the simulator in Live mode with nothing listening** (default
  composition, `WAIT_IT_OUT_BACKEND_URL=http://localhost:3100`): the Map showed "Live data"
  and, for the next sample trip, "The backend could not be reached. Check the connection. No
  leave-home time is shown." with Try Again; the places card said the driving route could not
  be loaded and the line stayed labeled schematic. No permission alert appeared.
- **That build against a stand-in server on the same Mac.** A throwaway local program answered
  the recommendation, device, and trip requests with made-up fixture values (it is not the
  team backend and is not in this repository). The Map showed the recommended departure, the
  predicted arrival, the server's sentence, "Test fixture traffic, not live" with a TEST DATA
  badge, and the confidence. With leave-home reminders on, the app registered once and
  synchronized its trips, and showed "Notifications have not been allowed for this app yet."
  with Allow Notifications. After a relaunch it synchronized with the stored credential and
  did not register again, which is the Keychain store working in the app. With reminders off
  it removed itself from the server, and a later launch with reminders on registered anew.
  Reminders were switched by editing the saved settings file between launches, not by tapping
  the toggle, and the permission prompt was never answered.

**Stage S3: not run**

- **Any request to the team backend**, deployed or local. At that time the wire format was
  covered only by tests against bodies shaped like the backend's and by the stand-in above;
  since the review fixes it is also covered by bodies captured from the real backend (above).
- **Anything involving Apple's push service.** No notification permission was granted, so the
  app never registered for remote notifications: no device token was obtained, no token was
  reported to a server, and no notification was received, shown, tapped, or answered with
  "I've left". The notification code paths (`AppDelegate`'s token and response handlers, the
  permission request in `SystemPushRegistrar`) compile and their decisions are unit-tested in
  the package, but the system has never called them.
- **A physical device**, a build signed with a development team, a Release build, and a
  distribution build with the production push entitlement.
- **Background behavior:** alerts arriving while the app is closed, a cold start from a
  notification, and what the server does while it sleeps.
- **The Data source controls by hand** beyond what `LiveModeUITests` drives (it switches the
  data mode; it does not type a server address), VoiceOver, large text sizes, iPad layouts, and
  Xcode previews of the new screens.

**Known limits of these checks**

- A build made with `CODE_SIGNING_ALLOWED=NO` (as the test commands use) has no Keychain
  access on the simulator. In such a build recommendations work, but turning reminders on
  ends in "Trips could not be synchronized: this device's server credential could not be read
  or saved." Build normally to try trip monitoring.
- On the iOS 27 simulator the navigation bar gives a leading item very little room. "Team
  backend" keeps its full width (the label read "Live data" in stage S3, as the record above
  says); the Demo data mode's older "Demo estimate" capsule is cut down to its icon there,
  while its spoken label and the TEST DATA badges on the cards are unaffected.
- What the next sample trip shows depends on the time of day, so the live UI tests accept
  every honest outcome for the trip card: a failed request, "The traffic forecast reaches
  about 11.5 hours ahead...", or "The ideal arrival time has passed." in the 45 minutes
  between a sample activity's ideal arrival and its start.
- The captured bodies are a snapshot. When the backend's responses change they have to be
  captured again and replaced verbatim; nothing regenerates them automatically.
