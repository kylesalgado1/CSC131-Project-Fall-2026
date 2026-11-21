import XCTest
@testable import WaitItOutUX

/// Step 0005: leave-home times. The model asks the injected `CommuteEstimating` provider for
/// every saved occurrence inside `DepartureHorizon` and for the pending draft, then applies
/// leave home = ideal arrival - travel time. These tests cover the default 60-minute test
/// commute on the sample schedule, the seven-day horizon, the Settings test duration (valid,
/// rejected, persisted, and loaded), recalculation after arrival edits, the editor's preview,
/// out-of-order and superseded answers, cancellation on delete, provider failures and Try
/// Again, unusable estimates, missing destinations, missed targets, midnight and
/// daylight-saving trips, and the reason shown whenever no leave-home time exists. Section 11
/// (re-run) adds the Map's calendar setup action, destination edits, and an activity moved to
/// another day with repeat days added.
///
/// Fixture clocks: Fri 2026-10-30 12:00 PDT (`TestFixtures.fridayNoon`) unless a test needs a
/// `ManualWallClock`, usually Mon 2026-10-26 06:00 PDT. Clocks fall back on Sun 2026-11-01, so
/// the sample occurrences inside the horizon at Friday noon (Mon 11-02 through Fri 11-06) are
/// in PST. `GatedCommuteEstimator` holds requests so a test can answer them in any order.
@MainActor
final class WaitItOutModelDepartureTests: XCTestCase {
    // MARK: Helpers

    /// A Pacific wall-clock instant.
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    /// Hour and minute of `date` on the Pacific wall clock.
    private func pacificClock(_ date: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestFixtures.pacific
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return [parts.hour ?? -1, parts.minute ?? -1]
    }

    /// The occurrence of `activityID` that starts on the given Pacific calendar day.
    private func occurrenceID(_ activityID: UUID, _ year: Int, _ month: Int, _ day: Int) -> OccurrenceID {
        OccurrenceID(activityID: activityID, date: LocalDate.of(pacific(year, month, day, 12), in: TestFixtures.pacific))
    }

    /// The successful calculation stored for `id`; fails the test when there is none.
    private func departureCalculation(
        _ model: WaitItOutModel,
        _ id: OccurrenceID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DepartureCalculation {
        let entry = try XCTUnwrap(model.departures[id], "No leave-home entry for \(id)", file: file, line: line)
        return try XCTUnwrap(entry.state.calculation, "Leave-home state for \(id) is \(entry.state)", file: file, line: line)
    }

    private func leaveHome(
        _ model: WaitItOutModel,
        _ id: OccurrenceID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Date {
        try departureCalculation(model, id, file: file, line: line).leaveHome
    }

    /// A clock at Mon 2026-10-26 06:00 PDT, before that week's first class.
    private func mondayMorningClock() -> ManualWallClock {
        ManualWallClock(pacific(2026, 10, 26, 6))
    }

    /// One-time class on Mon 2026-10-26, 9:00 to 9:50 AM PDT, ideal arrival 8:15 AM.
    private func oneTimeClass(title: String = "One-time class") -> Activity {
        TestFixtures.activity(
            title: title,
            start: pacific(2026, 10, 26, 9),
            end: pacific(2026, 10, 26, 9, 50),
            arrival: pacific(2026, 10, 26, 8, 15)
        )
    }

    /// A model whose scripted repository already holds `activities`. Without an estimator the
    /// model creates its own `TestCommuteProvider` on `clock`.
    private func scheduleModel(
        clock: any WallClock,
        activities: [Activity],
        estimator: (any CommuteEstimating)? = nil
    ) -> WaitItOutModel {
        TestFixtures.makeModel(
            clock: clock,
            repository: ScriptedActivityRepository(initial: activities),
            commuteEstimator: estimator
        )
    }

    /// Loads the one-time class with a provider that answers `responder` and checks the state
    /// of its only occurrence, which must carry no leave-home time.
    private func assertNoDeparture(
        _ expected: DepartureState,
        whenTheProviderAnswers responder: @escaping ScriptedCommuteEstimator.Responder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let activity = oneTimeClass()
        let estimator = ScriptedCommuteEstimator(responder: responder)
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: estimator)
        await model.loadActivities()
        await model.waitForDepartures()
        let entry = try XCTUnwrap(model.departures[occurrenceID(activity.id, 2026, 10, 26)], file: file, line: line)
        XCTAssertEqual(entry.state, expected, file: file, line: line)
        XCTAssertNil(entry.state.calculation, "No leave-home time is shown", file: file, line: line)
        let asked = await estimator.requestCount()
        XCTAssertEqual(asked, 1, "The provider was asked exactly once", file: file, line: line)
    }

    // MARK: 1. Default test commute on the sample schedule

    func testSampleScheduleLeavesAt715And1015WithTheDefault60MinuteTestCommute() async throws {
        let model = TestFixtures.makeModel()
        XCTAssertTrue(model.usesTestCommute)
        XCTAssertEqual(model.testCommuteDuration, .testDefault)
        await model.loadSampleActivities()
        await model.waitForDepartures()

        let classID = occurrenceID(SampleActivities.morningClassID, 2026, 11, 2)
        let classCalculation = try departureCalculation(model, classID)
        XCTAssertEqual(classCalculation.idealArrival, Date(timeIntervalSince1970: 1_793_636_100), "Mon 11-02 8:15 AM PST")
        XCTAssertEqual(classCalculation.leaveHome, Date(timeIntervalSince1970: 1_793_632_500), "Mon 11-02 7:15 AM PST")
        XCTAssertEqual(pacificClock(classCalculation.leaveHome), [7, 15])
        XCTAssertEqual(classCalculation.travelTime, .testDefault)
        XCTAssertTrue(classCalculation.isSimulated)
        XCTAssertEqual(classCalculation.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertEqual(classCalculation.estimatedAt, TestFixtures.fridayNoon, "Stamped with the injected clock")

        let labID = occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 3)
        let labCalculation = try departureCalculation(model, labID)
        XCTAssertEqual(labCalculation.idealArrival, Date(timeIntervalSince1970: 1_793_733_300), "Tue 11-03 11:15 AM PST")
        XCTAssertEqual(labCalculation.leaveHome, Date(timeIntervalSince1970: 1_793_729_700), "Tue 11-03 10:15 AM PST")
        XCTAssertEqual(pacificClock(labCalculation.leaveHome), [10, 15])
        XCTAssertEqual(labCalculation.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertTrue(labCalculation.isSimulated)

        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.id, classID, "Monday's class is the next trip")
        XCTAssertEqual(trip.state, model.departures[classID]?.state)

        let upcoming = DepartureHorizon.upcomingOccurrences(of: model.activities, at: TestFixtures.fridayNoon)
        XCTAssertEqual(upcoming.count, 5)
        for occurrence in upcoming {
            let label = occurrence.id.rawValue
            let calculation = try departureCalculation(model, occurrence.id)
            XCTAssertEqual(calculation.idealArrival, occurrence.idealArrival, label)
            XCTAssertEqual(calculation.leaveHome, occurrence.idealArrival.addingTimeInterval(-3_600), "Arrival minus travel time, \(label)")
            XCTAssertNotEqual(calculation.leaveHome, occurrence.start.addingTimeInterval(-3_600), "The start is never used, \(label)")
            XCTAssertEqual(calculation.travelTime, .testDefault, label)
            XCTAssertTrue(calculation.isSimulated, label)
            XCTAssertEqual(calculation.sourceLabel, TestCommuteProvider.sourceLabel, label)
            let expectedClock = occurrence.activity.id == SampleActivities.morningClassID ? [7, 15] : [10, 15]
            XCTAssertEqual(pacificClock(calculation.leaveHome), expectedClock, label)
        }
    }

    // MARK: 2. Seven-day horizon

    func testDeparturesCoverOnlyUpcomingOccurrencesWithinSevenDays() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        await model.waitForDepartures()

        let classID = SampleActivities.morningClassID
        let labID = SampleActivities.afternoonLabID
        let expected: Set<OccurrenceID> = [
            occurrenceID(classID, 2026, 11, 2),
            occurrenceID(labID, 2026, 11, 3),
            occurrenceID(classID, 2026, 11, 4),
            occurrenceID(labID, 2026, 11, 5),
            occurrenceID(classID, 2026, 11, 6)
        ]
        XCTAssertEqual(Set(model.departures.keys), expected)
        XCTAssertNil(model.departures[occurrenceID(labID, 2026, 10, 29)], "Thursday's lab is over")
        XCTAssertNil(model.departures[occurrenceID(classID, 2026, 10, 30)], "This morning's class ended at 9:50")
        XCTAssertNil(model.departures[occurrenceID(classID, 2026, 11, 9)], "Mon 11-09 is more than seven days away")
        let upcomingIDs = Set(DepartureHorizon.upcomingOccurrences(of: model.activities, at: TestFixtures.fridayNoon).map(\.id))
        XCTAssertEqual(upcomingIDs, expected)

        var ended = 0
        var planned = 0
        var beyond = 0
        let range = pacific(2026, 10, 25, 0)..<pacific(2026, 11, 15, 0)
        for occurrence in model.occurrences(in: range) {
            let state = model.departureState(for: occurrence)
            if expected.contains(occurrence.id) {
                planned += 1
                XCTAssertNotNil(state.calculation, occurrence.id.rawValue)
            } else if occurrence.end <= TestFixtures.fridayNoon {
                ended += 1
                XCTAssertEqual(state, .unavailable(.activityEnded), occurrence.id.rawValue)
            } else {
                beyond += 1
                XCTAssertEqual(state, .unavailable(.beyondHorizon), occurrence.id.rawValue)
            }
        }
        XCTAssertEqual([ended, planned, beyond], [5, 5, 5], "Ended, inside the horizon, and beyond it")
    }

