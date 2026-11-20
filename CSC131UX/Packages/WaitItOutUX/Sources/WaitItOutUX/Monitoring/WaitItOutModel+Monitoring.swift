import Foundation

/// Bookkeeping for trip monitoring. Not observed and never stored.
struct MonitoringTracking {
    /// What the server in use may still hold for this installation.
    enum ServerHolding: Equatable {
        /// Nothing was asked in this launch yet; a credential may survive from an earlier one.
        case unknown
        /// Trips were sent, so the server may be monitoring them.
        case trips
        /// The trips were withdrawn with an empty snapshot; only the device entry may remain.
        case deviceOnly
        /// The installation was removed, or never registered.
        case nothing
    }

    /// The one running reconciliation.
    var task: Task<Void, Never>?
    var needsReconcile = false
    var isForced = false
    var isUserRetry = false
    /// Bumped whenever the data source changes; an answer from an earlier epoch is dropped.
    var epoch: UInt64 = 0
    /// The set of the last synchronization attempt, acknowledged or not.
    var lastAttempted: [MonitoredTrip]?
    var lastAttemptAt: Date?
    /// The set the server last acknowledged, and when, on the device clock.
    var acknowledged: [MonitoredTrip]?
    var acknowledgedAt: Date?
    /// When the newest snapshot arrived, from a synchronization or a refresh.
    var snapshotAt: Date?
    var refreshAttemptAt: Date?
    var holding: ServerHolding = .unknown
    var withdrawalAttemptAt: Date?
    /// Servers left behind by an address change that could not be told yet. The lasting
    /// record is the credential each of them still has in the credential store
    /// (`TripMonitoring.serversLeftBehind()`); this is this session's working copy of it.
    var abandonedServers: [URL] = []
    /// True once the user chose the reminders toggle, the data mode, or the server address in
    /// this session. While stored settings cannot be read, only such a choice says what the
    /// user wants; the defaults in effect do not.
    var hasExplicitChoice = false
    /// For each trip without a plan, the server's sentence about it and the reading of the
    /// server's state before the one that first carried it (device clock): the sentence was
    /// written after that moment. `nil` when its age is unknown.
    var noPlanReasons: [OccurrenceID: (reason: String, writtenAfter: Date?)] = [:]
    var reregistrations = 0
    var permissionTask: Task<Void, Never>?
    var tripTasks: [OccurrenceID: (token: UInt64, task: Task<Void, Never>)] = [:]
    var tripTaskCounter: UInt64 = 0
    /// The monitored plan each departure was last asked to adopt, so a screen that keeps
    /// showing another answer is not asked again with every snapshot.
    var adoptedPlans: [OccurrenceID: MonitoredPlan] = [:]
}

/// What one reconciliation step has to do.
private enum MonitoringWork: Equatable {
    case none
    /// Saved activities cannot be read: show that, and leave the server untouched.
    case pause
    /// Saved settings cannot be read, so what the user wants is not known: show that, and
    /// leave the server untouched.
    case pauseForSettings
    /// Nothing of this installation is on the server: only the status needs settling.
    case settleOff
    /// Take this installation off the server.
    case withdraw
    case synchronize([MonitoredTrip])
    /// Read the server's state without changing it.
    case refresh
}

/// Server-side trip monitoring (stage S2). With the live backend and leave-home reminders on,
/// the server watches the user's upcoming trips and sends the alerts; the app sends no local
/// notification of its own. The model decides which trips should be monitored and keeps the
/// injected `TripMonitoring` service in line with them, exactly as it keeps the preview adapter
/// in line with the reminder plan in the Demo data mode.
///
/// `reconcileMonitoring()` runs wherever `reconcileReminders()` runs: after every departure
/// refresh and answer (which covers saving, editing, and deleting activities, sample loads and
/// clears, home and campus, and the minute ticks), when reminders are toggled, on Try Again,
/// after the schedule loads, and when the app returns to the foreground. Reconciliations run
/// one at a time and always use the newest wanted set.
///
/// - Nothing is sent before the schedule has been read, and while it cannot be read the status
///   is `.paused` and the server is left untouched. The same holds while stored settings
///   cannot be read (`.settingsUnreadable`): the defaults in effect then say "alerts off, the
///   built-in server", which is not what the user chose, so the installation is neither
///   withdrawn nor synchronized until the settings are readable or the user chooses anew.
/// - While a set is unacknowledged the status is `.pending`; `.active` is claimed only after
///   the server acknowledged exactly the trips the app wants monitored now.
/// - After a transient failure the next tick tries again once `monitoringRetryInterval` has
///   passed, and a forced call (launch, foreground, a toggle) always does. A server without
///   monitoring is asked again only by a forced call or Try Again, and a refused set waits for
///   Try Again or a change.
/// - With reminders off or the Demo data mode chosen, the installation is taken off the server:
///   withdrawals are real work, tried again until the server confirms. A withdrawal never
///   registers a device, and a credential is dropped only when the server confirmed.
/// - While a trip is being planned or monitored, the minute ticks read the server's state
///   again once it is `monitoringRefreshInterval` old. Only departures whose monitored plan
///   changed are asked again, so the screens follow the server without re-asking the rest.
extension WaitItOutModel {
    /// The most trips the app asks the server to monitor at once.
    public nonisolated static let monitoredTripLimit = 20
    /// How long after a transient failure the minute ticks try again: 60 seconds.
    public nonisolated static let monitoringRetryInterval: TimeInterval = 60
    /// How old the server's state may get while a trip is planned or monitored: 60 seconds.
    public nonisolated static let monitoringRefreshInterval: TimeInterval = 60

