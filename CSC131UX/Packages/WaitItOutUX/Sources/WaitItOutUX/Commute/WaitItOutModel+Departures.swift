import Foundation

/// One leave-home calculation and the request it answers.
public struct DepartureEntry: Equatable, Sendable {
    public let request: CommuteRequest
    public internal(set) var state: DepartureState
    /// Provider-settings revision the request was made under. A settings change makes the
    /// entry stale, so the next refresh asks again.
    let revision: UInt64
    /// Unique per request. An answer is applied only while its entry still holds this token,
    /// so a late or out-of-order answer for a superseded request is dropped.
    let token: UInt64
    /// When the request was made, on the injected clock. The live backend's automatic retries
    /// are timed from it.
    let attemptedAt: Date
    /// 1 for a first ask; one more for each automatic retry of the same failed trip, which
    /// lengthens the wait before the next one (`DepartureRetry`).
    let attempt: Int
}

/// When the live pipeline asks again by itself after a transient failure: 1 minute after the
/// first failed attempt, 2 minutes after the second, then every 5 minutes. The minute ticks
/// drive it, so a sleeping server or a lost connection recovers without Try Again. The demo
/// provider's errors are never retried automatically.
public enum DepartureRetry {
    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1:
            return 60
        case 2:
            return 2 * 60
        default:
            return 5 * 60
        }
    }
}

/// The Map's next trip: the first saved upcoming occurrence that has not started yet.
public struct NextTrip: Equatable, Sendable {
    public let occurrence: ActivityOccurrence
    public let state: DepartureState
}

/// Leave-home times (step 0005). The model asks the active `CommuteEstimating` provider for
/// every saved occurrence inside `DepartureHorizon` and for the pending draft. A demo estimate
/// goes through leave home = ideal arrival - travel time; a backend recommendation is shown as
/// the backend gave it, with no local arithmetic. Departures are never stored on an activity
/// and never edited; they are recalculated whenever an input changes:
/// - after every activity reload (load, save, delete, sample load or clear), which covers
///   arrival, time, destination, and repeat edits as well as deletions;
/// - after the Settings test duration changes;
/// - on the Calendar's and Map's minute ticks, so occurrences entering the horizon get one
///   and estimates older than `EstimateFreshness.lifetime` are refreshed (step 0006);
/// - after the Settings scenario or home and campus change (step 0006);
/// - after every draft change, for the editor's read-only preview.
/// Every change to `departures` also reconciles leave-home reminders (step 0007).
/// Requests whose inputs are unchanged keep their result. Superseded requests are cancelled,
/// and their answers are dropped by token, so a slow answer never overwrites a newer one.
/// When the same trip is asked again (new provider settings or a stale estimate), the earlier
/// calculation stays visible as `.refreshing`, marked out of date, until the answer arrives.
///
/// With the live backend: a refresh that fails keeps the last recommendation as `.stale`
/// (never as current), transient failures are retried on the minute ticks with a backoff, a
/// "not yet" answer is asked again when its time comes, and a change of data mode or server
/// address clears every result first, so nothing from one source is shown under the other.
/// A nearby departure is asked again one backend slot after it was last asked
/// (`EstimateFreshness.nearLifetime`), so its time holds still while traffic does.
/// While the server keeps a monitored plan current, that plan is what the screens show; such
/// an answer is asked again only when the server's state for that trip changes
/// (`invalidateDepartures(for:)`), when its departure has passed, or when it can no longer be
/// vouched for.
///
/// The editor's preview asks about the draft's first occurrence. With the live backend, a
/// repeating draft whose first occurrence has passed is previewed through its next upcoming
/// occurrence instead (`draftCommuteRequest(for:at:)`), and a request caused by a draft change
/// waits `liveDraftDebounce` first, so a drag or a turning picker asks once, for the value it
/// settles on. The demo preview asks at once, as before.
extension WaitItOutModel {
    // MARK: Saved occurrences