    // MARK: 3. Settings test duration

    func testChangingTheTestDurationRecalculatesEveryDeparture() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        let began = model.beginEditing(activityID: SampleActivities.morningClassID)
        XCTAssertTrue(began)
        await model.waitForDepartures()

        let classID = occurrenceID(SampleActivities.morningClassID, 2026, 11, 2)
        let labID = occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 3)
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 7, 15))
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15), "The editor previews the series' first occurrence")
        let beforeChange = model.departures

        let fortyFive = try CommuteDuration.minutes(45)
        let issue = model.applyTestCommuteMinutes("45")
        XCTAssertNil(issue)
        XCTAssertEqual(model.testCommuteDuration, fortyFive)
        XCTAssertEqual(model.preferences.testCommuteDuration, fortyFive)
        XCTAssertEqual(model.testCommuteProvider?.configuration.duration, fortyFive, "The provider uses the new duration")
        XCTAssertEqual(model.departures.count, 5)
        XCTAssertTrue(model.departures.values.allSatisfy({ $0.state.isLoading }), "Every saved leave-home time is requested again")
        // Step 0006: the same trip asked again keeps its earlier answer, marked out of date.
        for (id, entry) in model.departures {
            let earlier = try XCTUnwrap(beforeChange[id]?.state.calculation, "No earlier answer for \(id)")
            XCTAssertEqual(entry.state, .refreshing(earlier), id.rawValue)
            XCTAssertNil(entry.state.calculation, "An out-of-date time is not the current one, \(id)")
        }
        XCTAssertEqual(model.draftDeparture?.state.isLoading, true, "So is the editor's preview")
        XCTAssertEqual(
            model.draftDeparture?.state.staleCalculation?.leaveHome,
            pacific(2026, 10, 26, 7, 15),
            "The preview keeps its earlier time, marked out of date, until the new answer arrives"
        )

        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 7, 30))
        XCTAssertEqual(try leaveHome(model, labID), pacific(2026, 11, 3, 10, 30))
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 30))
        for (id, entry) in model.departures {
            XCTAssertEqual(entry.state.calculation?.travelTime, fortyFive, id.rawValue)
        }
        await model.flushPendingSaves()
        var saved = await store.saved
        XCTAssertEqual(saved.last?.testCommuteDuration, fortyFive, "The duration is persisted")

        let ninety = try CommuteDuration.minutes(90)
        let secondIssue = model.applyTestCommuteMinutes("90")
        XCTAssertNil(secondIssue)
        await model.waitForDepartures()
        XCTAssertEqual(model.testCommuteDuration, ninety)
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 6, 45))
        XCTAssertEqual(try leaveHome(model, labID), pacific(2026, 11, 3, 9, 45))
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 6, 45))
        await model.flushPendingSaves()
        saved = await store.saved
        XCTAssertEqual(saved.last?.testCommuteDuration, ninety)

        model.cancelDraft()
        XCTAssertNil(model.draftDeparture)
    }

    func testInvalidTestDurationInputIsRejectedAndKeepsTheLastValidValue() async throws {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        let classID = occurrenceID(SampleActivities.morningClassID, 2026, 11, 2)
        let settled = model.departures

        let rejected: [(text: String, issue: CommuteDurationIssue)] = [
            ("0", .notPositive),
            ("-5", .notPositive),
            ("abc", .notANumber),
            ("12.5", .notWholeMinutes),
            ("721", .tooLong),
            ("", .empty),
            ("nan", .notFinite)
        ]
        for (text, expected) in rejected {
            let issue = model.applyTestCommuteMinutes(text)
            XCTAssertEqual(issue, expected, "Input \"\(text)\"")
        }
        XCTAssertEqual(model.testCommuteDuration, .testDefault)
        XCTAssertEqual(model.preferences.testCommuteDuration, .testDefault)
        XCTAssertEqual(model.testCommuteProvider?.configuration.duration, .testDefault)
        XCTAssertEqual(model.departures, settled, "Nothing was requested again")
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 7, 15))
        await model.flushPendingSaves()
        let savedAfterRejects = await store.saved
        XCTAssertTrue(savedAfterRejects.isEmpty, "Rejected input is never persisted")

        let accepted = model.applyTestCommuteMinutes(" 45 ")
        XCTAssertNil(accepted, "Surrounding spaces are ignored")
        await model.waitForDepartures()
        let afterValid = model.departures
        let rejectedAgain = model.applyTestCommuteMinutes("0")
        XCTAssertEqual(rejectedAgain, .notPositive)
        XCTAssertEqual(model.testCommuteDuration, try CommuteDuration.minutes(45), "The last valid duration stays in use")
        XCTAssertEqual(model.departures, afterValid)
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 7, 30))
    }

    // MARK: 4. Arrival edits

    func testEditingTheArrivalRecalculatesTheSeries() async throws {
        let series = TestFixtures.activity(
            title: "Series class",
            start: pacific(2026, 10, 26, 9),
            end: pacific(2026, 10, 26, 9, 50),
            arrival: pacific(2026, 10, 26, 8, 15),
            repeatWeekdays: [.monday, .wednesday, .friday]
        )
        let model = scheduleModel(clock: mondayMorningClock(), activities: [series])
        await model.loadActivities()
        await model.waitForDepartures()

        let monday = occurrenceID(series.id, 2026, 10, 26)
        let wednesday = occurrenceID(series.id, 2026, 10, 28)
        let friday = occurrenceID(series.id, 2026, 10, 30)
        XCTAssertEqual(Set(model.departures.keys), [monday, wednesday, friday])
        XCTAssertEqual(try leaveHome(model, monday), Date(timeIntervalSince1970: 1_793_024_100), "Mon 10-26 7:15 AM PDT")
        XCTAssertEqual(try leaveHome(model, wednesday), pacific(2026, 10, 28, 7, 15))
        XCTAssertEqual(try leaveHome(model, friday), pacific(2026, 10, 30, 7, 15))

        let began = model.beginEditing(activityID: series.id)
        XCTAssertTrue(began)
        let eightThirty = pacific(2026, 10, 26, 8, 30)
        model.updateDraft { $0.setArrival(eightThirty) }
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)
        await model.waitForDepartures()

        XCTAssertEqual(model.departures[monday]?.request.arriveBy, eightThirty)
        XCTAssertEqual(try leaveHome(model, monday), pacific(2026, 10, 26, 7, 30))
        XCTAssertEqual(try leaveHome(model, wednesday), pacific(2026, 10, 28, 7, 30), "The whole series is recalculated")
        XCTAssertEqual(try leaveHome(model, friday), pacific(2026, 10, 30, 7, 30))
        XCTAssertNil(model.draftDeparture)
    }

    // MARK: 5. Draft preview and superseded answers

    func testDraftPreviewFollowsArrivalEditsAndIgnoresStaleAnswers() async throws {
        let gate = GatedCommuteEstimator()
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: gate)
        let id = occurrenceID(activity.id, 2026, 10, 26)
        let eightFifteen = pacific(2026, 10, 26, 8, 15)
        let eightThirty = pacific(2026, 10, 26, 8, 30)
        let staleLeave = pacific(2026, 10, 26, 8, 5)

        await model.loadActivities()
        let savedAsked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(savedAsked)
        let savedAnswered = await gate.answer(0, minutes: 60)
        XCTAssertTrue(savedAnswered)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 15))

        let began = model.beginEditing(activityID: activity.id)
        XCTAssertTrue(began)
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        XCTAssertEqual(model.draftDeparture?.request.occurrenceID, id)
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, eightFifteen)
        let draftAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(draftAsked)

        model.updateDraft { $0.setArrival(eightThirty) }
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, eightThirty)
        let editAsked = await waitUntil { await gate.isWaiting(2) }
        XCTAssertTrue(editAsked)
        let staleRequest = await gate.request(at: 1)
        let newestRequest = await gate.request(at: 2)
        XCTAssertEqual(staleRequest?.arriveBy, eightFifteen)
        XCTAssertEqual(newestRequest?.arriveBy, eightThirty)

        // The newest request is answered first; the superseded 8:15 request answers late.
        let newestAnswered = await gate.answer(2, minutes: 60)
        XCTAssertTrue(newestAnswered)
        let staleDelivered = await gate.answer(1, minutes: 10)
        await model.waitForDepartures()
        let staleCancelled = await waitUntil { await gate.wasCancelled(1) }
        XCTAssertTrue(staleCancelled, "Changing the arrival cancels the superseded preview request")

        let preview = try XCTUnwrap(model.draftDeparture?.state.calculation, "Stale answer delivered: \(staleDelivered)")
        XCTAssertEqual(preview.leaveHome, pacific(2026, 10, 26, 7, 30), "8:30 arrival minus 60 minutes")
        XCTAssertNotEqual(preview.leaveHome, staleLeave)
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, eightThirty)
        let staleShown = await waitUntil(timeout: .milliseconds(100)) {
            model.draftDeparture?.state.calculation?.leaveHome == staleLeave
        }
        XCTAssertFalse(staleShown, "The late answer never replaces the newer preview")
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 15), "The stored activity keeps its time until Save")
        let calls = await gate.callCount()
        XCTAssertEqual(calls, 3)

        model.cancelDraft()
        XCTAssertNil(model.draftDeparture)
    }

    func testOutOfOrderAnswersForSavedOccurrencesKeepTheNewestRequest() async throws {
        let gate = GatedCommuteEstimator()
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: gate)
        let id = occurrenceID(activity.id, 2026, 10, 26)
        let eightThirty = pacific(2026, 10, 26, 8, 30)
        let staleLeave = pacific(2026, 10, 26, 8, 10)

        await model.loadActivities()
        let firstAsked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(firstAsked)
        XCTAssertEqual(model.departures[id]?.state, .loading)

        var changed = activity
        changed.idealArrival = eightThirty
        try await model.saveActivity(changed)
        XCTAssertEqual(model.departures[id]?.state, .loading)
        XCTAssertEqual(model.departures[id]?.request.arriveBy, eightThirty)
        let secondAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(secondAsked)
        let firstRequest = await gate.request(at: 0)
        let secondRequest = await gate.request(at: 1)
        XCTAssertEqual(firstRequest?.arriveBy, pacific(2026, 10, 26, 8, 15))
        XCTAssertEqual(secondRequest?.arriveBy, eightThirty)

        let newestAnswered = await gate.answer(1, minutes: 60)
        XCTAssertTrue(newestAnswered)
        let staleDelivered = await gate.answer(0, minutes: 5)
        await model.waitForDepartures()
        let firstCancelled = await waitUntil { await gate.wasCancelled(0) }
        XCTAssertTrue(firstCancelled, "Saving the new arrival cancels the request for the old one")
        let staleShown = await waitUntil(timeout: .milliseconds(100)) {
            model.departures[id]?.state.calculation?.leaveHome == staleLeave
        }
        XCTAssertFalse(staleShown, "Stale answer delivered: \(staleDelivered)")
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 30))
        XCTAssertEqual(model.departures[id]?.request.arriveBy, eightThirty)
    }

    // MARK: 6. Deletion

    func testDeletingAnActivityCancelsItsRequestAndDropsItsDeparture() async throws {
        let gate = GatedCommuteEstimator()
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: gate)

        await model.loadActivities()
        let asked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.departures.count, 1)

        try await model.deleteActivity(id: activity.id)
        XCTAssertTrue(model.departures.isEmpty)
        let cancelled = await waitUntil { await gate.wasCancelled(0) }
        XCTAssertTrue(cancelled)
        let lateAnswer = await gate.answer(0, minutes: 60)
        XCTAssertFalse(lateAnswer, "The cancelled request no longer waits for an answer")
        await model.waitForDepartures()
        XCTAssertTrue(model.departures.isEmpty)

        // Deleting from the editor drops the saved entry and the editor's preview together.
        let lab = TestFixtures.activity(
            title: "Lab",
            start: pacific(2026, 10, 27, 12),
            end: pacific(2026, 10, 27, 17, 15),
            arrival: pacific(2026, 10, 27, 11, 15)
        )
        let labID = occurrenceID(lab.id, 2026, 10, 27)
        try await model.saveActivity(lab)
        XCTAssertEqual(model.departures[labID]?.state, .loading)
        let labAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(labAsked)
        let began = model.beginEditing(activityID: lab.id)
        XCTAssertTrue(began)
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        let previewAsked = await waitUntil { await gate.isWaiting(2) }
        XCTAssertTrue(previewAsked)

        let deleted = await model.deleteDraftActivity()
        XCTAssertTrue(deleted)
        XCTAssertNil(model.editSession)
        XCTAssertNil(model.draftDeparture)
        XCTAssertTrue(model.departures.isEmpty)
        let labCancelled = await waitUntil { await gate.wasCancelled(1) }
        XCTAssertTrue(labCancelled)
        let previewCancelled = await waitUntil { await gate.wasCancelled(2) }
        XCTAssertTrue(previewCancelled)
        await model.waitForDepartures()
        XCTAssertNil(model.draftDeparture)
        XCTAssertTrue(model.departures.isEmpty)
    }

    // MARK: 7. Provider failures and unusable estimates

    func testProviderFailureShowsErrorAndRetrySucceeds() async throws {
        let estimator = ScriptedCommuteEstimator(responder: { _ in throw TestStoreError() })
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: estimator)
        let id = occurrenceID(activity.id, 2026, 10, 26)

        await model.loadActivities()
        let began = model.beginEditing(activityID: activity.id)
        XCTAssertTrue(began)
        await model.waitForDepartures()
        XCTAssertEqual(model.departures[id]?.state, .error(.providerFailed))
        XCTAssertNil(model.departures[id]?.state.calculation)
        XCTAssertEqual(model.departures[id]?.state.isRetryable, true)
        XCTAssertEqual(model.draftDeparture?.state, .error(.providerFailed))
        let afterFailure = await estimator.requestCount()
        XCTAssertEqual(afterFailure, 2, "One request for the saved occurrence and one for the editor's preview")

        model.refreshDepartures()
        await model.waitForDepartures()
        let afterRefresh = await estimator.requestCount()
        XCTAssertEqual(afterRefresh, afterFailure, "A plain refresh keeps the error; only Try Again asks again")
        XCTAssertEqual(model.departures[id]?.state, .error(.providerFailed))

        await estimator.setResponder { _ in .estimate(testEstimate(minutes: 60)) }
        model.retryDepartures()
        XCTAssertEqual(model.departures[id]?.state, .loading)
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        await model.waitForDepartures()
        let afterRetry = await estimator.requestCount()
        XCTAssertEqual(afterRetry, afterFailure + 2)
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 15))
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))

        model.cancelDraft()
        XCTAssertNil(model.draftDeparture)
    }

    func testUnavailableAndInvalidEstimatesProduceNoDepartureTime() async throws {
        try await assertNoDeparture(.unavailable(.noEstimate(message: "No route (test)"))) { _ in
            .unavailable(message: "No route (test)")
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.notPositive)))) { _ in
            .estimate(testEstimate(minutes: 0))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.notPositive)))) { _ in
            .estimate(testEstimate(minutes: -30))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.notFinite)))) { _ in
            .estimate(testEstimate(minutes: .nan))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.notFinite)))) { _ in
            .estimate(testEstimate(minutes: .infinity))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.tooLong)))) { _ in
            .estimate(testEstimate(minutes: 1e300))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.travelTime(.tooLong)))) { _ in
            .estimate(testEstimate(minutes: 721))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.missingSourceLabel))) { _ in
            .estimate(testEstimate(minutes: 60, label: "   "))
        }
        try await assertNoDeparture(.error(.invalidEstimate(.timestamp))) { _ in
            .estimate(CommuteEstimate(
                travelTime: 3_600,
                sourceLabel: "Unit test estimate",
                estimatedAt: Date(timeIntervalSinceReferenceDate: .nan),
                isSimulated: true
            ))
        }

        // Twelve hours is still accepted; the trip then starts the evening before.
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: ScriptedCommuteEstimator(minutes: 720))
        await model.loadActivities()
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, occurrenceID(activity.id, 2026, 10, 26)), pacific(2026, 10, 25, 20, 15))
    }

    func testActivityWithoutUsableDestinationIsNotSentToTheProvider() async throws {
        let nowhere = Destination(id: DestinationID("nowhere"), name: "", coordinate: GeoCoordinate(latitude: .nan, longitude: 0))
        let unnamed = Destination(id: DestinationID("unnamed"), name: "   ", coordinate: TestFixtures.demoDestination.coordinate)
        let noDestination = TestFixtures.activity(
            title: "No destination",
            start: pacific(2026, 10, 26, 9),
            end: pacific(2026, 10, 26, 9, 50),
            arrival: pacific(2026, 10, 26, 8, 15),
            destination: nowhere
        )
        let blankName = TestFixtures.activity(
            title: "Blank destination name",
            start: pacific(2026, 10, 27, 9),
            end: pacific(2026, 10, 27, 9, 50),
            arrival: pacific(2026, 10, 27, 8, 15),
            destination: unnamed
        )
        let estimator = ScriptedCommuteEstimator(minutes: 60)
        let model = scheduleModel(clock: mondayMorningClock(), activities: [noDestination, blankName], estimator: estimator)
        await model.loadActivities()
        await model.waitForDepartures()

        XCTAssertEqual(model.departures[occurrenceID(noDestination.id, 2026, 10, 26)]?.state, .unavailable(.noDestination))
        XCTAssertEqual(model.departures[occurrenceID(blankName.id, 2026, 10, 27)]?.state, .unavailable(.noDestination))
        var asked = await estimator.requestCount()
        XCTAssertEqual(asked, 0, "The provider is never asked about a trip without a destination")
        for occurrence in model.occurrences(in: pacific(2026, 10, 26, 0)..<pacific(2026, 10, 28, 0)) {
            XCTAssertEqual(model.departureState(for: occurrence), .unavailable(.noDestination), occurrence.id.rawValue)
        }
        let settled = model.departures
        model.refreshDepartures()
        XCTAssertEqual(model.departures, settled, "A NaN coordinate does not make the entry look changed on every refresh")

        model.retryDepartures()
        await model.waitForDepartures()
        asked = await estimator.requestCount()
        XCTAssertEqual(asked, 0, "Try Again does not ask either")

        // Control: an activity at the sample campus is sent.
        let control = TestFixtures.activity(
            title: "Campus class",
            start: pacific(2026, 10, 28, 9),
            end: pacific(2026, 10, 28, 9, 50),
            arrival: pacific(2026, 10, 28, 8, 15)
        )
        let controlID = occurrenceID(control.id, 2026, 10, 28)
        try await model.saveActivity(control)
        await model.waitForDepartures()
        let requests = await estimator.requests
        XCTAssertEqual(requests.map(\.occurrenceID), [controlID])
        XCTAssertEqual(try leaveHome(model, controlID), pacific(2026, 10, 28, 7, 15))
    }

    // MARK: 8. Missed targets, midnight, and daylight saving

    func testPastDepartureIsReportedAsMayMissTargetNotMovedToNow() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 7, 30))
        let activity = oneTimeClass()
        let model = scheduleModel(clock: clock, activities: [activity])
        await model.loadActivities()
        await model.waitForDepartures()
        let id = occurrenceID(activity.id, 2026, 10, 26)
        let sevenFifteen = pacific(2026, 10, 26, 7, 15)

        let trip = try XCTUnwrap(model.nextTrip(at: clock.now()))
        XCTAssertEqual(trip.occurrence.id, id)
        let calculation = try XCTUnwrap(trip.state.calculation)
        XCTAssertEqual(calculation.leaveHome, sevenFifteen, "Still arrival minus travel time")
        XCTAssertNotEqual(calculation.leaveHome, clock.now(), "Never moved to now")
        XCTAssertEqual(calculation.timing(at: clock.now()), .departurePassed)
        XCTAssertEqual(calculation.estimatedAt, pacific(2026, 10, 26, 7, 30), "Stamped with the injected clock")
        let settled = model.departures[id]

        clock.set(pacific(2026, 10, 26, 8, 20))
        model.refreshDepartures()
        XCTAssertEqual(model.departures[id], settled, "The 50-minute-old estimate is kept: its 8:15 AM arrival has passed, so a tick does not ask again")
        let lateTrip = try XCTUnwrap(model.nextTrip(at: clock.now()))
        XCTAssertEqual(lateTrip.occurrence.id, id, "Not started yet, so still the next trip")
        let lateCalculation = try XCTUnwrap(lateTrip.state.calculation)
        XCTAssertEqual(lateCalculation.leaveHome, sevenFifteen)
        XCTAssertEqual(lateCalculation.timing(at: clock.now()), .arrivalPassed)

        clock.set(pacific(2026, 10, 26, 9, 10))
        model.refreshDepartures()
        XCTAssertNil(model.nextTrip(at: clock.now()), "An activity in progress is no longer the next trip")
        XCTAssertEqual(model.departureState(for: trip.occurrence).calculation?.leaveHome, sevenFifteen, "Its details still show the leave-home time")

        clock.set(pacific(2026, 10, 26, 10))
        model.refreshDepartures()
        XCTAssertNil(model.departures[id])
        XCTAssertEqual(model.departureState(for: trip.occurrence), .unavailable(.activityEnded))
        XCTAssertNil(model.nextTrip(at: clock.now()))
    }

    func testMidnightArrivalLeavesTheEveningBefore() async throws {
        let clock = ManualWallClock(pacific(2026, 10, 26, 12))
        let activity = TestFixtures.activity(
            title: "Midnight lab",
            start: pacific(2026, 10, 27, 0, 30),
            end: pacific(2026, 10, 27, 1, 30),
            arrival: pacific(2026, 10, 27, 0, 0)
        )
        let model = scheduleModel(clock: clock, activities: [activity])
        await model.loadActivities()
        await model.waitForDepartures()

        let calculation = try departureCalculation(model, occurrenceID(activity.id, 2026, 10, 27))
        XCTAssertEqual(calculation.idealArrival, pacific(2026, 10, 27, 0, 0))
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 23, 0))
        XCTAssertEqual(
            LocalDate.of(calculation.leaveHome, in: TestFixtures.pacific),
            LocalDate.of(pacific(2026, 10, 26, 12), in: TestFixtures.pacific)
        )
        XCTAssertTrue(calculation.leavesOnEarlierDay(in: TestFixtures.pacific))
        XCTAssertFalse(calculation.crossesClockChange(in: TestFixtures.pacific))
    }

    func testTripAcrossTheFallBackTakesTheFullTravelTime() async throws {
        // Sun 2026-11-01: clocks fall back from 2:00 AM PDT to 1:00 AM PST.
        let arrival = Date(timeIntervalSince1970: 1_793_527_200)
        let activity = TestFixtures.activity(
            title: "Early lab",
            start: arrival.addingTimeInterval(30 * 60),
            end: arrival.addingTimeInterval(90 * 60),
            arrival: arrival
        )
        let model = scheduleModel(
            clock: FixedWallClock(TestFixtures.fridayNoon),
            activities: [activity],
            estimator: ScriptedCommuteEstimator(minutes: 90)
        )
        await model.loadActivities()
        await model.waitForDepartures()

        let calculation = try departureCalculation(model, occurrenceID(activity.id, 2026, 11, 1))
        XCTAssertEqual(calculation.leaveHome, Date(timeIntervalSince1970: 1_793_521_800))
        XCTAssertEqual(calculation.idealArrival.timeIntervalSince(calculation.leaveHome), 90 * 60, "Elapsed time, not wall-clock time")
        XCTAssertEqual(pacificClock(calculation.leaveHome), [1, 30], "1:30 AM PDT")
        XCTAssertEqual(pacificClock(calculation.idealArrival), [2, 0], "2:00 AM PST")
        XCTAssertTrue(calculation.crossesClockChange(in: TestFixtures.pacific))
        XCTAssertFalse(calculation.leavesOnEarlierDay(in: TestFixtures.pacific))
    }

    // MARK: 9. Reasons without a leave-home time

    func testBeyondHorizonUnsavedAndEndedOccurrencesExplainWhy() async throws {
        let past = TestFixtures.activity(
            title: "Sunday review",
            start: pacific(2026, 10, 25, 9),
            end: pacific(2026, 10, 25, 9, 50),
            arrival: pacific(2026, 10, 25, 8, 15)
        )
        let soon = oneTimeClass()
        let farAway = TestFixtures.activity(
            title: "Far class",
            start: pacific(2026, 11, 5, 9),
            end: pacific(2026, 11, 5, 9, 50),
            arrival: pacific(2026, 11, 5, 8, 15)
        )
        let estimator = ScriptedCommuteEstimator(minutes: 60)
        let model = scheduleModel(clock: mondayMorningClock(), activities: [past, soon, farAway], estimator: estimator)
        await model.loadActivities()
        await model.waitForDepartures()

        let soonID = occurrenceID(soon.id, 2026, 10, 26)
        XCTAssertEqual(Set(model.departures.keys), [soonID])
        XCTAssertNil(model.departures[occurrenceID(farAway.id, 2026, 11, 5)], "Ten days ahead is beyond the horizon")
        let requests = await estimator.requests
        XCTAssertEqual(requests.map(\.occurrenceID), [soonID], "Only the occurrence inside the horizon is sent")

        let range = pacific(2026, 10, 25, 0)..<pacific(2026, 11, 8, 0)
        let occurrences = model.occurrences(in: range)
        let pastOccurrence = try XCTUnwrap(occurrences.first(where: { $0.activity.id == past.id }))
        let soonOccurrence = try XCTUnwrap(occurrences.first(where: { $0.activity.id == soon.id }))
        let farOccurrence = try XCTUnwrap(occurrences.first(where: { $0.activity.id == farAway.id }))
        XCTAssertEqual(model.departureState(for: pastOccurrence), .unavailable(.activityEnded))
        XCTAssertEqual(model.departureState(for: soonOccurrence).calculation?.leaveHome, pacific(2026, 10, 26, 7, 15))
        XCTAssertEqual(model.departureState(for: farOccurrence), .unavailable(.beyondHorizon))

        var edited = soon
        edited.idealArrival = pacific(2026, 10, 26, 8, 30)
        let editedOccurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: [edited], in: range).first)
        XCTAssertEqual(editedOccurrence.id, soonID, "Same occurrence identity as the stored one")
        XCTAssertEqual(model.departureState(for: editedOccurrence), .unavailable(.unsavedChanges))

        // The Calendar's preview of the same unsaved change says the same; the editor previews it.
        let began = model.beginEditing(activityID: soon.id)
        XCTAssertTrue(began)
        let eightThirty = pacific(2026, 10, 26, 8, 30)
        model.updateDraft { $0.setArrival(eightThirty) }
        let previewed = try XCTUnwrap(model.visibleWeekOccurrences.first(where: { $0.id == soonID }))
        XCTAssertEqual(model.departureState(for: previewed), .unavailable(.unsavedChanges))
        await model.waitForDepartures()
        XCTAssertEqual(model.draftDeparture?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 30))
        model.cancelDraft()
        XCTAssertNil(model.draftDeparture)
    }

    func testMinuteTickRequestsOccurrencesThatEnterTheHorizon() async throws {
        let clock = mondayMorningClock()
        let soon = oneTimeClass()
        let later = TestFixtures.activity(
            title: "Thursday class",
            start: pacific(2026, 11, 5, 9),
            end: pacific(2026, 11, 5, 9, 50),
            arrival: pacific(2026, 11, 5, 8, 15)
        )
        let estimator = ScriptedCommuteEstimator(minutes: 60)
        let model = scheduleModel(clock: clock, activities: [soon, later], estimator: estimator)
        await model.loadActivities()
        await model.waitForDepartures()

        let soonID = occurrenceID(soon.id, 2026, 10, 26)
        let laterID = occurrenceID(later.id, 2026, 11, 5)
        XCTAssertEqual(Set(model.departures.keys), [soonID])
        let laterOccurrence = try XCTUnwrap(model.occurrences(in: pacific(2026, 11, 5, 0)..<pacific(2026, 11, 6, 0)).first)
        XCTAssertEqual(laterOccurrence.id, laterID)
        XCTAssertEqual(model.departureState(for: laterOccurrence), .unavailable(.beyondHorizon))

        clock.set(pacific(2026, 10, 30, 6))
        XCTAssertEqual(model.departureState(for: laterOccurrence), .loading, "Inside the horizon, requested on the next tick")
        model.refreshDepartures()
        XCTAssertEqual(Set(model.departures.keys), [laterID], "The ended class is dropped")
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, laterID), pacific(2026, 11, 5, 7, 15))
        let requests = await estimator.requests
        XCTAssertEqual(requests.map(\.occurrenceID), [soonID, laterID])
    }

    // MARK: 10. Preferences, empty schedules, and providers

    func testStoredPreferenceDurationIsAppliedOnLoad() async throws {
        let thirty = try CommuteDuration.minutes(30)
        let classID = occurrenceID(SampleActivities.morningClassID, 2026, 11, 2)
        let labID = occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 3)

        let store = InMemoryPreferencesStore(initial: UserPreferences(appearance: .system, testCommuteDuration: thirty))
        let model = TestFixtures.makeModel(store: store)
        await model.loadSampleActivities()
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, classID), pacific(2026, 11, 2, 7, 15), "Before preferences load, 60 minutes apply")

        await model.loadPreferences()
        XCTAssertEqual(model.preferencesStatus, .ready)
        XCTAssertEqual(model.testCommuteDuration, thirty)
        XCTAssertEqual(model.testCommuteProvider?.configuration.duration, thirty)
        await model.waitForDepartures()
        let calculation = try departureCalculation(model, classID)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 11, 2, 7, 45))
        XCTAssertEqual(calculation.travelTime, thirty)
        XCTAssertEqual(try leaveHome(model, labID), pacific(2026, 11, 3, 10, 45))

        let loadedFirst = TestFixtures.makeModel(
            store: InMemoryPreferencesStore(initial: UserPreferences(appearance: .system, testCommuteDuration: thirty))
        )
        await loadedFirst.loadPreferences()
        await loadedFirst.loadSampleActivities()
        await loadedFirst.waitForDepartures()
        XCTAssertEqual(try leaveHome(loadedFirst, classID), pacific(2026, 11, 2, 7, 45))

        let unchanged = TestFixtures.makeModel(store: InMemoryPreferencesStore(initial: UserPreferences()))
        await unchanged.loadSampleActivities()
        await unchanged.waitForDepartures()
        let settled = unchanged.departures
        await unchanged.loadPreferences()
        XCTAssertEqual(unchanged.departures, settled, "A stored 60 minutes changes nothing")
    }

    func testEmptyScheduleHasNoNextTrip() async throws {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        await model.waitForDepartures()
        XCTAssertTrue(model.departures.isEmpty)
        XCTAssertNil(model.nextTrip(at: TestFixtures.fridayNoon))

        await model.loadSampleActivities()
        await model.waitForDepartures()
        XCTAssertEqual(model.departures.count, 5)
        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.id, occurrenceID(SampleActivities.morningClassID, 2026, 11, 2))
        XCTAssertEqual(trip.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15))

        await model.clearSampleActivities()
        await model.waitForDepartures()
        XCTAssertTrue(model.departures.isEmpty)
        XCTAssertNil(model.nextTrip(at: TestFixtures.fridayNoon))
    }

    func testATeamProviderHidesTheTestDurationSetting() async throws {
        let defaultModel = TestFixtures.makeModel()
        XCTAssertTrue(defaultModel.usesTestCommute)
        XCTAssertEqual(defaultModel.testCommuteDuration, .testDefault)

        let twenty = try CommuteDuration.minutes(20)
        let injected = TestCommuteProvider(
            clock: FixedWallClock(TestFixtures.fridayNoon),
            configuration: TestCommuteProvider.Configuration(duration: twenty)
        )
        let injectedModel = TestFixtures.makeModel(commuteEstimator: injected)
        XCTAssertTrue(injectedModel.usesTestCommute)
        XCTAssertEqual(injectedModel.testCommuteDuration, twenty, "Until preferences load, the provider's own duration is the setting")

        let teamModel = TestFixtures.makeModel(commuteEstimator: ScriptedCommuteEstimator(minutes: 25))
        XCTAssertFalse(teamModel.usesTestCommute)
        await teamModel.loadSampleActivities()
        await teamModel.waitForDepartures()
        let calculation = try departureCalculation(teamModel, occurrenceID(SampleActivities.morningClassID, 2026, 11, 2))
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 11, 2, 7, 50))
        XCTAssertEqual(calculation.travelTime, try CommuteDuration.minutes(25))
        XCTAssertEqual(calculation.sourceLabel, "Unit test estimate", "The team provider's own label is shown")
    }

    func testUnchangedRefreshDoesNotRequestAgain() async throws {
        let clock = mondayMorningClock()
        let estimator = ScriptedCommuteEstimator(minutes: 60)
        let activity = oneTimeClass()
        let model = scheduleModel(clock: clock, activities: [activity], estimator: estimator)
        await model.loadActivities()
        await model.waitForDepartures()
        let afterLoad = await estimator.requestCount()
        XCTAssertEqual(afterLoad, 1)
        let settled = model.departures

        model.refreshDepartures()
        model.refreshDepartures()
        clock.advance(by: 60)
        model.refreshDepartures()
        await model.loadActivities()
        await model.waitForDepartures()
        let afterRefresh = await estimator.requestCount()
        XCTAssertEqual(afterRefresh, 1, "Refreshes, a minute tick, and an identical reload keep the result")
        XCTAssertEqual(model.departures, settled)

        let began = model.beginEditing(activityID: activity.id)
        XCTAssertTrue(began)
        await model.waitForDepartures()
        let afterBegin = await estimator.requestCount()
        XCTAssertEqual(afterBegin, 2, "Opening the editor asks once for its preview")
        let preview = model.draftDeparture

        model.updateDraft { $0.title = "Renamed class" }
        let laterEnd = pacific(2026, 10, 26, 10)
        model.updateDraft { $0.setEnd(laterEnd) }
        await model.waitForDepartures()
        let afterEdits = await estimator.requestCount()
        XCTAssertEqual(afterEdits, afterBegin, "Title and end changes do not change the trip")
        XCTAssertEqual(model.draftDeparture, preview)

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        await model.waitForDepartures()
        let afterSave = await estimator.requestCount()
        XCTAssertEqual(afterSave, afterBegin, "Saving keeps the stored result while destination and arrival are unchanged")
        XCTAssertEqual(model.departures, settled)
        XCTAssertNil(model.draftDeparture)
    }

    // MARK: 11. Calendar setup, destination edits, and moved activities (re-run, 2026-11-02)

    func testCalendarSetupOpensTodayWithANewActivityAndItsLeaveHomePreview() async throws {
        let clock = mondayMorningClock()
        let model = TestFixtures.makeModel(clock: clock)
        await model.loadActivities()
        await model.waitForDepartures()
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertNil(model.nextTrip(at: clock.now()))
        model.showNextWeek()
        XCTAssertFalse(model.isShowingCurrentWeek)

        // The Map's Add Activity: the Calendar on today with a new activity in the editor.
        model.startCalendarSetup()
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertTrue(model.isShowingCurrentWeek)
        XCTAssertTrue(model.isShowingToday)
        let session = try XCTUnwrap(model.editSession)
        XCTAssertEqual(session.mode, .editor)
        XCTAssertTrue(session.draft.isNew)
        XCTAssertEqual(session.draft.start, pacific(2026, 10, 26, 7), "The next whole hour today")
        XCTAssertEqual(session.draft.idealArrival, pacific(2026, 10, 26, 6, 30))
        XCTAssertEqual(model.draftDeparture?.state, .loading)

        // The editor's read-only preview is the ideal arrival minus the 60-minute test commute.
        // At 6:00 AM that time has passed, so it is kept and judged a missed target, never "now".
        await model.waitForDepartures()
        let preview = try XCTUnwrap(model.draftDeparture?.state.calculation)
        XCTAssertEqual(preview.leaveHome, pacific(2026, 10, 26, 5, 30))
        XCTAssertEqual(preview.timing(at: clock.now()), .departurePassed)
        XCTAssertTrue(preview.isSimulated)
        XCTAssertTrue(model.departures.isEmpty, "Nothing is saved, so no saved trip is planned yet")
        XCTAssertNil(model.nextTrip(at: clock.now()))

        // With that change pending, the action only switches tabs: same draft, same week.
        model.selectedTab = .map
        model.showNextWeek()
        model.startCalendarSetup()
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertEqual(model.editSession?.id, session.id)
        XCTAssertFalse(model.isShowingCurrentWeek)

        model.cancelDraft()
        XCTAssertNil(model.editSession)
        XCTAssertNil(model.draftDeparture)
    }

    func testDestinationEditsRecalculateThePreviewAndTheSavedTrip() async throws {
        let gate = GatedCommuteEstimator()
        let activity = oneTimeClass()
        let model = scheduleModel(clock: mondayMorningClock(), activities: [activity], estimator: gate)
        let id = occurrenceID(activity.id, 2026, 10, 26)
        let library = Destination(
            id: DestinationID("test-library"),
            name: "Test library",
            coordinate: GeoCoordinate(latitude: 38.5816, longitude: -121.4944)
        )

        await model.loadActivities()
        let campusAsked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(campusAsked)
        let campusAnswered = await gate.answer(0, minutes: 60)
        XCTAssertTrue(campusAnswered)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 15))

        // The editor's preview asks again as soon as the draft's destination changes, starting
        // from loading: the campus answer is never shown for the new destination.
        let began = model.beginEditing(activityID: activity.id)
        XCTAssertTrue(began)
        let campusPreviewAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(campusPreviewAsked)
        model.updateDraft { $0.destination = library }
        XCTAssertEqual(model.draftDeparture?.state, .loading)
        XCTAssertEqual(model.draftDeparture?.request.destination, library)
        let libraryPreviewAsked = await waitUntil { await gate.isWaiting(2) }
        XCTAssertTrue(libraryPreviewAsked)
        let campusPreviewCancelled = await waitUntil { await gate.wasCancelled(1) }
        XCTAssertTrue(campusPreviewCancelled)
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 15), "The saved trip keeps its time until the change is saved")

        // Saving replaces the saved trip: the campus result is dropped and the new trip is asked.
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.draftDeparture)
        XCTAssertEqual(model.departures[id]?.state, .loading)
        XCTAssertEqual(model.departures[id]?.request.destination, library)
        let previewCancelled = await waitUntil { await gate.wasCancelled(2) }
        XCTAssertTrue(previewCancelled, "Ending the draft cancels its preview request")
        let libraryAsked = await waitUntil { await gate.isWaiting(3) }
        XCTAssertTrue(libraryAsked)
        let libraryRequest = await gate.request(at: 3)
        XCTAssertEqual(libraryRequest?.destination, library)
        XCTAssertEqual(libraryRequest?.arriveBy, pacific(2026, 10, 26, 8, 15), "Same ideal arrival, new destination")
        let libraryAnswered = await gate.answer(3, minutes: 20)
        XCTAssertTrue(libraryAnswered)
        await model.waitForDepartures()
        XCTAssertEqual(try leaveHome(model, id), pacific(2026, 10, 26, 7, 55), "Ideal arrival 8:15 AM minus 20 minutes of travel")
        XCTAssertEqual(model.nextTrip(at: pacific(2026, 10, 26, 6))?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 55))
    }

    func testMovingAnActivityToAnotherDayAndAddingRepeatDaysMovesItsLeaveHomeTimes() async throws {
        let gate = GatedCommuteEstimator()
        let activity = oneTimeClass()
        let clock = mondayMorningClock()
        let model = scheduleModel(clock: clock, activities: [activity], estimator: gate)
        let monday = occurrenceID(activity.id, 2026, 10, 26)
        let tuesday = occurrenceID(activity.id, 2026, 10, 27)
        let thursday = occurrenceID(activity.id, 2026, 10, 29)

        await model.loadActivities()
        let mondayAsked = await waitUntil { await gate.isWaiting(0) }
        XCTAssertTrue(mondayAsked)
        XCTAssertEqual(Set(model.departures.keys), [monday])

        // Move the class to Tuesday while Monday's answer is still out. Start, end, and the
        // 45-minute arrival lead move together, and the preview asks for the Tuesday trip.
        let began = model.beginEditing(activityID: activity.id)
        XCTAssertTrue(began)
        let mondayPreviewAsked = await waitUntil { await gate.isWaiting(1) }
        XCTAssertTrue(mondayPreviewAsked)
        let tuesdayNine = pacific(2026, 10, 27, 9)
        model.updateDraft { $0.setStart(tuesdayNine) }
        XCTAssertEqual(model.draftDeparture?.request.occurrenceID, tuesday)
        XCTAssertEqual(model.draftDeparture?.request.arriveBy, pacific(2026, 10, 27, 8, 15))
        let tuesdayPreviewAsked = await waitUntil { await gate.isWaiting(2) }
        XCTAssertTrue(tuesdayPreviewAsked)

        // Repeat days leave the previewed trip (the first occurrence) unchanged, so nothing is asked.
        let preview = model.draftDeparture
        model.updateDraft { $0.setRepeats(true) }
        model.updateDraft { $0.setRepeat(.thursday, isOn: true) }
        XCTAssertEqual(model.editSession?.draft.repeatWeekdays, [.tuesday, .thursday])
        XCTAssertEqual(model.draftDeparture, preview)

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.departures[monday], "The Monday occurrence no longer exists")
        XCTAssertEqual(Set(model.departures.keys), [tuesday, thursday], "Tuesday 11-03 lies beyond the seven days")
        XCTAssertEqual(model.departures[tuesday]?.state, .loading)
        XCTAssertEqual(model.departures[thursday]?.state, .loading)
        let mondayCancelled = await waitUntil { await gate.wasCancelled(0) }
        XCTAssertTrue(mondayCancelled, "Monday's request is cancelled once the class moved")
        let mondayPreviewCancelled = await waitUntil { await gate.wasCancelled(1) }
        XCTAssertTrue(mondayPreviewCancelled)
        let tuesdayPreviewCancelled = await waitUntil { await gate.wasCancelled(2) }
        XCTAssertTrue(tuesdayPreviewCancelled)

        // The two new trips may reach the provider in either order; both take 60 minutes.
        let thirdAsked = await waitUntil { await gate.isWaiting(3) }
        let fourthAsked = await waitUntil { await gate.isWaiting(4) }
        XCTAssertTrue(thirdAsked)
        XCTAssertTrue(fourthAsked)
        let thirdRequest = await gate.request(at: 3)
        let fourthRequest = await gate.request(at: 4)
        XCTAssertEqual(Set([thirdRequest?.occurrenceID, fourthRequest?.occurrenceID]), [tuesday, thursday])
        let thirdAnswered = await gate.answer(3, minutes: 60)
        let fourthAnswered = await gate.answer(4, minutes: 60)
        XCTAssertTrue(thirdAnswered)
        XCTAssertTrue(fourthAnswered)
        let lateMonday = await gate.answer(0, minutes: 5)
        XCTAssertFalse(lateMonday, "The cancelled Monday request no longer waits for an answer")
        await model.waitForDepartures()

        XCTAssertEqual(try leaveHome(model, tuesday), pacific(2026, 10, 27, 7, 15))
        XCTAssertEqual(try leaveHome(model, thursday), pacific(2026, 10, 29, 7, 15))
        XCTAssertNil(model.departures[monday])
        let trip = try XCTUnwrap(model.nextTrip(at: clock.now()))
        XCTAssertEqual(trip.occurrence.id, tuesday, "The Map's next trip follows the move")
        XCTAssertEqual(trip.state.calculation?.leaveHome, pacific(2026, 10, 27, 7, 15))
    }
}