    /// True when the server monitors trips for this app: the live backend is in use and the
    /// host composed a monitoring service.
    public var usesTripMonitoring: Bool {
        usesLiveBackend && liveBackend?.tripMonitor != nil
    }

    // MARK: Wanted trips

    /// The trips the server should monitor for `occurrences`: those whose ideal arrival is
    /// still ahead and whose resolved destination is usable, built exactly like the requests
    /// the screens make, so the origin, the destination, and the arrival are the same. Ordered
    /// by ideal arrival and limited to `limit`. Sample activities are included: the user
    /// loaded them explicitly. Pure.
    public nonisolated static func monitoredTrips(
        for occurrences: [ActivityOccurrence],
        home: CommutePlace,
        resolve: (Destination) -> Destination,
        now: Date,
        limit: Int = 20
    ) -> [MonitoredTrip] {
        var seen: Set<OccurrenceID> = []
        var trips: [MonitoredTrip] = []
        for occurrence in occurrences.sorted(by: DepartureHorizon.isOrderedBefore) {
            guard trips.count < limit else { break }
            guard occurrence.idealArrival > now, !seen.contains(occurrence.id) else { continue }
            let request = CommuteRequest(occurrence: occurrence, origin: home, destination: resolve(occurrence.activity.destination))
            guard request.hasUsableDestination else { continue }
            seen.insert(occurrence.id)
            trips.append(MonitoredTrip(
                id: occurrence.id,
                title: occurrence.activity.title,
                origin: request.origin.coordinate,
                destination: request.destination.coordinate,
                arriveBy: request.arriveBy,
                timeZoneIdentifier: occurrence.activity.timeZoneIdentifier
            ))
        }
        return trips
    }

    /// The trips the server should monitor at `now` for the saved schedule.
    func wantedMonitoredTrips(at now: Date) -> [MonitoredTrip] {
        Self.monitoredTrips(
            for: DepartureHorizon.upcomingOccurrences(of: activities, at: now),
            home: places.home,
            resolve: { resolvedDestination($0) },
            now: now,
            limit: max(0, min(Self.monitoredTripLimit, monitoringLimits.maxTrips))
        )
    }

    // MARK: Reconciliation

    /// Try Again after a failed synchronization, including one the app does not retry by
    /// itself.
    public func retryMonitoring() {
        reconcileMonitoring(force: true, isUserRetry: true)
    }

    /// Waits until monitoring is idle. Tests use this; the UI never needs to.
    public func waitForMonitoring() async {
        while true {
            if let task = monitoringTracking.permissionTask {
                await task.value
                if monitoringTracking.permissionTask == task {
                    monitoringTracking.permissionTask = nil
                }
                continue
            }
            if let task = monitoringTracking.task {
                await task.value
                continue
            }
            let tripTasks = monitoringTracking.tripTasks.values.map(\.task)
            guard !tripTasks.isEmpty else { break }
            for task in tripTasks {
                await task.value
            }
        }
    }

    /// Brings the server in line with the trips the app wants monitored now. Cheap when there
    /// is nothing to do. `force` checks with the server even when nothing changed (launch,
    /// foreground, toggles); `isUserRetry` also retries a failure the app leaves alone.
    func reconcileMonitoring(force: Bool = false, isUserRetry: Bool = false) {
        // Nothing is sent before the schedule has been read once: an empty list at launch
        // would cancel every trip the server still monitors.
        guard liveBackend?.tripMonitor != nil, activitiesStatus != .notLoaded else { return }
        let hasAbandonedServers = force && !monitoringTracking.abandonedServers.isEmpty && !isMonitoringPausedForSettings
        let isRunning = monitoringTracking.task != nil
        switch monitoringWork(at: currentDate(), forced: force, isUserRetry: isUserRetry, isRunning: isRunning) {
        case .none:
            guard hasAbandonedServers else { return }
        case .pause:
            setMonitoringStatus(.paused)
            guard hasAbandonedServers else { return }
        case .pauseForSettings:
            pauseMonitoringForSettings()
            return
        case .settleOff:
            settleMonitoringOff()
            guard hasAbandonedServers else { return }
        case .withdraw:
            settleMonitoringOff()
            if monitoringTracking.holding == .trips, monitoringWithdrawal != .pending {
                // Off for the user at once; the server is still being told.
                monitoringWithdrawal = .pending
            }
        case .synchronize(let trips):
            // Monitoring is never claimed for a set the server has not acknowledged.
            if !(monitoringStatus.isActive && monitoringTracking.acknowledged == trips) {
                setMonitoringStatus(.pending)
            }
        case .refresh:
            break
        }
        monitoringTracking.needsReconcile = true
        if force {
            monitoringTracking.isForced = true
        }
        if isUserRetry {
            monitoringTracking.isUserRetry = true
        }
        guard monitoringTracking.task == nil else { return }
        monitoringTracking.task = Task { [weak self] in
            await self?.runMonitoringReconciliation()
        }
    }

