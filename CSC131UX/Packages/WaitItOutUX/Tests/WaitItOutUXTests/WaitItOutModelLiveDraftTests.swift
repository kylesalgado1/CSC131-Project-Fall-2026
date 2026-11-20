import XCTest
@testable import WaitItOutUX

/// The editor's leave-home preview with the live backend. A repeating activity whose first
/// occurrence has passed is previewed through its next upcoming occurrence, so a series that
/// goes on never answers "the ideal arrival time has passed"; and a request caused by a draft
/// change waits a moment, so a drag or a turning picker asks the backend once, for the value
/// it settles on. The demo preview is unchanged: the first occurrence, asked at once.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. The weekly class meets Mon, Wed, Fri from 9:00 to
/// 9:50 AM since Mon 2026-10-26, with an ideal arrival of 8:15 AM. Clocks fall back on Sunday.
@MainActor
final class WaitItOutModelLiveDraftTests: XCTestCase {
    // MARK: Helpers

    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private func weeklyClass(id: UUID = UUID(), firstDay: Int = 26) -> Activity {
        TestFixtures.activity(
            id: id,
            title: "Weekly class",
            start: pacific(2026, 10, firstDay, 9),
            end: pacific(2026, 10, firstDay, 9, 50),
            arrival: pacific(2026, 10, firstDay, 8, 15),
            repeatWeekdays: [.monday, .wednesday, .friday]
        )
    }

    /// A live estimator that recommends leaving 70 minutes before whatever arrival it is asked about.
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

    private func launch(_ model: WaitItOutModel) async {
        await model.loadPreferences()
        await model.loadActivities()
        await model.waitForDepartures()
    }

    // MARK: The next occurrence

