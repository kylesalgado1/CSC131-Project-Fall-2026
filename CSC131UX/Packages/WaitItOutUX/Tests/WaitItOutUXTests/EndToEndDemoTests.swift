import XCTest
@testable import WaitItOutUX

/// Step 0008 end-to-end demo path through the one shared model, the way the three tabs drive
/// it, over real JSON files in a fresh temporary folder: an empty launch, a class dragged onto
/// the Calendar grid, its ideal arrival and weekly repeat, Save, the calculated leave-home time
/// in the Calendar details and on the Map, a reminder preview, an Edit Series, a relaunch, and
/// a Delete Series. A second test checks the two provided sample schedules in the 60-minute
/// test mode (leave home 7:15 AM and 10:15 AM) on both sides of a daylight-saving change, and a
/// third keeps the departure out of every stored and editable value.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. Daylight saving time ends on Sun 2026-11-01 at
/// 2:00 AM, so everything planned for the next week is in PST while "now" is in PDT.
@MainActor
final class EndToEndDemoTests: XCTestCase {
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    /// A unique empty folder, removed when the test ends.
    private func makeLocation() throws -> PrototypeStorageLocation {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WaitItOutUXEndToEndTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PrototypeStorageLocation(directory: directory)
    }

    /// A launch as the host composes it: file stores, the default test commute provider
    /// (60 minutes, Normal, no delay) and a fresh in-app reminder preview adapter, then
    /// settings, then the schedule, then every estimate and reminder settles.
    private func launch(_ location: PrototypeStorageLocation) async -> WaitItOutModel {
        let clock = FixedWallClock(TestFixtures.fridayNoon)
        let model = WaitItOutModel(
            clock: clock,
            preferencesStore: FilePreferencesStore(fileURL: location.preferencesFile, clock: clock),
            activityRepository: FileActivityRepository(fileURL: location.activitiesFile, clock: clock),
            weekCalculator: WeekCalculator(timeZone: TestFixtures.pacific, locale: TestFixtures.enUS),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "Test", version: "1", build: "1")
        )
        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)
        return model
    }

    private func settle(_ model: WaitItOutModel) async {
        await model.waitForDepartures()
        await model.waitForReminders()
    }

    /// Hour and minute of `date` on the Pacific wall clock.
    private func pacificClock(_ date: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestFixtures.pacific
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return [parts.hour ?? -1, parts.minute ?? -1]
    }

    // MARK: The demo path

    func testDemoPathFromEmptyLaunchThroughDragSaveRemindEditRelaunchAndDelete() async throws {
        let location = try makeLocation()
        let model = await launch(location)

        // Empty state: nothing stored, nothing to plan, reminders off, no storage problem.
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertNil(model.activityStorageIssue)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertTrue(model.visibleWeekOccurrences.isEmpty)
        XCTAssertNil(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(model.reminderPreview, .off)

        // Calendar: the next week's Monday, after the clocks fall back.
        model.selectedTab = .calendar
        model.showNextWeek()
        model.selectDay(at: 1)
        XCTAssertEqual(model.selectedDay, pacific(2026, 11, 2, 0))

        // Press and drag on empty grid space from 9:02 to 10:13: both ends snap to quarter hours.
        let layout = DayTimelineLayout(day: model.selectedDayRange, hourHeight: 60)
        XCTAssertEqual(layout.hourCount, 24)
        let drag = GridDrag(layout: layout, timeZone: TestFixtures.pacific)
        XCTAssertNil(drag.creationInterval(fromOffset: 542, toOffset: 546), "A 4-point touch creates nothing")
        let created = try XCTUnwrap(drag.creationInterval(fromOffset: 542, toOffset: 613))
        XCTAssertEqual(created, pacific(2026, 11, 2, 9, 0)..<pacific(2026, 11, 2, 10, 15))
        XCTAssertTrue(model.beginNewActivity(spanning: created))

        let started = try XCTUnwrap(model.editSession)
        XCTAssertEqual(started.mode, .editor, "Releasing the drag opens the editor")
        XCTAssertTrue(started.draft.isNew)
        XCTAssertEqual(started.draft.start, pacific(2026, 11, 2, 9, 0))
        XCTAssertEqual(started.draft.end, pacific(2026, 11, 2, 10, 15))
        XCTAssertEqual(started.draft.idealArrival, pacific(2026, 11, 2, 8, 30), "Default arrival: 30 minutes before the start")
        XCTAssertEqual(started.draft.destination.id, SampleLocation.demoCampus.destinationID)
        XCTAssertEqual(model.occurrences(on: model.selectedDayRange).map(\.activity.id), [started.draft.id], "The grid previews the draft")
        XCTAssertTrue(model.activities.isEmpty, "Nothing is stored before Save")

        // Editor: title, then the ideal arrival (second), then a weekly repeat.
        let arrival = pacific(2026, 11, 2, 8, 15)
        model.updateDraft { draft in
            draft.title = "Chemistry 1A"
            draft.setArrival(arrival)
            draft.setRepeat(.wednesday, isOn: true)
        }
        let draft = try XCTUnwrap(model.editSession?.draft)
        XCTAssertEqual(draft.start, pacific(2026, 11, 2, 9, 0), "Setting the arrival never moves the activity")
        XCTAssertEqual(draft.end, pacific(2026, 11, 2, 10, 15))
        XCTAssertEqual(draft.repeatWeekdays, [.monday, .wednesday], "The start's weekday is included")
        XCTAssertTrue(draft.isValid, "Issues: \(draft.issues)")

        // The editor's read-only leave-home line: ideal arrival minus the 60-minute test commute.
        await model.waitForDepartures()
        let editorLine = try XCTUnwrap(model.draftDeparture)
        XCTAssertEqual(editorLine.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15), "State: \(editorLine.state)")

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)
        XCTAssertNil(model.draftDeparture, "The editor preview ends with the draft")
        XCTAssertEqual(model.activities.count, 1)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(stored.title, "Chemistry 1A")
        XCTAssertEqual(stored.idealArrival, arrival)
        XCTAssertEqual(stored.repeatWeekdays, [.monday, .wednesday])
        XCTAssertEqual(stored.source, .user)
        await settle(model)

        // Calendar details: the Monday block and the Wednesday repeat each have a leave-home time.
        let monday = try XCTUnwrap(model.occurrences(on: model.selectedDayRange).first)
        XCTAssertEqual(monday.start, pacific(2026, 11, 2, 9, 0))
        XCTAssertEqual(monday.idealArrival, arrival)
        let mondayState = model.departureState(for: monday, at: TestFixtures.fridayNoon)
        XCTAssertEqual(mondayState.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15), "State: \(mondayState)")
        model.selectDay(at: 3)
        let wednesday = try XCTUnwrap(model.occurrences(on: model.selectedDayRange).first)
        XCTAssertEqual(wednesday.start, pacific(2026, 11, 4, 9, 0))
        XCTAssertEqual(wednesday.activity.id, stored.id)
        XCTAssertEqual(model.departureState(for: wednesday, at: TestFixtures.fridayNoon).calculation?.leaveHome, pacific(2026, 11, 4, 7, 15))

        // Map: the next trip is Monday's class with the same read-only, labeled leave-home time.
        model.selectedTab = .map
        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.id, monday.id)
        let tripCalculation = try XCTUnwrap(trip.state.calculation, "State: \(trip.state)")
        XCTAssertEqual(tripCalculation.leaveHome, pacific(2026, 11, 2, 7, 15))
        XCTAssertEqual(tripCalculation.travelTime, .testDefault)
        XCTAssertTrue(tripCalculation.isSimulated, "Shown with a TEST DATA badge")
        XCTAssertEqual(tripCalculation.sourceLabel, TestCommuteProvider.sourceLabel)

        // Reminder preview: off until asked for, then one per occurrence at its leave-home time.
        model.selectedTab = .settings
        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.map(\.id), [monday.id, wednesday.id])
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [pacific(2026, 11, 2, 7, 15), pacific(2026, 11, 4, 7, 15)])
        guard case let .next(reminder, laterCount, isUpdating, _, _) = model.reminderPreview else {
            return XCTFail("Expected the next reminder preview, got \(model.reminderPreview)")
        }
        XCTAssertEqual(reminder.id, monday.id)
        XCTAssertEqual(laterCount, 1)
        XCTAssertFalse(isUpdating)
        XCTAssertTrue(reminder.message.contains("7:15"), reminder.message)
        XCTAssertTrue(reminder.message.contains("not live traffic"), reminder.message)
        XCTAssertEqual(model.reminderDelivery, .inAppPreview)
        XCTAssertEqual(model.reminderDelivery.disclosure, "Preview only - no system notification will be sent.")

        // Edit Series: an earlier ideal arrival moves every leave-home time and reminder.
        XCTAssertTrue(model.beginEditing(activityID: stored.id))
        XCTAssertEqual(model.editSession?.draft.editsSeries, true)
        let earlierArrival = pacific(2026, 11, 2, 8, 0)
        model.updateDraft { $0.setArrival(earlierArrival) }
        let edited = await model.saveDraft()
        XCTAssertTrue(edited)
        await settle(model)
        XCTAssertEqual(model.activities.map(\.idealArrival), [earlierArrival])
        XCTAssertEqual(model.activities.first?.start, pacific(2026, 11, 2, 9, 0))
        XCTAssertEqual(model.nextTrip(at: TestFixtures.fridayNoon)?.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 0))
        XCTAssertEqual(model.reminderPreviews.map(\.id), [monday.id, wednesday.id], "Same occurrence ids, no duplicates")
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [pacific(2026, 11, 2, 7, 0), pacific(2026, 11, 4, 7, 0)])

        // Relaunch: the schedule and the reminder wish come back; times and previews are recalculated.
        await model.flushPendingSaves()
        let relaunched = await launch(location)
        XCTAssertEqual(relaunched.activities, model.activities)
        XCTAssertNil(relaunched.activityStorageIssue)
        XCTAssertNil(relaunched.preferencesStorageIssue)
        XCTAssertTrue(relaunched.remindersEnabled)
        let relaunchedTrip = try XCTUnwrap(relaunched.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(relaunchedTrip.occurrence.id, monday.id, "The occurrence identity is stable across launches")
        XCTAssertEqual(relaunchedTrip.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 0))
        XCTAssertEqual(relaunched.reminderPreviews.map(\.id), [monday.id, wednesday.id], "A new launch recreates the previews")
        let savedText = String(decoding: try Data(contentsOf: location.activitiesFile), as: UTF8.self)
        XCTAssertTrue(savedText.contains("schemaVersion"), savedText)
        XCTAssertTrue(savedText.contains("Chemistry 1A"), savedText)
        XCTAssertFalse(savedText.lowercased().contains("leavehome"), "Leave-home times are never stored")
        XCTAssertFalse(savedText.lowercased().contains("departure"), "Departures are never stored")

        // Delete Series: the activity, its leave-home times, and its reminders all go.
        XCTAssertTrue(relaunched.beginEditing(activityID: stored.id))
        let deleted = await relaunched.deleteDraftActivity()
        XCTAssertTrue(deleted)
        await settle(relaunched)
        XCTAssertNil(relaunched.editSession)
        XCTAssertTrue(relaunched.activities.isEmpty)
        XCTAssertTrue(relaunched.departures.isEmpty)
        XCTAssertNil(relaunched.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertTrue(relaunched.reminderPreviews.isEmpty, "Deleting the series cancels its reminders")
        XCTAssertEqual(relaunched.reminderPreview, .unavailable(trip: nil, gap: .noUpcomingTrips))

        let third = await launch(location)
        XCTAssertTrue(third.activities.isEmpty, "The delete survives a relaunch")
        XCTAssertTrue(third.remindersEnabled)
    }

    // MARK: The provided schedules

    /// The two sample schedules with the default 60-minute test commute: every class trip leaves
    /// home at 7:15 AM (ideal arrival 8:15 AM) and every lab trip at 10:15 AM (ideal arrival
    /// 11:15 AM) on the Pacific wall clock, in this week's PDT and the next week's PST alike.
    func testProvidedSchedulesLeaveAtSevenFifteenAndTenFifteenInSixtyMinuteTestMode() async throws {
        let model = TestFixtures.makeModel()
        await model.loadPreferences()
        await model.loadActivities()
        XCTAssertEqual(model.testCommuteDuration, .testDefault)
        XCTAssertEqual(model.testCommuteDuration.wholeMinutes, 60)
        XCTAssertEqual(model.testCommuteScenario, .normal)
        await model.loadSampleActivities()
        await settle(model)
        XCTAssertEqual(model.activities.count, 2)

        let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
        let upcoming = DepartureHorizon.upcomingOccurrences(of: model.activities, at: TestFixtures.fridayNoon)
        XCTAssertEqual(upcoming.map(\.start), [
            pacific(2026, 11, 2, 9, 0),
            pacific(2026, 11, 3, 12, 0),
            pacific(2026, 11, 4, 9, 0),
            pacific(2026, 11, 5, 12, 0),
            pacific(2026, 11, 6, 9, 0)
        ], "Mon to Fri of the next week; Friday's 9:00 AM class this week is already over")
        for occurrence in upcoming {
            let calculation = try XCTUnwrap(model.departureState(for: occurrence, at: TestFixtures.fridayNoon).calculation, "\(occurrence.id)")
            let isClass = occurrence.activity.id == SampleActivities.morningClassID
            XCTAssertEqual(pacificClock(occurrence.idealArrival), isClass ? [8, 15] : [11, 15], "\(occurrence.id)")
            XCTAssertEqual(pacificClock(calculation.leaveHome), isClass ? [7, 15] : [10, 15], "\(occurrence.id)")
            XCTAssertEqual(calculation.idealArrival.timeIntervalSince(calculation.leaveHome), 3_600, "Exactly the test commute, nothing else")
            XCTAssertTrue(formatter.leaveHomeText(for: calculation).contains(isClass ? "7:15" : "10:15"), formatter.leaveHomeText(for: calculation))
        }
        let trip = try XCTUnwrap(model.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.activity.id, SampleActivities.morningClassID)
        XCTAssertEqual(trip.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15))

        // This week, before the clocks change: Monday's class and Tuesday's lab in PDT.
        let mondayMorning = TestFixtures.makeModel(clock: FixedWallClock(pacific(2026, 10, 26, 6)))
        await mondayMorning.loadPreferences()
        await mondayMorning.loadActivities()
        await mondayMorning.loadSampleActivities()
        await settle(mondayMorning)
        let thisWeek = DepartureHorizon.upcomingOccurrences(of: mondayMorning.activities, at: pacific(2026, 10, 26, 6))
        let firstTwo = Array(thisWeek.prefix(2))
        XCTAssertEqual(firstTwo.map(\.start), [pacific(2026, 10, 26, 9, 0), pacific(2026, 10, 27, 12, 0)])
        let leaveTimes = firstTwo.compactMap { mondayMorning.departureState(for: $0, at: pacific(2026, 10, 26, 6)).calculation?.leaveHome }
        XCTAssertEqual(leaveTimes, [pacific(2026, 10, 26, 7, 15), pacific(2026, 10, 27, 10, 15)])
    }

    // MARK: No editable or stored departure

    /// The product contract: the leave-home time is derived, read-only, and never stored, so no
    /// stored or editable value may carry it, and there is nothing to "calculate" by hand.
    func testDepartureIsNeitherStoredNorEditable() throws {
        let activity = TestFixtures.activity(start: pacific(2026, 11, 2, 9, 0), repeatWeekdays: [.monday])
        let draft = ActivityDraft(editing: activity)
        // What the user edits and what is stored for each activity.
        let labels = Mirror(reflecting: activity).children.compactMap { $0.label }
            + Mirror(reflecting: draft).children.compactMap { $0.label }
        XCTAssertTrue(labels.contains("idealArrival"), "The ideal arrival is the editable input")
        for label in labels {
            let lowered = label.lowercased()
            XCTAssertFalse(lowered.contains("departure"), label)
            XCTAssertFalse(lowered.contains("leavehome"), label)
            XCTAssertFalse(lowered.contains("buffer"), label)
            XCTAssertFalse(lowered.contains("parking"), label)
        }
        // Settings hold the reminder wish, never a departure.
        let settingLabels = Mirror(reflecting: UserPreferences()).children.compactMap { $0.label }
        XCTAssertTrue(settingLabels.contains("leaveHomeRemindersEnabled"))
        XCTAssertFalse(settingLabels.contains { $0.lowercased().contains("departure") }, "\(settingLabels)")
        let encoded = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("departure"), encoded)
        XCTAssertFalse(encoded.contains("leavehome"), encoded)
    }
}