    /// What has to happen at `now`. It only reads state. `isRunning` is true when it is asked
    /// from outside the running reconciliation, whose request for a pending set is then
    /// already under way.
    private func monitoringWork(at now: Date, forced: Bool, isUserRetry: Bool, isRunning: Bool) -> MonitoringWork {
        let tracking = monitoringTracking
        if isMonitoringPausedForSettings {
            return monitoringStatus == .settingsUnreadable ? .none : .pauseForSettings
        }
        guard usesLiveBackend, remindersEnabled else {
            let settled: MonitoringWork = isMonitoringSettledOff ? .none : .settleOff
            switch tracking.holding {
            case .nothing:
                return settled
            case .deviceOnly:
                // No trips are left there; removing the device entry is tried when asked.
                return forced ? .withdraw : settled
            case .unknown, .trips:
                if forced { return .withdraw }
                if case .failed(let failure) = monitoringWithdrawal, !failure.isTransient { return settled }
                return isDue(tracking.withdrawalAttemptAt, at: now) ? .withdraw : settled
            }
        }
        if activityStorageIssue != nil {
            return monitoringStatus == .paused ? .none : .pause
        }
        let trips = wantedMonitoredTrips(at: now)
        guard tracking.lastAttempted == trips else { return .synchronize(trips) }
        switch monitoringStatus {
        case .active:
            if forced { return .synchronize(trips) }
            return needsSnapshotRefresh(at: now) ? .refresh : .none
        case .failed(let failure, _):
            if isUserRetry { return .synchronize(trips) }
            // A server without monitoring may have been set up since: it is asked again when
            // the app is opened or brought to the foreground and by a toggle, never on the ticks.
            if failure == .unavailableOnServer { return forced ? .synchronize(trips) : .none }
            // A refused set waits for Try Again or a change.
            guard failure.isTransient else { return .none }
            return forced || isDue(tracking.lastAttemptAt, at: now) ? .synchronize(trips) : .none
        case .pending:
            return forced || !isRunning ? .synchronize(trips) : .none
        case .off, .paused, .settingsUnreadable:
            return .synchronize(trips)
        }
    }

    private func runMonitoringReconciliation() async {
        while monitoringTracking.needsReconcile {
            monitoringTracking.needsReconcile = false
            let forced = monitoringTracking.isForced
            let isUserRetry = monitoringTracking.isUserRetry
            monitoringTracking.isForced = false
            monitoringTracking.isUserRetry = false
            guard let monitor = liveBackend?.tripMonitor else { break }
            if forced, !isMonitoringPausedForSettings {
                await releaseAbandonedServers(using: monitor)
            }
            switch monitoringWork(at: currentDate(), forced: forced, isUserRetry: isUserRetry, isRunning: false) {
            case .none:
                break
            case .pause:
                setMonitoringStatus(.paused)
            case .pauseForSettings:
                pauseMonitoringForSettings()
            case .settleOff:
                settleMonitoringOff()
            case .withdraw:
                await withdrawMonitoring(using: monitor)
            case .synchronize(let trips):
                await synchronizeMonitoring(trips, using: monitor)
            case .refresh:
                await refreshMonitoring(using: monitor)
            }
        }
        monitoringTracking.reregistrations = 0
        monitoringTracking.task = nil
        handBackUnvouchedMonitoredAnswers()
    }

    /// While a reconciliation is under way, a leave-home time taken from the server's plan
    /// stays on screen as current, because fresh news is expected any moment. When the
    /// reconciliation ends without a snapshot that is young enough (the synchronization or
    /// the read failed), that plan can no longer be vouched for: it is handed back to a direct
    /// request at once instead of staying current until the next minute tick.
    private func handBackUnvouchedMonitoredAnswers() {
        guard monitoredAnswersExpired(at: currentDate()) else { return }
        var shownAsCurrent: Set<OccurrenceID> = []
        for (id, entry) in departures {
            if case .success(let calculation) = entry.state, calculation.recommendation?.isMonitored == true {
                shownAsCurrent.insert(id)
            }
        }
        invalidateDepartures(for: shownAsCurrent)
    }

    private func synchronizeMonitoring(_ trips: [MonitoredTrip], using monitor: any TripMonitoring) async {
        let epoch = monitoringTracking.epoch
        monitoringTracking.lastAttempted = trips
        monitoringTracking.lastAttemptAt = currentDate()
        // From here on the server may hold these trips, whatever becomes of the answer.
        monitoringTracking.holding = .trips
        if monitoringWithdrawal != .none {
            monitoringWithdrawal = .none
        }
        if !(monitoringStatus.isActive && monitoringTracking.acknowledged == trips) {
            setMonitoringStatus(.pending)
        }
        do {
            let snapshot = try await monitor.synchronize(trips)
            guard epoch == monitoringTracking.epoch else { return }
            monitoringTracking.reregistrations = 0
            monitoringTracking.acknowledged = trips
            monitoringTracking.acknowledgedAt = snapshot.acknowledgedAt
            finishSynchronization(snapshot, for: trips)
        } catch {
            guard epoch == monitoringTracking.epoch else { return }
            failSynchronization(error)
        }
    }

    /// The server acknowledged `trips`. That counts as active only when they are still what
    /// the app wants: a change made while the request was under way keeps the status pending
    /// until the newest set is acknowledged too.
    private func finishSynchronization(_ snapshot: MonitoringSnapshot, for trips: [MonitoredTrip]) {
        guard usesLiveBackend, remindersEnabled, activityStorageIssue == nil else {
            // Turned off or paused meanwhile: the next step deals with it.
            monitoringTracking.needsReconcile = true
            return
        }
        if wantedMonitoredTrips(at: currentDate()) == trips {
            setMonitoringStatus(.active(acknowledgedAt: snapshot.acknowledgedAt, tripCount: trips.count))
        } else {
            setMonitoringStatus(.pending)
            monitoringTracking.needsReconcile = true
        }
        applyMonitoringSnapshot(snapshot)
    }

    private func failSynchronization(_ error: Error) {
        let failure = (error as? TripMonitoringFailure) ?? .invalidResponse
        if failure == .reregistered || failure == .notRegistered, monitoringTracking.reregistrations < 1 {
            // The server no longer knows this device: every trip is sent again, once.
            resynchronizeFromScratch()
            return
        }
        setMonitoringStatus(.failed(failure, lastAcknowledgedAt: monitoringTracking.acknowledgedAt))
    }

