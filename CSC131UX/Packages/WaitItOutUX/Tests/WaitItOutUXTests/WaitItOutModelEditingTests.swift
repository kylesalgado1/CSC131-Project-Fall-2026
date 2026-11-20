import XCTest
@testable import WaitItOutUX

/// Step 0004: creating, adjusting, saving, cancelling, and deleting activities through the one
/// edit session in `WaitItOutModel`. Every test drives the same model calls the editor sheet's
/// bindings and the calendar gestures make; nothing here touches a view. The 2026-11-02 re-run
/// added the commit-level checks for changed repeat days, invalid times on Save, and activities
/// and arrivals that cross midnight.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. The visible week runs Sun 2026-10-25 to Sat
/// 2026-10-31, entirely in daylight time, and the selected day starts as that Friday.
@MainActor
final class WaitItOutModelEditingTests: XCTestCase {
    // MARK: Helpers

    /// A Pacific wall-clock instant in October 2026.
    private func october(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(2026, 10, day, hour, minute)
    }

    /// Start, end, and ideal arrival of each occurrence, in order.
    private func schedule(_ occurrences: [ActivityOccurrence]) -> [[Date]] {
        occurrences.map { [$0.start, $0.end, $0.idealArrival] }
    }

    private func weekdays(_ occurrences: [ActivityOccurrence]) -> [Weekday] {
        occurrences.map { $0.id.date.weekday }
    }

    /// The editor's control path: the same draft changes the sheet's bindings make, in the
    /// order a user fills the form.
    private func fillEditor(
        _ model: WaitItOutModel,
        title: String,
        start: Date,
        end: Date,
        arrival: Date,
        alsoRepeatOn extraDays: [Weekday]
    ) {
        model.updateDraft { $0.title = title }
        model.updateDraft { $0.setStart(start) }
        model.updateDraft { $0.setEnd(end) }
        model.updateDraft { $0.setArrival(arrival) }
        model.updateDraft { $0.setRepeats(true) }
        for day in extraDays {
            model.updateDraft { $0.setRepeat(day, isOn: true) }
        }
    }

    /// A model whose scripted repository already holds `activities`, loaded once.
    private func loadedModel(with activities: [Activity]) async -> (WaitItOutModel, ScriptedActivityRepository) {
        let repository = ScriptedActivityRepository(initial: activities)
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()
        return (model, repository)
    }

    /// Mon, Wed, Fri 9:00 to 9:50 AM, ideal arrival 8:15 AM, first occurrence Mon 2026-10-26.
    private func mondayWednesdayFridaySeries(title: String = "Series class") -> Activity {
        TestFixtures.activity(
            title: title,
            start: october(26, 9),
            end: october(26, 9, 50),
            arrival: october(26, 8, 15),
            repeatWeekdays: [.monday, .wednesday, .friday]
        )
    }

    // MARK: 1. Both class schedules through the editor

    func testBothClassSchedulesEnteredInTheEditorMatchTheSampleSchedule() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()

        model.selectDay(at: 1)
        let beganMorning = model.beginNewActivity()
        XCTAssertTrue(beganMorning)
        let morningSession = try XCTUnwrap(model.editSession)
        XCTAssertEqual(morningSession.mode, .editor)
        XCTAssertEqual(morningSession.draft.start, october(26, 9), "A day other than today starts at 9:00 AM")
        fillEditor(model, title: "Morning class", start: october(26, 9), end: october(26, 9, 50), arrival: october(26, 8, 15), alsoRepeatOn: [.wednesday, .friday])
        XCTAssertEqual(model.activities, [], "Nothing is stored before Save")
        XCTAssertEqual(model.visibleWeekOccurrences.count, 3, "The calendar previews the unsaved series")
        let savedMorning = await model.saveDraft()
        XCTAssertTrue(savedMorning)
        XCTAssertNil(model.editSession)

        model.selectDay(at: 2)
        let beganLab = model.beginNewActivity()
        XCTAssertTrue(beganLab)
        fillEditor(model, title: "Afternoon lab", start: october(27, 12), end: october(27, 17, 15), arrival: october(27, 11, 15), alsoRepeatOn: [.thursday])
        let savedLab = await model.saveDraft()
        XCTAssertTrue(savedLab)
        XCTAssertNil(model.editSession)

        let writes = await repository.writeCount
        XCTAssertEqual(writes, 2, "Exactly one repository write per activity")
        XCTAssertEqual(model.activities.count, 2)

