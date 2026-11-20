import XCTest
@testable import WaitItOutUX

/// Step 0006: scenarios recalculate automatically and keep the earlier time as `.refreshing`,
/// Try Again only for errors, late answers dropped after a settings change, cancellation on a
/// scenario switch, the editor's preview across scenarios, home and campus edits, estimate
/// freshness, and Map and Calendar consistency after edits, duration and scenario changes, and
/// deleting the next event.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. The next sample trip is the class on Mon 2026-11-02
/// (arrival 8:15 AM PST); the lab follows on Tue 2026-11-03 (arrival 11:15 AM PST).
@MainActor
final class WaitItOutModelMapTests: XCTestCase {
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private var classID: OccurrenceID {
        OccurrenceID(activityID: SampleActivities.morningClassID, date: LocalDate.of(pacific(2026, 11, 2, 12), in: TestFixtures.pacific))
    }

    private func leaveHome(_ model: WaitItOutModel, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon), file: file, line: line)
        return try XCTUnwrap(trip.state.calculation, "State is \(trip.state)", file: file, line: line).leaveHome
    }

    private func newHome() throws -> CommutePlace {
        try CommutePlace(name: "Test apartment", coordinate: GeoCoordinate(latitude: 38.6, longitude: -121.5))
    }

    // MARK: Scenarios

    func testSwitchingScenariosRecalculatesAutomaticallyWithoutRetry() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 7, 15))
        let earlier = try XCTUnwrap(model.departures[classID]?.state.calculation)

        model.setTestCommuteScenario(.slow)
        XCTAssertEqual(model.testCommuteProvider?.configuration.scenario, .slow)
        XCTAssertEqual(model.departures[classID]?.state, .refreshing(earlier), "The earlier time stays, marked out of date")
        XCTAssertTrue(model.departures.values.allSatisfy { $0.state.isLoading })
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 6, 45))
        XCTAssertEqual(model.departures[classID]?.state.calculation?.sourceLabel, TestCommuteProvider.slowSourceLabel)

        model.setTestCommuteScenario(.unavailable)
        await model.waitForDepartures()
        let unavailable = try XCTUnwrap(model.departures[classID]?.state)
        XCTAssertEqual(unavailable, .unavailable(.noEstimate(message: TestCommuteProvider.unavailableMessage)))
        XCTAssertFalse(unavailable.isRetryable, "No Try Again without a failure")

        model.setTestCommuteScenario(.error)
        await model.waitForDepartures()
        XCTAssertEqual(model.departures[classID]?.state, .error(.providerFailed))
        XCTAssertEqual(model.departures[classID]?.state.isRetryable, true)
        model.retryDepartures()
        XCTAssertEqual(model.departures[classID]?.state, .loading)
        await model.waitForDepartures()
        XCTAssertEqual(model.departures[classID]?.state, .error(.providerFailed), "Error keeps failing until the scenario changes")

        model.setTestCommuteScenario(.normal)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 7, 15))
        await model.flushPendingSaves()
        let saved = await store.saved
        XCTAssertEqual(saved.last?.testCommuteScenario, .normal)
        XCTAssertTrue(saved.contains { $0.testCommuteScenario == .error }, "Every scenario change is persisted")
    }

    func testRetryDoesNotAskAgainForAnUnavailableEstimate() async throws {
        let estimator = ScriptedCommuteEstimator(responder: { _ in .unavailable(message: "No route (test)") })
        let model = TestFixtures.makeModel(commuteEstimator: estimator)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        let asked = await estimator.requestCount()
        model.retryDepartures()
        await model.waitForDepartures()
        let afterRetry = await estimator.requestCount()
        XCTAssertEqual(afterRetry, asked)
    }

    func testResetPrototypeTestingRestoresNormalAndSixtyMinutes() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        XCTAssertTrue(model.isPrototypeTestingAtDefaults)
        model.setTestCommuteScenario(.slow)
        XCTAssertNil(model.applyTestCommuteMinutes("45"))
        XCTAssertFalse(model.isPrototypeTestingAtDefaults)
        XCTAssertEqual(model.simulatedTravelTime, try CommuteDuration.minutes(68))

        model.resetPrototypeTesting()
        XCTAssertTrue(model.isPrototypeTestingAtDefaults)
        XCTAssertEqual(model.testCommuteProvider?.configuration.scenario, .normal)
        XCTAssertEqual(model.testCommuteProvider?.configuration.duration, .testDefault)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 7, 15))
        await model.flushPendingSaves()
        let saved = await store.saved
        XCTAssertEqual(saved.last?.testCommuteScenario, .normal)
        XCTAssertEqual(saved.last?.testCommuteDuration, .testDefault)
    }

    // MARK: Stale answers and cancellation

    func testLateAnswerAfterASettingsChangeIsDropped() async throws {
        let gate = GatedCommuteEstimator()
        let clock = ManualWallClock(pacific(2026, 10, 26, 6))
        let activity = TestFixtures.activity(start: pacific(2026, 10, 26, 9), arrival: pacific(2026, 10, 26, 8, 15))
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: gate)
        let id = OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
        await model.loadActivities()
        let firstAsked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(firstAsked)

        model.commuteSettingsDidChange()
        let secondAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(secondAsked)
        await gate.answer(1, minutes: 60)
        await gate.answer(0, minutes: 10)
        let firstCancelled = await waitUntil { await gate.wasCancelled(0) }
        XCTAssertTrue(firstCancelled, "The settings change cancels the request made under the old settings")
        await model.waitForDepartures()
        let late = await waitUntil(timeout: .milliseconds(100)) {
            model.departures[id]?.state.calculation?.leaveHome == pacific(2026, 10, 26, 8, 5)
        }
        XCTAssertFalse(late, "The answer for the old settings never shows")
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))

        let home = try newHome()
        model.setPlace(home, for: .home)
        XCTAssertEqual(model.departures[id]?.state, .loading, "A new home is a different trip")
        let thirdAsked = await waitUntil { await gate.isWaiting(2) }
        XCTAssertTrue(thirdAsked)
        let request = await gate.request(at: 2)
        XCTAssertEqual(request?.origin, home)
    }

    func testSwitchingBackBeforeASlowAnswerCancelsIt() async throws {
        let clock = FixedWallClock(TestFixtures.fridayNoon)
        let provider = TestCommuteProvider(clock: clock, configuration: .init(slowDelay: .seconds(5)))
        let model = TestFixtures.makeModel(clock: clock, commuteEstimator: provider)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        model.setTestCommuteScenario(.slow)
        let slowRequests = Array(model.departureTasks.values)
        XCTAssertEqual(slowRequests.count, model.departures.count, "One Slow request per trip")
        // Let the requests reach the provider, so each one waits inside the 5-second Slow pause.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.departures.values.allSatisfy { $0.state.isLoading }, "Still waiting for the Slow answers")

        let started = ContinuousClock.now
        model.setTestCommuteScenario(.normal)
        XCTAssertTrue(slowRequests.allSatisfy(\.isCancelled), "Switching back cancels every Slow request")
        for request in slowRequests {
            await request.value
        }
        await model.waitForDepartures()
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(3), "The cancelled Slow pauses ended early")
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 7, 15))
        XCTAssertEqual(model.departures[classID]?.state.calculation?.sourceLabel, TestCommuteProvider.sourceLabel, "No Slow answer shows")
    }

    // MARK: Editor preview

    func testEditorPreviewFollowsEveryScenarioAndOffersTryAgainOnlyAfterAnError() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        let began = model.beginEditing(activityID: SampleActivities.morningClassID)
        XCTAssertTrue(began)
        await model.waitForDepartures()
        // The editor previews the series' first occurrence: Mon 2026-10-26, arrival 8:15 AM PDT.
        let normal = try XCTUnwrap(model.draftDeparture?.state.calculation)
        XCTAssertEqual(normal.leaveHome, pacific(2026, 10, 26, 7, 15))

        model.setTestCommuteScenario(.slow)
        XCTAssertEqual(model.draftDeparture?.state, .refreshing(normal), "The preview keeps its time, marked out of date")
        await model.waitForDepartures()
        let slow = try XCTUnwrap(model.draftDeparture?.state.calculation)
        XCTAssertEqual(slow.leaveHome, pacific(2026, 10, 26, 6, 45))
        XCTAssertEqual(slow.sourceLabel, TestCommuteProvider.slowSourceLabel)

        model.setTestCommuteScenario(.error)
        XCTAssertEqual(model.draftDeparture?.state, .refreshing(slow))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state, .error(.providerFailed))
        model.retryDepartures()
        XCTAssertEqual(model.draftDeparture?.state, .loading, "Try Again asks the provider again")
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state, .error(.providerFailed), "Error keeps failing until the scenario changes")

        model.setTestCommuteScenario(.unavailable)
        XCTAssertEqual(model.draftDeparture?.state, .loading, "No earlier time to keep after a failure")
        await model.waitForDepartures()
        let unavailable = try XCTUnwrap(model.draftDeparture)
        XCTAssertEqual(unavailable.state, .unavailable(.noEstimate(message: TestCommuteProvider.unavailableMessage)))
        XCTAssertFalse(unavailable.state.isRetryable)
        model.retryDepartures()
        XCTAssertEqual(model.draftDeparture, unavailable, "Without a failure Try Again is not offered and nothing is asked again")

        model.resetPrototypeTesting()
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))
        XCTAssertEqual(model.editSession?.draft.hasChanges, false, "Scenario changes never edit the draft")
        model.cancelDraft()
        XCTAssertNil(model.draftDeparture)
    }

    // MARK: Home and campus

    func testInvalidPlaceInputChangesNothing() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        let settled = model.departures

        let issues = model.applyPlaceInput(PlaceInput(name: " ", latitude: "", longitude: "200"), for: .home)
        XCTAssertEqual(issues, [.emptyName, .emptyLatitude, .longitudeOutOfRange])
        XCTAssertEqual(model.places, model.samplePlaces)
        XCTAssertTrue(model.usesSamplePlaces)
        XCTAssertEqual(model.departures, settled)
        await model.flushPendingSaves()
        let saved = await store.saved
        XCTAssertTrue(saved.isEmpty)
    }

    func testHomeAndCampusEditsReachEveryRequestAndResetRestoresThem() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        let began = model.beginEditing(activityID: SampleActivities.afternoonLabID)
        XCTAssertTrue(began)
        await model.waitForDepartures()

        XCTAssertEqual(model.applyPlaceInput(PlaceInput(name: "Test apartment", latitude: "38.6", longitude: "-121.5"), for: .home), [])
        let home = try newHome()
        XCTAssertEqual(model.places.home, home)
        XCTAssertFalse(model.isSamplePlace(.home))
        XCTAssertTrue(model.isSamplePlace(.campus))
        XCTAssertTrue(model.departures.values.allSatisfy { $0.request.origin == home })
        XCTAssertEqual(model.draftDeparture?.request.origin, home, "The editor's preview follows the new home")

        let campus = try CommutePlace(name: "Test campus", coordinate: GeoCoordinate(latitude: 38.7, longitude: -121.3))
        model.setPlace(campus, for: .campus)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(stored.destination.name, SampleLocation.demoCampus.name, "Storage is not rewritten")
        XCTAssertEqual(model.resolvedDestination(stored.destination).name, "Test campus")
        XCTAssertTrue(model.departures.values.allSatisfy { $0.request.destination.coordinate == campus.coordinate })
        XCTAssertEqual(model.campusDestination.id, SampleLocation.demoCampus.destinationID)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 7, 15), "The test provider ignores distance")

        model.resetPlacesToSample()
        XCTAssertTrue(model.usesSamplePlaces)
        XCTAssertTrue(model.departures.values.allSatisfy { $0.request.origin == CommutePlaces.sample.home })
        model.cancelDraft()
    }

    func testStoredScenarioAndPlacesApplyOnLoad() async throws {
        let home = try newHome()
        let stored = UserPreferences(testCommuteScenario: .slow, places: CommutePlaces(home: home, campus: CommutePlaces.sample.campus))
        let model = TestFixtures.makeModel(store: InMemoryPreferencesStore(initial: stored))
        await model.loadPreferences()
        XCTAssertEqual(model.testCommuteProvider?.configuration.scenario, .slow)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model), pacific(2026, 11, 2, 6, 45))
        XCTAssertEqual(model.departures[classID]?.request.origin, home)
    }

    // MARK: Freshness

    func testStaleEstimatesRefreshOnlyWhileTheArrivalIsAhead() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 6))
        let estimator = ScriptedCommuteEstimator(responder: { _ in .estimate(testEstimate(minutes: 60, at: clock.now())) })
        let activity = TestFixtures.activity(start: pacific(2026, 10, 26, 9), arrival: pacific(2026, 10, 26, 8, 15))
        let model = TestFixtures.makeModel(clock: clock, repository: ScriptedActivityRepository(initial: [activity]), commuteEstimator: estimator)
        let id = OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
        await model.loadActivities()
        await model.waitForDepartures()
        let first = try XCTUnwrap(model.departures[id]?.state.calculation)

        clock.advance(by: 9 * 60)
        model.refreshDepartures()
        XCTAssertEqual(model.departures[id]?.state, .success(first), "Nine minutes old is still fresh")
        await model.waitForDepartures()
        var asked = await estimator.requestCount()
        XCTAssertEqual(asked, 1, "Nothing was asked again")

        clock.advance(by: 60)
        model.refreshDepartures()
        XCTAssertEqual(model.departures[id]?.state, .refreshing(first))
        await model.waitForDepartures()
        asked = await estimator.requestCount()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(model.departures[id]?.state.calculation?.estimatedAt, pacific(2026, 10, 26, 6, 10))

        clock.set(pacific(2026, 10, 26, 8, 40))
        model.refreshDepartures()
        await model.waitForDepartures()
        asked = await estimator.requestCount()
        XCTAssertEqual(asked, 2, "No refresh once the arrival target has passed")
    }

    // MARK: Map and Calendar consistency

    func testMapAndCalendarAgreeAfterEditsSettingsAndDeletingTheNextEvent() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()

        /// The Map's next trip next to what the Calendar shows for it: the block found the way
        /// the Calendar finds it (the trip's day in the visible week). An equal block means the
        /// detail sheet, which reads `departureState(for:)` for it, shows the Map's state, and
        /// that state must be the stored calculation. Returns the state both show.
        func agreedState(line: UInt = #line) throws -> DepartureState {
            let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon), line: line)
            model.selectDay(trip.occurrence.start)
            let block = try XCTUnwrap(
                model.occurrences(on: model.selectedDayRange).first(where: { $0.id == trip.occurrence.id }),
                "The Calendar shows the Map's next trip",
                line: line
            )
            XCTAssertEqual(block, trip.occurrence, "Same start, end, and ideal arrival", line: line)
            XCTAssertEqual(model.departures[trip.occurrence.id]?.state, trip.state, line: line)
            return trip.state
        }

        func assertConsistent(_ expected: Date, line: UInt = #line) async throws {
            await model.waitForDepartures()
            let state = try agreedState(line: line)
            XCTAssertEqual(state.calculation?.leaveHome, expected, line: line)
        }

        try await assertConsistent(pacific(2026, 11, 2, 7, 15))

        let began = model.beginEditing(activityID: SampleActivities.morningClassID)
        XCTAssertTrue(began)
        let arrival = pacific(2026, 10, 26, 8, 30)
        model.updateDraft { $0.setArrival(arrival) }
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        try await assertConsistent(pacific(2026, 11, 2, 7, 30))

        XCTAssertNil(model.applyTestCommuteMinutes("45"))
        try await assertConsistent(pacific(2026, 11, 2, 7, 45))

        model.setTestCommuteScenario(.slow)
        let pending = try agreedState()
        XCTAssertEqual(pending.staleCalculation?.leaveHome, pacific(2026, 11, 2, 7, 45), "Both keep the earlier time, out of date, until the Slow answer arrives")
        try await assertConsistent(pacific(2026, 11, 2, 7, 22))

        try await model.deleteActivity(id: SampleActivities.morningClassID)
        XCTAssertNil(model.departures[classID])
        model.selectDay(pacific(2026, 11, 2, 12))
        XCTAssertFalse(
            model.occurrences(on: model.selectedDayRange).contains { $0.activity.id == SampleActivities.morningClassID },
            "The Calendar no longer shows the deleted class"
        )
        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.activity.id, SampleActivities.afternoonLabID, "The lab becomes the next trip")
        try await assertConsistent(pacific(2026, 11, 3, 10, 7))
    }
}