    private func resynchronizeFromScratch() {
        monitoringTracking.reregistrations += 1
        monitoringTracking.lastAttempted = nil
        monitoringTracking.acknowledged = nil
        monitoringTracking.needsReconcile = true
        // A device registered anew holds every trip as active again: nothing the old one was
        // told about a departure carries over.
        let kept = departedStates.filter { $0.value == .sending }
        if kept != departedStates {
            departedStates = kept
        }
        setMonitoringStatus(.pending)
    }

    /// Reads the server's state. A failure leaves the status alone: the server still holds
    /// what it acknowledged, and only its newer state could not be read. It is tried again a
    /// minute later, and a monitored plan older than `MonitoringSnapshot.lifetime` stops being
    /// shown as current meanwhile.
    private func refreshMonitoring(using monitor: any TripMonitoring) async {
        let epoch = monitoringTracking.epoch
        monitoringTracking.refreshAttemptAt = currentDate()
        do {
            let snapshot = try await monitor.refresh()
            guard epoch == monitoringTracking.epoch, usesLiveBackend, remindersEnabled else { return }
            applyMonitoringSnapshot(snapshot)
        } catch {
            guard epoch == monitoringTracking.epoch else { return }
            switch (error as? TripMonitoringFailure) ?? .invalidResponse {
            case .reregistered, .notRegistered:
                guard monitoringTracking.reregistrations < 1 else { return }
                resynchronizeFromScratch()
            case .unavailableOnServer:
                setMonitoringStatus(.failed(.unavailableOnServer, lastAcknowledgedAt: monitoringTracking.acknowledgedAt))
            case .notConfigured, .offline, .timedOut, .server, .invalidResponse, .rejected, .superseded,
                 .notMonitored, .credentialStorage:
                break
            }
        }
    }

    /// True when the server's state should be read again at `now`: it is at least
    /// `monitoringRefreshInterval` old and some trip is being planned or monitored, or has
    /// reached the time the server said it would look at it next.
    private func needsSnapshotRefresh(at now: Date) -> Bool {
        let tracking = monitoringTracking
        guard let snapshotAt = tracking.snapshotAt,
              now.timeIntervalSince(snapshotAt) >= Self.monitoringRefreshInterval,
              isDue(tracking.refreshAttemptAt, at: now) else {
            return false
        }
        return monitoredTrips.values.contains { Self.wantsRefresh($0, at: now) }
    }

    /// True when the server's state for `trip` is expected to change around `now`: it is being
    /// planned or monitored, or it reached the time the server said it would look at it next.
    nonisolated static func wantsRefresh(_ trip: MonitoredTripState, at now: Date) -> Bool {
        switch trip.phase {
        case .planning, .monitoring:
            return true
        case .departed, .ended:
            return false
        case .scheduled, .planned:
            let due = [trip.planAvailableAt, trip.monitoringStartsAt, trip.nextCheckAt].compactMap { $0 }
            return due.contains { now >= $0 }
        }
    }

    /// True when what the server said about `trip` should have been read again by `now` and
    /// has not been for `MonitoringSnapshot.lifetime`: its alert times are then not shown as
    /// current.
    func monitoredStateIsOutOfDate(_ trip: MonitoredTripState, at now: Date) -> Bool {
        guard let snapshotAt = monitoringTracking.snapshotAt,
              now.timeIntervalSince(snapshotAt) >= MonitoringSnapshot.lifetime else {
            return false
        }
        return Self.wantsRefresh(trip, at: now)
    }

    /// A snapshot arrived, from a synchronization or a refresh: publish it, then ask again
    /// only for the departures whose monitored plan changed.
    func applyMonitoringSnapshot(_ snapshot: MonitoringSnapshot) {
        let before = monitoredTrips
        let workerRanBefore = monitorHealth?.enabled ?? false
        let horizonBefore = monitoringLimits.planningHorizon
        if monitoredAnswersLapsed(before: snapshot.acknowledgedAt) {
            // The screens went back to direct answers meanwhile; they adopt the plans afresh.
            monitoringTracking.adoptedPlans = [:]
        }
        noteNoPlanReasons(in: snapshot.trips, readBefore: monitoringTracking.snapshotAt)
        monitoringTracking.snapshotAt = snapshot.acknowledgedAt
        if monitoredTrips != snapshot.trips {
            monitoredTrips = snapshot.trips
        }
        if pushDelivery != snapshot.push {
            pushDelivery = snapshot.push
        }
        if monitorHealth != snapshot.monitor {
            monitorHealth = snapshot.monitor
        }
        if monitoringLimits != snapshot.limits {
            monitoringLimits = snapshot.limits
        }
        pruneDepartedStates()
        var affected = departuresAffected(
            before: before,
            workerRanBefore: workerRanBefore,
            after: snapshot.trips,
            workerRuns: snapshot.monitor.enabled,
            at: currentDate()
        )
        if snapshot.limits.planningHorizon != horizonBefore {
            // "Not yet" answers were worded with the earlier planning reach.
            for (id, entry) in departures {
                if case .unavailable(.notYetPlannable) = entry.state {
                    affected.insert(id)
                }
            }
        }
        invalidateDepartures(for: affected)
    }

    /// The plan the screens take from the server for `trip` at `now`: only the one the server
    /// still keeps current (`MonitoredTripState.currentPlan`, the rule `BackendSession` answers
    /// by). `workerRuns` is whether the server said it runs its monitoring worker.
    nonisolated static func monitoredPlan(of trip: MonitoredTripState?, workerRuns: Bool, at now: Date) -> MonitoredPlan? {
        trip?.currentPlan(monitorEnabled: workerRuns, at: now)
    }

