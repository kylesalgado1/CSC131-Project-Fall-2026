# Leave-home reminders: the `ReminderScheduling` boundary

Step 0007 added leave-home reminders to the prototype as **in-app previews only**. That is
still exactly what the Demo data mode does, and what a host without a live backend does:
nothing asks for notification permission, hands anything to the system's notification
service, or delivers anything in the background, and every place a reminder appears says
"Preview only - no system notification will be sent."

Since stages S2 and S3 the app's normal flow is different: with the team backend in use, the
**server** monitors the upcoming trips and sends push alerts, the app schedules no local
reminder at all, and the screens show the server's state instead of a preview. That is
described under "With the team backend: server-side monitoring" below. The two never run at
once.

## What a reminder is

- One reminder per saved occurrence, keyed by the occurrence's stable `OccurrenceID`
  (activity id plus local start day; see `ActivityOccurrence.swift`). The same occurrence gets
  the same id in every expansion and after every relaunch, so reconciliation never duplicates.
- It is due at the occurrence's calculated **leave-home time** (ideal arrival minus the
  validated travel time, `DepartureCalculator`). Nothing else is added or subtracted. For a
  backend recommendation (stage S1) it is due at the recommended departure exactly as the
  backend gave it, and its message names the backend's source instead of a travel-time formula
  ("... by your ideal arrival, 8:15 AM. Live traffic (TomTom) via the team backend."). A
  recommendation kept after a failed refresh (`.stale`) is not current and earns no reminder.
