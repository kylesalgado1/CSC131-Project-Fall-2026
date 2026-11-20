import XCTest
@testable import WaitItOutUX

/// Stage S1: the model on the live backend. A recommendation is shown verbatim and is the
/// same on every screen; an edit or a delete supersedes a request in flight and a late answer
/// is dropped; a failed refresh keeps the last recommendation marked out of date, never as
/// current; transient failures are retried on the minute ticks with a backoff and the demo
/// provider never is; "not yet" answers are asked again when their time comes; a "leave now"
/// answer stays put; switching the data mode or the server address clears every result so the
/// two sources are never mixed; and recurring occurrences send correct absolute instants on
/// both sides of a daylight-saving change.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT unless a test says otherwise. The one-time class
/// runs 9:00 to 9:50 AM with an ideal arrival of 8:15 AM.
@MainActor
final class WaitItOutModelBackendTests: XCTestCase {
    // MARK: Helpers

    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute, second)
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

    private func occurrenceID(_ activity: Activity) -> OccurrenceID {
        OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
    }

    /// A backend recommendation stamped with `clock`: leave at `departure`, arrive at `arrival`.
    private func advised(
        _ clock: ManualWallClock,
        departure: Date,
        arrival: Date,
        advice: DepartureAdvice = .leaveLater
    ) -> CommuteEstimateResponse {
        .recommendation(TestBackend.recommendation(advice: advice, departure: departure, arrival: arrival, margin: 15 * 60, generatedAt: clock.now()))
    }

    /// A live estimator that always recommends leaving at 7:05 AM and arriving at 7:50 AM.
    /// The local formula would give 8:15 minus 45 minutes = 7:30, and the demo provider 7:15.
    private func steadyBackend(_ clock: ManualWallClock) -> ScriptedCommuteEstimator {
        let departure = pacific(2026, 10, 26, 7, 5)
        let arrival = pacific(2026, 10, 26, 7, 50)
        return ScriptedCommuteEstimator { _ in
            .recommendation(TestBackend.recommendation(departure: departure, arrival: arrival, margin: 25 * 60, generatedAt: clock.now()))
        }
    }

    private func failing(_ kind: CommuteProviderFailure.Kind) -> ScriptedCommuteEstimator {
        ScriptedCommuteEstimator { _ in throw CommuteProviderFailure(kind) }
    }

    /// Loads settings and the schedule and waits for every answer, as a launch does.
    private func launch(_ model: WaitItOutModel) async {
        await model.loadPreferences()
        await model.loadActivities()
        await model.waitForDepartures()
    }

    /// One minute tick `seconds` later: what the Map's and Calendar's clocks do.
    private func tick(_ model: WaitItOutModel, _ clock: ManualWallClock, after seconds: TimeInterval) async {
        clock.advance(by: seconds)
        model.refreshDepartures()
        await model.waitForDepartures()
    }

    private func state(_ model: WaitItOutModel, _ activity: Activity) -> DepartureState? {
        model.departures[occurrenceID(activity)]?.state
    }

    // MARK: Without a live backend

    func testWithoutALiveBackendNothingChanges() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        XCTAssertFalse(model.hasLiveBackend)
        XCTAssertFalse(model.usesLiveBackend, "The default mode is live, but there is no backend to use")
        XCTAssertEqual(model.dataMode, .live)
        XCTAssertTrue(model.usesTestCommute)
        XCTAssertNil(model.backendBaseURL)

        model.setDataMode(.demo)
        XCTAssertEqual(model.preferences.dataMode, .live, "Switching does nothing without a live backend")
        XCTAssertNil(model.applyBackendAddress("not an address"))
        XCTAssertNil(model.applyBackendAddress("https://example.org"))
        XCTAssertNil(model.preferences.backendAddress)
        XCTAssertEqual(model.backendAddressText, "")

        await model.loadPreferences()
        await model.loadSampleActivities()
        await model.waitForDepartures()
        await model.waitForRoute()
        model.appDidBecomeActive()
        await model.waitForDepartures()

        XCTAssertEqual(model.routeState, .schematic)
        XCTAssertEqual(model.departures.count, 5)
        for entry in model.departures.values {
            let calculation = try XCTUnwrap(entry.state.calculation)
            XCTAssertNil(calculation.recommendation, "The demo path carries no recommendation")
            XCTAssertTrue(calculation.isSimulated)
            XCTAssertEqual(calculation.leaveHome, calculation.idealArrival.addingTimeInterval(-3_600), "The local formula, as before")
        }
        await model.flushPendingSaves()
        let saved = await store.saved
        XCTAssertTrue(saved.isEmpty, "Neither no-op wrote settings")
    }

    // MARK: Verbatim and consistent

    func testARecommendationIsShownVerbatim() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let demo = ScriptedCommuteEstimator(minutes: 60)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, demoEstimator: demo)
        XCTAssertTrue(model.hasLiveBackend)
        XCTAssertTrue(model.usesLiveBackend)
        XCTAssertFalse(model.usesTestCommute, "Nothing on screen is test data while live")
        await launch(model)

        let calculation = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 7, 5), "Exactly the backend's recommended departure")
        XCTAssertEqual(calculation.idealArrival, pacific(2026, 10, 26, 8, 15))
        XCTAssertEqual(calculation.travelTime.seconds, 45 * 60)
        XCTAssertNotEqual(
            calculation.leaveHome,
            calculation.idealArrival.addingTimeInterval(-calculation.travelTime.seconds),
            "Not ideal arrival minus drive time: the app adds no arithmetic of its own"
        )
        XCTAssertEqual(calculation.recommendation?.recommendedDeparture, pacific(2026, 10, 26, 7, 5))
        XCTAssertEqual(calculation.recommendation?.predictedArrival, pacific(2026, 10, 26, 7, 50))
        XCTAssertFalse(calculation.isSimulated)
        XCTAssertEqual(calculation.sourceLabel, "Live traffic (TomTom) via the team backend")
        XCTAssertEqual(calculation.estimatedAt, pacific(2026, 10, 26, 6))

        let liveRequests = await live.requests
        XCTAssertEqual(liveRequests.count, 1)
        XCTAssertEqual(liveRequests.first?.arriveBy, pacific(2026, 10, 26, 8, 15), "The ideal arrival, never the start")
        XCTAssertEqual(liveRequests.first?.origin, model.places.home)
        XCTAssertEqual(liveRequests.first?.destination.coordinate, model.places.campus.coordinate)
        let demoRequests = await demo.requestCount()
        XCTAssertEqual(demoRequests, 0, "Live mode never calls the demo provider")
    }

    func testEveryScreenReadsTheSameRecommendation() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: steadyBackend(clock))
        await launch(model)

        let stored = try XCTUnwrap(state(model, activity))
        XCTAssertNotNil(stored.calculation?.recommendation)
        // Calendar detail sheet.
        let occurrence = try XCTUnwrap(model.occurrences(in: pacific(2026, 10, 26, 0)..<pacific(2026, 10, 27, 0)).first)
        XCTAssertEqual(model.departureState(for: occurrence), stored)
        // Map next-trip card.
        let trip = try XCTUnwrap(model.nextTrip(at: clock.now()))
        XCTAssertEqual(trip.occurrence.id, occurrenceID(activity))
        XCTAssertEqual(trip.state, stored)
        // Editor preview of the unchanged activity.
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state, stored, "The editor shows the same recommendation")
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))
    }

    // MARK: Superseded requests

    func testALateBackendAnswerCannotOverwriteANewerEdit() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = LateAnsweringEstimator()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await model.loadPreferences()
        await model.loadActivities()
        let asked = await waitUntil { await live.callCount() == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(state(model, activity), .loading)

        // The user moves the ideal arrival to 8:00 while the first request is still in flight.
        let edited = oneTimeClass(id: activity.id, arrival: pacific(2026, 10, 26, 8, 0))
        try await model.saveActivity(edited)
        let askedAgain = await waitUntil { await live.callCount() == 2 }
        XCTAssertTrue(askedAgain)
        let second = await live.request(at: 1)
        XCTAssertEqual(second?.arriveBy, pacific(2026, 10, 26, 8, 0))
        XCTAssertEqual(model.departures[occurrenceID(edited)]?.request.arriveBy, pacific(2026, 10, 26, 8, 0))

        // The answer for the old 8:15 arrival arrives late. It must not appear anywhere.
        let delivered = await live.answer(0, with: advised(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        XCTAssertTrue(delivered)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.departures[occurrenceID(edited)]?.state, .loading, "The late answer for the old arrival is dropped")

        await live.answer(1, with: advised(clock, departure: pacific(2026, 10, 26, 6, 50), arrival: pacific(2026, 10, 26, 7, 40)))
        await model.waitForDepartures()
        let calculation = try XCTUnwrap(model.departures[occurrenceID(edited)]?.state.calculation)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 6, 50))
        XCTAssertEqual(calculation.idealArrival, pacific(2026, 10, 26, 8, 0))
    }

    func testALateAnswerForTheEditorPreviewIsDroppedToo() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = LateAnsweringEstimator()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [], liveEstimator: live)
        await launch(model)
        try await model.saveActivity(activity)
        _ = await waitUntil { await live.callCount() == 1 }
        // The saved trip is answered; only the editor's preview is in flight from here on.
        await live.answer(0, with: advised(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        await model.waitForDepartures()

        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        _ = await waitUntil { await live.callCount() == 2 }
        let newArrival = pacific(2026, 10, 26, 8, 0)
        model.updateDraft { $0.setArrival(newArrival) }
        let asked = await waitUntil { await live.callCount() == 3 }
        XCTAssertTrue(asked, "The changed arrival is asked for")
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 10, 26, 8, 0))

        await live.answer(1, with: advised(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.draftDeparture?.state, .loading, "The answer for the earlier draft arrival is dropped")

        await live.answer(2, with: advised(clock, departure: pacific(2026, 10, 26, 6, 50), arrival: pacific(2026, 10, 26, 7, 40)))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 6, 50))
    }

    func testDeletingAnActivityCancelsItsBackendRequest() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = GatedCommuteEstimator()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await model.loadPreferences()
        await model.loadActivities()
        let asked = await waitUntil { await live.callCount() == 1 }
        XCTAssertTrue(asked)

        try await model.deleteActivity(id: activity.id)
        let cancelled = await waitUntil { await live.wasCancelled(0) }
        XCTAssertTrue(cancelled, "The request in flight is cancelled")
        XCTAssertTrue(model.departures.isEmpty)
        XCTAssertNil(model.nextTrip(at: clock.now()))
    }

    // MARK: Failed refresh

    func testAFailedRefreshKeepsTheLastRecommendationOutOfDate() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        let first = try XCTUnwrap(state(model, activity)?.calculation)

        // One backend slot later the recommendation is due for a refresh, and the backend is unreachable.
        await live.setResponder { _ in throw CommuteProviderFailure(.offline) }
        clock.advance(by: 900)
        model.refreshDepartures()
        XCTAssertEqual(state(model, activity), .refreshing(first), "Marked out of date while asking")
        await model.waitForDepartures()

        let kept = try XCTUnwrap(state(model, activity))
        XCTAssertEqual(kept, .stale(first, .provider(.offline)), "The last good answer is kept")
        XCTAssertNil(kept.calculation, "And it is never the current leave-home time")
        XCTAssertNotEqual(kept, .success(first))
        XCTAssertTrue(kept.isRetryable)
        XCTAssertEqual(model.nextTrip(at: clock.now())?.state, kept, "The Map shows the same out-of-date state")

        // Try Again: the kept time stays visible while the backend is asked, then the new answer replaces it.
        let newDeparture = pacific(2026, 10, 26, 7, 0)
        let newArrival = pacific(2026, 10, 26, 7, 50)
        await live.setResponder { _ in
            .recommendation(TestBackend.recommendation(departure: newDeparture, arrival: newArrival, generatedAt: clock.now()))
        }
        model.retryDepartures()
        XCTAssertEqual(state(model, activity), .refreshing(first))
        await model.waitForDepartures()
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, newDeparture)
        let requests = await live.requestCount()
        XCTAssertEqual(requests, 3)
    }

    func testAKeptRecommendationIsRetriedAutomatically() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        let first = try XCTUnwrap(state(model, activity)?.calculation)

        await live.setResponder { _ in throw CommuteProviderFailure(.offline) }
        await tick(model, clock, after: 900)
        XCTAssertEqual(state(model, activity), .stale(first, .provider(.offline)))
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 2)

        await tick(model, clock, after: 59)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2, "Not before a minute has passed")
        await tick(model, clock, after: 1)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 3, "Asked again on the tick a minute later")
        XCTAssertEqual(state(model, activity), .stale(first, .provider(.offline)), "Still failing: still kept, still out of date")

        let departure = pacific(2026, 10, 26, 7, 5)
        let arrival = pacific(2026, 10, 26, 7, 50)
        await live.setResponder { _ in
            .recommendation(TestBackend.recommendation(departure: departure, arrival: arrival, generatedAt: clock.now()))
        }
        await tick(model, clock, after: 119)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 3, "The second wait is two minutes")
        await tick(model, clock, after: 1)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(state(model, activity)?.calculation?.estimatedAt, clock.now(), "Recovered without Try Again")
    }

    func testAFailedDemoRefreshStillBecomesAnError() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let estimator = ScriptedCommuteEstimator { _ in .estimate(testEstimate(minutes: 60, at: clock.now())) }
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: estimator)
        await launch(model)
        XCTAssertNotNil(state(model, activity)?.calculation)

        await estimator.setResponder { _ in throw CommuteProviderFailure(.offline) }
        await tick(model, clock, after: 600)
        XCTAssertEqual(state(model, activity), .error(.provider(.offline)), "A demo estimate is not kept: no leave-home time is shown")
        XCTAssertNil(state(model, activity)?.staleCalculation)
    }

    // MARK: Automatic retry

    func testTransientFailuresAreRetriedOnTheTicksWithABackoff() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = failing(.timedOut)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        XCTAssertEqual(state(model, activity), .error(.provider(.timedOut)))

        // Waits of 1, 2, 5, and 5 minutes; nothing is asked a second early.
        var expected = 1
        for wait in [60.0, 120.0, 300.0, 300.0] {
            await tick(model, clock, after: wait - 1)
            var requests = await live.requestCount()
            XCTAssertEqual(requests, expected, "No retry before \(Int(wait)) seconds")
            await tick(model, clock, after: 1)
            expected += 1
            requests = await live.requestCount()
            XCTAssertEqual(requests, expected, "Retried after \(Int(wait)) seconds")
            XCTAssertEqual(state(model, activity), .error(.provider(.timedOut)))
        }
        XCTAssertEqual(model.departures[occurrenceID(activity)]?.attempt, 5)

        // Try Again asks at once and starts the backoff over.
        model.retryDepartures()
        await model.waitForDepartures()
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 6)
        XCTAssertEqual(model.departures[occurrenceID(activity)]?.attempt, 1)
        await tick(model, clock, after: 60)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 7, "One minute after Try Again, not five")

        // The server wakes up: the next retry succeeds without any tap.
        let departure = pacific(2026, 10, 26, 7, 5)
        let arrival = pacific(2026, 10, 26, 7, 50)
        await live.setResponder { _ in
            .recommendation(TestBackend.recommendation(departure: departure, arrival: arrival, generatedAt: clock.now()))
        }
        await tick(model, clock, after: 120)
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, departure)
    }

    func testLastingFailuresWaitForTryAgain() async throws {
        let kinds: [CommuteProviderFailure.Kind] = [.notConfigured, .invalidResponse, .unauthorized, .server(status: 400), .server(status: 404)]
        for kind in kinds {
            let clock = mondayMorningClock()
            let activity = oneTimeClass()
            let live = failing(kind)
            let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
            await launch(model)
            XCTAssertEqual(state(model, activity), .error(.provider(kind)))

            for _ in 0..<12 {
                await tick(model, clock, after: 60)
            }
            model.appDidBecomeActive()
            await model.waitForDepartures()
            var requests = await live.requestCount()
            XCTAssertEqual(requests, 1, "\(kind) is not retried automatically, on ticks or in the foreground")

            model.retryDepartures()
            await model.waitForDepartures()
            requests = await live.requestCount()
            XCTAssertEqual(requests, 2, "Try Again asks for \(kind)")
        }
    }

    func testReturningToTheForegroundRetriesTransientFailuresAtOnce() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = failing(.offline)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 1)

        clock.advance(by: 5)
        model.appDidBecomeActive()
        await model.waitForDepartures()
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2, "No waiting for the backoff when the user comes back")
    }

    func testTheDemoProviderIsNeverRetriedAutomatically() async throws {
        // Without a live backend: the injected provider's failure waits for Try Again, as before.
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let standalone = failing(.timedOut)
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: standalone)
        await launch(model)
        XCTAssertEqual(state(model, activity), .error(.provider(.timedOut)), "A provider's own failure kind is kept")
        for _ in 0..<12 {
            await tick(model, clock, after: 60)
        }
        model.appDidBecomeActive()
        await model.waitForDepartures()
        var requests = await standalone.requestCount()
        XCTAssertEqual(requests, 1, "Errors are not retried automatically without the live backend")

        // With a live backend but in Demo mode: the same, and the backend is never called.
        let demoClock = mondayMorningClock()
        let live = steadyBackend(demoClock)
        let demo = failing(.timedOut)
        let store = InMemoryPreferencesStore(initial: UserPreferences(dataMode: .demo))
        let demoModel = TestBackend.makeLiveModel(clock: demoClock, activities: [activity], liveEstimator: live, demoEstimator: demo, store: store)
        await launch(demoModel)
        XCTAssertFalse(demoModel.usesLiveBackend)
        for _ in 0..<12 {
            await tick(demoModel, demoClock, after: 60)
        }
        demoModel.appDidBecomeActive()
        await demoModel.waitForDepartures()
        requests = await demo.requestCount()
        XCTAssertEqual(requests, 1)
        let liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 0, "Demo mode never calls the backend")
    }

    func testTheEditorPreviewIsRetriedWithTheSavedTripsWhenLive() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = failing(.timedOut)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state, .error(.provider(.timedOut)))
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 2, "The saved trip and the preview")

        await tick(model, clock, after: 59)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2)
        await tick(model, clock, after: 1)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 4, "Both are asked again: the message says retried automatically, and it is")

        let departure = pacific(2026, 10, 26, 7, 5)
        let arrival = pacific(2026, 10, 26, 7, 50)
        await live.setResponder { _ in
            .recommendation(TestBackend.recommendation(departure: departure, arrival: arrival, generatedAt: clock.now()))
        }
        await tick(model, clock, after: 120)
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, departure)
        XCTAssertEqual(model.draftDeparture?.state, state(model, activity), "Preview and saved trip agree again")
    }

    func testTheDemoEditorPreviewIsStillLeftAloneOnTicks() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let estimator = ScriptedCommuteEstimator { _ in .estimate(testEstimate(minutes: 60, at: clock.now())) }
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: estimator)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        await model.waitForDepartures()
        var requests = await estimator.requestCount()
        XCTAssertEqual(requests, 2)

        await tick(model, clock, after: 660)
        requests = await estimator.requestCount()
        XCTAssertEqual(requests, 3, "Only the saved trip's stale estimate is refreshed, exactly as before")
        XCTAssertEqual(model.draftDeparture?.state.calculation?.estimatedAt, pacific(2026, 10, 26, 6))
    }

    // MARK: Not yet

    func testAFarOffTripCostsNoRequestUntilItEntersTheHorizon() async throws {
        let clock = mondayMorningClock()
        // Arrive by 7:00 PM: 13 hours ahead. The backend plans 11 hours 30 minutes ahead.
        let evening = TestFixtures.activity(
            title: "Evening seminar",
            start: pacific(2026, 10, 26, 19, 45),
            end: pacific(2026, 10, 26, 20, 35),
            arrival: pacific(2026, 10, 26, 19, 0)
        )
        let body = TestBackend.verdictBody(
            action: "leave_later",
            leaveNow: (pacific(2026, 10, 26, 7, 30), pacific(2026, 10, 26, 8, 20)),
            recommended: (pacific(2026, 10, 26, 17, 30), pacific(2026, 10, 26, 18, 40)),
            marginMinutes: 20,
            generatedAt: pacific(2026, 10, 26, 7, 30)
        )
        let transport = ScriptedHTTPTransport(.http(status: 200, body: body))
        let provider = BackendCommuteProvider(
            client: TestBackend.client(transport: transport, clock: clock),
            clock: clock,
            describe: { "<\(TestBackend.iso($0))>" }
        )
        let model = TestBackend.makeLiveModel(clock: clock, activities: [evening], liveEstimator: provider)
        await launch(model)

        let askAgainAt = pacific(2026, 10, 26, 7, 30)
        let notYet = DepartureState.unavailable(.notYetPlannable(
            message: "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after <2026-10-26T14:30:00.000Z>.",
            askAgainAt: askAgainAt
        ))
        XCTAssertEqual(state(model, evening), notYet)
        XCTAssertFalse(notYet.isRetryable, "Nothing failed: no Try Again")
        var sent = await transport.requestCount()
        XCTAssertEqual(sent, 0, "The message is shown with no request at all")

        // Ticks before the trip enters the horizon still cost nothing.
        for _ in 0..<5 {
            await tick(model, clock, after: 60)
        }
        clock.set(pacific(2026, 10, 26, 7, 29, 59))
        model.refreshDepartures()
        await model.waitForDepartures()
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(state(model, evening), notYet)

        // Once the clock passes that time, the next tick asks and the recommendation appears.
        clock.set(askAgainAt)
        model.refreshDepartures()
        await model.waitForDepartures()
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
        let calculation = try XCTUnwrap(state(model, evening)?.calculation)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 17, 30))
        XCTAssertEqual(calculation.recommendation?.margin, 20 * 60)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.string("arriveBy"), "2026-10-27T02:00:00.000Z", "7:00 PM PDT as an absolute instant")
    }

    func testANoRushVerdictIsAskedAgainAfterTenMinutes() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let sixAM = pacific(2026, 10, 26, 6)
        let reason = "Traffic is steady, so waiting will not cut your driving much. You have 45 minutes before you need to leave to make your deadline, so there is no need to go yet."
        let noRush = TestBackend.verdictBody(
            action: "no_rush",
            reason: reason,
            leaveNow: (sixAM, sixAM.addingTimeInterval(45 * 60)),
            recommended: (sixAM, sixAM.addingTimeInterval(45 * 60)),
            marginMinutes: 90,
            generatedAt: sixAM
        )
        let transport = ScriptedHTTPTransport(.http(status: 200, body: noRush))
        let provider = BackendCommuteProvider(
            client: TestBackend.client(transport: transport, clock: clock),
            clock: clock,
            describe: { "<\(TestBackend.iso($0))>" }
        )
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: provider)
        await launch(model)

        XCTAssertEqual(
            state(model, activity),
            .unavailable(.notYetPlannable(message: "\(reason) Checked <2026-10-26T13:00:00.000Z>.", askAgainAt: sixAM.addingTimeInterval(600))),
            "No recommendation yet, in the backend's own words"
        )
        var sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
        await tick(model, clock, after: 599)
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)

        let planned = TestBackend.verdictBody(
            action: "leave_later",
            leaveNow: (sixAM.addingTimeInterval(600), sixAM.addingTimeInterval(600 + 45 * 60)),
            recommended: (pacific(2026, 10, 26, 7, 5), pacific(2026, 10, 26, 7, 50)),
            marginMinutes: 25,
            generatedAt: sixAM.addingTimeInterval(600)
        )
        await transport.setReply(.http(status: 200, body: planned))
        await tick(model, clock, after: 1)
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 2, "Asked again ten minutes later")
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))
    }

    // MARK: Leave now

    func testALeaveNowAnswerStaysPutAcrossMinuteTicks() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 7, 20))
        let activity = oneTimeClass()
        let live = ScriptedCommuteEstimator { _ in
            let now = clock.now()
            return .recommendation(TestBackend.recommendation(
                advice: .leaveNow,
                departure: now,
                arrival: now.addingTimeInterval(45 * 60),
                reason: "Traffic won't improve much in the next 3 hours.",
                margin: 10 * 60,
                generatedAt: now
            ))
        }
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: TestFixtures.enUS)
        let answered = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(answered.recommendation?.advice, .leaveNow)
        XCTAssertEqual(answered.leaveHome, pacific(2026, 10, 26, 7, 20))

        for minute in 1...3 {
            await tick(model, clock, after: 60)
            XCTAssertEqual(state(model, activity), .success(answered), "Still the same current answer after \(minute) minute ticks")
            let requests = await live.requestCount()
            XCTAssertEqual(requests, 1, "No extra request on tick \(minute)")
            XCTAssertNil(formatter.departureTimingText(for: answered, at: clock.now()), "No local warning about a passed time")
            let spoken = formatter.departureAccessibilityLabel(for: answered, at: clock.now())
            XCTAssertFalse(spoken.contains("may miss"), spoken)
            XCTAssertTrue(spoken.hasPrefix("Leave now, as of 7:20"), spoken)
        }

        await tick(model, clock, after: 60)
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 1, "Four minutes: still inside its fixed lifetime")
        await tick(model, clock, after: 60)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2, "Five minutes: asked again")
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, pacific(2026, 10, 26, 7, 25))
    }

    func testAnUnreachableArrivalIsShownInTheBackendsTerms() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 7, 50))
        let activity = oneTimeClass()
        let live = ScriptedCommuteEstimator { _ in
            let now = clock.now()
            return .recommendation(TestBackend.recommendation(
                advice: .leaveNow,
                departure: now,
                arrival: now.addingTimeInterval(65 * 60),
                reason: "Leave now, you may be late by about 40 minutes.",
                lateBy: 40 * 60,
                generatedAt: now
            ))
        }
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)

        let late = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertTrue(late.isArrivalUnreachable)
        XCTAssertEqual(late.recommendation?.advice, .leaveNow)
        XCTAssertEqual(late.recommendation?.lateBy, 40 * 60)
        XCTAssertEqual(late.leaveHome, pacific(2026, 10, 26, 7, 50), "The backend's own departure, not a local guess")
        XCTAssertEqual(late.recommendation?.predictedArrival, pacific(2026, 10, 26, 8, 55))
        XCTAssertEqual(model.nextTrip(at: clock.now())?.state, .success(late), "A current answer: the lateness is information, not a failure")

        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: TestFixtures.enUS)
        XCTAssertEqual(
            formatter.departureTimingText(for: late, at: clock.now()),
            "Your ideal arrival is no longer reachable: leaving now you would arrive about 40 minutes late."
        )
        await tick(model, clock, after: 60)
        XCTAssertEqual(state(model, activity), .success(late))
        let requests = await live.requestCount()
        XCTAssertEqual(requests, 1)
    }

    func testAPassedPlannedDepartureIsHandedBackToTheBackend() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 7, 10))
        let activity = oneTimeClass()
        let plannedDeparture = pacific(2026, 10, 26, 7, 15)
        let live = ScriptedCommuteEstimator { _ in
            let now = clock.now()
            if now <= plannedDeparture {
                return .recommendation(TestBackend.recommendation(departure: plannedDeparture, arrival: plannedDeparture.addingTimeInterval(45 * 60), generatedAt: now))
            }
            return .recommendation(TestBackend.recommendation(advice: .leaveNow, departure: now, arrival: now.addingTimeInterval(50 * 60), generatedAt: now))
        }
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        let planned = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(planned.leaveHome, plannedDeparture)

        // On time is still on time: nothing is asked at 7:15 sharp.
        clock.set(plannedDeparture)
        model.refreshDepartures()
        await model.waitForDepartures()
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 1)

        // The next tick after it passed asks the backend, which now says leave now.
        clock.set(pacific(2026, 10, 26, 7, 16))
        model.refreshDepartures()
        XCTAssertEqual(state(model, activity), .refreshing(planned), "The passed time is marked out of date, not judged locally")
        await model.waitForDepartures()
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2)
        let handedOver = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(handedOver.recommendation?.advice, .leaveNow)
        XCTAssertEqual(handedOver.leaveHome, pacific(2026, 10, 26, 7, 16))
    }

    // MARK: A steady time for a nearby departure

    func testANearbyLeaveHomeTimeHoldsStillWhileTrafficDoes() async throws {
        // Inside three hours the backend's candidate departures are the moment it is asked plus
        // whole 15-minute slots, and it recommends the latest one that still arrives 10 minutes
        // early. With a steady 45-minute drive that is the latest slot at or before the ideal
        // arrival minus 55 minutes; when only "now" is left, it says leave now. Asked at
        // arbitrary moments this answer jumps by up to a slot with traffic unchanged (6:00
        // gives 7:15, 6:10 gives 7:10, 6:20 gives 7:20).
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let asks = DateLog()
        let slot: TimeInterval = 15 * 60
        let live = ScriptedCommuteEstimator { request in
            let now = clock.now()
            asks.append(now)
            let latest = request.arriveBy.addingTimeInterval(-55 * 60)
            let slots = (latest.timeIntervalSince(now) / slot).rounded(.down)
            guard slots >= 1 else {
                return .recommendation(TestBackend.recommendation(
                    advice: .leaveNow,
                    departure: now,
                    arrival: now.addingTimeInterval(45 * 60),
                    margin: 10 * 60,
                    generatedAt: now
                ))
            }
            let departure = now.addingTimeInterval(slots * slot)
            return .recommendation(TestBackend.recommendation(
                departure: departure,
                arrival: departure.addingTimeInterval(45 * 60),
                margin: request.arriveBy.timeIntervalSince(departure) - 45 * 60,
                generatedAt: now
            ))
        }
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await launch(model)
        let sevenFifteen = pacific(2026, 10, 26, 7, 15)
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, sevenFifteen)

        // The Map's clock ticks once a minute for the 75 minutes until that departure.
        for minute in 1...75 {
            clock.advance(by: 60)
            model.refreshDepartures()
            let during = state(model, activity)
            XCTAssertEqual(
                (during?.calculation ?? during?.staleCalculation)?.leaveHome,
                sevenFifteen,
                "While it is asked again (minute \(minute)) the time on screen is the same"
            )
            await model.waitForDepartures()
            let shown = try XCTUnwrap(state(model, activity)?.calculation, "A current answer after minute \(minute)")
            XCTAssertEqual(shown.leaveHome, sevenFifteen, "The leave-home time never moved (minute \(minute))")
        }

        let six = pacific(2026, 10, 26, 6)
        XCTAssertEqual(
            asks.values,
            [0, 15, 30, 45, 60, 75].map { six.addingTimeInterval(TimeInterval($0) * 60) },
            "Asked exactly one backend slot apart, so every ask lands on the same grid of departures"
        )
        let last = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(last.recommendation?.advice, .leaveNow, "At 7:15 the backend says leave now, at the very time that was shown all along")
        XCTAssertEqual(last.leaveHome, sevenFifteen)
    }

    func testASlowAnswerDoesNotShiftTheNextAskOffTheGrid() async throws {
        // The answer to the 6:00 ask arrives 40 seconds later, as from a server that is waking
        // up. The next ask still goes out on the 6:15 tick: its age is counted from the ask.
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = LateAnsweringEstimator()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live)
        await model.loadPreferences()
        await model.loadActivities()
        _ = await waitUntil { await live.callCount() == 1 }
        clock.advance(by: 40)
        await live.answer(0, with: advised(clock, departure: pacific(2026, 10, 26, 7, 15), arrival: pacific(2026, 10, 26, 8, 0)))
        await model.waitForDepartures()
        XCTAssertEqual(state(model, activity)?.calculation?.estimatedAt, pacific(2026, 10, 26, 6, 0, 40))

        // Minute ticks at 6:01 ... 6:14 ask nothing; the one at 6:15 does.
        clock.set(pacific(2026, 10, 26, 6, 14))
        model.refreshDepartures()
        var calls = await live.callCount()
        XCTAssertEqual(calls, 1)
        clock.set(pacific(2026, 10, 26, 6, 15))
        model.refreshDepartures()
        let asked = await waitUntil { await live.callCount() == 2 }
        XCTAssertTrue(asked, "Fifteen minutes after the ask, not sixteen")
        await live.answer(1, with: advised(clock, departure: pacific(2026, 10, 26, 7, 15), arrival: pacific(2026, 10, 26, 8, 0)))
        await model.waitForDepartures()
        calls = await live.callCount()
        XCTAssertEqual(calls, 2)
    }

    // MARK: Data mode

    func testSwitchingTheDataModeNeverMixesTheTwoSources() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let store = RecordingPreferencesStore()
        // No demo estimator: the model's own TestCommuteProvider, 60 minutes, is the demo.
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, store: store)
        await launch(model)
        XCTAssertTrue(model.beginEditing(activityID: activity.id))
        await model.waitForDepartures()
        XCTAssertEqual(state(model, activity)?.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))
        var liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 2)

        // To Demo: every live value is gone at once. Nothing is kept as "out of date".
        model.setDataMode(.demo)
        XCTAssertFalse(model.usesLiveBackend)
        XCTAssertTrue(model.usesTestCommute)
        XCTAssertEqual(state(model, activity), .loading, "A different source starts from loading, never from refreshing")
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        await model.waitForDepartures()
        let demo = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertNil(demo.recommendation, "A simulated value is never labeled as a backend recommendation")
        XCTAssertTrue(demo.isSimulated)
        XCTAssertEqual(demo.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertEqual(demo.leaveHome, pacific(2026, 10, 26, 7, 15), "8:15 minus the 60-minute test commute")
        XCTAssertNil(model.draftDeparture?.state.calculation?.recommendation)
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))
        liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 2, "Demo mode never calls the backend")
        await model.flushPendingSaves()
        var saved = await store.saved
        XCTAssertEqual(saved.last?.dataMode, .demo, "The choice is stored")

        // Demo ticks stay in the demo.
        await tick(model, clock, after: 660)
        liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 2)
        XCTAssertTrue(state(model, activity)?.calculation?.isSimulated ?? false)

        // Back to Live: every simulated value is gone at once.
        model.setDataMode(.live)
        XCTAssertTrue(model.usesLiveBackend)
        XCTAssertFalse(model.usesTestCommute)
        XCTAssertEqual(state(model, activity), .loading)
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        await model.waitForDepartures()
        let back = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertNotNil(back.recommendation, "A backend value is never labeled as simulated")
        XCTAssertFalse(back.isSimulated)
        XCTAssertEqual(back.leaveHome, pacific(2026, 10, 26, 7, 5))
        liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 4)
        await model.flushPendingSaves()
        saved = await store.saved
        XCTAssertEqual(saved.last?.dataMode, .live)

        // Choosing the mode already in use changes nothing.
        model.setDataMode(.live)
        XCTAssertNotNil(state(model, activity)?.calculation)
        liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 4)
    }

    func testALiveAnswerArrivingAfterTheSwitchToDemoIsDropped() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = LateAnsweringEstimator()
        let demo = ScriptedCommuteEstimator(minutes: 30)
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, demoEstimator: demo)
        await model.loadPreferences()
        await model.loadActivities()
        let asked = await waitUntil { await live.callCount() == 1 }
        XCTAssertTrue(asked)

        model.setDataMode(.demo)
        await model.waitForDepartures()
        let simulated = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertEqual(simulated.leaveHome, pacific(2026, 10, 26, 7, 45))

        await live.answer(0, with: advised(clock, departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50)))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state(model, activity), .success(simulated), "The backend's late answer does not replace the demo value")
        XCTAssertNil(state(model, activity)?.calculation?.recommendation)
        let demoRequests = await demo.requestCount()
        XCTAssertEqual(demoRequests, 1)
        let liveCalls = await live.callCount()
        XCTAssertEqual(liveCalls, 1)
    }

    func testTheStoredDataModeAndAddressApplyAtLaunch() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let demo = ScriptedCommuteEstimator(minutes: 60)
        let configuration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let store = InMemoryPreferencesStore(initial: UserPreferences(dataMode: .demo, backendAddress: "https://stored.example"))
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, demoEstimator: demo, configuration: configuration, store: store)
        XCTAssertTrue(model.usesLiveBackend, "Live until the stored settings say otherwise")

        await launch(model)
        XCTAssertFalse(model.usesLiveBackend, "The stored Demo mode applies")
        XCTAssertEqual(model.dataMode, .demo)
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://stored.example", "The stored address reaches the client")
        XCTAssertEqual(model.backendAddressText, "https://stored.example")
        XCTAssertEqual(model.backendBaseURL?.absoluteString, "https://stored.example")
        XCTAssertNil(state(model, activity)?.calculation?.recommendation)
        let liveRequests = await live.requestCount()
        XCTAssertEqual(liveRequests, 0, "The backend was never asked")
        let demoRequests = await demo.requestCount()
        XCTAssertEqual(demoRequests, 1)

        // Stored text that is not a usable address counts as none: the host's default applies.
        let brokenConfiguration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let brokenStore = InMemoryPreferencesStore(initial: UserPreferences(backendAddress: "http://example.org/path"))
        let other = TestBackend.makeLiveModel(clock: clock, liveEstimator: live, configuration: brokenConfiguration, store: brokenStore)
        await other.loadPreferences()
        XCTAssertEqual(brokenConfiguration.baseURL, TestBackend.baseURL)
        XCTAssertNil(brokenConfiguration.overrideBaseURL)
    }

    func testSettingsLoadedAfterTheScheduleReplaceLiveResults() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let store = InMemoryPreferencesStore(initial: UserPreferences(dataMode: .demo))
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, store: store)
        // The schedule first, as Try Again on Saved data can do.
        await model.loadActivities()
        await model.waitForDepartures()
        XCTAssertNotNil(state(model, activity)?.calculation?.recommendation)

        await model.loadPreferences()
        XCTAssertFalse(model.usesLiveBackend)
        XCTAssertNil(state(model, activity)?.staleCalculation, "The live value is not kept under the demo")
        await model.waitForDepartures()
        let demo = try XCTUnwrap(state(model, activity)?.calculation)
        XCTAssertNil(demo.recommendation)
        XCTAssertTrue(demo.isSimulated)
    }

    // MARK: Server address

    func testTheServerAddressIsValidatedStoredAndApplied() async throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let live = steadyBackend(clock)
        let configuration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let store = RecordingPreferencesStore()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [activity], liveEstimator: live, configuration: configuration, store: store)
        await launch(model)
        XCTAssertEqual(model.backendAddressText, "")
        XCTAssertEqual(model.backendBaseURL, TestBackend.baseURL, "The host's default")

        // Unusable text: the issue is returned and nothing changes.
        XCTAssertEqual(model.applyBackendAddress("http://example.org"), .needsHTTPS)
        XCTAssertEqual(model.applyBackendAddress("example.org"), .unsupportedScheme)
        XCTAssertEqual(model.backendAddressText, "")
        XCTAssertEqual(configuration.baseURL, TestBackend.baseURL)
        XCTAssertNotNil(state(model, activity)?.calculation, "The results stay")
        var requests = await live.requestCount()
        XCTAssertEqual(requests, 1)

        // A new address: stored normalized, handed to the client, and everything asked again.
        XCTAssertNil(model.applyBackendAddress("  HTTPS://Other.example/ "))
        XCTAssertEqual(model.backendAddressText, "https://other.example")
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://other.example")
        XCTAssertEqual(state(model, activity), .loading, "Nothing from the old server lingers")
        await model.waitForDepartures()
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2)
        await model.flushPendingSaves()
        var saved = await store.saved
        XCTAssertEqual(saved.last?.backendAddress, "https://other.example")

        // The same address again: nothing to do.
        XCTAssertNil(model.applyBackendAddress("https://other.example"))
        XCTAssertNotNil(state(model, activity)?.calculation)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 2)

        // Empty text: back to the host's default.
        XCTAssertNil(model.applyBackendAddress(""))
        XCTAssertEqual(model.backendAddressText, "")
        XCTAssertEqual(configuration.baseURL, TestBackend.baseURL)
        XCTAssertEqual(state(model, activity), .loading)
        await model.waitForDepartures()
        requests = await live.requestCount()
        XCTAssertEqual(requests, 3)
        await model.flushPendingSaves()
        saved = await store.saved
        XCTAssertNil(saved.last?.backendAddress)

        // In Demo mode the address is stored for later, and the demo results are left alone.
        model.setDataMode(.demo)
        await model.waitForDepartures()
        let demo = try XCTUnwrap(state(model, activity))
        XCTAssertNil(model.applyBackendAddress("https://third.example"))
        XCTAssertEqual(configuration.baseURL?.absoluteString, "https://third.example")
        XCTAssertEqual(state(model, activity), demo)
        requests = await live.requestCount()
        XCTAssertEqual(requests, 3)
    }

    // MARK: Pure pieces

    func testAFailureKeepsOnlyAnEarlierRecommendation() throws {
        let arrival = pacific(2026, 10, 26, 8, 15)
        let advised = try DepartureCalculation.make(
            idealArrival: arrival,
            recommendation: TestBackend.recommendation(departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50), generatedAt: pacific(2026, 10, 26, 6))
        ).get()
        let demo = try DepartureCalculation.make(idealArrival: arrival, estimate: testEstimate(minutes: 60)).get()
        let failure = DepartureState.error(.provider(.offline))

        XCTAssertEqual(WaitItOutModel.settledState(failure, replacing: .refreshing(advised)), .stale(advised, .provider(.offline)))
        XCTAssertEqual(WaitItOutModel.settledState(failure, replacing: .stale(advised, .provider(.timedOut))), .stale(advised, .provider(.offline)))
        XCTAssertEqual(WaitItOutModel.settledState(.error(.providerFailed), replacing: .refreshing(advised)), .stale(advised, .providerFailed))
        XCTAssertEqual(WaitItOutModel.settledState(failure, replacing: .refreshing(demo)), failure, "A demo estimate is not kept")
        XCTAssertEqual(WaitItOutModel.settledState(failure, replacing: .loading), failure, "Nothing earlier to keep")
        XCTAssertEqual(WaitItOutModel.settledState(.success(demo), replacing: .refreshing(advised)), .success(demo), "An answer replaces what was kept")
        let gone = DepartureState.unavailable(.noEstimate(message: "No coverage."))
        XCTAssertEqual(WaitItOutModel.settledState(gone, replacing: .refreshing(advised)), gone, "Unavailable is an answer, not a failure")
    }

    func testAKeptRecommendationEarnsNoReminder() throws {
        let clock = mondayMorningClock()
        let activity = oneTimeClass()
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [activity], at: clock.now())
        let occurrence = try XCTUnwrap(upcoming.first)
        let advised = try DepartureCalculation.make(
            idealArrival: occurrence.idealArrival,
            recommendation: TestBackend.recommendation(departure: pacific(2026, 10, 26, 7, 5), arrival: pacific(2026, 10, 26, 7, 50), generatedAt: clock.now())
        ).get()
        func plan(_ state: DepartureState) -> ReminderPlan {
            ReminderPlan.make(
                upcoming: upcoming,
                at: clock.now(),
                state: { _ in state },
                makeReminder: { occurrence, calculation in
                    ScheduledReminder(id: occurrence.id, fireDate: calculation.leaveHome, title: "T", message: "M")
                }
            )
        }
        let current = plan(.success(advised))
        XCTAssertEqual(current.reminders.map(\.fireDate), [pacific(2026, 10, 26, 7, 5)], "A current recommendation is due at its recommended departure")
        XCTAssertNil(current.nextTripGap)

        let kept = plan(.stale(advised, .provider(.offline)))
        XCTAssertTrue(kept.reminders.isEmpty, "An out-of-date recommendation is not current")
        XCTAssertEqual(kept.nextTripGap, .estimateFailed(.provider(.offline)))
        XCTAssertTrue(kept.held.isEmpty)

        let notYet = plan(.unavailable(.notYetPlannable(message: "Not yet.", askAgainAt: clock.now().addingTimeInterval(600))))
        XCTAssertTrue(notYet.reminders.isEmpty)
        XCTAssertEqual(notYet.nextTripGap, .estimateUnavailable(.notYetPlannable(message: "Not yet.", askAgainAt: clock.now().addingTimeInterval(600))))
    }

    // MARK: Recurrence across daylight-saving changes

    /// A daily series at 9:00 AM Pacific with an ideal arrival of 8:15 AM, asked through the
    /// real provider and a scripted transport that recommends leaving an hour before each
    /// requested arrival. Returns the model, the transport, and the series.
    private func dailySeries(clock: ManualWallClock, firstDay: (Int, Int, Int)) async -> (WaitItOutModel, ScriptedHTTPTransport, Activity) {
        let series = TestFixtures.activity(
            title: "Daily class",
            start: pacific(firstDay.0, firstDay.1, firstDay.2, 9),
            end: pacific(firstDay.0, firstDay.1, firstDay.2, 9, 50),
            arrival: pacific(firstDay.0, firstDay.1, firstDay.2, 8, 15),
            repeatWeekdays: Set(Weekday.allCases)
        )
        let generatedAt = clock.now()
        let transport = ScriptedHTTPTransport { request in
            guard let arriveBy = request.string("arriveBy").flatMap(BackendDate.parse) else {
                return .http(status: 400, body: TestBackend.errorBody("bad_request", "arriveBy must be a date-time."))
            }
            return .http(status: 200, body: TestBackend.verdictBody(
                action: "leave_later",
                leaveNow: (generatedAt, generatedAt.addingTimeInterval(45 * 60)),
                recommended: (arriveBy.addingTimeInterval(-3_600), arriveBy.addingTimeInterval(-900)),
                marginMinutes: 15,
                generatedAt: generatedAt
            ))
        }
        // A horizon of eight days, so every occurrence of the week is asked in one launch.
        let provider = BackendCommuteProvider(
            client: TestBackend.client(transport: transport, clock: clock),
            clock: clock,
            planningHorizon: 8 * 24 * 3_600
        )
        let model = TestBackend.makeLiveModel(clock: clock, activities: [series], liveEstimator: provider)
        await launch(model)
        return (model, transport, series)
    }

    private func pacificClock(_ date: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestFixtures.pacific
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return [parts.hour ?? -1, parts.minute ?? -1]
    }

    func testOccurrencesOnBothSidesOfTheFallBackSendCorrectInstants() async throws {
        // Fri 2026-10-30 12:00 PDT. Clocks fall back on Sun 2026-11-01.
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let (model, transport, series) = await dailySeries(clock: clock, firstDay: (2026, 10, 31))
        let requests = await transport.requests
        let sent = requests.compactMap { $0.string("arriveBy") }.sorted()
        XCTAssertEqual(sent, [
            "2026-10-31T15:15:00.000Z",
            "2026-11-01T16:15:00.000Z",
            "2026-11-02T16:15:00.000Z",
            "2026-11-03T16:15:00.000Z",
            "2026-11-04T16:15:00.000Z",
            "2026-11-05T16:15:00.000Z",
            "2026-11-06T16:15:00.000Z"
        ], "8:15 AM is 15:15Z in PDT and 16:15Z in PST")

        XCTAssertEqual(model.departures.count, 7)
        for (id, entry) in model.departures {
            XCTAssertEqual(id.activityID, series.id)
            let calculation = try XCTUnwrap(entry.state.calculation, id.rawValue)
            XCTAssertEqual(pacificClock(calculation.idealArrival), [8, 15], id.rawValue)
            XCTAssertEqual(calculation.leaveHome, calculation.idealArrival.addingTimeInterval(-3_600), "The answer for this occurrence's own instant, \(id.rawValue)")
            XCTAssertEqual(pacificClock(calculation.leaveHome), [7, 15], id.rawValue)
        }
    }

    func testOccurrencesOnBothSidesOfTheSpringForwardSendCorrectInstants() async throws {
        // Fri 2027-03-12 12:00 PST. Clocks spring forward on Sun 2027-03-14.
        let clock = ManualWallClock(pacific(2027, 3, 12, 12))
        let (model, transport, _) = await dailySeries(clock: clock, firstDay: (2027, 3, 13))
        let requests = await transport.requests
        let sent = requests.compactMap { $0.string("arriveBy") }.sorted()
        XCTAssertEqual(sent, [
            "2027-03-13T16:15:00.000Z",
            "2027-03-14T15:15:00.000Z",
            "2027-03-15T15:15:00.000Z",
            "2027-03-16T15:15:00.000Z",
            "2027-03-17T15:15:00.000Z",
            "2027-03-18T15:15:00.000Z",
            "2027-03-19T15:15:00.000Z"
        ], "8:15 AM is 16:15Z in PST and 15:15Z in PDT")
        XCTAssertEqual(model.departures.count, 7)
        for (id, entry) in model.departures {
            let calculation = try XCTUnwrap(entry.state.calculation, id.rawValue)
            XCTAssertEqual(pacificClock(calculation.idealArrival), [8, 15], id.rawValue)
            XCTAssertEqual(pacificClock(calculation.leaveHome), [7, 15], id.rawValue)
        }
    }
}

/// The moments a scripted backend was asked, readable from a `@Sendable` closure.
private final class DateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Date] = []

    var values: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ date: Date) {
        lock.lock()
        stored.append(date)
        lock.unlock()
    }
}