    /// The departures a new set of trip states changes: those whose monitored plan differs
    /// (which includes a plan the server stopped keeping current, such as after its
    /// time-to-leave alert: that departure is handed back to a direct request), and those of a
    /// monitored trip whose screen still shows another answer (asked once per plan, so a
    /// provider that never takes the server's plan is not asked every minute).
    private func departuresAffected(
        before: [OccurrenceID: MonitoredTripState],
        workerRanBefore: Bool,
        after: [OccurrenceID: MonitoredTripState],
        workerRuns: Bool,
        at now: Date
    ) -> Set<OccurrenceID> {
        var ids: Set<OccurrenceID> = []
        for id in Set(before.keys).union(after.keys) {
            let plan = Self.monitoredPlan(of: after[id], workerRuns: workerRuns, at: now)
            if Self.monitoredPlan(of: before[id], workerRuns: workerRanBefore, at: now) != plan {
                ids.insert(id)
                monitoringTracking.adoptedPlans[id] = plan
            }
        }
        for (id, trip) in after {
            guard let plan = Self.monitoredPlan(of: trip, workerRuns: workerRuns, at: now), let entry = departures[id],
                  monitoringTracking.adoptedPlans[id] != plan else {
                continue
            }
            switch entry.state {
            case .success(let calculation) where calculation.recommendation?.isMonitored == true:
                continue
            case .loading, .refreshing, .success, .unavailable, .error, .stale:
                ids.insert(id)
                monitoringTracking.adoptedPlans[id] = plan
            }
        }
        return ids
    }

    /// True when the snapshot before the one arriving at `arrival` was gone or older than
    /// `MonitoringSnapshot.lifetime`, so monitored answers had stopped counting as current.
    private func monitoredAnswersLapsed(before arrival: Date) -> Bool {
        guard let snapshotAt = monitoringTracking.snapshotAt else { return true }
        return arrival.timeIntervalSince(snapshotAt) >= MonitoringSnapshot.lifetime
    }

    /// True when a leave-home time taken from the server's monitored plan can no longer be
    /// shown as current at `now`: the newest snapshot is older than
    /// `MonitoringSnapshot.lifetime` (or gone) and no reconciliation is under way to renew it.
    func monitoredAnswersExpired(at now: Date) -> Bool {
        guard monitoringTracking.task == nil else { return false }
        guard let snapshotAt = monitoringTracking.snapshotAt else { return true }
        return now.timeIntervalSince(snapshotAt) >= MonitoringSnapshot.lifetime
    }

    // MARK: Withdrawal

    /// Takes this installation off the server in use: the device entry and its trips are
    /// deleted. When that fails, an empty snapshot under the credential it already has at
    /// least stops the alerts (`withdrawTrips`, which never registers a device); when that
    /// fails too, the failure is remembered and tried again.
    private func withdrawMonitoring(using monitor: any TripMonitoring) async {
        let epoch = monitoringTracking.epoch
        // The server is named now, so a later address change cannot redirect the request.
        let server = liveBackend?.configuration.baseURL
        let holding = monitoringTracking.holding
        monitoringTracking.withdrawalAttemptAt = currentDate()
        settleMonitoringOff()
        if holding == .trips, monitoringWithdrawal != .pending {
            monitoringWithdrawal = .pending
        }
        do {
            try await monitor.unregister(from: server)
            guard epoch == monitoringTracking.epoch else { return }
            finishWithdrawal(leaving: .nothing)
        } catch {
            guard epoch == monitoringTracking.epoch, holding != .deviceOnly else { return }
            let failure = (error as? TripMonitoringFailure) ?? .invalidResponse
            do {
                try await monitor.withdrawTrips()
                guard epoch == monitoringTracking.epoch else { return }
                finishWithdrawal(leaving: .deviceOnly)
            } catch {
                guard epoch == monitoringTracking.epoch else { return }
                if monitoringWithdrawal != .failed(failure) {
                    monitoringWithdrawal = .failed(failure)
                }
            }
        }
    }

    private func finishWithdrawal(leaving holding: MonitoringTracking.ServerHolding) {
        monitoringTracking.holding = holding
        if monitoringWithdrawal != .none {
            monitoringWithdrawal = .none
        }
        // A leave-home time still taken from the server's plan is asked again directly.
        invalidateDepartures(for: monitoredDepartureIDs())
    }

    /// Tells the servers an address change left behind to forget this installation: those
    /// remembered in this session, and every other server the monitoring service still holds
    /// a credential for, which is how one that could not be told survives a restart. One that
    /// cannot be told now stays on the list for the next forced reconciliation, and its
    /// credential stays in the store.
    private func releaseAbandonedServers(using monitor: any TripMonitoring) async {
        for server in await monitor.serversLeftBehind() where !monitoringTracking.abandonedServers.contains(server) {
            monitoringTracking.abandonedServers.append(server)
        }
        for server in monitoringTracking.abandonedServers {
            // The address may have changed back to this server meanwhile: it is in use again.
            guard !isServerInUse(server) else {
                monitoringTracking.abandonedServers.removeAll { $0 == server }
                continue
            }
            do {
                try await monitor.unregister(from: server)
                monitoringTracking.abandonedServers.removeAll { $0 == server }
            } catch {
                continue
            }
        }
        let warns = !monitoringTracking.abandonedServers.isEmpty
        if previousServerMayStillAlert != warns {
            previousServerMayStillAlert = warns
        }
    }

    /// The data mode or the server address changed: nothing known about monitoring carries
    /// over, and answers still under way are dropped. The forced reconciliation that follows
    /// every such change does the rest.
    func monitoringSourceDidChange() {
        guard liveBackend?.tripMonitor != nil else { return }
        monitoringTracking.epoch &+= 1
        for entry in monitoringTracking.tripTasks.values {
            entry.task.cancel()
        }
        monitoringTracking.tripTasks = [:]
        monitoringTracking.withdrawalAttemptAt = nil
        monitoringTracking.reregistrations = 0
        clearMonitoredState()
        if monitoringLimits != .fallback {
            monitoringLimits = .fallback
        }
        let waits = usesLiveBackend && remindersEnabled && activitiesStatus != .notLoaded && activityStorageIssue == nil
        setMonitoringStatus(waits ? .pending : .off)
    }

