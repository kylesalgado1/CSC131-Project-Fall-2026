import XCTest
@testable import WaitItOutUX

/// Stage S2: the model keeps the server's trip monitoring in line with the saved schedule.
/// Every change that matters (create, edit, delete, samples, home or campus, the toggle, the
/// data mode, the server address) ends with the right set acknowledged or withdrawn; nothing
/// is sent before the schedule loads; monitoring is claimed only after the server
/// acknowledged the current trips; failures are retried by the rules; and in Live mode the
/// local reminder adapter is not used at all.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The one-time class runs 9:00 to 9:50 AM with an
/// ideal arrival of 8:15 AM; the lab runs 11:00 to 11:50 AM with an ideal arrival of 10:15 AM.
@MainActor
final class WaitItOutModelMonitoringTests: XCTestCase {
    // MARK: Helpers

    private let address = "https://backend.example"

    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private func mondayMorningClock() -> ManualWallClock {
        ManualWallClock(pacific(2026, 10, 26, 6))
    }

    private func oneTimeClass(id: UUID = UUID(), arrival: Date? = nil) -> Activity {
        TestFixtures.activity(
            id: id,
            title: "One-time class",
            start: pacific(2026, 10, 26, 9),
            end: pacific(2026, 10, 26, 9, 50),
            arrival: arrival ?? pacific(2026, 10, 26, 8, 15)
        )
    }

    private func lab(id: UUID = UUID()) -> Activity {
        TestFixtures.activity(
            id: id,
            title: "Lab",
            start: pacific(2026, 10, 26, 11),
            end: pacific(2026, 10, 26, 11, 50),
            arrival: pacific(2026, 10, 26, 10, 15)
        )
    }