    /// Re-plans leave-home times for the saved upcoming occurrences at the current time. Keeps
    /// results whose request and provider settings are unchanged, starts a request for
    /// anything new or changed, and cancels requests for occurrences that were deleted,
    /// edited, or left the horizon. Cheap when nothing changed.
    public func refreshDepartures() {
        refreshDepartures(retryingFailures: false)
    }

    /// How long a live preview request waits after the draft change that caused it: 600
    /// milliseconds. A newer change cancels the wait, so only the last one is sent.
    public nonisolated static let liveDraftDebounce: Duration = .milliseconds(600)

    /// Try Again: asks the provider again for every failed calculation, including the
    /// editor's preview. Answers without an estimate are not retried (see `isRetryable`).
    /// Under a plan the server itself could not refresh, asking the provider alone would only
    /// read the same snapshot again, so that trip's state is read from the server first
    /// (`refreshMonitoredTrip`), which then asks for its leave-home time once more.
    public func retryDepartures() {
        let unrefreshedByServer = departures.filter { entry in
            if case .stale(_, .staleServerData) = entry.value.state { return true }
            return false
        }
        refreshDepartures(retryingFailures: true)
        syncDraftDeparture(force: draftDeparture?.state.isRetryable ?? false)
        for id in unrefreshedByServer.keys {
            refreshMonitoredTrip(id)
        }
    }

    /// The leave-home state for `occurrence` at the current time. Saved upcoming occurrences
    /// read their calculation; others say why there is none.
    public func departureState(for occurrence: ActivityOccurrence) -> DepartureState {
        departureState(for: occurrence, at: currentDate())
    }

    public func departureState(for occurrence: ActivityOccurrence, at now: Date) -> DepartureState {
        // Checked first, so an occurrence that ended since the last tick says so at once.
        if occurrence.end <= now {
            return .unavailable(.activityEnded)
        }
        if let entry = departures[occurrence.id], entry.request == commuteRequest(for: occurrence) {
            return entry.state
        }
        guard activities.contains(occurrence.activity) else {
            return .unavailable(.unsavedChanges)
        }
        guard DepartureHorizon.covers(occurrence, at: now) else {
            return .unavailable(.beyondHorizon)
        }
        // Inside the horizon but not requested yet: the next refresh starts it.
        return .loading
    }

    /// The trip the Map summarizes at `now`, or `nil` when nothing saved starts within the horizon.
    public func nextTrip(at now: Date) -> NextTrip? {
        let upcoming = DepartureHorizon.upcomingOccurrences(of: activities, at: now)
        guard let occurrence = DepartureHorizon.nextTrip(in: upcoming, at: now) else { return nil }
        return NextTrip(occurrence: occurrence, state: departureState(for: occurrence, at: now))
    }

    /// The Map's calendar setup action for an empty schedule: shows the Calendar on today and
    /// opens the editor for a new activity. With a change already pending it only switches tabs.
    public func startCalendarSetup() {
        selectedTab = .calendar
        guard editSession == nil else { return }
        showCurrentWeek()
        beginNewActivity()
    }

    /// Waits for every running leave-home request. Tests use this; the UI never needs to.
    public func waitForDepartures() async {
        for task in Array(departureTasks.values) {
            await task.value
        }
        await draftDepartureTask?.value
    }