    /// The server address changed from `old` to `new`. A server that may still hold this
    /// installation is remembered so it can be told; what the new one holds is not known yet.
    func monitoringAddressDidChange(from old: URL?, to new: URL?) {
        guard liveBackend?.tripMonitor != nil, old != new else { return }
        if let new {
            monitoringTracking.abandonedServers.removeAll { $0 == new }
        }
        let held = monitoringTracking.holding == .trips || monitoringTracking.holding == .deviceOnly
        if let old, held {
            monitoringTracking.abandonedServers.removeAll { $0 == old }
            monitoringTracking.abandonedServers.append(old)
            if monitoringTracking.abandonedServers.count > 3 {
                monitoringTracking.abandonedServers.removeFirst()
            }
        }
        monitoringTracking.holding = .unknown
        if monitoringWithdrawal != .none {
            monitoringWithdrawal = .none
        }
    }

    // MARK: Notification permission and push registration

    /// Shows the system prompt when the user has not decided yet, and registers for push
    /// notifications when allowed. Called when reminders are turned on in Live mode and by the
    /// "Allow Notifications" button. The server is told the outcome with the next
    /// synchronization.
    public func requestNotificationPermission() {
        guard usesLiveBackend, let monitor = liveBackend?.tripMonitor else { return }
        let previous = monitoringTracking.permissionTask
        monitoringTracking.permissionTask = Task { [weak self] in
            await previous?.value
            let permission = await monitor.requestNotificationPermission()
            self?.adoptNotificationPermission(permission)
        }
    }

    /// The host received a device token, or failed to: synchronize at once so the push status
    /// on screen is current.
    public func pushRegistrationDidChange() {
        guard usesLiveBackend, let monitor = liveBackend?.tripMonitor else { return }
        let previous = monitoringTracking.permissionTask
        monitoringTracking.permissionTask = Task { [weak self] in
            await previous?.value
            let permission = await monitor.notificationPermission()
            self?.adoptNotificationPermission(permission)
        }
        if remindersEnabled {
            reconcileMonitoring(force: true)
        }
    }

    /// Launch and foreground: checks the permission again and, with reminders on, registers
    /// with the push service again. Never prompts.
    func refreshPushRegistration() {
        guard usesLiveBackend, let monitor = liveBackend?.tripMonitor else { return }
        let wantsAlerts = remindersEnabled
        let previous = monitoringTracking.permissionTask
        monitoringTracking.permissionTask = Task { [weak self] in
            await previous?.value
            if wantsAlerts {
                await monitor.refreshPushRegistration()
            }
            let permission = await monitor.notificationPermission()
            self?.adoptNotificationPermission(permission)
        }
    }

    private func adoptNotificationPermission(_ permission: NotificationPermission) {
        guard notificationPermission != permission else { return }
        notificationPermission = permission
        // The server learns whether alerts are allowed with the next synchronization.
        if usesLiveBackend, remindersEnabled {
            reconcileMonitoring(force: true)
        }
    }

    // MARK: "I've left"

    /// Tells the server the user has left for the trip, which ends its monitoring. `arriveBy`
    /// is the arrival time the user meant, such as the one a notification carried; without one
    /// it is the trip's current arrival time. The outcome is published per trip in
    /// `departedStates`; success is claimed only after the server answered.
    public func markDeparted(_ id: OccurrenceID, arriveBy: Date? = nil) async {
        guard usesLiveBackend, let monitor = liveBackend?.tripMonitor, departedStates[id] != .sending else { return }
        guard let target = arriveBy ?? monitoredTrips[id]?.arriveBy ?? occurrence(for: id)?.idealArrival else {
            departedStates[id] = .failed(.notMonitored)
            return
        }
        let epoch = monitoringTracking.epoch
        departedStates[id] = .sending
        let result = await monitor.markDeparted(id, arriveBy: target)
        guard epoch == monitoringTracking.epoch else { return }
        switch result {
        case .success(let state):
            monitoredTrips[id] = state
            // Success is the server's own answer: it reports the trip as left.
            departedStates[id] = state.phase == .departed ? .done : .failed(.invalidResponse)
            invalidateDepartures(for: [id])
        case .failure(let failure):
            departedStates[id] = .failed(failure)
            switch failure {
            case .reregistered, .notRegistered, .notMonitored, .superseded:
                // The server does not hold what the app thought: bring the two in line again.
                reconcileMonitoring(force: true)
            case .notConfigured, .offline, .timedOut, .server, .invalidResponse, .unavailableOnServer,
                 .rejected, .credentialStorage:
                break
            }
        }
    }

    /// Where telling the server "I've left" stands for the trip, or `nil` before the user did.
    public func departedState(for id: OccurrenceID) -> DepartedState? {
        departedStates[id]
    }

    // MARK: Notifications

    /// A notification was tapped: shows the Calendar on the trip's day and asks it to present
    /// the trip's details (`tripToPresent`), then reads the trip's current state from the
    /// server. Before the schedule has loaded the id is kept and opened right after the load.
    /// A trip that is no longer in the calendar leaves a notice instead.
    public func openTrip(_ id: OccurrenceID) {
        guard activitiesStatus != .notLoaded else {
            pendingTripToOpen = id
            return
        }
        pendingTripToOpen = nil
        selectedTab = .calendar
        guard let occurrence = occurrence(for: id) else {
            calendarNotice = activityStorageIssue == nil ? MonitoringText.tripNoLongerInCalendar : MonitoringText.tripUnreadable
            return
        }
        selectDay(occurrence.start)
        tripToPresent = id
        refreshMonitoredTrip(id)
    }

