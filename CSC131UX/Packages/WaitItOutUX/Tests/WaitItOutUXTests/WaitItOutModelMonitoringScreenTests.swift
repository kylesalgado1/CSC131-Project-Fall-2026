import XCTest
@testable import WaitItOutUX

/// Stage S3: what the screens read from the model about server-side trip monitoring. Settings
/// lists the next monitored trip by name, the Map card lists its own trip, "I've Left" ends
/// with the server's answer, and a trip a notification named is presented by the Calendar only
/// when nothing stands in the way.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The one-time class runs 9:00 to 9:50 AM with an
/// ideal arrival of 8:15 AM; the server monitors it and plans to leave at 7:05 AM. The lab
/// runs 11:00 to 11:50 AM with an ideal arrival of 10:15 AM.
@MainActor
final class WaitItOutModelMonitoringScreenTests: XCTestCase {
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)

    private func pacific(_ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(2026, 10, 26, hour, minute)
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> String {
        formatter.clockTime(pacific(hour, minute))
    }

    private func oneTimeClass() -> Activity {
        TestFixtures.activity(title: "One-time class", start: pacific(9), end: pacific(9, 50), arrival: pacific(8, 15))
    }

    private func lab() -> Activity {
        TestFixtures.activity(title: "Lab", start: pacific(11), end: pacific(11, 50), arrival: pacific(10, 15))
    }

    private func occurrenceID(_ activity: Activity) -> OccurrenceID {
        OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
    }

    private func makeModel(
        _ clock: ManualWallClock,
        activities: [Activity],
        monitor: RecordingTripMonitor?,
        remindersOn: Bool = true,
        dataMode: DataMode = .live
    ) -> WaitItOutModel {
        TestBackend.makeLiveModel(
            clock: clock,
            activities: activities,
            liveEstimator: ScriptedCommuteEstimator { request in
                .recommendation(TestBackend.recommendation(
                    departure: request.arriveBy.addingTimeInterval(-70 * 60),
                    arrival: request.arriveBy.addingTimeInterval(-25 * 60),
                    margin: 25 * 60,
                    generatedAt: clock.now()
                ))
            },
            demoEstimator: ScriptedCommuteEstimator(minutes: 60),
            tripMonitor: monitor,
            store: InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn, dataMode: dataMode))
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

    /// A monitor that allows notifications and reports `activity` as actively monitored, with
    /// a plan to leave at 7:05 AM.
    private func monitoring(_ activity: Activity, clock: ManualWallClock) async -> RecordingTripMonitor {
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        await monitor.report(occurrenceID(activity), as: RecordingTripMonitor.Report(
            phase: .monitoring,
            plan: TestBackend.plan(departure: pacific(7, 5), arrival: pacific(7, 50), evaluatedAt: clock.now())
        ))
        return monitor
    }

    private func occurrence(of activity: Activity, in model: WaitItOutModel) throws -> ActivityOccurrence {
        try XCTUnwrap(model.occurrence(for: occurrenceID(activity)))
    }

    // MARK: The status view's content

    func testSettingsNamesTheNextMonitoredTripAndTheMapListsItsOwn() async throws {
        let clock = ManualWallClock(pacific(6))
        let first = oneTimeClass()
        let second = lab()
        let monitor = await monitoring(first, clock: clock)
        let model = makeModel(clock, activities: [first, second], monitor: monitor)
        await launch(model)
        XCTAssertNil(model.monitoringObstacle)

        let plan = ["Monitoring started \(time(5, 5)).", "Time-to-leave alert at the recommended departure, currently \(time(7, 5))."]
        let settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(settings.kind, .active)
        XCTAssertEqual(settings.status, MonitoringText.activeDelivery)
        XCTAssertEqual(settings.details, [
            "The server confirmed 2 trips at \(time(6)).",
            "Alerts are set up for trips through Monday, October 26. Open the app again before then to keep them coming.",
            "Next monitored trip: One-time class, arrive by \(time(8, 15))."
        ] + plan)
        XCTAssertEqual(model.monitoringCoverageEnd, second.idealArrival, "The arrival of the last trip the server holds")
        XCTAssertFalse(settings.offersRetry || settings.offersAllowNotifications || settings.offersOpenSettings)

        let card = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true, trip: try occurrence(of: first, in: model))
        XCTAssertEqual(card.status, MonitoringText.activeDelivery)
        XCTAssertEqual(card.details, plan, "The card's own trip needs no heading")

        // The lab is only being planned: the server said nothing yet that could be listed.
        let other = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true, trip: try occurrence(of: second, in: model))
        XCTAssertEqual(other.details, ["The server is working out when you should leave."])
    }

    func testAnObstacleIsNamedInsteadOfThePlan() async throws {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        await monitor.setPermission(.denied)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        XCTAssertEqual(model.monitoringObstacle, .permissionDenied)

        let settings = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(settings.kind, .needsPermission)
        XCTAssertEqual(settings.status, "Notifications are off for Test. Turn them on in iOS Settings to get alerts.")
        XCTAssertEqual(settings.details, [
            "The server confirmed 1 trip at \(time(6)).",
            "Alerts are set up for trips through Monday, October 26. Open the app again before then to keep them coming."
        ], "No alert is listed that could not arrive")
        XCTAssertTrue(settings.offersOpenSettings)

        let summary = try XCTUnwrap(model.monitoringSummary(for: try occurrence(of: activity, in: model)))
        XCTAssertEqual(formatter.tripMonitoringSentences(for: summary, at: clock.now()), ["Notifications are off for this app in iOS Settings."])
        XCTAssertTrue(summary.canMarkDeparted, "Leaving can still be reported")
    }

    func testAllowNotificationsIsOfferedUntilTheUserAnswered() async {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        await monitor.setPermission(.notDetermined, afterRequest: .authorized)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        let before = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(before.status, "Notifications have not been allowed for this app yet.")
        XCTAssertTrue(before.offersAllowNotifications)

        model.requestNotificationPermission()
        await settle(model)
        let after = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(after.kind, .active)
        XCTAssertFalse(after.offersAllowNotifications)
    }

    func testWithoutAMonitoringServiceLiveModeSaysThatNoAlertIsSent() async {
        let clock = ManualWallClock(pacific(6))
        let model = makeModel(clock, activities: [oneTimeClass()], monitor: nil)
        await launch(model)
        XCTAssertTrue(model.usesLiveBackend)
        XCTAssertFalse(model.usesTripMonitoring)
        let shown = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(shown, MonitoringPresentation(kind: .off, status: MonitoringText.notAvailable))
    }

    func testSwitchingToLiveReadsThePermissionWithoutPrompting() async {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        let model = makeModel(clock, activities: [activity], monitor: monitor, dataMode: .demo)
        await launch(model)
        XCTAssertEqual(model.notificationPermission, .notDetermined, "The Demo data mode never asks about notifications")
        var refreshes = await monitor.pushRefreshes
        XCTAssertEqual(refreshes, 0)

        model.setDataMode(.live)
        await settle(model)
        XCTAssertEqual(model.notificationPermission, .authorized)
        XCTAssertNil(model.monitoringObstacle, "Nothing claims that notifications are not allowed yet")
        let shown = model.monitoringPresentation(formatter: formatter, at: clock.now())
        XCTAssertEqual(shown.kind, .active)
        XCTAssertFalse(shown.offersAllowNotifications)
        refreshes = await monitor.pushRefreshes
        XCTAssertEqual(refreshes, 1, "Registered with the push service, as a launch in Live mode does")
        let prompts = await monitor.permissionRequests
        XCTAssertEqual(prompts, 0, "Switching the data mode never prompts")

        model.setDataMode(.demo)
        await settle(model)
        refreshes = await monitor.pushRefreshes
        XCTAssertEqual(refreshes, 1, "The Demo data mode asks nothing")
    }

    // MARK: The Map card

    func testTheMapShowsMonitoringOnlyInLiveModeWithRemindersOnOrAfterAFailedWithdrawal() async {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        XCTAssertTrue(model.showsMonitoringOnMap)

        await monitor.failUnregister(with: .offline)
        await monitor.failWithdrawTrips(with: .offline)
        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.offline))
        XCTAssertTrue(model.showsMonitoringOnMap, "The server may still alert, and the card says so")
        let card = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true)
        XCTAssertEqual(card.status, "Leave-home alerts are off.")
        XCTAssertEqual(card.details, [MonitoringText.withdrawalSentence(.failed(.offline)) ?? ""])
        XCTAssertTrue(card.offersRetry)

        await monitor.failUnregister(with: nil)
        await monitor.failWithdrawTrips(with: nil)
        model.retryReminders()
        await settle(model)
        XCTAssertEqual(model.monitoringWithdrawal, .none)
        XCTAssertFalse(model.showsMonitoringOnMap)

        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertTrue(model.showsMonitoringOnMap)
        model.setDataMode(.demo)
        await settle(model)
        XCTAssertFalse(model.showsMonitoringOnMap, "The Demo data mode shows its reminder preview instead")
        XCTAssertFalse(TestFixtures.makeModel().showsMonitoringOnMap)
    }

    // MARK: "I've left"

    func testIveLeftEndsWithTheServersAnswerOnEveryScreen() async throws {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        let trip = try occurrence(of: activity, in: model)
        let before = try XCTUnwrap(model.monitoringSummary(for: trip))
        XCTAssertTrue(before.canMarkDeparted)
        XCTAssertNil(before.departedSentence)

        await monitor.failDeparted(with: .offline)
        await model.markDeparted(trip.id, arriveBy: trip.idealArrival)
        let failed = try XCTUnwrap(model.monitoringSummary(for: trip))
        XCTAssertEqual(failed.departedSentence, "Could not tell the server you left; it may still send alerts for this trip.")
        XCTAssertTrue(failed.canMarkDeparted)
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: failed.departed), "Try Again")

        await monitor.failDeparted(with: nil)
        await model.markDeparted(trip.id, arriveBy: trip.idealArrival)
        await settle(model)
        let done = try XCTUnwrap(model.monitoringSummary(for: trip))
        XCTAssertEqual(done.departedSentence, "Marked as left. Monitoring ended for this trip.")
        XCTAssertFalse(done.canMarkDeparted)
        XCTAssertEqual(formatter.tripMonitoringSentences(for: done, at: clock.now()), [], "Only the I've-left sentence remains")
        let card = model.monitoringPresentation(formatter: formatter, at: clock.now(), isCompact: true, trip: trip)
        XCTAssertEqual(card.details, [])
        let arrivals = await monitor.departedArrivals
        XCTAssertEqual(arrivals, [trip.idealArrival, trip.idealArrival], "Sent for the arrival the screen showed")
    }

    // MARK: A trip a notification named

    func testTheCalendarPresentsARequestedTripOnceNothingStandsInTheWay() async throws {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        XCTAssertEqual(model.tripPresentationStep, .idle)

        // Tapped before the schedule loaded: nothing is asked of the Calendar yet.
        model.openTrip(occurrenceID(activity))
        XCTAssertNil(model.tripToPresent)
        XCTAssertEqual(model.tripPresentationStep, .idle)

        await launch(model)
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertEqual(model.tripToPresent, occurrenceID(activity))
        let trip = try occurrence(of: activity, in: model)
        XCTAssertEqual(model.tripPresentationStep, .present(trip))

        // While the editor is open the request is kept, not dropped.
        XCTAssertTrue(model.beginNewActivity())
        XCTAssertEqual(model.tripPresentationStep, .wait)
        model.cancelDraft()
        XCTAssertEqual(model.tripPresentationStep, .present(trip))

        // What the Calendar does once the details are set to show.
        model.tripToPresent = nil
        XCTAssertEqual(model.tripPresentationStep, .idle)
    }

    func testARequestedTripThatWasDeletedIsDiscarded() async throws {
        let clock = ManualWallClock(pacific(6))
        let activity = oneTimeClass()
        let monitor = await monitoring(activity, clock: clock)
        let model = makeModel(clock, activities: [activity], monitor: monitor)
        await launch(model)
        model.openTrip(occurrenceID(activity))
        try await model.deleteActivity(id: activity.id)
        await settle(model)
        XCTAssertEqual(model.tripToPresent, occurrenceID(activity))
        XCTAssertEqual(model.tripPresentationStep, .discard)
    }
}