    /// `retryingFailures` is Try Again: every failed calculation is asked again.
    /// `skippingBackoff` is the return to the foreground: with the live backend, transient
    /// failures are asked again at once instead of waiting for their backoff.
    func refreshDepartures(retryingFailures: Bool, skippingBackoff: Bool = false) {
        let now = currentDate()
        let upcoming = DepartureHorizon.upcomingOccurrences(of: activities, at: now)
        var next: [OccurrenceID: DepartureEntry] = [:]
        for occurrence in upcoming {
            let request = commuteRequest(for: occurrence)
            let existing = departures[occurrence.id]
            if let existing,
               existing.request == request,
               existing.revision == commuteRevision,
               !needsNewRequest(existing, at: now, retryingFailures: retryingFailures, skippingBackoff: skippingBackoff) {
                next[occurrence.id] = existing
                continue
            }
            departureTasks[occurrence.id]?.cancel()
            departureTasks[occurrence.id] = nil
            let entry = makeDepartureEntry(for: request, replacing: existing, at: now, isUserRetry: retryingFailures)
            next[occurrence.id] = entry
            if entry.state.isLoading {
                departureTasks[occurrence.id] = startDepartureRequest(request, token: entry.token)
            }
        }
        let superseded = departureTasks.keys.filter { next[$0] == nil }
        for id in superseded {
            departureTasks[id]?.cancel()
            departureTasks[id] = nil
        }
        if next != departures {
            departures = next
        }
        refreshLiveDraftDeparture(at: now, skippingBackoff: skippingBackoff)
        retryRouteIfDue(at: now)
        reconcileReminders()
    }

    /// True when a kept entry must be asked again at `now`: Try Again on a failure, a stale
    /// calculation, a "not yet" answer whose time has come, or, with the live backend only, a
    /// transient failure whose backoff has passed. An entry whose request is in flight is kept.
    private func needsNewRequest(_ entry: DepartureEntry, at now: Date, retryingFailures: Bool, skippingBackoff: Bool) -> Bool {
        if retryingFailures, entry.state.isRetryable { return true }
        if let calculation = entry.state.calculation,
           EstimateFreshness.needsRefresh(calculation, at: now, askedAt: entry.attemptedAt) {
            return true
        }
        if showsExpiredMonitoredAnswer(entry, at: now) { return true }
        if case .unavailable(.notYetPlannable(_, let askAgainAt)) = entry.state, now >= askAgainAt { return true }
        guard usesLiveBackend, let failure = entry.state.failure, failure.isTransient else { return false }
        return skippingBackoff || now.timeIntervalSince(entry.attemptedAt) >= DepartureRetry.delay(afterAttempt: entry.attempt)
    }

    /// True when `entry` shows a leave-home time taken from the server's monitored plan and
    /// that plan can no longer be vouched for: the server's state has not been read for longer
    /// than `MonitoringSnapshot.lifetime`, or monitoring ended. A monitored recommendation
    /// whose departure is ahead is not re-asked by age (the server pushes its changes), so this
    /// is what hands the trip back to a direct request instead of leaving an old plan on screen
    /// as current.
    private func showsExpiredMonitoredAnswer(_ entry: DepartureEntry, at now: Date) -> Bool {
        let shown: DepartureCalculation?
        switch entry.state {
        case .success(let calculation):
            shown = calculation
        case .stale(let calculation, .staleServerData):
            shown = calculation
        case .loading, .refreshing, .unavailable, .error, .stale:
            shown = nil
        }
        guard shown?.recommendation?.isMonitored == true else { return false }
        return monitoredAnswersExpired(at: now)
    }

    /// Asks again for exactly these saved occurrences, because what the server reports about
    /// their monitored trips changed. Each keeps its earlier calculation visible as
    /// `.refreshing`, marked out of date, until the answer arrives; every other occurrence is
    /// left alone. The editor's preview follows when it is for one of them.
    func invalidateDepartures(for ids: Set<OccurrenceID>) {
        guard !ids.isEmpty else { return }
        let now = currentDate()
        var next = departures
        for id in ids {
            guard let existing = departures[id], existing.revision == commuteRevision else { continue }
            departureTasks[id]?.cancel()
            departureTasks[id] = nil
            let entry = makeDepartureEntry(for: existing.request, replacing: existing, at: now, isUserRetry: true)
            next[id] = entry
            if entry.state.isLoading {
                departureTasks[id] = startDepartureRequest(existing.request, token: entry.token)
            }
        }
        if next != departures {
            departures = next
            reconcileReminders()
        }
        if let draft = draftDeparture, ids.contains(draft.request.occurrenceID), draft.revision == commuteRevision {
            syncDraftDeparture(force: true, isUserRetry: false)
        }
    }