    /// Opens the trip a notification named before the schedule had loaded.
    func openPendingTrip() {
        guard let id = pendingTripToOpen, activitiesStatus != .notLoaded else { return }
        openTrip(id)
    }

    /// The saved occurrence with this id, expanded from its stored activity and the id's local
    /// day, or `nil` when the activity is gone or no longer has an occurrence on that day.
    public func occurrence(for id: OccurrenceID) -> ActivityOccurrence? {
        guard let activity = activities.first(where: { $0.id == id.activityID }) else { return nil }
        // The occurrence starts on the id's local day in the activity's zone. Two days before
        // and three after that day's UTC midnight cover every zone offset and arrival lead.
        let window = id.date.adding(days: -2).utcMidnight..<id.date.adding(days: 3).utcMidnight
        return OccurrenceExpander.occurrences(of: activity, in: window).first { $0.id == id }
    }

    /// The host forwards what the user did with a trip notification. `tripID` and `arriveBy`
    /// come from the notification's payload (see `TripNotificationPayload`). Both actions open
    /// the trip; "I've left" then tells the server, for the arrival time the notification was
    /// about, so an old notification can never end the monitoring of a rescheduled trip.
    /// Returns once the outcome is recorded in the model's state.
    public func handleNotificationAction(tripID: String, action: NotificationAction, arriveBy: Date? = nil) async {
        guard let id = OccurrenceID(rawValue: tripID) else {
            selectedTab = .calendar
            calendarNotice = MonitoringText.tripNoLongerInCalendar
            return
        }
        openTrip(id)
        guard action == .left else { return }
        await markDeparted(id, arriveBy: arriveBy)
    }

    /// Makes sure stored settings and the stored schedule are loaded before a notification
    /// response is handled, so the server address and the data mode apply to every backend
    /// call. Joins a load that is under way and never starts a second one.
    public func prepareForNotificationResponse() async {
        if let running = storedStateTask {
            await running.value
            return
        }
        guard preferencesStatus == .notLoaded || activitiesStatus == .notLoaded else { return }
        await loadStoredState()
    }

    /// Reads one trip's current state from the server, then asks for its leave-home time
    /// again, so an opened trip shows what the server holds now.
    func refreshMonitoredTrip(_ id: OccurrenceID) {
        guard usesLiveBackend, remindersEnabled, let monitor = liveBackend?.tripMonitor else { return }
        let epoch = monitoringTracking.epoch
        monitoringTracking.tripTaskCounter &+= 1
        let token = monitoringTracking.tripTaskCounter
        monitoringTracking.tripTasks[id]?.task.cancel()
        let task = Task { [weak self] in
            var state: MonitoredTripState?
            var failure: TripMonitoringFailure?
            do {
                state = try await monitor.refreshTrip(id)
            } catch {
                failure = (error as? TripMonitoringFailure) ?? .invalidResponse
            }
            guard let self else { return }
            if self.monitoringTracking.tripTasks[id]?.token == token {
                self.monitoringTracking.tripTasks[id] = nil
            }
            guard !Task.isCancelled, epoch == self.monitoringTracking.epoch else { return }
            self.applyTripRefresh(state, failure: failure, for: id)
        }
        monitoringTracking.tripTasks[id] = (token: token, task: task)
    }

    private func applyTripRefresh(_ state: MonitoredTripState?, failure: TripMonitoringFailure?, for id: OccurrenceID) {
        if let failure {
            if failure == .reregistered || failure == .notRegistered {
                reconcileMonitoring(force: true)
            }
        } else if let state {
            if monitoredTrips[id] != state {
                monitoredTrips[id] = state
                pruneDepartedStates()
            }
        } else if monitoredTrips[id] != nil {
            // The server no longer holds a trip the app believed it monitors.
            monitoredTrips[id] = nil
            reconcileMonitoring(force: true)
        }
        invalidateDepartures(for: [id])
    }

    // MARK: What the screens show

    /// What keeps alerts from being described as active now, or `nil` when nothing does.
    public var monitoringObstacle: MonitoringObstacle? {
        MonitoringObstacle.resolve(
            status: monitoringStatus,
            push: pushDelivery,
            monitor: monitorHealth,
            permission: notificationPermission
        )
    }

    /// The honest sentence about delivery: that the server will try, or the exact obstacle.
    public var monitoringDeliverySentence: String {
        var tripCount = 0
        if case .active(_, let count) = monitoringStatus {
            tripCount = count
        }
        return MonitoringText.deliverySentence(for: monitoringObstacle, tripCount: tripCount)
    }

    /// What the server reports about the trip with this id, or `nil` when it is not monitored.
    public func monitoringSummary(for id: OccurrenceID) -> MonitoringSummary? {
        guard usesLiveBackend, remindersEnabled, let trip = monitoredTrips[id] else { return nil }
        var reasonWrittenAfter: Date?
        if let noted = monitoringTracking.noPlanReasons[id], noted.reason == trip.noPlanReason {
            reasonWrittenAfter = noted.writtenAfter
        }
        return MonitoringSummary(
            trip: trip,
            departed: departedStates[id],
            obstacle: monitoringObstacle,
            limits: monitoringLimits,
            noPlanReasonWrittenAfter: reasonWrittenAfter,
            lastReadAt: monitoringTracking.snapshotAt,
            isOutOfDate: monitoredStateIsOutOfDate(trip, at: currentDate())
        )
    }