        let samples = SampleActivities.make(
            weekContaining: TestFixtures.fridayNoon,
            timeZone: TestFixtures.pacific,
            destination: TestFixtures.demoDestination
        )
        let sampleMorning = try XCTUnwrap(samples.first(where: { $0.id == SampleActivities.morningClassID }))
        let sampleLab = try XCTUnwrap(samples.first(where: { $0.id == SampleActivities.afternoonLabID }))
        let morning = try XCTUnwrap(model.activities.first(where: { $0.title == "Morning class" }))
        let lab = try XCTUnwrap(model.activities.first(where: { $0.title == "Afternoon lab" }))

        for (stored, sample) in [(morning, sampleMorning), (lab, sampleLab)] {
            XCTAssertEqual(stored.start, sample.start, stored.title)
            XCTAssertEqual(stored.end, sample.end, stored.title)
            XCTAssertEqual(stored.idealArrival, sample.idealArrival, stored.title)
            XCTAssertEqual(stored.repeatWeekdays, sample.repeatWeekdays, stored.title)
            XCTAssertEqual(stored.source, .user, stored.title)
            XCTAssertEqual(stored.timeZoneIdentifier, "America/Los_Angeles", stored.title)
            XCTAssertEqual(stored.destination, TestFixtures.demoDestination, stored.title)
        }
        XCTAssertEqual(morning.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertEqual(lab.repeatWeekdays, [.tuesday, .thursday])

        let occurrences = model.visibleWeekOccurrences
        let sampleOccurrences = OccurrenceExpander.occurrences(of: samples, in: model.visibleWeek.range)
        XCTAssertEqual(weekdays(occurrences), [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertEqual(weekdays(occurrences), weekdays(sampleOccurrences))
        XCTAssertEqual(schedule(occurrences), schedule(sampleOccurrences))
        XCTAssertEqual(occurrences.map(\.activity.title), [
            "Morning class", "Afternoon lab", "Morning class", "Afternoon lab", "Morning class"
        ])

        let morningOccurrences = occurrences.filter { $0.activity.id == morning.id }
        let sampleMorningOccurrences = sampleOccurrences.filter { $0.activity.id == SampleActivities.morningClassID }
        XCTAssertEqual(weekdays(morningOccurrences), [.monday, .wednesday, .friday])
        XCTAssertEqual(schedule(morningOccurrences), schedule(sampleMorningOccurrences))
        XCTAssertEqual(schedule(morningOccurrences).last, [october(30, 9), october(30, 9, 50), october(30, 8, 15)])

        let labOccurrences = occurrences.filter { $0.activity.id == lab.id }
        let sampleLabOccurrences = sampleOccurrences.filter { $0.activity.id == SampleActivities.afternoonLabID }
        XCTAssertEqual(weekdays(labOccurrences), [.tuesday, .thursday])
        XCTAssertEqual(schedule(labOccurrences), schedule(sampleLabOccurrences))
        XCTAssertEqual(schedule(labOccurrences).first, [october(27, 12), october(27, 17, 15), october(27, 11, 15)])
    }

    // MARK: 2. Validation feedback

    func testEmptyTitleIsFlaggedOnlyAfterSaveAndNothingIsStored() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()

        let began = model.beginNewActivity()
        XCTAssertTrue(began)
        let before = try XCTUnwrap(model.editSession)
        XCTAssertEqual(before.mode, .editor)
        XCTAssertEqual(before.draft.start, october(30, 13), "Today starts at the next whole hour")
        XCTAssertEqual(before.draft.end, october(30, 14))
        XCTAssertEqual(before.draft.idealArrival, october(30, 12, 30))
        XCTAssertEqual(before.draft.title, "")
        XCTAssertFalse(before.hasAttemptedSave)
        XCTAssertEqual(before.draft.issues, [.emptyTitle])
        XCTAssertEqual(before.visibleIssues, [], "An untouched title is not flagged before Save")

        let saved = await model.saveDraft()
        XCTAssertFalse(saved)
        let after = try XCTUnwrap(model.editSession, "The editor stays open")
        XCTAssertTrue(after.hasAttemptedSave)
        XCTAssertEqual(after.visibleIssues, [.emptyTitle])
        XCTAssertEqual(after.visibleIssues(for: .title), [.emptyTitle])
        XCTAssertEqual(after.commitState, .editing)
        XCTAssertEqual(after.draft, before.draft)
        XCTAssertEqual(model.activities, [])
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [])
    }