    /// With the live backend, the editor's preview follows the same rules as the saved trips on
    /// every tick: it is asked again after a transient failure, when a "not yet" answer comes
    /// due, when its recommendation is stale, and when a repeating draft moved on to its next
    /// occurrence. The demo preview is left alone, as before.
    private func refreshLiveDraftDeparture(at now: Date, skippingBackoff: Bool) {
        guard usesLiveBackend, let entry = draftDeparture, entry.revision == commuteRevision else { return }
        if let draft = editSession?.draft, draftCommuteRequest(for: draft, at: now) != entry.request {
            syncDraftDeparture(force: true, isUserRetry: false)
            return
        }
        guard needsNewRequest(entry, at: now, retryingFailures: false, skippingBackoff: skippingBackoff) else { return }
        syncDraftDeparture(force: true, isUserRetry: false)
    }

    // MARK: Draft preview

    /// The trip the editor's preview asks about at `now`. In the Demo data mode, and for a
    /// one-time draft, that is the draft's first occurrence, as the editor shows it. With the
    /// live backend, a repeating draft whose first ideal arrival has passed is asked about
    /// through its next upcoming occurrence: the backend plans real trips, and the series goes
    /// on, so "the ideal arrival has passed" would be true of the first occurrence only.
    func draftCommuteRequest(for draft: ActivityDraft, at now: Date) -> CommuteRequest {
        guard usesLiveBackend, let next = nextDraftOccurrence(of: draft, at: now) else {
            return commuteRequest(for: draft)
        }
        return CommuteRequest(occurrence: next, origin: places.home, destination: resolvedDestination(draft.destination))
    }

    /// The next occurrence of a repeating draft whose first ideal arrival has passed at `now`,
    /// or `nil` for a one-time draft, a series that has not begun, and a draft that has no
    /// further occurrence (one that would not pass validation).
    func nextDraftOccurrence(of draft: ActivityDraft, at now: Date) -> ActivityOccurrence? {
        guard draft.isRecurring, draft.idealArrival <= now else { return nil }
        // A weekly series has an arrival ahead within any seven days; one more day covers an
        // arrival that falls exactly on the window's end.
        let window = now..<now.addingTimeInterval(DepartureHorizon.lookahead + 24 * 3_600)
        return OccurrenceExpander.occurrences(of: draft.activity, in: window).first { $0.idealArrival > now }
    }

    /// The occurrence the editor's preview is about when that is not the draft's first one
    /// (see `draftCommuteRequest(for:at:)`), so the editor can say which day the time is for.
    public var draftPreviewOccurrence: ActivityOccurrence? {
        guard let draft = editSession?.draft, let entry = draftDeparture, usesLiveBackend,
              let next = nextDraftOccurrence(of: draft, at: entry.attemptedAt),
              next.id == entry.request.occurrenceID else {
            return nil
        }
        return next
    }