    /// The day through which alerts are set up: the arrival of the last trip the server
    /// acknowledged. Trips are sent only while the app is open (the next
    /// `DepartureHorizon.lookaheadDays` days, at most `monitoredTripLimit`), so nothing later is
    /// monitored until the app is opened again. `nil` unless the server acknowledged trips.
    public var monitoringCoverageEnd: Date? {
        guard usesLiveBackend, remindersEnabled, monitoringStatus.isActive else { return nil }
        return monitoringTracking.acknowledged?.map(\.arriveBy).max()
    }

    /// What the server reports about `occurrence`, or `nil` when it is not monitored or the
    /// server's trip is for another arrival time (an edit the server has not acknowledged yet).
    public func monitoringSummary(for occurrence: ActivityOccurrence) -> MonitoringSummary? {
        guard let trip = monitoredTrips[occurrence.id],
              abs(trip.arriveBy.timeIntervalSince(occurrence.idealArrival)) < 0.001 else {
            return nil
        }
        return monitoringSummary(for: occurrence.id)
    }

    /// The next trip the server is planning or monitoring, for the status view: the first
    /// saved occurrence with an arrival ahead that is monitored and neither left nor over.
    public func nextMonitoringSummary(at now: Date) -> MonitoringSummary? {
        upcomingMonitoringSummaries(at: now).first
    }

    /// Every trip the server is planning or monitoring, soonest first: the saved occurrences
    /// with an arrival ahead that are monitored and neither left nor over.
    public func upcomingMonitoringSummaries(at now: Date) -> [MonitoringSummary] {
        DepartureHorizon.upcomingOccurrences(of: activities, at: now)
            .filter { $0.idealArrival > now }
            .compactMap { monitoringSummary(for: $0) }
            .filter { $0.phase != .departed && $0.phase != .ended }
    }

    // MARK: Helpers

    private var isMonitoringSettledOff: Bool {
        monitoringStatus == .off && monitoredTrips.isEmpty && pushDelivery == nil && monitorHealth == nil && departedStates.isEmpty
    }

    private func setMonitoringStatus(_ status: MonitoringStatus) {
        if monitoringStatus != status {
            monitoringStatus = status
        }
    }

    /// Nothing is monitored for the user now: the status is off and no server state is shown.
    private func settleMonitoringOff() {
        clearMonitoredState()
        setMonitoringStatus(.off)
    }

    private func clearMonitoredState() {
        if !monitoredTrips.isEmpty {
            monitoredTrips = [:]
        }
        if pushDelivery != nil {
            pushDelivery = nil
        }
        if monitorHealth != nil {
            monitorHealth = nil
        }
        if !departedStates.isEmpty {
            departedStates = [:]
        }
        monitoringTracking.noPlanReasons = [:]
        monitoringTracking.lastAttempted = nil
        monitoringTracking.lastAttemptAt = nil
        monitoringTracking.acknowledged = nil
        monitoringTracking.acknowledgedAt = nil
        monitoringTracking.snapshotAt = nil
        monitoringTracking.refreshAttemptAt = nil
        monitoringTracking.adoptedPlans = [:]
    }

    /// "I've left" outcomes are kept only for trips the server still reports, and a recorded
    /// success only while the server itself still says the user left: a trip that was
    /// rescheduled, or registered anew, is monitored again and can be left again.
    private func pruneDepartedStates() {
        let kept = departedStates.filter { id, state in
            guard let trip = monitoredTrips[id] else { return state == .sending }
            return state != .done || trip.phase == .departed
        }
        if kept != departedStates {
            departedStates = kept
        }
    }

    /// Remembers, for each trip without a plan, the server's sentence about it and how old it
    /// can be at most. A sentence the reading before this one (`readBefore`) did not carry was
    /// written since then; one that was already there keeps its earlier stamp, and one that
    /// arrives with the first reading of a session has an unknown age.
    private func noteNoPlanReasons(in trips: [OccurrenceID: MonitoredTripState], readBefore: Date?) {
        var noted: [OccurrenceID: (reason: String, writtenAfter: Date?)] = [:]
        for (id, trip) in trips {
            guard let reason = trip.noPlanReason else { continue }
            if let known = monitoringTracking.noPlanReasons[id], known.reason == reason {
                noted[id] = known
            } else {
                noted[id] = (reason: reason, writtenAfter: readBefore)
            }
        }
        monitoringTracking.noPlanReasons = noted
    }

    /// True while stored settings could not be read and the user has not chosen anew in this
    /// session. The settings in effect are then defaults (alerts off, the built-in server),
    /// not the user's wish, so nothing is withdrawn from or sent to any server on their word.
    var isMonitoringPausedForSettings: Bool {
        preferencesStorageIssue != nil && !monitoringTracking.hasExplicitChoice
    }

    /// Shows that saved settings could not be read and leaves the server untouched. What the
    /// server reported earlier is no longer shown: it may belong to another server.
    private func pauseMonitoringForSettings() {
        clearMonitoredState()
        setMonitoringStatus(.settingsUnreadable)
    }

    /// True when `server` is the address requests go to now.
    private func isServerInUse(_ server: URL) -> Bool {
        guard let inUse = liveBackend?.configuration.baseURL else { return false }
        return BackendSession.origin(of: inUse) == BackendSession.origin(of: server)
    }

    /// The departures whose screen shows a leave-home time taken from the server's plan.
    private func monitoredDepartureIDs() -> Set<OccurrenceID> {
        var ids: Set<OccurrenceID> = []
        for (id, entry) in departures {
            let shown = entry.state.calculation ?? entry.state.staleCalculation
            if shown?.recommendation?.isMonitored == true {
                ids.insert(id)
            }
        }
        return ids
    }

    private func isDue(_ last: Date?, at now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.monitoringRetryInterval
    }
}
