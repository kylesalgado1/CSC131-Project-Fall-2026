import XCTest
@testable import WaitItOutUX

/// Honesty of server-side trip monitoring in the states an adversarial review found wrong:
/// unreadable settings pause instead of withdrawing; a server left behind is found again after
/// a restart; a recorded "I've left" does not outlive a reschedule or a new registration; a
/// trip the server cannot plan is never described as alerted; the server's own no-plan
/// sentence is repeated only while it is fresh; Try Again under a plan the server could not
/// refresh reads the trip again; a state that could not be read again stops showing alert
/// times; and a withdrawal the server could not confirm is not reported as done.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The one-time class runs 9:00 to 9:50 AM with an
/// ideal arrival of 8:15 AM.
@MainActor
final class WaitItOutModelMonitoringStateTests: XCTestCase {
    // MARK: Helpers

    private let address = "https://backend.example"
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)

    private func pacific(_ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(2026, 10, 26, hour, minute)
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> String {
        formatter.clockTime(pacific(hour, minute))
    }

    private func oneTimeClass(arrival: Date? = nil) -> Activity {
        TestFixtures.activity(title: "One-time class", start: pacific(9), end: pacific(9, 50), arrival: arrival ?? pacific(8, 15))
    }

    private func occurrenceID(_ activity: Activity) -> OccurrenceID {
        OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
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

    private func makeModel(
        _ clock: ManualWallClock,
        activities: [Activity],
        monitor: RecordingTripMonitor,
        estimator: (any CommuteEstimating)? = nil,
        store: (any PreferencesStoring)? = nil,
        remindersOn: Bool = true
    ) -> WaitItOutModel {
        TestBackend.makeLiveModel(
            clock: clock,
            activities: activities,
            liveEstimator: estimator ?? steadyBackend(clock),
            demoEstimator: ScriptedCommuteEstimator(minutes: 60),
            tripMonitor: monitor,
            store: store ?? InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn))
        )
    }

    private func settle(_ model: WaitItOutModel) async {
        for _ in 0..<4 {
            await model.waitForDepartures()
            await model.waitForMonitoring()
            await model.waitForReminders()
        }
        await model.flushPendingSaves()
    }

    private func launch(_ model: WaitItOutModel) async {
        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)
    }

    private func tick(_ model: WaitItOutModel, _ clock: ManualWallClock, after seconds: TimeInterval) async {
        clock.advance(by: seconds)
        model.refreshDepartures()
        await settle(model)
    }

    private func monitoringPlan(_ clock: ManualWallClock, departure: Date? = nil) -> RecordingTripMonitor.Report {
        let leave = departure ?? pacific(7, 5)
        return RecordingTripMonitor.Report(
            phase: .monitoring,
            plan: TestBackend.plan(departure: leave, arrival: leave.addingTimeInterval(45 * 60), evaluatedAt: clock.now())
        )
    }

    // MARK: Unreadable settings

    func testUnreadableSettingsPauseMonitoringInsteadOfWithdrawingTheInstallation() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        // What the user really chose, which cannot be read at launch: alerts on, another server.
        let stored = UserPreferences(leaveHomeRemindersEnabled: true, backendAddress: "https://chosen.example")
        let store = UnreadableUntilToldPreferencesStore(stored: stored)
        let other = try XCTUnwrap(URL(string: "https://chosen.example"))
        await monitor.setServersLeftBehind([other])
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor, store: store)

        await launch(model)
        XCTAssertNotNil(model.preferencesStorageIssue)
        XCTAssertFalse(model.remindersEnabled, "The defaults are in effect: alerts off, the built-in server")
        var events = await monitor.events
        XCTAssertEqual(events, [], "Neither withdrawn from the built-in server nor from the server the user had chosen, and nothing synchronized on a default's word")
        XCTAssertEqual(model.monitoringStatus, .settingsUnreadable)
        XCTAssertEqual(model.monitoringObstacle, .settingsUnreadable)
        XCTAssertTrue(model.isMonitoringPausedForSettings)

        let shown = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(shown, MonitoringPresentation(
            kind: .paused,
            status: "Saved settings could not be read, so nothing was changed on the server. If leave-home alerts were on, the server may still send them."
        ), "Not \"alerts are off\": that is not known")
        XCTAssertTrue(model.showsMonitoringOnMap, "The Map says so too")

        // Ticks and the foreground keep it that way.
        await tick(model, clock, after: 61)
        model.appDidBecomeActive()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events, [])
        XCTAssertFalse(model.previousServerMayStillAlert, "The chosen server was not treated as left behind")

        // The settings can be read again: what the user chose applies, on the chosen server.
        await store.makeReadable()
        await model.retryLoadingStorage()
        await settle(model)
        XCTAssertNil(model.preferencesStorageIssue)
        XCTAssertTrue(model.remindersEnabled)
        XCTAssertEqual(model.backendBaseURL, other)
        XCTAssertTrue(model.monitoringStatus.isActive)
        events = await monitor.events
        XCTAssertTrue(events.contains("synchronize 1"), "\(events)")
        XCTAssertFalse(events.contains("unregister https://chosen.example"), "The server in use is never withdrawn from: \(events)")
    }

    func testAnExplicitChoiceEndsThePauseForUnreadableSettings() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor, store: FailingPreferencesStore())
        await launch(model)
        XCTAssertEqual(model.monitoringStatus, .settingsUnreadable)
        var events = await monitor.events
        XCTAssertEqual(events, [])

        // The user turns alerts on now: that is a wish the app does know.
        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertFalse(model.isMonitoringPausedForSettings)
        XCTAssertTrue(model.monitoringStatus.isActive)
        events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1"])

        // And off again: now the withdrawal is the user's own decision.
        model.setRemindersEnabled(false)
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)"])
        XCTAssertEqual(model.monitoringStatus, .off)
    }

    // MARK: Servers left behind

    func testAServerLeftBehindIsFoundAgainAfterARestart() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        // An earlier launch changed the address while the old server could not be told; its
        // credential is still stored, and this launch knows nothing else about it.
        let old = try XCTUnwrap(URL(string: "https://old.example"))
        await monitor.setServersLeftBehind([old])
        await monitor.failUnregister(from: old, with: .offline)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)

        await launch(model)
        var unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.map { $0?.absoluteString }, ["https://old.example"], "Tried at launch, from the stored credential alone")
        XCTAssertTrue(model.previousServerMayStillAlert, "And said when it still cannot be told")
        XCTAssertTrue(model.monitoringStatus.isActive, "The server in use is unaffected")

        // Ticks leave it alone; the next foreground tries again, and succeeds.
        await tick(model, clock, after: 120)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.count, 1)
        await monitor.failUnregister(from: old, with: nil)
        model.appDidBecomeActive()
        await settle(model)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.map { $0?.absoluteString }, ["https://old.example", "https://old.example"])
        XCTAssertFalse(model.previousServerMayStillAlert)

        // Nothing is left to tell.
        model.appDidBecomeActive()
        await settle(model)
        unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.count, 2)
    }

    func testAServerThatIsInUseAgainIsNotWithdrawnFromAsLeftBehind() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        // The store still names the built-in server, which is the one in use.
        await monitor.setServersLeftBehind([TestBackend.baseURL])
        await launch(model)
        let unregistered = await monitor.unregistered
        XCTAssertEqual(unregistered.count, 0, "The server in use is never told to forget this installation")
        XCTAssertFalse(model.previousServerMayStillAlert)
        XCTAssertTrue(model.monitoringStatus.isActive)
    }

    // MARK: "I've left" after a reschedule or a new registration

    func testIveLeftIsForgottenWhenTheServerMonitorsTheTripAgain() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        await model.markDeparted(id)
        await settle(model)
        XCTAssertEqual(model.departedState(for: id), .done)
        XCTAssertEqual(model.monitoringSummary(for: id)?.departedSentence, "Marked as left. Monitoring ended for this trip.")
        XCTAssertEqual(model.monitoringSummary(for: id)?.canMarkDeparted, false)

        // The user moves the ideal arrival to 8:30. The server restarts the trip for the new
        // time and monitors it again.
        let moved = TestFixtures.activity(id: activity.id, title: activity.title, start: activity.start, end: activity.end, arrival: pacific(8, 30))
        await monitor.report(id, as: monitoringPlan(clock, departure: pacific(7, 20)))
        try await model.saveActivity(moved)
        await settle(model)

        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring)
        XCTAssertNil(model.departedState(for: id), "What was recorded for the earlier arrival time is gone")
        let summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertNil(summary.departedSentence, "Nothing claims that monitoring ended")
        XCTAssertFalse(summary.isDeparted)
        XCTAssertTrue(summary.canMarkDeparted, "I've Left is offered for the new time")
        XCTAssertEqual(
            formatter.monitoringPlanLines(for: summary, at: clock.now()),
            ["Monitoring started \(time(5, 20)).", "Time-to-leave alert at the recommended departure, currently \(time(7, 20))."],
            "And the server's plan is listed again"
        )
    }

    func testIveLeftIsForgottenWhenTheDeviceIsRegisteredAnew() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock))
        // A second trip that is still being planned keeps the minute ticks reading the server.
        let lab = TestFixtures.activity(title: "Lab", start: pacific(11), end: pacific(11, 50), arrival: pacific(10, 15))
        let model = makeModel(clock, activities: [activity, lab], monitor: monitor)
        await launch(model)
        await model.markDeparted(id)
        await settle(model)
        XCTAssertEqual(model.departedState(for: id), .done)

        // The server lost the device. Registered anew, it holds the trip as active again.
        await monitor.report(id, as: monitoringPlan(clock))
        await monitor.failRefresh(with: .reregistered)
        await tick(model, clock, after: 60)
        await monitor.failRefresh(with: nil)
        await settle(model)

        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring)
        XCTAssertNil(model.departedState(for: id))
        XCTAssertEqual(model.monitoringSummary(for: id)?.canMarkDeparted, true)
    }

    // MARK: A trip the server cannot plan

    func testATripTheServerCannotPlanIsNeverDescribedAsAlerted() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: .init(phase: .planning, plan: nil, lastErrorCode: "budget_exhausted"))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        XCTAssertTrue(model.monitoringStatus.isActive, "The server holds the trip")
        XCTAssertNil(model.monitoringObstacle, "And nothing is wrong with the delivery path")
        XCTAssertNotNil(model.departures[id]?.state.calculation, "A direct question still gets a leave-home time")

        let problem = "The server has used up its traffic checks for today, so this trip is not being re-checked. A time-to-leave alert is still sent from the last plan, if there is one."
        let summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(summary.lastErrorCode, "budget_exhausted")
        XCTAssertFalse(summary.alertsAreActive)

        let settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(settings.kind, .problem)
        XCTAssertEqual(settings.status, "The server confirmed your trips, but alerts are not active for the next one right now.")
        XCTAssertEqual(settings.details, [
            "The server confirmed 1 trip at \(time(6)).",
            "Alerts are set up for trips through Monday, October 26. Open the app again before then to keep them coming.",
            "Next monitored trip: One-time class, arrive by \(time(8, 15)).",
            problem
        ])
        let occurrence = try XCTUnwrap(model.occurrence(for: id))
        let card = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true, trip: occurrence)
        XCTAssertEqual(card.kind, .problem)
        XCTAssertEqual(card.status, "Alerts are not active for this trip right now.")
        XCTAssertEqual(card.details, [problem])
        XCTAssertEqual(formatter.tripMonitoringSentences(for: summary, at: clock.now()), ["Alerts are not active for this trip right now.", problem])
        for sentence in [settings.status, card.status] + settings.details + card.details {
            XCTAssertFalse(sentence.contains("working out"), sentence)
            XCTAssertFalse(sentence.contains("will try to alert"), sentence)
        }

        // The server plans the trip after all: the ordinary wording returns.
        await monitor.report(id, as: monitoringPlan(clock))
        await tick(model, clock, after: 60)
        let recovered = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(recovered.kind, .active)
        XCTAssertEqual(recovered.status, MonitoringText.activeDelivery)
    }

    func testAProblemWithALaterTripAlsoKeepsTheOverallStatusFromSayingAlertsAreActive() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let first = oneTimeClass()
        let lab = TestFixtures.activity(title: "Lab", start: pacific(11), end: pacific(11, 50), arrival: pacific(10, 15))
        let evening = TestFixtures.activity(title: "Evening class", start: pacific(18), end: pacific(18, 50), arrival: pacific(17, 15))
        await monitor.report(occurrenceID(first), as: monitoringPlan(clock))
        await monitor.report(occurrenceID(lab), as: .init(phase: .planning, plan: nil, lastErrorCode: "no_coverage"))
        let model = makeModel(clock, activities: [first, lab, evening], monitor: monitor)
        await launch(model)

        // The next trip is fine and is listed as such; the lab is the one the server cannot plan.
        XCTAssertEqual(model.upcomingMonitoringSummaries(at: clock.now()).map(\.tripID), [occurrenceID(first), occurrenceID(lab), occurrenceID(evening)])
        var settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(settings.kind, .problem)
        XCTAssertEqual(settings.status, "The server confirmed your trips, but alerts are not active for 1 of them right now.")
        XCTAssertTrue(settings.details.contains("Next monitored trip: One-time class, arrive by \(time(8, 15))."))
        XCTAssertFalse(settings.details.joined().contains("no traffic data"), "The list is the next trip's; the lab says it on its own card and sheet")

        // The Map card of a trip that is fine still says that the server will try.
        let card = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true, trip: try XCTUnwrap(model.occurrence(for: occurrenceID(first))))
        XCTAssertEqual(card.kind, .active)
        XCTAssertEqual(card.status, MonitoringText.activeDelivery)

        // A second troubled trip is counted.
        await monitor.report(occurrenceID(evening), as: .init(phase: .planning, plan: nil, lastErrorCode: "budget_exhausted"))
        await tick(model, clock, after: 60)
        settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(settings.status, "The server confirmed your trips, but alerts are not active for 2 of them right now.")
    }

    func testTheServersNoPlanSentenceIsRepeatedOnlyAfterItWasSeenToAppear() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let reason = "Your deadline is 2 hr 15 min away, so there is no need to leave yet."
        await monitor.report(id, as: .init(phase: .planning, plan: nil, noPlanReason: reason))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        // The first reading of a session: the sentence may have been written long ago.
        var summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(summary.noPlanReason, reason)
        XCTAssertNil(summary.noPlanReasonWrittenAfter)
        XCTAssertEqual(formatter.monitoringLines(for: summary, at: clock.now()), ["The server has no departure to recommend for this trip yet."])
        XCTAssertFalse(summary.alertsAreActive)

        // A minute later the server says something new: that sentence was written within the minute.
        let newer = "Your deadline is 2 hr 14 min away, so there is no need to leave yet."
        await monitor.report(id, as: .init(phase: .planning, plan: nil, noPlanReason: newer))
        let readBefore = clock.now()
        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(summary.noPlanReasonWrittenAfter, readBefore)
        XCTAssertEqual(formatter.monitoringLines(for: summary, at: clock.now()), [newer], "Fresh: the server's own words")

        // The same sentence read again keeps its first stamp, and after two minutes it is
        // no longer repeated.
        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(summary.noPlanReasonWrittenAfter, readBefore, "Reading it again does not make it newer")
        XCTAssertEqual(formatter.monitoringLines(for: summary, at: clock.now()), [newer], "Exactly two minutes at most")
        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertEqual(formatter.monitoringLines(for: summary, at: clock.now()), ["The server has no departure to recommend for this trip yet."])
    }

    // MARK: Try Again under a plan the server could not refresh

    func testTryAgainUnderAPlanTheServerCouldNotRefreshReadsTheTripAgain() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock))
        // A source of monitored answers that hands over the server's plan as it is, stale or not.
        let isStale = Flag(true)
        let estimator = ScriptedCommuteEstimator { _ in
            .recommendation(TestBackend.recommendation(
                departure: TestFixtures.date(2026, 10, 26, 7, 5),
                arrival: TestFixtures.date(2026, 10, 26, 7, 50),
                generatedAt: clock.now(),
                isStale: isStale.value,
                isMonitored: true
            ))
        }
        let model = makeModel(clock, activities: [activity], monitor: monitor, estimator: estimator)
        await launch(model)
        guard case .stale(_, .staleServerData) = model.departures[id]?.state else {
            return XCTFail("Expected the server's stale plan kept as out of date, got \(String(describing: model.departures[id]?.state))")
        }
        var tripReads = await monitor.tripRefreshes
        XCTAssertEqual(tripReads, [])

        // Try Again really asks the server for the trip, not just the snapshot it already has.
        isStale.set(false)
        model.retryDepartures()
        await settle(model)
        tripReads = await monitor.tripRefreshes
        XCTAssertEqual(tripReads, [id], "The trip's state is read from the server")
        XCTAssertNotNil(model.departures[id]?.state.calculation, "And the leave-home time follows what it said")

        // A failure of another kind is retried as before, without a read of the trip.
        await estimator.setResponder { _ in throw CommuteProviderFailure(.offline) }
        model.invalidateDepartures(for: [id])
        await settle(model)
        model.retryDepartures()
        await settle(model)
        tripReads = await monitor.tripRefreshes
        XCTAssertEqual(tripReads, [id])
    }

    // MARK: A state that could not be read again

    func testAStateThatCouldNotBeReadAgainStopsShowingAlertTimes() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        let current = ["Monitoring started \(time(5, 5)).", "Time-to-leave alert at the recommended departure, currently \(time(7, 5))."]
        var summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertFalse(summary.isOutOfDate)
        XCTAssertEqual(formatter.monitoringPlanLines(for: summary, at: clock.now()), current)

        // The server cannot be reached; the minute ticks keep trying.
        await monitor.failRefresh(with: .offline)
        await tick(model, clock, after: 60)
        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertFalse(summary.isOutOfDate, "Two minutes without news is not yet out of date")
        XCTAssertEqual(formatter.monitoringPlanLines(for: summary, at: clock.now()), current)

        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertTrue(summary.isOutOfDate)
        XCTAssertEqual(summary.lastReadAt, pacific(6))
        let lines = formatter.monitoringPlanLines(for: summary, at: clock.now())
        XCTAssertEqual(lines, ["The server's plan for this trip was last read \(time(6)), so its alert times are not shown until it is read again."])
        XCTAssertFalse(lines.joined().contains("currently"), "No alert time from a state nobody could read again")
        let settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertFalse(settings.details.joined().contains("currently"), "\(settings.details)")

        // News again: the times are back.
        await monitor.failRefresh(with: nil)
        await tick(model, clock, after: 60)
        summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertFalse(summary.isOutOfDate)
        XCTAssertEqual(formatter.monitoringPlanLines(for: summary, at: clock.now()), current)
    }

    func testAMonitoredPlanIsHandedBackAtOnceWhenTheForegroundSynchronizationFails() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        await monitor.report(id, as: monitoringPlan(clock))
        // The live provider answers from the server's plan while it can, then fails.
        let isReachable = Flag(true)
        let estimator = ScriptedCommuteEstimator { _ in
            guard isReachable.value else { throw CommuteProviderFailure(.offline) }
            return .recommendation(TestBackend.recommendation(
                departure: TestFixtures.date(2026, 10, 26, 7, 5),
                arrival: TestFixtures.date(2026, 10, 26, 7, 50),
                generatedAt: clock.now(),
                isMonitored: true
            ))
        }
        let model = makeModel(clock, activities: [activity], monitor: monitor, estimator: estimator)
        await launch(model)
        let planned = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(planned.recommendation?.isMonitored, true)

        // Half an hour in the background; on return nothing can be reached. The departure,
        // 7:05, is still ahead, so only the failed synchronization tells that the plan on
        // screen is half an hour old and unconfirmed.
        clock.advance(by: 30 * 60)
        await monitor.failSynchronize(with: .offline)
        isReachable.set(false)
        model.appDidBecomeActive()
        await settle(model)

        XCTAssertEqual(model.monitoringStatus.failure, .offline)
        guard case .stale(let kept, .provider(.offline)) = model.departures[id]?.state else {
            return XCTFail("The unconfirmed plan is kept but not shown as current, without waiting for a tick: \(String(describing: model.departures[id]?.state))")
        }
        XCTAssertEqual(kept.leaveHome, planned.leaveHome)

        // The kept plan follows the ordinary retry backoff from here: the reconciliations that
        // keep failing do not ask for it again each time.
        let asked = await estimator.requestCount()
        model.appDidBecomeActive()
        await settle(model)
        let askedAfter = await estimator.requestCount()
        XCTAssertEqual(askedAfter, asked + 1, "Only the foreground's own retry of the failed request")
    }

    func testAPlannedTripThatIsNotDueIsNotCalledOutOfDate() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        // Tomorrow's class: planned, and the server looks at it again tomorrow morning.
        let start = TestFixtures.date(2026, 10, 27, 9)
        let activity = TestFixtures.activity(title: "Tomorrow's class", start: start, end: start.addingTimeInterval(50 * 60), arrival: start.addingTimeInterval(-45 * 60))
        let id = OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
        let departure = TestFixtures.date(2026, 10, 27, 7, 5)
        await monitor.report(id, as: .init(
            phase: .planned,
            plan: TestBackend.plan(departure: departure, arrival: departure.addingTimeInterval(45 * 60), evaluatedAt: clock.now()),
            nextCheckAt: TestFixtures.date(2026, 10, 27, 5, 5)
        ))
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)

        // Nothing is due on the server for hours, so nothing is read again, and that is fine.
        await tick(model, clock, after: 3_600)
        let refreshes = await monitor.refreshCalls
        XCTAssertEqual(refreshes, 0)
        let summary = try XCTUnwrap(model.monitoringSummary(for: id))
        XCTAssertFalse(summary.isOutOfDate, "An old reading is only out of date when a newer one was due")
        XCTAssertEqual(formatter.monitoringPlanLines(for: summary, at: clock.now()), [
            "Monitoring starts about 2 hours before the recommended departure.",
            "Heads-up about 90 minutes before the recommended departure.",
            "Time-to-leave alert at the recommended departure."
        ])
    }

    // MARK: A withdrawal the server could not confirm

    func testAWithdrawalAServerWithoutMonitoringCouldNotConfirmIsNotReportedAsDone() async throws {
        let clock = ManualWallClock(pacific(6))
        let monitor = RecordingTripMonitor(clock: clock)
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: monitor)
        await launch(model)
        XCTAssertTrue(model.monitoringStatus.isActive)

        // The server answers 503 "monitoring_unavailable" to the removal and to the empty
        // snapshot: it says nothing about the device and the trips it still holds.
        await monitor.failUnregister(with: .unavailableOnServer)
        await monitor.failWithdrawTrips(with: .unavailableOnServer)
        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .off, "Off for the user at once")
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.unavailableOnServer), "But not reported as withdrawn")
        XCTAssertEqual(
            MonitoringText.withdrawalSentence(model.monitoringWithdrawal),
            "The server could not be told to stop (this server does not support trip monitoring yet), so it may still send alerts for a while. It is tried again when you tap Try Again or open the app again."
        )
        var events = await monitor.events
        XCTAssertEqual(events, ["synchronize 1", "unregister \(address)", "withdrawTrips"])

        // Not retried on the ticks, which the sentence does not promise either.
        await tick(model, clock, after: 61)
        await tick(model, clock, after: 600)
        events = await monitor.events
        XCTAssertEqual(events.count, 3)

        // Opening the app again tries once more, and so does Try Again.
        model.appDidBecomeActive()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(Array(events.suffix(2)), ["unregister \(address)", "withdrawTrips"])
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.unavailableOnServer))

        await monitor.failUnregister(with: nil)
        model.retryReminders()
        await settle(model)
        events = await monitor.events
        XCTAssertEqual(events.last, "unregister \(address)")
        XCTAssertEqual(model.monitoringWithdrawal, .none, "Confirmed by the server at last")
    }
}

/// A flag a `@Sendable` closure can read while the test changes it.
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

/// Settings that cannot be read until the test says so, like a damaged file that is repaired.
/// Saves are refused meanwhile, as the file store refuses to replace what it could not read.
private actor UnreadableUntilToldPreferencesStore: PreferencesStoring {
    private var stored: UserPreferences
    private var isReadable = false

    init(stored: UserPreferences) {
        self.stored = stored
    }

    nonisolated var persistenceDescription: String { "Unreadable test store" }

    func makeReadable() {
        isReadable = true
    }

    func loadPreferences() async throws -> UserPreferences? {
        guard isReadable else { throw PersistenceError.damaged }
        return stored
    }

    func savePreferences(_ preferences: UserPreferences) async throws {
        guard isReadable else { throw PersistenceError.unreadableDataProtected }
        stored = preferences
    }
}