    func testEndBeforeStartIsShownImmediatelyWithoutASaveAttempt() async throws {
        let model = TestFixtures.makeModel(repository: ScriptedActivityRepository(), initialTab: .calendar)
        let began = model.beginNewActivity()
        XCTAssertTrue(began)
        model.updateDraft { $0.setEnd(TestFixtures.date(2026, 10, 30, 12, 45)) }

        let session = try XCTUnwrap(model.editSession)
        XCTAssertFalse(session.hasAttemptedSave)
        XCTAssertEqual(session.visibleIssues(for: .times), [.endNotAfterStart])
        XCTAssertEqual(session.visibleIssues, [.endNotAfterStart], "The empty title stays hidden until Save")
        XCTAssertEqual(session.visibleIssues(for: .title), [])
    }

    // MARK: 3. No duplicate commits

    func testConcurrentSavesCommitExactlyOnce() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()
        let began = model.beginNewActivity()
        XCTAssertTrue(began)
        model.updateDraft { $0.title = "Study group" }

        async let first = model.saveDraft()
        async let second = model.saveDraft()
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 }.count, 1, "Exactly one of two overlapping saves commits")
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.activities.count, 1)
        XCTAssertEqual(model.activities.first?.title, "Study group")
        XCTAssertNil(model.editSession)

        let third = await model.saveDraft()
        XCTAssertFalse(third, "With no pending draft there is nothing to save")
        let writesAfterThird = await repository.writeCount
        XCTAssertEqual(writesAfterThird, 1)
        XCTAssertEqual(model.activities.count, 1)
    }

    func testSavingAnUnchangedEditEndsTheSessionWithoutWriting() async throws {
        let stored = TestFixtures.activity(title: "Office hours", start: october(30, 9))
        let (model, repository) = await loadedModel(with: [stored])
        let began = model.beginEditing(activityID: stored.id)
        XCTAssertTrue(began)

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(model.activities, [stored])
    }

    // MARK: 4. Cancel restores the original

    func testCancellingACalendarMoveRestoresTheOriginalWithoutWriting() async throws {
        let original = TestFixtures.activity(title: "Office hours", start: october(30, 9))
        let (model, repository) = await loadedModel(with: [original])

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: original.id))
        XCTAssertEqual(model.editSession?.mode, .calendar)
        let occurrence = try XCTUnwrap(model.visibleWeekOccurrences.first)
        XCTAssertEqual(occurrence.start, october(30, 9))

        let friday = DayTimelineLayout(day: october(30, 0)..<october(31, 0), hourHeight: 60)
        let drag = GridDrag(layout: friday, timeZone: TestFixtures.pacific)
        let moved = drag.draft(draft, dragging: occurrence, kind: .move, translation: 30)
        XCTAssertEqual(moved.start, october(30, 9, 30), "60 points per hour, so 30 points is half an hour")
        XCTAssertEqual(moved.end, october(30, 10, 20))
        XCTAssertEqual(moved.idealArrival, october(30, 8, 45))
        model.replaceDraft(moved)

        XCTAssertEqual(model.visibleWeekOccurrences.map(\.start), [october(30, 9, 30)], "The calendar previews the move")
        XCTAssertEqual(model.calendarActivities.map(\.start), [october(30, 9, 30)])
        XCTAssertEqual(model.activities, [original], "Storage-backed state is untouched while the draft is pending")

        model.cancelDraft()
        XCTAssertNil(model.editSession)
        XCTAssertEqual(model.visibleWeekOccurrences.map(\.start), [october(30, 9)])
        XCTAssertEqual(schedule(model.visibleWeekOccurrences), [[october(30, 9), october(30, 9, 50), october(30, 8, 15)]])
        XCTAssertEqual(model.activities, [original])
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [original])
    }

    // MARK: 5. Series edit from a later occurrence

    func testMovingAWednesdayOccurrenceRetimesTheWholeSeriesAndKeepsTheArrivalLead() async throws {
        let series = mondayWednesdayFridaySeries()
        let (model, repository) = await loadedModel(with: [series])

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: series.id))
        let wednesday = try XCTUnwrap(model.visibleWeekOccurrences.first(where: { $0.id.date.weekday == .wednesday }))
        XCTAssertEqual(wednesday.start, october(28, 9))

        model.replaceDraft(draft.movingOccurrence(wednesday, toStart: october(28, 9, 30)))
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)

        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(model.activities.count, 1)
        XCTAssertEqual(stored.id, series.id)
        XCTAssertEqual(stored.start, october(26, 9, 30), "The stored start stays the Monday first occurrence")
        XCTAssertEqual(stored.end, october(26, 10, 20), "Duration kept")
        XCTAssertEqual(stored.idealArrival, october(26, 8, 45), "45-minute arrival lead kept")
        XCTAssertEqual(stored.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertEqual(stored.title, series.title)
        XCTAssertEqual(stored.source, .user)

        let occurrences = model.visibleWeekOccurrences
        XCTAssertEqual(weekdays(occurrences), [.monday, .wednesday, .friday])
        XCTAssertEqual(occurrences.map(\.start), [october(26, 9, 30), october(28, 9, 30), october(30, 9, 30)])
        XCTAssertEqual(occurrences.map(\.idealArrival), [october(26, 8, 45), october(28, 8, 45), october(30, 8, 45)])
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
    }

    // MARK: 6. Delete

    func testDeletingASeriesRemovesEveryOccurrence() async throws {
        let series = mondayWednesdayFridaySeries()
        let (model, repository) = await loadedModel(with: [series])
        XCTAssertEqual(model.visibleWeekOccurrences.count, 3)

        let began = model.beginEditing(activityID: series.id)
        XCTAssertTrue(began)
        let deleted = await model.deleteDraftActivity()
        XCTAssertTrue(deleted)
        XCTAssertNil(model.editSession)
        XCTAssertNil(model.calendarNotice, "Deleting on purpose is not reported as a removal")
        XCTAssertEqual(model.activities, [])
        XCTAssertEqual(model.visibleWeekOccurrences, [])
        model.showNextWeek()
        XCTAssertEqual(model.visibleWeekOccurrences, [], "Later weeks are empty too")
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [])
    }

    func testFailedDeleteKeepsTheActivityAndTheDraftUntilCancelled() async throws {
        let series = mondayWednesdayFridaySeries()
        let (model, repository) = await loadedModel(with: [series])
        await repository.setFailWrites(true)

        let began = model.beginEditing(activityID: series.id)
        XCTAssertTrue(began)
        let deleted = await model.deleteDraftActivity()
        XCTAssertFalse(deleted)

        let session = try XCTUnwrap(model.editSession)
        if case .failed = session.commitState {
        } else {
            XCTFail("Expected a failed commit state, got \(session.commitState)")
        }
        XCTAssertNotNil(session.failureMessage)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(model.activities, [series])
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [series])

        model.cancelDraft()
        XCTAssertNil(model.editSession)
        XCTAssertEqual(model.visibleWeekOccurrences.count, 3)
    }

    func testDeleteIsRefusedForANewDraft() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        let began = model.beginNewActivity()
        XCTAssertTrue(began)

        let deleted = await model.deleteDraftActivity()
        XCTAssertFalse(deleted, "A draft that was never stored has nothing to delete")
        let session = try XCTUnwrap(model.editSession)
        XCTAssertEqual(session.commitState, .editing)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
    }

    // MARK: 7. Storage failure on save

    func testFailedSaveKeepsTheDraftAndARetryStoresItOnce() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()
        await repository.setFailWrites(true)

        let began = model.beginNewActivity()
        XCTAssertTrue(began)
        model.updateDraft { $0.title = "Study group" }
        let draftID = try XCTUnwrap(model.editSession?.draft.id)

        let firstAttempt = await model.saveDraft()
        XCTAssertFalse(firstAttempt)
        let failed = try XCTUnwrap(model.editSession, "The draft survives a storage failure")
        XCTAssertEqual(failed.draft.id, draftID)
        XCTAssertEqual(failed.draft.title, "Study group")
        XCTAssertTrue(failed.hasAttemptedSave)
        XCTAssertFalse(failed.isBusy)
        let message = try XCTUnwrap(failed.failureMessage)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(model.activities, [])
        let writesAfterFailure = await repository.writeCount
        XCTAssertEqual(writesAfterFailure, 0)

        await repository.setFailWrites(false)
        let retry = await model.saveDraft()
        XCTAssertTrue(retry)
        XCTAssertNil(model.editSession)
        XCTAssertEqual(model.activities.map(\.id), [draftID])
        XCTAssertEqual(model.activitiesStatus, .ready)
        let writesAfterRetry = await repository.writeCount
        XCTAssertEqual(writesAfterRetry, 1)
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored.map(\.id), [draftID])
    }

    // MARK: 8. Coherence across tabs and Settings actions

    func testCalendarDraftSurvivesTabSwitchesAndIsDroppedWhenItsSampleIsCleared() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()
        await model.loadSampleActivities()
        XCTAssertTrue(model.allSamplesLoaded)

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: SampleActivities.morningClassID))
        let monday = try XCTUnwrap(model.visibleWeekOccurrences.first(where: {
            $0.activity.id == SampleActivities.morningClassID && $0.id.date.weekday == .monday
        }))
        model.replaceDraft(draft.movingOccurrence(monday, toStart: october(26, 10)))
        let pending = try XCTUnwrap(model.editSession)
        XCTAssertEqual(pending.draft.start, october(26, 10))

        for tab in [PrototypeTab.map, .settings, .calendar] {
            model.selectedTab = tab
            XCTAssertEqual(model.editSession, pending, "The draft survives switching to \(tab)")
        }
        XCTAssertNil(model.calendarNotice)

        await model.clearSampleActivities()
        XCTAssertNil(model.editSession, "A draft whose activity was removed is dropped, not saved")
        let notice = try XCTUnwrap(model.calendarNotice)
        XCTAssertTrue(notice.contains("was removed"), notice)
        XCTAssertTrue(notice.contains("Sample morning class"), notice)
        XCTAssertEqual(model.activities, [])
        XCTAssertEqual(model.visibleWeekOccurrences, [], "The removed sample is not drawn from the dropped draft")

        model.dismissCalendarNotice()
        XCTAssertNil(model.calendarNotice)
    }

    // MARK: 9. One pending change at a time

    func testOtherChangesAreRefusedWhileADraftIsPending() async throws {
        let first = TestFixtures.activity(title: "Office hours", start: october(30, 9))
        let second = TestFixtures.activity(title: "Tutoring", start: october(30, 14))
        let (model, _) = await loadedModel(with: [first, second])

        let unknownEdit = model.beginEditing(activityID: UUID())
        XCTAssertFalse(unknownEdit)
        XCTAssertNil(model.beginAdjusting(activityID: UUID()))
        XCTAssertNil(model.editSession)

        let adjusting = try XCTUnwrap(model.beginAdjusting(activityID: first.id))
        XCTAssertEqual(adjusting.id, first.id)

        let newActivity = model.beginNewActivity()
        XCTAssertFalse(newActivity)
        let newSpan = model.beginNewActivity(spanning: october(30, 16)..<october(30, 17))
        XCTAssertFalse(newSpan)
        let otherEdit = model.beginEditing(activityID: second.id)
        XCTAssertFalse(otherEdit)
        XCTAssertNil(model.beginAdjusting(activityID: second.id))

        let unchanged = try XCTUnwrap(model.editSession)
        XCTAssertEqual(unchanged.draft.id, first.id)
        XCTAssertEqual(unchanged.mode, .calendar)
        XCTAssertNotNil(model.beginAdjusting(activityID: first.id), "Adjusting the same activity again continues its draft")

        let sameEdit = model.beginEditing(activityID: first.id)
        XCTAssertTrue(sameEdit)
        let editing = try XCTUnwrap(model.editSession)
        XCTAssertEqual(editing.mode, .editor)
        XCTAssertEqual(editing.id, unchanged.id, "The same session moves into the editor")
        XCTAssertEqual(editing.draft, unchanged.draft)
        XCTAssertEqual(model.activities, [first, second])
    }

    func testShowDraftInEditorKeepsCalendarChanges() async throws {
        let stored = TestFixtures.activity(title: "Tutoring", start: october(30, 14))
        let (model, repository) = await loadedModel(with: [stored])

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: stored.id))
        let occurrence = try XCTUnwrap(model.visibleWeekOccurrences.first)
        model.replaceDraft(draft.movingOccurrence(occurrence, toStart: october(30, 14, 30)))
        XCTAssertEqual(model.editSession?.mode, .calendar)

        model.showDraftInEditor()
        let session = try XCTUnwrap(model.editSession)
        XCTAssertEqual(session.mode, .editor)
        XCTAssertEqual(session.draft.start, october(30, 14, 30))
        XCTAssertEqual(session.draft.end, october(30, 15, 20))
        XCTAssertEqual(session.draft.idealArrival, october(30, 13, 45))
        XCTAssertEqual(model.activities, [stored])
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
    }

    // MARK: 10. Drag creation

    func testDragCreationOpensTheEditorWithTheDraggedTimes() throws {
        let model = TestFixtures.makeModel(repository: ScriptedActivityRepository(), initialTab: .calendar)
        let friday = DayTimelineLayout(day: october(30, 0)..<october(31, 0), hourHeight: 60)
        let drag = GridDrag(layout: friday, timeZone: TestFixtures.pacific)
        let interval = try XCTUnwrap(drag.creationInterval(fromOffset: 540, toOffset: 600))
        XCTAssertEqual(interval, october(30, 9)..<october(30, 10))

        let began = model.beginNewActivity(spanning: interval)
        XCTAssertTrue(began)
        let session = try XCTUnwrap(model.editSession)
        XCTAssertEqual(session.mode, .editor)
        XCTAssertTrue(session.draft.isNew)
        XCTAssertEqual(session.draft.start, october(30, 9))
        XCTAssertEqual(session.draft.end, october(30, 10))
        XCTAssertEqual(session.draft.idealArrival, october(30, 8, 30))
        XCTAssertEqual(session.draft.title, "")
        XCTAssertEqual(session.draft.source, .user)
        XCTAssertEqual(session.draft.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(session.draft.destination, TestFixtures.demoDestination)
        XCTAssertNil(session.draft.repeatWeekdays)
        XCTAssertEqual(model.activities, [])
    }

    func testDragCreationRefusesAnEmptyRange() {
        let model = TestFixtures.makeModel(repository: ScriptedActivityRepository(), initialTab: .calendar)
        let nine = october(30, 9)
        let began = model.beginNewActivity(spanning: nine..<nine)
        XCTAssertFalse(began)
        XCTAssertNil(model.editSession)
    }

    // MARK: 11. Recurrence editing

    func testChangingTheRepeatDaysOfASeriesAppliesToEveryWeekWithOneWrite() async throws {
        let series = mondayWednesdayFridaySeries()
        let (model, repository) = await loadedModel(with: [series])

        let began = model.beginEditing(activityID: series.id)
        XCTAssertTrue(began)
        XCTAssertEqual(model.editSession?.draft.editsSeries, true)
        model.updateDraft { $0.setRepeat(.friday, isOn: false) }
        model.updateDraft { $0.setRepeat(.thursday, isOn: true) }
        XCTAssertEqual(weekdays(model.visibleWeekOccurrences), [.monday, .wednesday, .thursday], "The calendar previews the new days before Save")
        XCTAssertEqual(model.activities, [series], "Nothing is stored before Save")

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.activities.count, 1)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(stored.id, series.id, "The series is replaced, not duplicated")
        XCTAssertEqual(stored.repeatWeekdays, [.monday, .wednesday, .thursday])
        XCTAssertEqual([stored.start, stored.end, stored.idealArrival], [series.start, series.end, series.idealArrival], "Only the days changed")

        XCTAssertEqual(schedule(model.visibleWeekOccurrences), [
            [october(26, 9), october(26, 9, 50), october(26, 8, 15)],
            [october(28, 9), october(28, 9, 50), october(28, 8, 15)],
            [october(29, 9), october(29, 9, 50), october(29, 8, 15)]
        ])
        model.showNextWeek()
        XCTAssertEqual(weekdays(model.visibleWeekOccurrences), [.monday, .wednesday, .thursday], "Every later week follows the new days")
        XCTAssertEqual(model.visibleWeekOccurrences.map(\.start), [
            TestFixtures.date(2026, 11, 2, 9, 0),
            TestFixtures.date(2026, 11, 4, 9, 0),
            TestFixtures.date(2026, 11, 5, 9, 0)
        ], "Still 9:00 AM on the wall clock after the clocks fall back")
    }

    func testTurningRepeatOffKeepsOnlyTheFirstOccurrenceOfTheSeries() async throws {
        let series = mondayWednesdayFridaySeries()
        let (model, repository) = await loadedModel(with: [series])

        let began = model.beginEditing(activityID: series.id)
        XCTAssertTrue(began)
        model.updateDraft { $0.setRepeats(false) }
        let draft = try XCTUnwrap(model.editSession?.draft)
        XCTAssertTrue(draft.editsSeries)
        XCTAssertTrue(draft.removesRepeats, "The editor warns that only the first occurrence remains")
        XCTAssertEqual(draft.issues, [])

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(stored.id, series.id)
        XCTAssertNil(stored.repeatWeekdays)
        XCTAssertEqual(schedule(model.visibleWeekOccurrences), [[october(26, 9), october(26, 9, 50), october(26, 8, 15)]], "Only Monday's first occurrence remains")
        model.showNextWeek()
        XCTAssertEqual(model.visibleWeekOccurrences, [], "No later occurrence remains")
    }

    // MARK: 12. Invalid times and repeat days on Save

    func testInvalidTimesAndRepeatDaysStopSaveUntilFixedThenSaveOnce() async throws {
        let stored = TestFixtures.activity(title: "Office hours", start: october(30, 9))
        let (model, repository) = await loadedModel(with: [stored])
        let began = model.beginEditing(activityID: stored.id)
        XCTAssertTrue(began)

        model.updateDraft { draft in
            draft.setEnd(october(30, 8, 30))
            draft.setArrival(october(30, 9, 10))
            draft.setRepeat(.monday, isOn: true)
            draft.setRepeat(.friday, isOn: false)
        }
        let refused = await model.saveDraft()
        XCTAssertFalse(refused)
        let session = try XCTUnwrap(model.editSession, "The editor stays open with every change")
        XCTAssertEqual(session.visibleIssues, [.endNotAfterStart, .arrivalAfterStart, .repeatWeekdaysExcludeStartDay(.friday)])
        XCTAssertEqual(session.visibleIssues(for: .times), [.endNotAfterStart])
        XCTAssertEqual(session.visibleIssues(for: .arrival), [.arrivalAfterStart])
        XCTAssertEqual(session.visibleIssues(for: .recurrence), [.repeatWeekdaysExcludeStartDay(.friday)])
        XCTAssertEqual(session.commitState, .editing)
        XCTAssertEqual(session.draft.repeatWeekdays, [.monday])
        XCTAssertEqual(model.activities, [stored])
        let writesAfterRefusal = await repository.writeCount
        XCTAssertEqual(writesAfterRefusal, 0)

        model.updateDraft { draft in
            draft.setEnd(october(30, 10))
            draft.setArrival(october(30, 8, 30))
            draft.setRepeat(.friday, isOn: true)
        }
        let fixed = try XCTUnwrap(model.editSession)
        XCTAssertEqual(fixed.visibleIssues, [])
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(model.editSession)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.activities.count, 1)
        let updated = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(updated.id, stored.id)
        XCTAssertEqual([updated.start, updated.end, updated.idealArrival], [october(30, 9), october(30, 10), october(30, 8, 30)])
        XCTAssertEqual(updated.repeatWeekdays, [.monday, .friday])
        XCTAssertEqual(weekdays(model.visibleWeekOccurrences), [.friday], "The stored start is the first occurrence, so no Monday comes before it")
        model.showNextWeek()
        XCTAssertEqual(weekdays(model.visibleWeekOccurrences), [.monday, .friday])
    }

    // MARK: 13. Midnight

    func testOvernightActivityFromTheEditorIsSavedOnceAndDrawnOnBothDays() async throws {
        let repository = ScriptedActivityRepository()
        let model = TestFixtures.makeModel(repository: repository, initialTab: .calendar)
        await model.loadActivities()
        let friday = october(30, 0)..<october(31, 0)
        let saturday = october(31, 0)..<TestFixtures.date(2026, 11, 1, 0, 0)

        let began = model.beginNewActivity()
        XCTAssertTrue(began)
        model.updateDraft { $0.title = "Night lab" }
        model.updateDraft { $0.setStart(october(30, 23)) }
        let moved = try XCTUnwrap(model.editSession?.draft)
        XCTAssertEqual(moved.end, october(31, 0), "Starts keeps the one-hour length, so the end lands on midnight")
        XCTAssertEqual(moved.idealArrival, october(30, 22, 30), "Starts keeps the 30-minute arrival lead")
        XCTAssertFalse(moved.endsOnLaterDay, "Ending exactly at midnight still counts as Friday")

        model.updateDraft { $0.setEnd(october(31, 1, 30)) }
        let draft = try XCTUnwrap(model.editSession?.draft)
        XCTAssertTrue(draft.endsOnLaterDay)
        XCTAssertEqual(draft.duration, 150 * 60)
        XCTAssertEqual(draft.issues, [])
        XCTAssertEqual(model.occurrences(on: saturday).map(\.activity.id), [draft.id], "The calendar previews the part after midnight before Save")

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual([stored.start, stored.end, stored.idealArrival], [october(30, 23), october(31, 1, 30), october(30, 22, 30)])

        let fridaySchedule = DaySchedule.make(day: friday, occurrences: model.occurrences(on: friday), layout: DayTimelineLayout(day: friday, hourHeight: 60))
        let fridayBlock = try XCTUnwrap(fridaySchedule.blocks.first)
        XCTAssertEqual(fridayBlock.frame.minY, 1_380, accuracy: 0.001)
        XCTAssertEqual(fridayBlock.frame.height, 60, accuracy: 0.001)
        XCTAssertTrue(fridayBlock.frame.isClippedAtEnd, "Friday's part runs to the bottom of the day")
        let saturdaySchedule = DaySchedule.make(day: saturday, occurrences: model.occurrences(on: saturday), layout: DayTimelineLayout(day: saturday, hourHeight: 60))
        let saturdayBlock = try XCTUnwrap(saturdaySchedule.blocks.first)
        XCTAssertEqual(saturdayBlock.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(saturdayBlock.frame.height, 90, accuracy: 0.001)
        XCTAssertTrue(saturdayBlock.frame.isClippedAtStart, "Saturday's part continues from Friday")
        XCTAssertEqual(saturdayBlock.occurrence.id, fridayBlock.occurrence.id, "One occurrence drawn on two days")
    }

    func testMovingABlockPastMidnightKeepsTheArrivalLeadAndPreviewsBothDays() async throws {
        let lateLab = TestFixtures.activity(title: "Late lab", start: october(30, 22), end: october(30, 23), arrival: october(30, 21, 30))
        let (model, repository) = await loadedModel(with: [lateLab])
        let friday = october(30, 0)..<october(31, 0)
        let saturday = october(31, 0)..<TestFixtures.date(2026, 11, 1, 0, 0)
        XCTAssertEqual(model.occurrences(on: saturday), [])

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: lateLab.id))
        let occurrence = try XCTUnwrap(model.occurrences(on: friday).first)
        let drag = GridDrag(layout: DayTimelineLayout(day: friday, hourHeight: 60), timeZone: TestFixtures.pacific)
        model.replaceDraft(drag.draft(draft, dragging: occurrence, kind: .move, translation: 90))

        let pending = try XCTUnwrap(model.editSession?.draft)
        XCTAssertEqual(pending.start, october(30, 23, 30), "90 points at 60 points per hour is an hour and a half later")
        XCTAssertEqual(pending.end, october(31, 0, 30), "The end crosses midnight")
        XCTAssertEqual(pending.idealArrival, october(30, 23), "The 30-minute arrival lead is kept")
        XCTAssertTrue(pending.endsOnLaterDay)
        XCTAssertEqual(model.occurrences(on: saturday).map(\.activity.id), [lateLab.id], "The preview already continues on Saturday")
        XCTAssertEqual(model.activities, [lateLab], "Nothing is stored before Save")

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 1)
        let stored = try XCTUnwrap(model.activities.first)
        XCTAssertEqual([stored.start, stored.end, stored.idealArrival], [october(30, 23, 30), october(31, 0, 30), october(30, 23)])
        XCTAssertEqual(stored.arrivalLead, 30 * 60)
        XCTAssertEqual(model.occurrences(on: saturday).map(\.end), [october(31, 0, 30)])
    }

    func testMovingAnEarlyBlockUpPutsTheArrivalOnThePreviousDayWithTheSameLead() async throws {
        let earlyShift = TestFixtures.activity(title: "Early shift", start: october(31, 0, 30), end: october(31, 1, 30), arrival: october(31, 0))
        let (model, _) = await loadedModel(with: [earlyShift])
        let friday = october(30, 0)..<october(31, 0)
        let saturday = october(31, 0)..<TestFixtures.date(2026, 11, 1, 0, 0)
        XCTAssertEqual(model.occurrences(on: friday), [], "An arrival exactly at midnight belongs to Saturday")

        let draft = try XCTUnwrap(model.beginAdjusting(activityID: earlyShift.id))
        let occurrence = try XCTUnwrap(model.occurrences(on: saturday).first)
        let drag = GridDrag(layout: DayTimelineLayout(day: saturday, hourHeight: 60), timeZone: TestFixtures.pacific)
        model.replaceDraft(drag.draft(draft, dragging: occurrence, kind: .move, translation: -30))

        let pending = try XCTUnwrap(model.editSession?.draft)
        XCTAssertEqual(pending.start, october(31, 0))
        XCTAssertEqual(pending.end, october(31, 1))
        XCTAssertEqual(pending.idealArrival, october(30, 23, 30), "The 30-minute lead now reaches into Friday")
        XCTAssertTrue(pending.arrivalOnEarlierDay)

        let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
        let arrivalText = formatter.draftArrivalText(pending)
        XCTAssertTrue(arrivalText.contains("Fri"), "The unsaved-change bar names the arrival's day: \(arrivalText)")
        XCTAssertEqual(formatter.arrivalDayNote(arrival: pending.idealArrival, start: pending.start), "Arrival is on Friday, October 30, the day before the activity")

        let fridaySchedule = DaySchedule.make(day: friday, occurrences: model.occurrences(on: friday), layout: DayTimelineLayout(day: friday, hourHeight: 60))
        XCTAssertEqual(fridaySchedule.blocks, [], "The block itself stays on Saturday")
        XCTAssertEqual(fridaySchedule.arrivalOnlyMarkers.map(\.occurrence.activity.id), [earlyShift.id], "Friday shows the arrival marker alone")
    }
}