    private func occurrenceID(_ activity: Activity, in zone: TimeZone = TestFixtures.pacific) -> OccurrenceID {
        OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: zone))
    }

    /// A live estimator that recommends leaving 70 minutes before the ideal arrival.
    private func steadyBackend(_ clock: ManualWallClock) -> ScriptedCommuteEstimator {
        ScriptedCommuteEstimator { request in
            .recommendation(TestBackend.recommendation(
                departure: request.arriveBy.addingTimeInterval(-70 * 60),
                arrival: request.arriveBy.addingTimeInterval(-25 * 60),
                margin: 25 * 60,
                generatedAt: clock.now()
            ))
        }
    }

    private func preferences(remindersOn: Bool, dataMode: DataMode = .live) -> InMemoryPreferencesStore {
        InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn, dataMode: dataMode))
    }

    private func makeModel(
        _ clock: ManualWallClock,
        activities: [Activity] = [],
        monitor: RecordingTripMonitor,
        estimator: (any CommuteEstimating)? = nil,
        remindersOn: Bool = true,
        dataMode: DataMode = .live,
        scheduler: (any ReminderScheduling)? = nil,
        repository: (any ActivityRepository)? = nil
    ) -> WaitItOutModel {
        TestBackend.makeLiveModel(
            clock: clock,
            activities: activities,
            liveEstimator: estimator ?? steadyBackend(clock),
            demoEstimator: ScriptedCommuteEstimator(minutes: 60),
            tripMonitor: monitor,
            store: preferences(remindersOn: remindersOn, dataMode: dataMode),
            reminderScheduler: scheduler,
            repository: repository
        )
    }

    /// Waits until departures, monitoring, and reminders are all idle.
    private func settle(_ model: WaitItOutModel) async {
        for _ in 0..<4 {
            await model.waitForDepartures()
            await model.waitForMonitoring()
            await model.waitForReminders()
        }
        await model.flushPendingSaves()
    }

    /// Loads settings and the schedule and waits for everything, as a launch does.
    private func launch(_ model: WaitItOutModel) async {
        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)
    }

    /// One minute tick `seconds` later: what the Map's and Calendar's clocks do.
    private func tick(_ model: WaitItOutModel, _ clock: ManualWallClock, after seconds: TimeInterval) async {
        clock.advance(by: seconds)
        model.refreshDepartures()
        await settle(model)
    }

    private func expectedTrip(for activity: Activity, home: GeoCoordinate? = nil, campus: CommutePlace? = nil) -> MonitoredTrip {
        MonitoredTrip(
            id: occurrenceID(activity),
            title: activity.title,
            origin: home ?? CommutePlaces.sample.home.coordinate,
            destination: (campus ?? CommutePlaces.sample.campus).coordinate,
            arriveBy: activity.idealArrival,
            timeZoneIdentifier: activity.timeZoneIdentifier
        )
    }

    private func lastSent(_ monitor: RecordingTripMonitor) async throws -> [MonitoredTrip] {
        let sent = await monitor.lastSynchronized()
        return try XCTUnwrap(sent, "Nothing was synchronized")
    }

    private func monitoringPlan(_ clock: ManualWallClock, departure: Date, arrival: Date, isStale: Bool = false) -> RecordingTripMonitor.Report {
        RecordingTripMonitor.Report(
            phase: .monitoring,
            plan: TestBackend.plan(departure: departure, arrival: arrival, evaluatedAt: clock.now(), isStale: isStale)
        )
    }

    // MARK: Without a monitoring service

    func testWithoutAMonitoringServiceNothingChanges() async throws {
        let clock = mondayMorningClock()
        let scheduler = RecordingReminderScheduler()
        let activity = oneTimeClass()
        let model = TestFixtures.makeModel(clock: clock, repository: InMemoryActivityRepository(initial: [activity]), reminderScheduler: scheduler)
        XCTAssertFalse(model.usesTripMonitoring)
        await model.loadPreferences()
        await model.loadActivities()
        model.setRemindersEnabled(true)
        await settle(model)

        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.monitoringObstacle, .off)
        XCTAssertNil(model.monitoringSummary(for: occurrenceID(activity)))
        XCTAssertEqual(model.reminderSync, .synced, "The standalone prototype keeps its preview reminders")
        XCTAssertEqual(model.reminderPreviews.count, 1)
        let pending = await scheduler.pending
        XCTAssertEqual(pending.count, 1)
        model.retryMonitoring()
        model.pushRegistrationDidChange()
        model.requestNotificationPermission()
        await model.markDeparted(occurrenceID(activity))
        XCTAssertTrue(model.departedStates.isEmpty)
        XCTAssertEqual(model.notificationPermission, .notDetermined)
    }

    // MARK: What is sent, and when

    func testNothingIsSentBeforeTheScheduleLoads() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        XCTAssertTrue(model.usesTripMonitoring)

        await model.loadPreferences()
        model.appDidBecomeActive()
        model.retryMonitoring()
        await settle(model)
        var events = await monitor.events
        XCTAssertTrue(events.isEmpty, "An empty list before the schedule is read would cancel every trip the server monitors: \(events)")
        XCTAssertEqual(model.monitoringStatus, .off)

        await model.loadActivities()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1"])
        let sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: activity)])
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
        XCTAssertEqual(model.monitoredTrips.keys.map(\.rawValue), [occurrenceID(activity).rawValue])
        XCTAssertEqual(model.pushDelivery, PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil))
        XCTAssertEqual(model.monitorHealth, MonitorHealth(enabled: true, dependable: true, lastTickAt: nil))
    }

    func testTurningRemindersOnAsksForPermissionAndSynchronizes() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.notDetermined, afterRequest: .authorized)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor, remindersOn: false)
        await launch(model)

        var events = await monitor.events
        XCTAssertEqual(events, ["unregister \(address)"], "Off at launch: whatever an earlier launch left on the server is withdrawn")
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.monitoringWithdrawal, .none)
        var permissionRequests = await monitor.permissionRequests
        XCTAssertEqual(permissionRequests, 0, "Nobody is prompted before turning the feature on")

        model.setRemindersEnabled(true)
        XCTAssertEqual(model.monitoringStatus, .pending, "Not active before the server acknowledged the trips")
        XCTAssertEqual(model.monitoringObstacle, .pending)
        await settle(model)

        permissionRequests = await monitor.permissionRequests
        XCTAssertEqual(permissionRequests, 1, "The system prompt belongs to turning the feature on")
        XCTAssertEqual(model.notificationPermission, .authorized)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
        XCTAssertNil(model.monitoringObstacle)
        events = await monitor.events
        XCTAssertEqual(events, ["unregister \(address)", "synchronize 1", "synchronize 1"], "Once for the trips, once more to tell the server the permission")
        let sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: activity)])
        await model.flushPendingSaves()
        XCTAssertTrue(model.remindersEnabled)
    }

    func testCreateEditAndDeleteEachSendTheNewSet() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, monitor: monitor)
        await launch(model)
        var sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [], "On with nothing saved: the empty set is acknowledged too")
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 0))
        XCTAssertEqual(model.monitoringDeliverySentence, "Notifications have not been allowed for this app yet.")

        let activity = oneTimeClass()
        try await model.saveActivity(activity)
        await settle(model)
        sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: activity)])

        let earlier = oneTimeClass(id: activity.id, arrival: pacific(2026, 10, 26, 8))
        try await model.saveActivity(earlier)
        await settle(model)
        sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: earlier)], "The same trip id with the new arrival time")
        XCTAssertEqual(sent?.first?.id, occurrenceID(activity))
        XCTAssertEqual(model.monitoredTrips[occurrenceID(activity)]?.arriveBy, pacific(2026, 10, 26, 8))

        var renamed = earlier
        renamed.title = "  Renamed class  "
        try await model.saveActivity(renamed)
        await settle(model)
        sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent?.first?.title, "Renamed class", "Trimmed for the notification text")

        try await model.deleteActivity(id: activity.id)
        await settle(model)
        sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [], "Deleting withdraws the trip")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        let count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 5, "One synchronization per change, none for the ticks in between")
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 0))
    }

    func testLoadingAndClearingTheSampleScheduleSendsItsTrips() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, monitor: monitor)
        await launch(model)

        await model.loadSampleActivities()
        await settle(model)
        let sent = try await lastSent(monitor)
        XCTAssertEqual(sent.map(\.title), ["Sample morning class", "Sample afternoon lab", "Sample morning class", "Sample afternoon lab", "Sample morning class"])
        XCTAssertEqual(sent.map(\.arriveBy), [
            pacific(2026, 10, 26, 8, 15), pacific(2026, 10, 27, 11, 15), pacific(2026, 10, 28, 8, 15),
            pacific(2026, 10, 29, 11, 15), pacific(2026, 10, 30, 8, 15)
        ], "Ordered by ideal arrival; next Monday's class lies beyond the seven days")
        XCTAssertEqual(sent.map(\.id.rawValue), [
            "\(SampleActivities.morningClassID.uuidString)@2026-10-26",
            "\(SampleActivities.afternoonLabID.uuidString)@2026-10-27",
            "\(SampleActivities.morningClassID.uuidString)@2026-10-28",
            "\(SampleActivities.afternoonLabID.uuidString)@2026-10-29",
            "\(SampleActivities.morningClassID.uuidString)@2026-10-30"
        ])
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 5))

        await model.clearSampleActivities()
        await settle(model)
        let cleared = await monitor.lastSynchronized()
        XCTAssertEqual(cleared, [])
    }

    func testRecurringOccurrencesKeepTheirIdsAcrossReconciliations() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, monitor: monitor)
        await launch(model)
        await model.loadSampleActivities()
        await settle(model)
        let first = try await lastSent(monitor)
        let countBefore = await monitor.synchronizeCount()

        // Ticks, a foreground, and a relaunch-like reload all describe the same trips.
        await tick(model, clock, after: 60)
        await tick(model, clock, after: 60)
        let countAfterTicks = await monitor.synchronizeCount()
        XCTAssertEqual(countAfterTicks, countBefore, "Nothing changed, so nothing was sent again")
        model.appDidBecomeActive()
        await settle(model)
        await model.loadActivities()
        await settle(model)
        let again = try await lastSent(monitor)
        XCTAssertEqual(again, first, "The same occurrences have the same ids and values every time")
        let countAfterForced = await monitor.synchronizeCount()
        XCTAssertEqual(countAfterForced, countBefore + 2, "Foreground and reload each check with the server once")

        // Once Monday's arrival has passed, that occurrence drops out; the others keep their ids.
        clock.set(pacific(2026, 10, 26, 8, 16))
        model.refreshDepartures()
        await settle(model)
        let later = try await lastSent(monitor)
        XCTAssertEqual(later.map(\.id), Array(first.map(\.id).dropFirst()))
    }

    func testAHomeOrCampusChangeSendsTheNewCoordinates() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        let home = try CommutePlace(name: "New home", coordinate: GeoCoordinate(latitude: 38.60, longitude: -121.50))
        model.setPlace(home, for: .home)
        await settle(model)
        var sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: activity, home: home.coordinate)])

        let campus = try CommutePlace(name: "Other campus", coordinate: GeoCoordinate(latitude: 38.54, longitude: -121.76))
        model.setPlace(campus, for: .campus)
        await settle(model)
        sent = await monitor.lastSynchronized()
        XCTAssertEqual(sent, [expectedTrip(for: activity, home: home.coordinate, campus: campus)], "A campus activity follows the campus set in Settings")
        XCTAssertEqual(sent?.first?.destination, campus.coordinate, "Only the coordinates are sent; the campus name stays on the device")
        let count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 3)
    }

    func testTheWantedTripsArePureBoundedAndOrdered() throws {
        let now = pacific(2026, 10, 26, 6)
        let home = CommutePlaces.sample.home
        var occurrences: [ActivityOccurrence] = []
        for index in 0..<30 {
            let start = now.addingTimeInterval(TimeInterval(30 - index) * 3_600)
            let activity = TestFixtures.activity(title: "Class \(index)", start: start, arrival: start.addingTimeInterval(-1_800))
            occurrences.append(ActivityOccurrence(id: occurrenceID(activity), activity: activity, start: activity.start, end: activity.end, idealArrival: activity.idealArrival))
        }
        let trips = WaitItOutModel.monitoredTrips(for: occurrences, home: home, resolve: { $0 }, now: now)
        XCTAssertEqual(trips.count, 20, "At most twenty")
        XCTAssertEqual(trips.map(\.arriveBy), trips.map(\.arriveBy).sorted(), "Ordered by ideal arrival")
        XCTAssertEqual(trips.first?.title, "Class 29", "The soonest first")
        XCTAssertEqual(Set(trips.map(\.id)).count, 20)

        let limited = WaitItOutModel.monitoredTrips(for: occurrences, home: home, resolve: { $0 }, now: now, limit: 3)
        XCTAssertEqual(limited.map(\.title), ["Class 29", "Class 28", "Class 27"])

        // An arrival that has passed, an unusable destination, and a duplicate are left out.
        let passed = TestFixtures.activity(title: "Passed", start: now.addingTimeInterval(600), arrival: now)
        let nowhere = TestFixtures.activity(
            title: "Nowhere",
            start: now.addingTimeInterval(7_200),
            destination: Destination(id: DestinationID("elsewhere"), name: "Elsewhere", coordinate: GeoCoordinate(latitude: .nan, longitude: 0))
        )
        let fine = TestFixtures.activity(title: "Fine", start: now.addingTimeInterval(7_200))
        let mixed = [passed, nowhere, fine, fine].map {
            ActivityOccurrence(id: occurrenceID($0), activity: $0, start: $0.start, end: $0.end, idealArrival: $0.idealArrival)
        }
        let kept = WaitItOutModel.monitoredTrips(for: mixed, home: home, resolve: { $0 }, now: now)
        XCTAssertEqual(kept.map(\.title), ["Fine"])
        XCTAssertEqual(kept.first?.origin, home.coordinate)
    }

    // MARK: Pending, failed, paused

    func testMonitoringIsPendingUntilTheServerAcknowledges() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.holdSynchronize()
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await model.loadPreferences()
        await model.loadActivities()
        let isWaiting = await waitUntil { await monitor.waitingCount() == 1 }
        XCTAssertTrue(isWaiting)

        XCTAssertEqual(model.monitoringStatus, .pending, "The request is under way: nothing is claimed yet")
        XCTAssertEqual(model.monitoringDeliverySentence, "Waiting for the server to confirm monitoring.")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        XCTAssertNil(model.monitoringSummary(for: occurrenceID(activity)))

        await monitor.release()
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
        XCTAssertNotNil(model.monitoringSummary(for: occurrenceID(activity)))
    }

    func testAnEditDuringASynchronizationEndsWithTheNewestSetAcknowledged() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.holdSynchronize()
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await model.loadPreferences()
        await model.loadActivities()
        let isWaiting = await waitUntil { await monitor.waitingCount() == 1 }
        XCTAssertTrue(isWaiting)

        // The arrival moves while the first snapshot is still on its way.
        let earlier = oneTimeClass(id: activity.id, arrival: pacific(2026, 10, 26, 8))
        try await model.saveActivity(earlier)
        XCTAssertEqual(model.monitoringStatus, .pending)
        let stillOne = await monitor.synchronizeCount()
        XCTAssertEqual(stillOne, 1, "One synchronization at a time")

        // The server acknowledges the older set. That is not what the app wants any more.
        await monitor.releaseOne()
        let isSendingNewest = await waitUntil {
            let count = await monitor.synchronizeCount()
            let waiting = await monitor.waitingCount()
            return count == 2 && waiting == 1
        }
        XCTAssertTrue(isSendingNewest)
        XCTAssertEqual(model.monitoringStatus, .pending, "An acknowledgement of an outdated set is not a reason to claim monitoring")
        XCTAssertEqual(model.monitoredTrips[occurrenceID(activity)]?.arriveBy, pacific(2026, 10, 26, 8, 15), "The server's state is shown as it is: still the old arrival")
        let edited = try XCTUnwrap(model.occurrence(for: occurrenceID(activity)))
        XCTAssertNil(model.monitoringSummary(for: edited), "And it is not presented as the edited trip's")

        await monitor.release()
        await settle(model)
        let sent = await monitor.synchronized
        XCTAssertEqual(sent, [[expectedTrip(for: activity)], [expectedTrip(for: earlier)]], "The older set was acknowledged first, then the newest was sent")
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
        XCTAssertEqual(model.monitoredTrips[occurrenceID(activity)]?.arriveBy, pacific(2026, 10, 26, 8), "What is shown is the server's state for the newest set")
    }

    func testTurningRemindersOffDuringASynchronizationEndsWithdrawn() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.holdSynchronize()
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await model.loadPreferences()
        await model.loadActivities()
        let isWaiting = await waitUntil { await monitor.waitingCount() == 1 }
        XCTAssertTrue(isWaiting)

        model.setRemindersEnabled(false)
        XCTAssertEqual(model.monitoringStatus, .off, "Off at once, whatever the request in flight answers")
        await monitor.release()
        await settle(model)

        let events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)"])
        XCTAssertEqual(model.monitoringStatus, .off, "The acknowledgement that arrived late did not turn it back on")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        XCTAssertNil(model.pushDelivery)
        XCTAssertEqual(model.monitoringWithdrawal, .none)
    }

    func testAFailureIsRetriedAfterAMinuteAndWhenForced() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.failSynchronize(with: .offline)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.monitoringStatus, .failed(.offline, lastAcknowledgedAt: nil))
        XCTAssertEqual(model.monitoringDeliverySentence, "Trips could not be synchronized: the backend could not be reached.")
        XCTAssertEqual(model.monitoringObstacle, .failed(.offline))

        await tick(model, clock, after: 30)
        var count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 1, "Not before a minute has passed")
        await tick(model, clock, after: 30)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 2, "Tried again by the tick after 60 seconds")
        XCTAssertEqual(model.monitoringStatus, .failed(.offline, lastAcknowledgedAt: nil))

        // The foreground does not wait for the minute.
        await monitor.failSynchronize(with: nil)
        clock.advance(by: 5)
        model.appDidBecomeActive()
        await settle(model)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 3)
        let acknowledgedAt = clock.now()
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: acknowledgedAt, tripCount: 1))

        // A later failure says when the server last acknowledged.
        await monitor.failSynchronize(with: .timedOut)
        clock.advance(by: 120)
        try await model.saveActivity(lab())
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .failed(.timedOut, lastAcknowledgedAt: acknowledgedAt))
        XCTAssertEqual(model.monitoredTrips.count, 1, "What the server last reported stays visible, under the failure")
        XCTAssertNotNil(model.monitoringSummary(for: occurrenceID(activity))?.obstacle, "And no trip is described as actively alerted")

        // Try Again does not wait either.
        await monitor.failSynchronize(with: nil)
        model.retryReminders()
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 2))
    }

    func testARefusedSetWaitsForTryAgainOrAChange() async throws {
        let failure = TripMonitoringFailure.rejected(message: "A trip's arrival time is more than 8 days away.")
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.failSynchronize(with: failure)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.monitoringStatus, .failed(failure, lastAcknowledgedAt: nil))

        await tick(model, clock, after: 61)
        await tick(model, clock, after: 300)
        model.appDidBecomeActive()
        await settle(model)
        var count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 1, "Asking again by itself would only get the same answer")

        model.retryMonitoring()
        await settle(model)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 2, "Try Again asks")

        try await model.saveActivity(lab())
        await settle(model)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 3, "A changed set is a new question")
        XCTAssertEqual(
            MonitoringText.failureSentence(failure),
            "The server did not accept these trips: A trip's arrival time is more than 8 days away."
        )
    }

    func testAServerWithoutMonitoringIsAskedAgainOnForegroundButNeverOnTheTicks() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.failSynchronize(with: .unavailableOnServer)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.monitoringStatus, .failed(.unavailableOnServer, lastAcknowledgedAt: nil))
        XCTAssertEqual(MonitoringText.failureSentence(.unavailableOnServer), "This server does not support trip monitoring yet.")
        var count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 1)

        // The server's tables do not appear by themselves within a minute: the ticks leave it alone.
        await tick(model, clock, after: 61)
        await tick(model, clock, after: 300)
        await tick(model, clock, after: 3_600)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 1, "Never retried on the minute ticks")

        // Opening the app again asks once more: the server may have been set up since.
        model.appDidBecomeActive()
        await settle(model)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 2, "The foreground asks again")
        XCTAssertEqual(model.monitoringStatus, .failed(.unavailableOnServer, lastAcknowledgedAt: nil))

        model.retryMonitoring()
        await settle(model)
        count = await monitor.synchronizeCount()
        XCTAssertEqual(count, 3, "Try Again asks")

        // The toggle is a forced check too, and once the server has monitoring it is used.
        await monitor.failSynchronize(with: nil)
        model.setRemindersEnabled(false)
        await settle(model)
        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertTrue(model.monitoringStatus.isActive)
    }

    func testMonitoringIsPausedWhileSavedActivitiesCannotBeRead() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let repository = ScriptedActivityRepository(initial: [oneTimeClass()])
        await repository.setFailReads(true)
        let model = makeModel(clock, monitor: monitor, repository: repository)
        await launch(model)

        XCTAssertNotNil(model.activityStorageIssue)
        XCTAssertEqual(model.monitoringStatus, .paused)
        XCTAssertEqual(model.monitoringObstacle?.sentence, "Saved activities could not be read, so trip monitoring is paused. Nothing was changed on the server.")
        var events = await monitor.events
        XCTAssertTrue(events.isEmpty, "The empty list read from broken storage is never sent: \(events)")
        await tick(model, clock, after: 120)
        model.appDidBecomeActive()
        await settle(model)
        events = await monitor.events
        XCTAssertTrue(events.isEmpty, "\(events)")

        await repository.setFailReads(false)
        await model.retryLoadingStorage()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1"])
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
    }

    // MARK: Withdrawal

    func testTurningRemindersOffTakesTheTripsOffTheServer() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertTrue(model.monitoringStatus.isActive)

        model.setRemindersEnabled(false)
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.monitoringWithdrawal, .pending, "The server is still being told")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        await settle(model)

        let events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)"])
        XCTAssertEqual(model.monitoringWithdrawal, .none)
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertNil(model.pushDelivery)
        XCTAssertNil(model.monitorHealth)

        // Nothing more is sent while off, whatever happens.
        await tick(model, clock, after: 120)
        model.appDidBecomeActive()
        try await model.saveActivity(lab())
        await settle(model)
        let later = await monitor.events
        XCTAssertEqual(later, events)
    }

    func testAFailedRemovalFallsBackToAnEmptySnapshot() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        await monitor.failUnregister(with: .server(status: 500))

        model.setRemindersEnabled(false)
        await settle(model)
        var events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)", "withdrawTrips"], "The device could not be removed, so its trips were withdrawn with an empty set, without registering anything")
        let synchronized = await monitor.synchronizeCount()
        XCTAssertEqual(synchronized, 1, "The withdrawal never goes through the path that could register a new device")
        XCTAssertEqual(model.monitoringWithdrawal, .none, "No alert can come any more")
        XCTAssertEqual(model.monitoringStatus, .off)

        // The device entry itself is removed when the app next checks, not on every tick.
        await tick(model, clock, after: 120)
        events = await monitor.events
        XCTAssertEqual(events.count, 3)
        await monitor.failUnregister(with: nil)
        model.appDidBecomeActive()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events.last, "unregister \(address)")
        XCTAssertEqual(events.count, 4)
        model.appDidBecomeActive()
        await settle(model)
        let final = await monitor.events
        XCTAssertEqual(final.count, 4, "Removed: nothing is left to do")
    }

    func testAWithdrawalTheServerNeverHeardIsRememberedAndRetried() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        await monitor.failUnregister(with: .offline)
        await monitor.failWithdrawTrips(with: .offline)

        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .off, "Off for the user at once")
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.offline), "But the app does not pretend the server knows")
        XCTAssertEqual(
            MonitoringText.withdrawalSentence(model.monitoringWithdrawal),
            "The server could not be told to stop (the backend could not be reached), so it may still send alerts for a while. This is tried again automatically."
        )
        var events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)", "withdrawTrips"])

        await tick(model, clock, after: 30)
        events = await monitor.events
        XCTAssertEqual(events.count, 3, "Not before a minute has passed")
        await monitor.failUnregister(with: nil)
        await tick(model, clock, after: 30)
        events = await monitor.events
        XCTAssertEqual(events.last, "unregister \(address)")
        XCTAssertEqual(model.monitoringWithdrawal, .none)
    }

    func testTheDemoDataModeWithdrawsAndLiveModeNeverUsesThePreviewAdapter() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let scheduler = RecordingReminderScheduler()
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor, scheduler: scheduler)
        await launch(model)
        await tick(model, clock, after: 60)
        model.appDidBecomeActive()
        await settle(model)

        var reads = await scheduler.readCalls
        var schedules = await scheduler.scheduleCalls
        var cancels = await scheduler.cancelCalls
        XCTAssertEqual([reads, schedules, cancels], [0, 0, 0], "Live: the server sends the alerts and no local reminder exists")
        XCTAssertEqual(model.reminderSync, .idle)
        XCTAssertTrue(model.reminderPreviews.isEmpty)
        XCTAssertEqual(model.reminderPlan, .none)
        XCTAssertEqual(model.reminderPreview, .off)
        XCTAssertTrue(model.monitoringStatus.isActive)

        // Demo: the trips leave the server and the preview adapter takes over, as before.
        model.setDataMode(.demo)
        XCTAssertEqual(model.monitoringStatus, .off)
        await settle(model)
        let events = await monitor.events
        XCTAssertEqual(events.last, "unregister \(address)")
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [pacific(2026, 10, 26, 7, 15)], "The demo formula: 8:15 minus the 60-minute test commute")
        var pending = await scheduler.pending
        XCTAssertEqual(pending.count, 1)
        let synchronizedInDemo = await monitor.synchronizeCount()

        await tick(model, clock, after: 60)
        model.appDidBecomeActive()
        await settle(model)
        let stillTheSame = await monitor.synchronizeCount()
        XCTAssertEqual(stillTheSame, synchronizedInDemo, "Demo: the server holds no trips and is sent none")

        // Back to Live: the local previews are emptied once, then the adapter is left alone.
        model.setDataMode(.live)
        XCTAssertEqual(model.monitoringStatus, .pending)
        await settle(model)
        pending = await scheduler.pending
        XCTAssertTrue(pending.isEmpty, "Local and remote reminders never compete")
        XCTAssertEqual(model.reminderSync, .idle)
        XCTAssertTrue(model.reminderPreviews.isEmpty)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
        reads = await scheduler.readCalls
        schedules = await scheduler.scheduleCalls
        cancels = await scheduler.cancelCalls
        await tick(model, clock, after: 60)
        model.appDidBecomeActive()
        await settle(model)
        let readsAfter = await scheduler.readCalls
        let schedulesAfter = await scheduler.scheduleCalls
        let cancelsAfter = await scheduler.cancelCalls
        XCTAssertEqual([readsAfter, schedulesAfter, cancelsAfter], [reads, schedules, cancels], "Once emptied, the adapter is not touched again while live")
    }

    func testAStoredDemoModeNeverSendsTrips() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let scheduler = RecordingReminderScheduler()
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor, dataMode: .demo, scheduler: scheduler)
        await launch(model)

        let events = await monitor.events
        XCTAssertEqual(events, ["unregister \(address)"], "Only the withdrawal of whatever an earlier launch left behind")
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.count, 1)
        let permissionRequests = await monitor.permissionRequests
        XCTAssertEqual(permissionRequests, 0)

        model.setRemindersEnabled(false)
        model.setRemindersEnabled(true)
        await settle(model)
        let after = await monitor.events
        XCTAssertEqual(after.filter { $0.hasPrefix("synchronize") }, [], "The demo toggle is about previews only")
        let asked = await monitor.permissionRequests
        XCTAssertEqual(asked, 0, "The demo never asks for notification permission")

        // A new server address while in Demo: nothing is sent to it either, and whatever an
        // earlier launch may have left there is withdrawn.
        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        await settle(model)
        let afterAddress = await monitor.events
        XCTAssertEqual(afterAddress, ["unregister \(address)", "unregister http://localhost:3000"])
        XCTAssertFalse(model.previousServerMayStillAlert)
        XCTAssertEqual(model.monitoringStatus, .off)
    }

    func testAnAddressChangeTellsTheOldServerFirst() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertTrue(model.monitoringStatus.isActive)

        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        XCTAssertEqual(model.monitoringStatus, .pending, "Nothing acknowledged by the old server counts for the new one")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        await settle(model)

        let events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)", "synchronize 1"], "The server left behind forgets this installation before the new one gets the trips")
        XCTAssertFalse(model.previousServerMayStillAlert)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
    }

    func testAnOldServerThatCannotBeToldIsRemembered() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        await monitor.failUnregister(with: .offline)

        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        await settle(model)
        XCTAssertTrue(model.previousServerMayStillAlert)
        XCTAssertEqual(MonitoringText.previousServerWarning, "The previous server may still send alerts for a while.")
        XCTAssertTrue(model.monitoringStatus.isActive, "The new server is in use regardless")
        var unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.map { $0?.absoluteString }, [address])

        // Ticks leave it alone; the next foreground tries again.
        await tick(model, clock, after: 120)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.count, 1)
        await monitor.failUnregister(with: nil)
        model.appDidBecomeActive()
        await settle(model)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.map { $0?.absoluteString }, [address, address])
        XCTAssertFalse(model.previousServerMayStillAlert)

        // Going back to a server is not leaving it behind.
        XCTAssertNil(model.applyBackendAddress(""))
        await settle(model)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.map { $0?.absoluteString }, [address, address, "http://localhost:3000"])
    }

    // MARK: Refreshing the server's state

    func testTheServersStateIsReadAgainOnlyWhileATripNeedsIt() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let plan = TestBackend.plan(departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50), evaluatedAt: clock.now())
        // Planned, monitoring starts at 6:30 and the server looks again at 6:20.
        await monitor.report(id, as: .init(phase: .planned, plan: plan, monitoringStartsAt: pacific(2026, 10, 26, 6, 30), nextCheckAt: pacific(2026, 10, 26, 6, 20)))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        await tick(model, clock, after: 60)
        await tick(model, clock, after: 600)
        var refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 0, "Nothing is due on the server before 6:20")

        clock.set(pacific(2026, 10, 26, 6, 20))
        model.refreshDepartures()
        await settle(model)
        refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 1, "The server said it would look at 6:20")
        await tick(model, clock, after: 30)
        refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 1, "At most once a minute")
        await tick(model, clock, after: 30)
        refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 2)

        // Actively monitored: read every minute.
        await monitor.report(id, as: monitoringPlan(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        await tick(model, clock, after: 60)
        await tick(model, clock, after: 60)
        await tick(model, clock, after: 60)
        refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 5)
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring)
        let synchronizations = await monitor.synchronizeCount()
        XCTAssertEqual(synchronizations, 1, "Reading the state never sends the trips again")
        XCTAssertTrue(model.monitoringStatus.isActive)
    }

    func testAChangedTripReResolvesOnlyItsOwnDeparture() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let estimator = steadyBackend(clock)
        let first = oneTimeClass()
        let second = lab()
        let model = makeModel(clock, activities: [first, second], monitor: monitor, estimator: estimator)
        await launch(model)
        func asked(_ activity: Activity) async -> Int {
            await estimator.requests.filter { $0.occurrenceID == self.occurrenceID(activity) }.count
        }
        var classAsked = await asked(first)
        var labAsked = await asked(second)
        XCTAssertEqual([classAsked, labAsked], [1, 1])

        // The server starts monitoring the class; the lab is unchanged.
        await monitor.report(occurrenceID(first), as: monitoringPlan(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        await tick(model, clock, after: 60)
        classAsked = await asked(first)
        labAsked = await asked(second)
        XCTAssertEqual([classAsked, labAsked], [2, 1], "Only the departure whose monitored plan changed was asked again")
        XCTAssertEqual(model.monitoredTrips[occurrenceID(first)]?.phase, .monitoring)

        // The same plan again changes nothing, and nothing is asked again.
        await tick(model, clock, after: 60)
        await tick(model, clock, after: 60)
        classAsked = await asked(first)
        labAsked = await asked(second)
        XCTAssertEqual([classAsked, labAsked], [2, 1])

        // A new plan for the class: again only the class.
        await monitor.report(occurrenceID(first), as: monitoringPlan(clock, departure: pacific(2026, 10, 26, 6, 55), arrival: pacific(2026, 10, 26, 7, 45)))
        await tick(model, clock, after: 60)
        classAsked = await asked(first)
        labAsked = await asked(second)
        XCTAssertEqual([classAsked, labAsked], [3, 1])
    }

    func testAnUnreadableServerStateStopsVouchingForMonitoredAnswers() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let departure = pacific(2026, 10, 26, 7, 5)
        let arrival = pacific(2026, 10, 26, 7, 50)
        await monitor.report(id, as: monitoringPlan(clock, departure: departure, arrival: arrival))
        // The live provider answers from the server's plan while it can, then fails.
        let isReachable = Flag(true)
        let estimator = ScriptedCommuteEstimator { _ in
            guard isReachable.value else { throw CommuteProviderFailure(.offline) }
            return .recommendation(TestBackend.recommendation(departure: departure, arrival: arrival, generatedAt: clock.now(), isMonitored: true))
        }
        let model = makeModel(clock, activities: [activity], monitor: monitor, estimator: estimator)
        await launch(model)
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)

        // The server's state cannot be read any more.
        await monitor.failRefresh(with: .offline)
        isReachable.set(false)
        await tick(model, clock, after: 60)
        XCTAssertTrue(model.monitoringStatus.isActive, "The server still holds what it acknowledged")
        XCTAssertNotNil(model.departures[id]?.state.calculation, "A minute without news is not yet out of date")
        await tick(model, clock, after: 60)
        XCTAssertNotNil(model.departures[id]?.state.calculation)

        await tick(model, clock, after: 60)
        guard case .stale(let kept, .provider(.offline)) = model.departures[id]?.state else {
            return XCTFail("Three minutes without news: the plan is kept but never shown as current, got \(String(describing: model.departures[id]?.state))")
        }
        XCTAssertEqual(kept.leaveHome, departure)
        let refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 3, "Tried every minute meanwhile")

        // News again: the plan is current again.
        await monitor.failRefresh(with: nil)
        isReachable.set(true)
        await tick(model, clock, after: 60)
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, departure)
    }

    func testAServerThatLostTheDeviceGetsEverythingAgain() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        await monitor.failRefresh(with: .reregistered)
        await tick(model, clock, after: 60)
        let events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "refresh", "synchronize 1"], "The read found the device gone, so the trips were sent again")
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: clock.now(), tripCount: 1))
    }

    // MARK: Permission and push

    func testTheForegroundChecksThePushRegistrationAndSynchronizes() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.notificationPermission, .authorized, "Read at launch, without prompting")
        let permissionRequests = await monitor.permissionRequests
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertNil(model.monitoringObstacle)
        XCTAssertEqual(model.monitoringDeliverySentence, "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed.")
        let countAtLaunch = await monitor.synchronizeCount()

        // The user turns notifications off in iOS Settings and comes back.
        await monitor.setPermission(.denied)
        clock.advance(by: 10)
        model.appDidBecomeActive()
        await settle(model)
        let pushRefreshes = await monitor.pushRefreshes
        XCTAssertEqual(pushRefreshes, 2, "Launch and foreground")
        XCTAssertEqual(model.notificationPermission, .denied)
        XCTAssertEqual(model.monitoringObstacle, .permissionDenied)
        XCTAssertEqual(model.monitoringDeliverySentence, "Notifications are off for this app in iOS Settings.")
        let count = await monitor.synchronizeCount()
        XCTAssertGreaterThan(count, countAtLaunch, "The server is told")

        // The host reports a new device token.
        let before = await monitor.synchronizeCount()
        model.pushRegistrationDidChange()
        await settle(model)
        let after = await monitor.synchronizeCount()
        XCTAssertEqual(after, before + 1, "A changed registration is synchronized at once")
    }

    func testAllowNotificationsAsksAndTellsTheServer() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.monitoringObstacle, .permissionNotDetermined)
        let before = await monitor.synchronizeCount()

        await monitor.setPermission(.notDetermined, afterRequest: .authorized)
        model.requestNotificationPermission()
        await settle(model)
        let asked = await monitor.permissionRequests
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(model.notificationPermission, .authorized)
        XCTAssertNil(model.monitoringObstacle)
        let after = await monitor.synchronizeCount()
        XCTAssertEqual(after, before + 1)
    }

    // MARK: "I've left"

    func testIveLeftEndsMonitoringOnlyAfterTheServerAnswers() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let estimator = steadyBackend(clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        let model = makeModel(clock, activities: [activity], monitor: monitor, estimator: estimator)
        await launch(model)
        let summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertTrue(summary.canMarkDeparted, "Offered while the server is actively monitoring")
        XCTAssertTrue(summary.alertsAreActive)
        XCTAssertNil(summary.departedSentence)
        XCTAssertNil(model.departedState(for: id))

        // The server cannot be told.
        await monitor.failDeparted(with: .offline)
        await model.markDeparted(id)
        XCTAssertEqual(model.departedState(for: id), .failed(.offline))
        let failed = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(failed.departedSentence, "Could not tell the server you left; it may still send alerts for this trip.")
        XCTAssertTrue(failed.canMarkDeparted, "Try Again is possible")
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring, "Nothing is claimed")

        // Now it answers.
        await monitor.failDeparted(with: nil)
        let askedBefore = await estimator.requestCount()
        await model.markDeparted(id)
        await settle(model)
        XCTAssertEqual(model.departedState(for: id), .done)
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .departed)
        let done = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(done.departedSentence, "Marked as left. Monitoring ended for this trip.")
        XCTAssertFalse(done.canMarkDeparted)
        XCTAssertFalse(done.alertsAreActive)
        XCTAssertTrue(done.isDeparted)
        let arrivals = await monitor.departedArrivals
        XCTAssertEqual(arrivals, [activity.idealArrival, activity.idealArrival], "Sent for the trip's current arrival time")
        let askedAfter = await estimator.requestCount()
        XCTAssertEqual(askedAfter, askedBefore + 1, "The leave-home time is asked again, now directly")
    }

    func testIveLeftFromAnOldNotificationCannotEndARescheduledTrip() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        let before = await monitor.synchronizeCount()

        // The notification was about an 8:00 arrival; the trip is now for 8:15.
        let payload: [AnyHashable: Any] = ["tripId": id.rawValue, "kind": "leave_now", "arriveBy": "2026-10-26T15:00:00.000Z"]
        await model.handleNotificationAction(
            tripID: try XCTUnwrap(TripNotificationPayload.tripID(from: payload)),
            action: TripNotificationPayload.action(forIdentifier: "WAIT_IT_OUT_LEFT"),
            arriveBy: TripNotificationPayload.arriveBy(from: payload)
        )
        await settle(model)

        let arrivals = await monitor.departedArrivals
        XCTAssertEqual(arrivals, [pacific(2026, 10, 26, 8)], "Exactly the arrival time the notification carried")
        XCTAssertEqual(model.departedState(for: id), .failed(.superseded))
        XCTAssertEqual(model.monitoringSummary(for: id)?.departedSentence, "This trip was rescheduled; monitoring continues for the new time.")
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring)
        XCTAssertEqual(model.tripToPresent, id, "The trip is opened so the outcome is visible")
        XCTAssertEqual(model.selectedTab, .calendar)
        let after = await monitor.synchronizeCount()
        XCTAssertEqual(after, before + 1, "The app checks what the server holds")
    }

    // MARK: Notifications

    func testOpeningATripShowsItsDayAndReadsItsState() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let estimator = steadyBackend(clock)
        // Wednesday's class, while the Map shows today.
        let wednesday = TestFixtures.activity(
            title: "Midweek class",
            start: pacific(2026, 10, 28, 9),
            end: pacific(2026, 10, 28, 9, 50),
            arrival: pacific(2026, 10, 28, 8, 15)
        )
        let id = occurrenceID(wednesday)
        let model = makeModel(clock, activities: [wednesday], monitor: monitor, estimator: estimator)
        await launch(model)
        XCTAssertEqual(model.selectedTab, .map)
        let askedBefore = await estimator.requestCount()

        model.openTrip(id)
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertEqual(model.selectedDay, pacific(2026, 10, 28, 0))
        XCTAssertEqual(model.tripToPresent, id)
        XCTAssertNil(model.calendarNotice)
        XCTAssertEqual(model.occurrence(for: id)?.idealArrival, pacific(2026, 10, 28, 8, 15))
        await settle(model)
        let tripRefreshes = await monitor.tripRefreshes
        XCTAssertEqual(tripRefreshes, [id], "The trip's current state is read from the server")
        let askedAfter = await estimator.requestCount()
        XCTAssertEqual(askedAfter, askedBefore + 1, "And its leave-home time is asked again")
    }

    func testATripTappedBeforeTheScheduleLoadsOpensAfterTheLoad() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let model = makeModel(clock, activities: [activity], monitor: monitor)

        // A cold start from a notification: nothing is loaded yet.
        await model.handleNotificationAction(tripID: id.rawValue, action: .open)
        XCTAssertNil(model.tripToPresent)
        XCTAssertEqual(model.selectedTab, .map)
        XCTAssertNil(model.occurrence(for: id))

        await model.prepareForNotificationResponse()
        XCTAssertEqual(model.tripToPresent, id)
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertEqual(model.selectedDay, pacific(2026, 10, 26, 0))
        await settle(model)
    }

    func testATripThatIsGoneLeavesANotice() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        let deleted = OccurrenceID(activityID: UUID(), date: LocalDate.of(activity.start, in: TestFixtures.pacific))
        model.openTrip(deleted)
        XCTAssertEqual(model.calendarNotice, "That trip is no longer in your calendar.")
        XCTAssertNil(model.tripToPresent)
        XCTAssertEqual(model.selectedTab, .calendar)

        model.dismissCalendarNotice()
        model.selectedTab = .map
        // The activity exists, but not on that day.
        let otherDay = OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific).adding(days: 1))
        XCTAssertNil(model.occurrence(for: otherDay))
        model.openTrip(otherDay)
        XCTAssertEqual(model.calendarNotice, "That trip is no longer in your calendar.")

        model.dismissCalendarNotice()
        await model.handleNotificationAction(tripID: "not an occurrence id", action: .left)
        XCTAssertEqual(model.calendarNotice, "That trip is no longer in your calendar.")
        let departed = await monitor.departedCalls
        XCTAssertTrue(departed.isEmpty)
    }

    func testANotificationResponseJoinsTheLaunchLoad() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let store = CountingPreferencesStore(UserPreferences(leaveHomeRemindersEnabled: true))
        let model = TestBackend.makeLiveModel(
            clock: clock,
            activities: [oneTimeClass()],
            liveEstimator: steadyBackend(clock),
            tripMonitor: monitor,
            store: store
        )

        async let launchLoad: Void = model.loadStoredState()
        async let response: Void = model.prepareForNotificationResponse()
        async let secondResponse: Void = model.prepareForNotificationResponse()
        _ = await (launchLoad, response, secondResponse)
        await settle(model)

        let loads = await store.loads
        XCTAssertEqual(loads, 1, "One load, however many callers asked")
        XCTAssertEqual(model.activities.count, 1)
        XCTAssertTrue(model.remindersEnabled, "Stored settings were applied before anything was sent")

        await model.prepareForNotificationResponse()
        let later = await store.loads
        XCTAssertEqual(later, 1, "Already loaded: nothing is read again")
        let synchronizations = await monitor.synchronizeCount()
        XCTAssertEqual(synchronizations, 1)
    }

    // MARK: Summaries

    func testTheSummaryIsForTheTripTheServerHolds() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        await monitor.holdSynchronize()
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let departure = pacific(2026, 10, 26, 7, 5)
        await monitor.report(id, as: .init(phase: .planned, plan: TestBackend.plan(departure: departure, arrival: pacific(2026, 10, 26, 7, 50), evaluatedAt: clock.now())))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await model.loadPreferences()
        await model.loadActivities()
        await monitor.release()
        await settle(model)

        let occurrence = try XCTUnwrap(model.occurrence(for: id))
        let summary = try XCTUnwrap(model.monitoringSummary(for: occurrence))
        XCTAssertEqual(summary.phase, .planned)
        XCTAssertEqual(summary.recommendedDeparture, departure)
        XCTAssertEqual(summary.monitoringStartsAt, departure.addingTimeInterval(-120 * 60))
        XCTAssertEqual(summary.headsUpAt, departure.addingTimeInterval(-90 * 60))
        XCTAssertNil(summary.headsUpSentAt)
        XCTAssertNil(summary.obstacle)
        XCTAssertTrue(summary.alertsAreActive)
        XCTAssertFalse(summary.canMarkDeparted, "Not offered before monitoring started")
        XCTAssertEqual(summary.deliverySentence, MonitoringText.activeDelivery)
        XCTAssertEqual(model.nextMonitoringSummary(at: clock.now()), summary)

        // An edit the server has not acknowledged yet: its state is for another arrival time.
        await monitor.holdSynchronize()
        let earlier = oneTimeClass(id: activity.id, arrival: pacific(2026, 10, 26, 8))
        try await model.saveActivity(earlier)
        let edited = try XCTUnwrap(model.occurrence(for: id))
        XCTAssertNil(model.monitoringSummary(for: edited), "The old trip's state is not shown under the edited one")
        XCTAssertNil(model.nextMonitoringSummary(at: clock.now()))
        await monitor.release()
        await settle(model)
        XCTAssertNotNil(model.monitoringSummary(for: edited))
    }

    func testEveryObstacleReachesTheSummary() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        XCTAssertNil(model.monitoringObstacle)

        func resynchronized() async -> MonitoringObstacle? {
            model.appDidBecomeActive()
            await settle(model)
            return model.monitoringSummary(for: id)?.obstacle
        }
        await monitor.setPush(PushDeliveryStatus(serverConfigured: false, deviceRegistered: true, authorized: true, lastFailure: nil))
        var obstacle = await resynchronized()
        XCTAssertEqual(obstacle, .serverCannotPush)
        await monitor.setPush(PushDeliveryStatus(serverConfigured: true, deviceRegistered: false, authorized: true, lastFailure: "BadDeviceToken"))
        obstacle = await resynchronized()
        XCTAssertEqual(obstacle, .deviceNotRegistered)
        XCTAssertEqual(model.pushDelivery?.lastFailure, "BadDeviceToken")
        await monitor.setPush(PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: false, lastFailure: nil))
        obstacle = await resynchronized()
        XCTAssertEqual(obstacle, .permissionNotReported)
        await monitor.setPush(PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil))
        await monitor.setMonitor(MonitorHealth(enabled: false, dependable: false, lastTickAt: nil))
        obstacle = await resynchronized()
        XCTAssertEqual(obstacle, .monitorNotRunning)
        await monitor.setMonitor(MonitorHealth(enabled: true, dependable: false, lastTickAt: clock.now()))
        obstacle = await resynchronized()
        XCTAssertEqual(obstacle, .monitorNotDependable)
        XCTAssertEqual(model.monitoringDeliverySentence, "This server only checks traffic while it is awake, so alerts can be late or missing when the app is closed.")
        XCTAssertEqual(model.monitoringSummary(for: id)?.alertsAreActive, false)
        await monitor.setMonitor(MonitorHealth(enabled: true, dependable: true, lastTickAt: clock.now()))
        obstacle = await resynchronized()
        XCTAssertNil(obstacle)
    }

    func testTheServersLimitsReplaceTheFallback() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let limits = MonitoringLimits(planningHorizon: 600 * 60, monitorLead: 60 * 60, headsUpLead: 45 * 60, meaningfulShift: 10 * 60, maxTrips: 2)
        await monitor.setLimits(limits)
        let model = makeModel(clock, monitor: monitor)
        XCTAssertEqual(model.monitoringLimits, .fallback)
        await launch(model)
        XCTAssertEqual(model.monitoringLimits, limits)

        // The server takes two trips at most, so the app sends the two soonest.
        await model.loadSampleActivities()
        await settle(model)
        let sent = try await lastSent(monitor)
        XCTAssertEqual(sent.map(\.arriveBy), [pacific(2026, 10, 26, 8, 15), pacific(2026, 10, 27, 11, 15)])
        XCTAssertEqual(
            MonitoringText.remindersFooter(limits: model.monitoringLimits),
            "The team backend watches traffic for your upcoming trips, starting about 1 hour before the recommended departure. It sends a heads-up about 45 minutes before, an update only when the departure moves by at least 10 minutes, and an alert when it is time to leave. Delivery is best effort and needs notification permission. The app sends your trips for the next 7 days (at most 2) to the server each time it is opened or brought to the foreground, so alerts stop for later trips unless you open the app again. Trips are removed from the server after they end; turning this off deletes this installation's data from the server."
        )

        // Another source starts from the fallback again.
        model.setDataMode(.demo)
        XCTAssertEqual(model.monitoringLimits, .fallback)
        await settle(model)
    }

    // MARK: Time zones and daylight saving

    func testOccurrencesAcrossTheFallBackCarryCorrectInstantsAndZones() async throws {
        // Fri 2026-10-30 06:00 PDT. Clocks go back on Sun 2026-11-01.
        let clock = ManualWallClock(pacific(2026, 10, 30, 6))
        let monitor = RecordingTripMonitor(clock: clock)
        let series = TestFixtures.activity(
            title: "Weekly class",
            start: pacific(2026, 10, 30, 9),
            end: pacific(2026, 10, 30, 9, 50),
            arrival: pacific(2026, 10, 30, 8, 15),
            repeatWeekdays: [.monday, .friday]
        )
        let model = makeModel(clock, activities: [series], monitor: monitor)
        await launch(model)

        let sent = try await lastSent(monitor)
        XCTAssertEqual(sent.map(\.id.rawValue), ["\(series.id.uuidString)@2026-10-30", "\(series.id.uuidString)@2026-11-02"])
        XCTAssertEqual(sent.map(\.arriveBy), [
            Date(timeIntervalSince1970: 1_793_373_300),
            Date(timeIntervalSince1970: 1_793_636_100)
        ], "8:15 AM PDT is 15:15 UTC on Friday; 8:15 AM PST is 16:15 UTC on Monday")
        XCTAssertEqual(sent.map { TestBackend.iso($0.arriveBy) }, ["2026-10-30T15:15:00.000Z", "2026-11-02T16:15:00.000Z"])
        XCTAssertEqual(Set(sent.map(\.timeZoneIdentifier)), ["America/Los_Angeles"])
    }

    func testOccurrencesAcrossTheSpringForwardCarryCorrectInstantsAndZones() async throws {
        // Fri 2027-03-12 06:00 PST. Clocks go forward on Sun 2027-03-14.
        let clock = ManualWallClock(pacific(2027, 3, 12, 6))
        let monitor = RecordingTripMonitor(clock: clock)
        let series = TestFixtures.activity(
            title: "Weekly class",
            start: pacific(2027, 3, 12, 9),
            end: pacific(2027, 3, 12, 9, 50),
            arrival: pacific(2027, 3, 12, 8, 15),
            repeatWeekdays: [.monday, .friday]
        )
        let model = makeModel(clock, activities: [series], monitor: monitor)
        await launch(model)

        let sent = try await lastSent(monitor)
        XCTAssertEqual(sent.map(\.id.rawValue), ["\(series.id.uuidString)@2027-03-12", "\(series.id.uuidString)@2027-03-15"])
        XCTAssertEqual(sent.map { TestBackend.iso($0.arriveBy) }, ["2027-03-12T16:15:00.000Z", "2027-03-15T15:15:00.000Z"], "8:15 AM PST, then 8:15 AM PDT")
        XCTAssertEqual(Set(sent.map(\.timeZoneIdentifier)), ["America/Los_Angeles"])
    }

    func testAnActivityInAnotherZoneKeepsItsOwnLocalDayAndZone() async throws {
        let clock = mondayMorningClock()
        let monitor = RecordingTripMonitor(clock: clock)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 12:30 AM on Tuesday in New York is 9:30 PM on Monday in California.
        let start = TestFixtures.date(2026, 10, 27, 0, 30, in: newYork)
        let seminar = TestFixtures.activity(title: "Remote seminar", start: start, arrival: start.addingTimeInterval(-15 * 60), timeZone: newYork)
        let model = makeModel(clock, activities: [seminar], monitor: monitor)
        await launch(model)

        let sent = try await lastSent(monitor)
        XCTAssertEqual(sent.map(\.id.rawValue), ["\(seminar.id.uuidString)@2026-10-27"], "The id keeps the activity's own local day, not the device's")
        XCTAssertEqual(sent.first?.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(sent.first.map { TestBackend.iso($0.arriveBy) }, "2026-10-27T04:15:00.000Z")
        let id = try XCTUnwrap(sent.first?.id)
        XCTAssertEqual(model.occurrence(for: id)?.start, start, "The id leads back to the same occurrence")
        model.openTrip(id)
        XCTAssertEqual(model.selectedDay, pacific(2026, 10, 26, 0), "Shown on the calendar's own day")
        await settle(model)
    }
}

/// A flag a test flips from the main actor while a provider reads it from another task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Preferences store that counts how often it was read.
private actor CountingPreferencesStore: PreferencesStoring {
    private let stored: UserPreferences
    private(set) var loads = 0

    init(_ stored: UserPreferences) {
        self.stored = stored
    }

    nonisolated var persistenceDescription: String { "Counting test store" }

    func loadPreferences() async throws -> UserPreferences? {
        loads += 1
        return stored
    }

    func savePreferences(_ preferences: UserPreferences) async throws {}
}