    func testARepeatingActivityPastItsFirstOccurrenceIsPreviewedThroughItsNextOne() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let series = weeklyClass()
        // The real provider over a scripted transport: it answers "the ideal arrival time has
        // passed" by itself, without a request, for any arrival that is not ahead.
        let nextArrival = pacific(2026, 11, 2, 8, 15)
        let transport = ScriptedHTTPTransport(.http(status: 200, body: TestBackend.verdictBody(
            action: "leave_later",
            leaveNow: (TestFixtures.fridayNoon, TestFixtures.fridayNoon.addingTimeInterval(45 * 60)),
            recommended: (nextArrival.addingTimeInterval(-70 * 60), nextArrival.addingTimeInterval(-25 * 60)),
            marginMinutes: 25,
            generatedAt: TestFixtures.fridayNoon
        )))
        let provider = BackendCommuteProvider(client: TestBackend.client(transport: transport, clock: clock), clock: clock, planningHorizon: 8 * 86_400)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [series], liveEstimator: provider)
        await launch(model)
        let before = await transport.requestCount()

        XCTAssertTrue(model.beginEditing(activityID: series.id))
        await model.waitForDepartures()
        let entry = try XCTUnwrap(model.draftDeparture)
        XCTAssertEqual(entry.request.arriveBy, nextArrival, "Monday's arrival, 8:15 AM PST, not the first one of four days ago")
        XCTAssertEqual(entry.request.occurrenceID.rawValue, "\(series.id.uuidString)@2026-11-02")
        XCTAssertEqual(entry.state.calculation?.leaveHome, nextArrival.addingTimeInterval(-70 * 60))
        XCTAssertEqual(model.draftPreviewOccurrence?.idealArrival, nextArrival, "The editor can say which occurrence the time is for")

        let sent = await transport.requests.dropFirst(before)
        XCTAssertEqual(sent.map { $0.string("arriveBy") }, ["2026-11-02T16:15:00.000Z"], "One request, for the occurrence that can still be reached")
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: TestFixtures.enUS)
        let message = formatter.departureMessage(for: entry.state)
        XCTAssertNil(message, "A current leave-home time, with no message about a passed arrival")
        XCTAssertEqual(
            DepartureWording.nextOccurrenceNote(arrival: formatter.reminderTimestamp(nextArrival)),
            "The first occurrence has passed, so the leave-home time below is for the next one: arrive by \(formatter.reminderTimestamp(nextArrival))."
        )

        // Moving the arrival 15 minutes earlier moves the next occurrence's arrival with it.
        model.updateDraft { $0.setArrival(self.pacific(2026, 10, 26, 8, 0)) }
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 11, 2, 8, 0))
        XCTAssertNotEqual(formatter.departureMessage(for: model.draftDeparture?.state ?? .loading), "The ideal arrival time has passed. No leave-home time is shown.")
    }

    func testThePreviewMovesOnWhenTheNextOccurrencePasses() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let series = weeklyClass()
        let live = steadyBackend(clock)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [series], liveEstimator: live)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: series.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 11, 2, 8, 15))

        // The editor stays open over the weekend. On Monday at 8:16 that arrival has passed too.
        clock.set(pacific(2026, 11, 2, 8, 16))
        model.refreshDepartures()
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 11, 4, 8, 15), "Wednesday's occurrence is the next one now")
        XCTAssertNotNil(model.draftDeparture?.state.calculation)
    }

    func testOnlyASeriesThatGoesOnIsPreviewedThroughALaterOccurrence() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        // A one-time activity in the past has no next occurrence: the plain statement is true.
        let once = TestFixtures.activity(title: "One-time class", start: pacific(2026, 10, 26, 9), end: pacific(2026, 10, 26, 9, 50), arrival: pacific(2026, 10, 26, 8, 15))
        // A series that begins next week is previewed through its first occurrence, as shown.
        let later = TestFixtures.activity(
            title: "Next week's class",
            start: pacific(2026, 11, 3, 9),
            end: pacific(2026, 11, 3, 9, 50),
            arrival: pacific(2026, 11, 3, 8, 15),
            repeatWeekdays: [.tuesday]
        )
        let transport = ScriptedHTTPTransport(.http(status: 502, body: TestBackend.errorBody("routing_unavailable", "The routing service is unavailable.")))
        let provider = BackendCommuteProvider(client: TestBackend.client(transport: transport, clock: clock), clock: clock, planningHorizon: 8 * 86_400)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [once, later], liveEstimator: provider)
        await launch(model)

        XCTAssertTrue(model.beginEditing(activityID: once.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, once.idealArrival)
        XCTAssertEqual(model.draftDeparture?.state, .unavailable(.noEstimate(message: "The ideal arrival time has passed.")))
        XCTAssertNil(model.draftPreviewOccurrence)
        model.cancelDraft()

        XCTAssertTrue(model.beginEditing(activityID: later.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, later.idealArrival, "The first occurrence is still ahead")
        XCTAssertNil(model.draftPreviewOccurrence, "So no note about another occurrence is shown")
    }

    func testTheDemoPreviewStillAsksAboutTheFirstOccurrence() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let series = weeklyClass()
        let demo = ScriptedCommuteEstimator { _ in .estimate(testEstimate(minutes: 60, at: clock.now())) }
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [series]), commuteEstimator: demo)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: series.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, series.idealArrival, "The demo formula is shown for the occurrence the editor shows, as before")
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))
        XCTAssertNil(model.draftPreviewOccurrence)

        // The same holds in the Demo data mode of a host that has a live backend.
        let live = steadyBackend(clock)
        let both = TestBackend.makeLiveModel(
            clock: clock,
            activities: [series],
            liveEstimator: live,
            demoEstimator: demo,
            store: InMemoryPreferencesStore(initial: UserPreferences(dataMode: .demo))
        )
        await launch(both)
        XCTAssertTrue(both.beginEditing(activityID: series.id))
        await both.waitForDepartures()
        XCTAssertEqual(both.draftDeparture?.request.arriveBy, series.idealArrival)
        let asked = await live.requestCount()
        XCTAssertEqual(asked, 0, "The backend is never asked in the Demo data mode")
    }

    // MARK: Waiting for the draft to settle

    func testALiveDraftChangeIsAskedOnlyOnceItSettles() async throws {
        XCTAssertEqual(WaitItOutModel.liveDraftDebounce, .milliseconds(600))
        // Mon 2026-10-26 06:00 PDT; the one-time class has its ideal arrival at 8:15 AM.
        let clock = ManualWallClock(pacific(2026, 10, 26, 6))
        let activity = TestFixtures.activity(title: "One-time class", start: pacific(2026, 10, 26, 9), end: pacific(2026, 10, 26, 9, 50), arrival: pacific(2026, 10, 26, 8, 15))
        let live = steadyBackend(clock)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        var asked = await live.requestCount()
        XCTAssertEqual(asked, 1, "The saved trip")

        // Opening the editor and then dragging the arrival across twelve quarter-hour steps,
        // faster than anyone could read an answer.
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        for step in 1...12 {
            model.updateDraft { $0.setArrival(self.pacific(2026, 10, 26, 8, 15).addingTimeInterval(TimeInterval(-step) * 5 * 60)) }
        }
        XCTAssertEqual(model.draftDeparture?.state, .loading, "The preview shows at once that it is working")
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 10, 26, 7, 15))
        try await Task.sleep(for: .milliseconds(100))
        asked = await live.requestCount()
        XCTAssertEqual(asked, 1, "Nothing was sent while the draft was still changing")

        await model.waitForDepartures()
        let requests = await live.requests
        XCTAssertEqual(requests.count, 2, "One request for the whole gesture, not thirteen")
        XCTAssertEqual(requests.last?.arriveBy, pacific(2026, 10, 26, 7, 15), "For the value the draft settled on")
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 6, 5))

        // Try Again and the minute ticks are not draft changes: they ask at once.
        await live.setResponder { _ in throw CommuteProviderFailure(.offline) }
        model.updateDraft { $0.setArrival(self.pacific(2026, 10, 26, 7, 30)) }
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state, .error(.provider(.offline)))
        asked = await live.requestCount()
        model.retryDepartures()
        let retried = await waitUntil(timeout: .milliseconds(300)) { await live.requestCount() >= asked + 1 }
        XCTAssertTrue(retried, "Try Again is not delayed")
        await model.waitForDepartures()
    }

    func testTheDemoPreviewIsNotDelayed() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 6))
        let activity = TestFixtures.activity(title: "One-time class", start: pacific(2026, 10, 26, 9), end: pacific(2026, 10, 26, 9, 50), arrival: pacific(2026, 10, 26, 8, 15))
        let demo = ScriptedCommuteEstimator { _ in .estimate(testEstimate(minutes: 60, at: clock.now())) }
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: demo)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        await model.waitForDepartures()
        let before = await demo.requestCount()

        model.updateDraft { $0.setArrival(self.pacific(2026, 10, 26, 8, 0)) }
        let answered = await waitUntil(timeout: .milliseconds(300)) { model.draftDeparture?.state.calculation != nil }
        XCTAssertTrue(answered, "The local demo answers well inside the time a live request would still be waiting")
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 0))
        let after = await demo.requestCount()
        XCTAssertEqual(after, before + 1)
    }
}