- `ScheduledReminder` carries `id`, `fireDate`, `title` ("Time to leave for Sample morning
  class"), and `message` ("Leave home at 7:15 AM to reach Sample campus by your ideal arrival,
  8:15 AM. Travel time 1 hour (simulated test estimate, not live traffic)."). `identifier` gives a
  string such as `leave-home.<uuid>@2026-11-02` for a system notification request.

## Who decides what

| Piece | Kind | Responsibility |
| --- | --- | --- |
| `UserPreferences.leaveHomeRemindersEnabled` | Stored preference | The user's wish. Saved in `preferences.json`; never says whether a reminder exists. |
| `ReminderPlan.make` | Pure function | Which reminders should exist now: saved occurrences inside `DepartureHorizon` (7 days) that have not started, with a current (`.success`) calculation whose leave-home time is still ahead; at most `ReminderPlan.maximumCount` (20). It also records why the next trip has no reminder (`ReminderGap`). |
| `ReminderChanges.between` | Pure function | The difference between what the adapter holds and the plan: schedule missing or changed reminders, cancel unwanted, past, and duplicate ones, keep a held one. Applying it and reconciling again yields no changes. |
| `WaitItOutModel.reconcileReminders` | Model | Runs the plan and the difference against the adapter, one reconciliation at a time, always with the newest plan. |
| `reminderSync`, `reminderPreviews` | Model state, never stored | Delivery status: `idle`, `updating`, `synced`, `failed`, or `paused`, and what the adapter reported last. |
| `ReminderScheduling` | Protocol | The adapter: stores, replaces, and removes what it is given. No policy. |

Desired preference and delivery status are deliberately separate: turning reminders on while
the adapter fails shows "Reminder previews could not be updated" with Try Again, and the
preference stays on; turning them off while the adapter fails says the earlier previews could
not be removed.

## The protocol

```swift
public protocol ReminderScheduling: Sendable {
    var delivery: ReminderDelivery { get }                       // .inAppPreview or .systemNotification
    func pendingReminders() async throws -> [ScheduledReminder]  // everything the adapter holds
    func schedule(_ reminders: [ScheduledReminder]) async throws // add, or replace by id
    func cancelReminders(withIDs ids: Set<OccurrenceID>) async throws // unknown ids are ignored
}
```

- Every method may do I/O; the model calls them off the main actor and applies the outcome on
  the main actor.
- `delivery.disclosure` is the sentence the UI shows under every reminder. The prototype's
  adapter returns `.inAppPreview`, whose disclosure is "Preview only - no system notification
  will be sent." The UI never words a preview as a notification.
- Throwing from any method marks the reconciliation as failed. The model keeps the user's
  preference, shows the failure, and offers Try Again; it never retries on its own in a loop.

## When reconciliation runs

- After every leave-home refresh and every estimate that arrives. This covers saving,
  editing, and deleting activities, loading and clearing samples, changing the test duration
  or scenario, editing home or campus, and the Map's and Calendar's minute ticks (a reminder
  that falls due drops out). A refresh whose plan is unchanged since the last successful
  reconciliation does nothing.
- When reminders or the failure simulation are toggled, on Try Again, after the schedule
  loads at launch (so a relaunch recreates previews and cleans up stale ones in a persistent
  adapter), and when the app returns to the foreground (`WaitItOutRootView` calls
  `appDidBecomeActive()`). These always re-read the adapter.
- Never before the schedule has been read once, and never while it cannot be read
  (`reminderSync == .paused`): reconciling against an empty list would remove reminders that
  are still valid.
- While the settings file cannot be read, default settings apply (Settings > Saved data says
  so), so reminders count as off and reconciliation removes pending ones until Try Again reads
  the saved wish again or the user turns reminders back on. The in-app preview adapter starts
  empty at every launch, so the prototype loses nothing. A team adapter that keeps system
  reminders across launches can pause on `preferencesStorageIssue` as well, the way
  `WaitItOutModel+Reminders.swift` pauses on `activityStorageIssue`.
- While a trip's estimate is being refreshed for the same trip (`DepartureState.refreshing`),
  a reminder already pending for it is kept and marked "Out of date: updating" until the new
  estimate arrives. A trip without an estimate in this launch (`.loading`, such as a changed
  trip or every trip right after launch) gets no reminder until its estimate arrives.
  Estimates are never stored, so no reminder is ever based on a time from an earlier launch:
  with a persistent system adapter, the launch reconciliation removes each reminder and the
  arriving estimate puts it back (or leaves it out, with the reason, when the estimate is
  unavailable or fails). A team that prefers to keep earlier system reminders while launch
  estimates load can treat `.loading` like `.refreshing` in `ReminderPlan.make`.

When no preview can be created, the preview says why: nothing saved in the next 7 days, the
estimate is still loading, the provider gave no estimate (Unavailable scenario, no
destination), the estimate failed (Error scenario, with Try Again on the trip), or the
leave-home time has already passed.

## The prototype adapter: `PreviewReminderScheduler`

- Keeps reminders in memory, thread-safe behind a lock, for the life of the process. After a
  relaunch it starts empty and the launch reconciliation recreates the previews.
- Deterministic failure simulation for Settings > Prototype testing > "Simulate reminder
  failure": while on, every call throws `PreviewReminderSchedulerError` and changes nothing,
  so Try Again keeps failing; turning it off reconciles at once. The setting is stored with
  the other Prototype testing values, and "Reset to Normal, 60 Minutes" turns it off.

## With the team backend: server-side monitoring (stages S2 and S3)

When the host passes a `LiveBackend` with a `TripMonitoring` service and the data mode is Live,
leave-home alerts are the server's job: it watches traffic for the user's upcoming trips and
sends push notifications. The preview adapter above is then not used at all, and the app
schedules no local reminder, so local and remote reminders never compete. The same Settings
toggle (`UserPreferences.leaveHomeRemindersEnabled`) is the wish in both modes. The Demo data
mode works exactly as described above, and the server holds no trips for it.

| Piece | Kind | Responsibility |
| --- | --- | --- |
| `WaitItOutModel.monitoredTrips(for:home:resolve:now:limit:)` | Pure function | Which trips the server should monitor: saved occurrences inside `DepartureHorizon` whose ideal arrival is ahead and whose destination is usable, built exactly like the requests the screens make, ordered by ideal arrival, at most 20 (or the server's own limit). Sample activities are included. |
| `WaitItOutModel.reconcileMonitoring` | Model | Keeps the service in line with the wanted set: one reconciliation at a time, always the newest set. Called from `reconcileReminders`, so it shares every trigger listed above. |
| `monitoringStatus` | Model state, never stored | `off`, `paused` (saved activities unreadable; the server is left untouched), `settingsUnreadable` (saved settings unreadable; the server is left untouched), `pending` (not acknowledged yet), `active(acknowledgedAt:tripCount:)`, `failed(failure, lastAcknowledgedAt:)`. |
| `monitoredTrips`, `pushDelivery`, `monitorHealth`, `monitoringLimits` | Model state, never stored | What the server last reported: each trip's phase, plan, and alert times; whether alerts can reach this device; whether its monitoring worker is dependable; its own lead times. |
| `TripMonitoring` | Protocol | The service: `synchronize` (the complete set, idempotent), `refresh`, `refreshTrip`, `markDeparted`, `unregister` (remove the installation), `withdrawTrips` (an empty set under the existing credential, never a registration), `serversLeftBehind` (other servers that still hold a credential), and the notification permission calls. `BackendSession` implements it. |
| `PushRegistering` | Protocol | The host's adapter over the system notification and application APIs (`SystemPushRegistrar` in the prototype host). The package never names those APIs. |
| `MonitoringPresentation`, `MonitoringStatusView` | Pure value and view (stage S3) | What the Settings reminders section and the Map card show in Live mode: one delivery sentence that never promises delivery, the lines under it, and which of Try Again, Allow Notifications, and Open Settings are offered. The Live counterpart of `ReminderPreview` and `ReminderPreviewView`. |
| `TripDepartedControl` | View (stage S3) | "I've Left" in the Calendar details and on the Map card, with its outcome. |

Rules the model follows:

- **Nothing before the schedule is read**, and nothing while it cannot be read: an empty list
  would cancel every trip the server still monitors.
- **Pending until acknowledged.** The status is `active` only after the server acknowledged
  exactly the trips wanted now. A change made while a request is under way keeps it `pending`
  until the newest set is acknowledged as well.
- **Unreadable settings pause everything.** While `preferencesStorageIssue` is set and the
  user has not chosen the toggle, the data mode, or the server address anew in this session,
  the settings in effect are defaults (alerts off, the built-in server), not the user's wish.
  The model then neither withdraws the installation nor synchronizes, and does not tell any
  other server to forget it; the status is `settingsUnreadable` and the screens say that
  alerts the user had turned on may still arrive.
- **Failures.** A transient failure (no connection, a timeout, a server error including the
  server's 503 `temporarily_unavailable`) is tried again by the next minute tick once 60
  seconds have passed, and at once by a forced call (launch, foreground, a toggle). A server
  without monitoring (503 `monitoring_unavailable`, or one that predates the endpoints) is
  asked again only by a forced call or Try Again. A set the server refused waits for Try Again
  (`retryMonitoring()`) or a change. The minute ticks are the Map's, the Calendar's, and, in a
  host with a live backend, the Settings tab's.
- **Withdrawal is real work.** Turning reminders off, choosing the Demo data mode, or changing
  the server address removes this installation from the server (`unregister`). The credential
  is dropped only when the server confirmed (204), no longer knows the device (401), or
  predates the endpoints; after any other answer it is kept. When the removal fails, an empty
  set under the same credential at least stops the alerts (`withdrawTrips`, which never
  registers a device and reports no push token); when that fails too, `monitoringWithdrawal`
  is `failed` and it is tried again: on the ticks after a transient failure, otherwise on the
  next forced call or Try Again, and the sentence on screen says which. A server left behind
  by an address change that could not be told sets `previousServerMayStillAlert` ("The
  previous server may still send alerts for a while."). It is found again after a restart,
  because its credential is still in the store (`serversLeftBehind`).
- **How far ahead.** The wanted set is the next 7 days, at most 20 trips, and it is sent only
  while the app is open (launch, foreground, changes). Nothing is sent from the background, so
  alerts stop for later trips until the app is opened again. `monitoringCoverageEnd` is the
  arrival of the last trip the server acknowledged; Settings shows it ("Alerts are set up for
  trips through <day>. Open the app again before then to keep them coming.") and the footer
  states the rule.
- **Reading the server's state.** While a trip is being planned or monitored, or has reached a
  time the server named, the minute ticks call `refresh` once the last snapshot is 60 seconds
  old. A snapshot changes only the departures whose monitored plan changed, where "monitored
  plan" means the plan the server still keeps current (`MonitoredTripState.currentPlan`: the
  monitoring phase, a running worker, not stale, a departure still ahead, no time-to-leave or
  late alert yet). A plan that stops being current is handed back to a direct request.
- **"I've left" follows the server.** A recorded success (`DepartedState.done`) is kept only
  while the server reports the trip as left. When the trip is rescheduled, or the device is
  registered anew, the server monitors it again and the record is dropped.
- **Permission.** Turning reminders on in Live mode asks for notification permission through
  the service; launch and foreground re-check it and register for push again, without
  prompting. The server is told the outcome with the next synchronization.

What the screens can say comes from pure helpers. `monitoringObstacle` is `nil` only when the
server acknowledged the trips, it has push credentials and a token for this device, the user
allows notifications, and its monitoring worker runs dependably; then the sentence is "The
server is monitoring your upcoming trips and will try to alert you. Delivery is not
guaranteed." Otherwise the exact obstacle is named, for example "Notifications are off for this
app in iOS Settings.", "This device is not registered for push notifications yet.", "The
server has no push credentials, so alerts cannot be delivered.", "Waiting for the server to
confirm monitoring.", "Trips could not be synchronized: the backend could not be reached.",
"This server is not running trip monitoring.", or "This server only checks traffic while it is
awake, so alerts can be late or missing when the app is closed." Per trip,
`monitoringSummary(for:)` and `OccurrenceFormatter.monitoringLines(for:at:)` give, before the
server monitors the trip, lines relative to the departure ("Monitoring starts about 2 hours
before the recommended departure.", "Heads-up about 90 minutes before the recommended
departure.", "Time-to-leave alert at the recommended departure."): the screens then show a
direct answer, and the server's stored times are not printed beside it. Once it monitors the
trip: "Monitoring started 5:05 AM.", "Heads-up about 5:35 AM." or "Heads-up sent 5:36 AM." (only
with the server's own stamp), and "Time-to-leave alert at the recommended departure, currently
7:05 AM." while that departure is ahead. No coming alert is promised for a departure that has
passed, after a late alert ("Late alert sent 5:45 AM."), or while the plan cannot meet the
arrival. An alert that was not sent reads "Heads-up queued; not sent yet." or "The last alert
could not be sent: reason". A state that could not be read again for three minutes shows no
alert times at all. Nothing is ever called delivered.

When the server itself reports a problem with a trip (`MonitoringSummary.hasServerProblem`),
alerts are not described as active for it, whatever the delivery path looks like: the
sentence is "Alerts are not active for this trip right now." (in Settings, "The server
confirmed your trips, but alerts are not active for the next one right now."), and the trip's
line says why. By the server's `lastError.code`: `no_coverage`, "The server has no traffic
data for this route, so it cannot plan or alert for this trip."; `budget_exhausted`, "The
server has used up its traffic checks for today, so this trip is not being re-checked. A
time-to-leave alert is still sent from the last plan, if there is one."; `routing_unavailable`,
`internal`, and any other code, "The server could not check traffic for this trip just now.
It keeps trying." For a trip without a plan and with the server's own `noPlanReason`: that
sentence, verbatim, for two minutes after the app saw it appear (it is worded relative to
when it was written), and "The server has no departure to recommend for this trip yet."
afterwards or when its age is unknown.

"I've left" (`markDeparted(_:arriveBy:)`) is published per trip as `DepartedState`: "Telling the
server…", "Marked as left. Monitoring ended for this trip.", "This trip was rescheduled;
monitoring continues for the new time.", or "Could not tell the server you left; it may still
send alerts for this trip."

### What the screens show (stage S3)

- **Settings, Leave-home reminders.** In Live mode the section has no PREVIEW badge, its footer
  describes the server's monitoring in the server's own numbers (`MonitoringText.remindersFooter`
  from `MonitoringLimits`: by default monitoring starts about 2 hours before the recommended
  departure, a heads-up about 90 minutes before, updates only for changes of at least 5
  minutes, then a time-to-leave alert), says that delivery is best effort and needs
  notification permission, says how far ahead alerts reach ("The app sends your trips for the
  next 7 days (at most 20) to the server each time it is opened or brought to the foreground,
  so alerts stop for later trips unless you open the app again."), and states the retention:
  trips are removed from the server after they end, and turning reminders off deletes this
  installation's data from the server. The body is `MonitoringStatusView`, which in Settings
  also names the day alerts are set up through. In the Demo data mode the section is word for
  word what it was, with `ReminderPreviewView`.
- **Map card.** The compact `MonitoringStatusView` for the card's own trip, where the Demo data
  mode shows the compact preview.
- **Permission.** "Allow Notifications" appears while the permission has not been decided and
  the server has answered or failed; after a refusal the text is "Notifications are off for
  <app name>. Turn them on in iOS Settings to get alerts." with "Open Settings". Neither
  appears while the server is still being asked, so a button cannot flash at launch for a
  permission that is already granted.
- **The server's plan is hidden while delivery is blocked.** "Monitoring starts...", "Heads-up..."
  and "Time-to-leave alert..." are listed only when nothing keeps alerts from reaching the
  device, or the only caveat is a server that checks while it is awake, or the trip is over.
- **"I've Left"** in the Calendar details and on the Map card, while the server monitors the
  trip or has sent its time-to-leave alert. It sends the occurrence's own ideal arrival, has no
  confirmation, and reads "Try Again" after a failure.
- **A tapped notification** opens the Calendar on the trip's day and its details
  (`tripToPresent`, consumed through `TripPresentationStep`: only once the schedule is loaded and
  no editor is open).

### The host's side (stage S3)

The prototype host implements the system half in two files, the only ones allowed to name the
notification APIs (`scripts/check_project_structure.py` enforces it):

- `SystemPushRegistrar` reads and requests the permission (alerts and sounds; provisional and
  ephemeral authorizations count as allowed) and registers with the push service. When that
  registration fails, the system's reason is shown as this device's failure ("This device
  could not register for push notifications (reason)."), never as a send the server attempted.
- `AppDelegate` registers the trip category with its one "I've left" action, forwards the
  device token to `BackendSession`, shows trip notifications that arrive while the app is open,
  and hands a response to the model: `prepareForNotificationResponse()`, then
  `handleNotificationAction(tripID:action:arriveBy:)`, then the system's completion handler.
  A dismissal or another sender's notification does nothing
  (`TripNotificationPayload.response`).
- **"I've left" opens the app.** The action carries the foreground option, so the request to
  the server is made by the visible app, with the outcome on screen. Nothing is sent from the
  background, and no background mode is declared.
- With `WAIT_IT_OUT_DATA_MODE=demo` the host composes no backend, and none of this code runs.

Push delivery has not been verified: it needs a server with push credentials and a device,
and a device build of this project needs a team whose App ID has the Push Notifications
capability (an Apple Developer Program team), because the project carries the push
entitlement. A simulator build needs no team. See
[`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md).

## Providing a local-notification implementation instead

This section is about the `ReminderScheduling` boundary only, for a team that wants reminders
scheduled on the device rather than sent by the server. The prototype host does not do this:
in Live mode its alerts are the server's push notifications described above.

The team's adapter replaces `PreviewReminderScheduler()` in the host's composition root
(`WaitItOutUXPrototype/AppDependencies.swift`, or the team app's equivalent). Nothing in the
package changes. An adapter over `UNUserNotificationCenter` would:

1. Return `.systemNotification` from `delivery`, so the UI stops saying "Preview only".
2. Request authorization at a moment the team chooses (for example when the user turns
   reminders on), and throw from `schedule` when authorization is denied so the UI shows the
   failure and Try Again. The preview adapter deliberately never requests permission.
3. Map `schedule` to `UNNotificationRequest(identifier: reminder.identifier, content:
   trigger:)` with a `UNCalendarNotificationTrigger` built from `fireDate` in the device's
   calendar (or a `UNTimeIntervalNotificationTrigger` for the elapsed interval), title and
   body from the reminder; adding a request with an existing identifier replaces it.
4. Map `pendingReminders` to `pendingNotificationRequests()`, keeping only identifiers with
   the `leave-home.` prefix and parsing the occurrence id back with `OccurrenceID(rawValue:)`.
   Store the fire date in `userInfo` so the reminder can be rebuilt exactly; otherwise the
   difference sees a changed reminder and replaces it, which is harmless.
5. Map `cancelReminders` to `removePendingNotificationRequests(withIdentifiers:)` (and
   `removeDeliveredNotifications` if delivered ones should disappear).
6. Keep within the system limit of 64 pending requests per app; the plan never asks for more
   than 20.

Because the model reconciles at launch, on foreground, and after every change against
whatever the adapter reports, a persistent system adapter needs no migration: stale requests
from an earlier launch (deleted activities, changed times, past reminders, duplicates) are
removed by the first reconciliation after the schedule loads.

Tests for a team adapter can reuse the model tests in
`Packages/WaitItOutUX/Tests/WaitItOutUXTests/WaitItOutModelReminderTests.swift`, which run
against `RecordingReminderScheduler`, a persistent fake that can start with stale,
duplicate, and past reminders.