    /// Keeps `draftDeparture` in step with the pending draft. Called after every draft change;
    /// does nothing while the draft's destination and arrival and the provider settings are
    /// unchanged, so typing a title never re-requests. With the live backend a request caused
    /// by a draft change (not `force`: Try Again, a tick, a changed server plan) is sent only
    /// after `liveDraftDebounce`; the preview shows loading or its out-of-date time meanwhile.
    func syncDraftDeparture(force: Bool = false, isUserRetry: Bool = true) {
        guard let draft = editSession?.draft else {
            draftDepartureTask?.cancel()
            draftDepartureTask = nil
            if draftDeparture != nil {
                draftDeparture = nil
            }
            return
        }
        let now = currentDate()
        let request = draftCommuteRequest(for: draft, at: now)
        if !force, let current = draftDeparture, current.request == request, current.revision == commuteRevision {
            return
        }
        draftDepartureTask?.cancel()
        draftDepartureTask = nil
        let entry = makeDepartureEntry(for: request, replacing: draftDeparture, at: now, isUserRetry: isUserRetry)
        draftDeparture = entry
        guard entry.state.isLoading else { return }
        let estimator = activeCommuteEstimator
        let token = entry.token
        let debounce: Duration? = usesLiveBackend && !force ? Self.liveDraftDebounce : nil
        draftDepartureTask = Task { [weak self] in
            if let debounce {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    // A newer draft change replaced this one before it was sent.
                    return
                }
            }
            let state = await WaitItOutModel.resolveDeparture(request, using: estimator)
            guard !Task.isCancelled, let self, var current = self.draftDeparture, current.token == token else { return }
            current.state = WaitItOutModel.settledState(state, replacing: current.state)
            self.draftDeparture = current
            self.draftDepartureTask = nil
        }
    }

    // MARK: Settings

    /// True when leave-home times come from the prototype's test provider, so Settings shows
    /// the Test commute duration and the screens label every value as test data. False with a
    /// team provider and while the live backend is in use.
    public var usesTestCommute: Bool {
        testCommuteProvider != nil && !usesLiveBackend
    }

    /// The simulated commute the test provider reports. Initially 60 minutes.
    public var testCommuteDuration: CommuteDuration {
        preferences.testCommuteDuration
    }

    /// Settings field: applies whole minutes from 1 to 720 and returns `nil`. Returns the
    /// issue and changes nothing for anything else, so the last valid duration stays in use.
    @discardableResult
    public func applyTestCommuteMinutes(_ text: String) -> CommuteDurationIssue? {
        switch CommuteDuration.parseMinutes(text) {
        case .success(let duration):
            setTestCommuteDuration(duration)
            return nil
        case .failure(let issue):
            return issue
        }
    }

    /// The test provider's deterministic scenario (step 0006). Initially Normal.
    public var testCommuteScenario: TestCommuteProvider.Scenario {
        preferences.testCommuteScenario
    }

    /// Settings "Prototype testing": switches the test provider's scenario, persists it, and
    /// recalculates every leave-home time automatically. Earlier answers stay visible, marked
    /// out of date, until the new ones arrive; answers for the old scenario are dropped.
    public func setTestCommuteScenario(_ scenario: TestCommuteProvider.Scenario) {
        guard preferences.testCommuteScenario != scenario else { return }
        preferences.testCommuteScenario = scenario
        persistPreferences()
        commuteSettingsDidChange()
    }

    /// True when the scenario is Normal, the test duration is 60 minutes, and the reminder
    /// failure simulation (step 0007) is off.
    public var isPrototypeTestingAtDefaults: Bool {
        preferences.testCommuteScenario == .normal
            && preferences.testCommuteDuration == .testDefault
            && !preferences.simulatesReminderFailure
    }

    /// Settings reset: Normal scenario, the 60-minute test duration, and no reminder failure
    /// simulation, recalculated once.
    public func resetPrototypeTesting() {
        guard !isPrototypeTestingAtDefaults else { return }
        let reminderFailureChanged = preferences.simulatesReminderFailure
        preferences.testCommuteScenario = .normal
        preferences.testCommuteDuration = .testDefault
        preferences.simulatesReminderFailure = false
        persistPreferences()
        applyReminderSettings()
        commuteSettingsDidChange()
        if reminderFailureChanged {
            reconcileReminders(force: true)
        }
    }

    /// The simulated travel time the current test settings produce, or `nil` for the
    /// Unavailable and Error scenarios and for a team provider.
    public var simulatedTravelTime: CommuteDuration? {
        guard usesTestCommute else { return nil }
        return testCommuteScenario.travelTime(for: testCommuteDuration)
    }

    /// Pushes the stored test duration and scenario into the test provider and invalidates
    /// every result, so the next refresh asks again. While the live backend is in use the test
    /// provider only takes the settings: its values are not on screen, so nothing is asked again.
    func commuteSettingsDidChange() {
        applyTestCommuteSettings()
        guard !usesLiveBackend else { return }
        commuteRevision &+= 1
        refreshDepartures()
        syncDraftDeparture()
    }

    // MARK: Requests

    /// Hands the stored test duration and scenario to the test provider.
    func applyTestCommuteSettings() {
        testCommuteProvider?.setDuration(preferences.testCommuteDuration)
        testCommuteProvider?.setScenario(preferences.testCommuteScenario)
    }

    /// A new entry for `request`. When `previous` answered the same trip, its calculation is
    /// kept as `.refreshing` (marked out of date) instead of blanking the screen, also after a
    /// failed refresh (`.stale`); a different trip, such as a changed arrival or a new home,
    /// starts from `.loading`. An automatic retry of the same failed trip counts one attempt
    /// more; Try Again and every other reason start counting again.
    private func makeDepartureEntry(
        for request: CommuteRequest,
        replacing previous: DepartureEntry?,
        at now: Date,
        isUserRetry: Bool
    ) -> DepartureEntry {
        departureTokenCounter &+= 1
        let state: DepartureState
        if !request.hasUsableDestination {
            state = .unavailable(.noDestination)
        } else if let previous, previous.request == request,
                  let earlier = previous.state.calculation ?? previous.state.staleCalculation {
            state = .refreshing(earlier)
        } else {
            state = .loading
        }
        var attempt = 1
        if let previous, !isUserRetry, previous.request == request, previous.revision == commuteRevision,
           previous.state.failure?.isTransient == true {
            attempt = previous.attempt + 1
        }
        return DepartureEntry(
            request: request,
            state: state,
            revision: commuteRevision,
            token: departureTokenCounter,
            attemptedAt: now,
            attempt: attempt
        )
    }

    private func startDepartureRequest(_ request: CommuteRequest, token: UInt64) -> Task<Void, Never> {
        let estimator = activeCommuteEstimator
        return Task { [weak self] in
            let state = await WaitItOutModel.resolveDeparture(request, using: estimator)
            guard !Task.isCancelled else { return }
            self?.applyDeparture(state, token: token, for: request.occurrenceID)
        }
    }

    private func applyDeparture(_ state: DepartureState, token: UInt64, for id: OccurrenceID) {
        guard var entry = departures[id], entry.token == token else { return }
        departureTasks[id] = nil
        entry.state = Self.settledState(state, replacing: entry.state)
        departures[id] = entry
        reconcileReminders()
    }

    /// The state an answer leaves behind. A failure that arrives while an earlier backend
    /// recommendation for the same trip is on screen keeps that recommendation as `.stale`, so
    /// the last good answer is not lost but is never shown as current. A demo estimate is not
    /// kept: its failure becomes `.error`, as before.
    nonisolated static func settledState(_ answer: DepartureState, replacing current: DepartureState) -> DepartureState {
        guard case .error(let failure) = answer,
              let earlier = current.staleCalculation,
              earlier.recommendation != nil else {
            return answer
        }
        return .stale(earlier, failure)
    }

    /// Asks the provider off the main actor and maps the answer. A `CommuteProviderFailure`
    /// keeps its kind; any other thrown error, including a cancellation the model did not ask
    /// for, becomes a generic provider failure.
    private nonisolated static func resolveDeparture(_ request: CommuteRequest, using estimator: any CommuteEstimating) async -> DepartureState {
        do {
            let response = try await estimator.estimateCommute(for: request)
            return DepartureState.resolving(response, for: request)
        } catch let failure as CommuteProviderFailure {
            return .error(.provider(failure.kind))
        } catch {
            return .error(.providerFailed)
        }
    }
}
