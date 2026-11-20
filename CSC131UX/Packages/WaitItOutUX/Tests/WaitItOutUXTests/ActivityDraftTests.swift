import XCTest
@testable import WaitItOutUX

final class ActivityDraftTests: XCTestCase {
    private let zone = TestFixtures.pacific
    private let destination = TestFixtures.demoDestination
    /// Fri 2026-10-30, an ordinary 24-hour Pacific day.
    private let fridayRange = TestFixtures.date(2026, 10, 30)..<TestFixtures.date(2026, 10, 31)
    /// Sun 2026-11-01 through Sat 2026-11-07; the clocks fall back on its first day.
    private let followingWeek = TestFixtures.date(2026, 11, 1)..<TestFixtures.date(2026, 11, 8)

    // MARK: Helpers

    private func onFriday(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        TestFixtures.date(2026, 10, 30, hour, minute, second)
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int) throws -> LocalDate {
        try XCTUnwrap(LocalDate(year: year, month: month, day: day))
    }

    /// Fri 2026-10-30 09:00 to 09:50 Pacific, ideal arrival 08:15.
    private func fridayLecture(source: ActivitySource = .user) -> Activity {
        TestFixtures.activity(start: onFriday(9, 0), source: source)
    }

    /// Mon, Wed, Fri at 09:00 Pacific, first occurrence Mon 2026-10-26.
    private func mondayWednesdayFridaySeries() -> Activity {
        TestFixtures.activity(start: TestFixtures.mondayNine, repeatWeekdays: [.monday, .wednesday, .friday])
    }

    private func expandedOccurrence(of activity: Activity, startingOn date: LocalDate, in range: Range<Date>) throws -> ActivityOccurrence {
        let found = OccurrenceExpander.occurrences(of: activity, in: range).first { $0.id.date == date }
        return try XCTUnwrap(found, "Expected an occurrence on \(date)")
    }

    private func fridayOccurrence(of activity: Activity) throws -> ActivityOccurrence {
        try expandedOccurrence(of: activity, startingOn: localDate(2026, 10, 30), in: fridayRange)
    }

    // MARK: New activity defaults

    func testNewActivityOnAnotherDayStartsAtNineForOneHour() throws {
        let monday = try localDate(2026, 10, 26)
        let draft = ActivityDraft.newActivity(on: monday, now: TestFixtures.fridayNoon, timeZone: zone, destination: destination)

        XCTAssertEqual(draft.start, TestFixtures.date(2026, 10, 26, 9, 0))
        XCTAssertEqual(draft.start, TestFixtures.mondayNine)
        XCTAssertEqual(draft.end, TestFixtures.date(2026, 10, 26, 10, 0))
        XCTAssertEqual(draft.idealArrival, TestFixtures.date(2026, 10, 26, 8, 30))
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.source, .user)
        XCTAssertNil(draft.original)
        XCTAssertNil(draft.repeatWeekdays)
        XCTAssertEqual(draft.timeZoneIdentifier, zone.identifier)
        XCTAssertTrue(draft.isNew)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertTrue(draft.changesSchedule)
        XCTAssertFalse(draft.editsSeries)
        XCTAssertEqual(draft.issues, [.emptyTitle])
    }

    func testNewActivityTodayStartsAtTheNextWholeHour() throws {
        let friday = try localDate(2026, 10, 30)
        let draft = ActivityDraft.newActivity(on: friday, now: TestFixtures.fridayNoon, timeZone: zone, destination: destination)

        XCTAssertEqual(draft.start, onFriday(13, 0))
        XCTAssertEqual(draft.end, onFriday(14, 0))
        XCTAssertEqual(draft.idealArrival, onFriday(12, 30))
    }

    func testNewActivityLateAtNightStartsAtElevenTheSameDay() throws {
        let friday = try localDate(2026, 10, 30)
        let draft = ActivityDraft.newActivity(on: friday, now: onFriday(23, 30), timeZone: zone, destination: destination)

        XCTAssertEqual(draft.start, onFriday(23, 0))
        XCTAssertEqual(draft.end, TestFixtures.date(2026, 10, 31, 0, 0))
        XCTAssertEqual(draft.idealArrival, onFriday(22, 30))
        XCTAssertEqual(draft.startDate, friday)
        XCTAssertFalse(draft.endsOnLaterDay, "Ending exactly at midnight counts as the start day")
    }

    // MARK: Editing a stored activity

    func testEditingDraftRoundTripsTheStoredActivity() {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)

        XCTAssertEqual(draft.activity, stored)
        XCTAssertEqual(draft.original, stored)
        XCTAssertEqual(draft.id, stored.id)
        XCTAssertFalse(draft.isNew)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.changesSchedule)
        XCTAssertTrue(draft.isValid)
    }

    func testTitleChangeIsAChangeButNotAScheduleChange() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.title = "Renamed lecture"

        XCTAssertTrue(draft.hasChanges)
        XCTAssertFalse(draft.changesSchedule)
        XCTAssertEqual(draft.activity.title, "Renamed lecture")
    }

    func testSampleSourceIsKept() {
        var draft = ActivityDraft(editing: fridayLecture(source: .sample))
        draft.setStart(onFriday(10, 0))

        XCTAssertEqual(draft.source, .sample)
        XCTAssertEqual(draft.activity.source, .sample)
    }

    // MARK: Editor controls

    func testSetStartKeepsDurationAndArrivalLead() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setStart(onFriday(11, 0))

        XCTAssertEqual(draft.start, onFriday(11, 0))
        XCTAssertEqual(draft.end, onFriday(11, 50))
        XCTAssertEqual(draft.idealArrival, onFriday(10, 15))
        XCTAssertEqual(draft.duration, 50 * 60)
        XCTAssertEqual(draft.arrivalLead, 45 * 60)
        XCTAssertTrue(draft.changesSchedule)
    }

    func testSetStartFloorsToWholeMinutes() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setStart(onFriday(11, 0, 30))

        XCTAssertEqual(draft.start, onFriday(11, 0))
        XCTAssertEqual(draft.end, onFriday(11, 50))
        XCTAssertEqual(draft.idealArrival, onFriday(10, 15))

        draft.setStart(onFriday(12, 0, 59))
        XCTAssertEqual(draft.start, onFriday(12, 0))
    }

    func testNonFiniteInstantsAreIgnored() {
        let original = ActivityDraft(editing: fridayLecture())
        var draft = original
        draft.setStart(Date(timeIntervalSinceReferenceDate: .nan))
        draft.setStart(Date(timeIntervalSinceReferenceDate: .infinity))
        draft.setEnd(Date(timeIntervalSinceReferenceDate: .nan))
        draft.setArrival(Date(timeIntervalSinceReferenceDate: -.infinity))

        XCTAssertEqual(draft, original)
    }

    func testSetEndChangesOnlyTheEnd() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setEnd(onFriday(10, 30))

        XCTAssertEqual(draft.start, onFriday(9, 0))
        XCTAssertEqual(draft.end, onFriday(10, 30))
        XCTAssertEqual(draft.idealArrival, onFriday(8, 15))
        XCTAssertTrue(draft.isValid)
    }

    func testSetArrivalChangesOnlyTheArrival() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setArrival(onFriday(8, 40))

        XCTAssertEqual(draft.start, onFriday(9, 0))
        XCTAssertEqual(draft.end, onFriday(9, 50))
        XCTAssertEqual(draft.idealArrival, onFriday(8, 40))
        XCTAssertEqual(draft.arrivalLead, 20 * 60)
        XCTAssertTrue(draft.isValid)
    }

    func testEndNotAfterStartIsReported() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setEnd(onFriday(8, 30))
        XCTAssertTrue(draft.issues.contains(.endNotAfterStart), "\(draft.issues)")

        draft.setEnd(onFriday(9, 0))
        XCTAssertTrue(draft.issues.contains(.endNotAfterStart), "\(draft.issues)")
        XCTAssertFalse(draft.isValid)
    }

    func testArrivalAfterStartIsReported() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setArrival(onFriday(9, 10))

        XCTAssertTrue(draft.issues.contains(.arrivalAfterStart), "\(draft.issues)")
        XCTAssertFalse(draft.isValid)
    }

    func testArrivalMoreThanADayBeforeStartIsReported() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setArrival(onFriday(9, 0).addingTimeInterval(-25 * 3_600))

        XCTAssertTrue(draft.issues.contains(.arrivalTooEarly), "\(draft.issues)")
        XCTAssertFalse(draft.isValid)
    }

    func testDurationOverADayIsReported() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setEnd(onFriday(9, 0).addingTimeInterval(25 * 3_600))

        XCTAssertTrue(draft.issues.contains(.durationTooLong), "\(draft.issues)")
        XCTAssertFalse(draft.isValid)
    }

    // MARK: Midnight

    func testOvernightActivityIsValidAndEndsOnALaterDay() {
        let draft = ActivityDraft(
            title: "Night lab",
            start: onFriday(23, 0),
            end: TestFixtures.date(2026, 10, 31, 1, 0),
            destination: destination,
            timeZone: zone
        )

        XCTAssertEqual(draft.issues, [])
        XCTAssertTrue(draft.isValid)
        XCTAssertTrue(draft.endsOnLaterDay)
        XCTAssertFalse(draft.arrivalOnEarlierDay)
        XCTAssertEqual(draft.duration, 2 * 3_600)
    }

    func testEndingExactlyAtMidnightStaysOnTheStartDay() {
        let draft = ActivityDraft(
            title: "Late lab",
            start: onFriday(23, 0),
            end: TestFixtures.date(2026, 10, 31, 0, 0),
            destination: destination,
            timeZone: zone
        )

        XCTAssertTrue(draft.isValid)
        XCTAssertFalse(draft.endsOnLaterDay)
    }

    func testArrivalOnThePreviousDayIsValid() {
        var draft = ActivityDraft(
            title: "Early shift",
            start: TestFixtures.date(2026, 10, 31, 0, 30),
            end: TestFixtures.date(2026, 10, 31, 1, 20),
            destination: destination,
            timeZone: zone
        )
        draft.setArrival(onFriday(23, 45))

        XCTAssertEqual(draft.idealArrival, onFriday(23, 45))
        XCTAssertEqual(draft.issues, [])
        XCTAssertTrue(draft.arrivalOnEarlierDay)
        XCTAssertEqual(draft.arrivalLead, 45 * 60)
        XCTAssertFalse(draft.endsOnLaterDay)
    }

    // MARK: Repeats

    func testTurningRepeatOnStartsWithTheStartWeekday() {
        var draft = ActivityDraft(editing: fridayLecture())
        XCTAssertEqual(draft.startWeekday, .friday)

        draft.setRepeats(true)
        XCTAssertEqual(draft.repeatWeekdays, [.friday])
        XCTAssertTrue(draft.isRecurring)
        XCTAssertTrue(draft.isValid)

        draft.setRepeat(.wednesday, isOn: true)
        XCTAssertEqual(draft.repeatWeekdays, [.wednesday, .friday])
        XCTAssertTrue(draft.isValid)
    }

    func testRemovingRepeatDaysIsReported() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setRepeats(true)
        draft.setRepeat(.wednesday, isOn: true)

        draft.setRepeat(.friday, isOn: false)
        XCTAssertEqual(draft.repeatWeekdays, [.wednesday])
        XCTAssertTrue(draft.issues.contains(.repeatWeekdaysExcludeStartDay(.friday)), "\(draft.issues)")

        draft.setRepeat(.wednesday, isOn: false)
        XCTAssertEqual(draft.repeatWeekdays, [])
        XCTAssertTrue(draft.issues.contains(.noRepeatWeekdays), "\(draft.issues)")
        XCTAssertFalse(draft.issues.contains(.repeatWeekdaysExcludeStartDay(.friday)), "\(draft.issues)")

        draft.setRepeats(false)
        XCTAssertNil(draft.repeatWeekdays)
        XCTAssertFalse(draft.isRecurring)
        XCTAssertTrue(draft.isValid)
    }

    func testAddingARepeatDayToAOneTimeDraftKeepsTheStartWeekday() {
        var draft = ActivityDraft(editing: fridayLecture())
        draft.setRepeat(.monday, isOn: true)

        XCTAssertEqual(draft.repeatWeekdays, [.monday, .friday])
        XCTAssertTrue(draft.isValid)
    }

    func testTurningRepeatOffOnAStoredSeriesRemovesRepeats() {
        var draft = ActivityDraft(editing: mondayWednesdayFridaySeries())
        XCTAssertTrue(draft.editsSeries)
        XCTAssertFalse(draft.removesRepeats)

        draft.setRepeats(true)
        XCTAssertEqual(draft.repeatWeekdays, [.monday, .wednesday, .friday], "Turning repeat on again keeps the chosen days")

        draft.setRepeats(false)
        XCTAssertNil(draft.repeatWeekdays)
        XCTAssertTrue(draft.editsSeries)
        XCTAssertTrue(draft.removesRepeats)
        XCTAssertTrue(draft.changesSchedule)

        var oneTime = ActivityDraft(editing: fridayLecture())
        oneTime.setRepeats(false)
        XCTAssertFalse(oneTime.editsSeries)
        XCTAssertFalse(oneTime.removesRepeats)
    }

    func testMovingASeriesStartToAnUnselectedWeekdayIsReported() {
        var draft = ActivityDraft(editing: mondayWednesdayFridaySeries())
        draft.setStart(TestFixtures.date(2026, 10, 27, 9, 0))

        XCTAssertEqual(draft.startWeekday, .tuesday)
        XCTAssertEqual(draft.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertTrue(draft.issues.contains(.repeatWeekdaysExcludeStartDay(.tuesday)), "\(draft.issues)")
        XCTAssertFalse(draft.isValid)
    }

    // MARK: Calendar gestures

    func testMovingAOneTimeOccurrenceKeepsDurationAndLead() throws {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)
        let occurrence = try fridayOccurrence(of: stored)

        let moved = draft.movingOccurrence(occurrence, toStart: onFriday(11, 0))

        XCTAssertEqual(moved.start, onFriday(11, 0))
        XCTAssertEqual(moved.end, onFriday(11, 50))
        XCTAssertEqual(moved.idealArrival, onFriday(10, 15))
        XCTAssertEqual(moved.id, stored.id)
        XCTAssertTrue(moved.changesSchedule)
        XCTAssertEqual(draft.start, onFriday(9, 0), "The source draft is a value and stays unchanged")
    }

    func testMovingALaterSeriesOccurrenceRetimesTheFirstOccurrenceOnTheWallClock() throws {
        let series = mondayWednesdayFridaySeries()
        let draft = ActivityDraft(editing: series)
        let wednesday = try localDate(2026, 11, 4)
        let occurrence = try expandedOccurrence(of: series, startingOn: wednesday, in: followingWeek)
        // Wed 2026-11-04 09:00 PST is 17:00 UTC.
        XCTAssertEqual(occurrence.start, Date(timeIntervalSince1970: 1_793_811_600))
        XCTAssertEqual(occurrence.start, TestFixtures.date(2026, 11, 4, 9, 0))

        let moved = draft.movingOccurrence(occurrence, toStart: TestFixtures.date(2026, 11, 4, 9, 30))

        // Mon 2026-10-26 09:30 PDT is 16:30 UTC: the same wall-clock time, not the same UTC time.
        XCTAssertEqual(moved.start, Date(timeIntervalSince1970: 1_793_032_200))
        XCTAssertEqual(moved.start, TestFixtures.date(2026, 10, 26, 9, 30))
        XCTAssertEqual(moved.end, TestFixtures.date(2026, 10, 26, 10, 20))
        XCTAssertEqual(moved.idealArrival, TestFixtures.date(2026, 10, 26, 8, 45))
        XCTAssertEqual(moved.duration, 50 * 60)
        XCTAssertEqual(moved.arrivalLead, 45 * 60)
        XCTAssertEqual(moved.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertTrue(moved.isValid)

        let reexpanded = try expandedOccurrence(of: moved.activity, startingOn: wednesday, in: followingWeek)
        // Wed 2026-11-04 09:30 PST is 17:30 UTC.
        XCTAssertEqual(reexpanded.start, Date(timeIntervalSince1970: 1_793_813_400))
        XCTAssertEqual(reexpanded.start, TestFixtures.date(2026, 11, 4, 9, 30))
        XCTAssertEqual(reexpanded.end, TestFixtures.date(2026, 11, 4, 10, 20))
        XCTAssertEqual(reexpanded.idealArrival, TestFixtures.date(2026, 11, 4, 8, 45))
    }

    func testResizingAnOccurrenceStartKeepsTheEnd() throws {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)
        let occurrence = try fridayOccurrence(of: stored)

        let resized = draft.resizingOccurrence(occurrence, toStart: onFriday(8, 30))

        XCTAssertEqual(resized.start, onFriday(8, 30))
        XCTAssertEqual(resized.end, onFriday(9, 50))
        XCTAssertEqual(resized.idealArrival, onFriday(7, 45), "The arrival keeps its lead")
    }

    func testResizingAnOccurrenceEndKeepsStartAndArrival() throws {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)
        let occurrence = try fridayOccurrence(of: stored)

        let resized = draft.resizingOccurrence(occurrence, toEnd: onFriday(10, 30))

        XCTAssertEqual(resized.start, onFriday(9, 0))
        XCTAssertEqual(resized.end, onFriday(10, 30))
        XCTAssertEqual(resized.idealArrival, onFriday(8, 15))
    }

    func testGestureThatChangesTheOccurrenceDayIsIgnored() throws {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)
        let occurrence = try fridayOccurrence(of: stored)

        XCTAssertEqual(draft.movingOccurrence(occurrence, toStart: TestFixtures.date(2026, 10, 31, 9, 0)), draft)
        XCTAssertEqual(draft.resizingOccurrence(occurrence, toStart: TestFixtures.date(2026, 10, 29, 23, 0)), draft)
    }

    func testOccurrenceOfAnotherActivityIsIgnored() throws {
        let draft = ActivityDraft(editing: fridayLecture())
        let other = fridayLecture()
        XCTAssertNotEqual(other.id, draft.id)
        let otherOccurrence = try fridayOccurrence(of: other)

        XCTAssertEqual(draft.movingOccurrence(otherOccurrence, toStart: onFriday(11, 0)), draft)
        XCTAssertEqual(draft.resizingOccurrence(otherOccurrence, toEnd: onFriday(10, 30)), draft)
    }

    func testNonPositiveDurationsAreIgnored() throws {
        let stored = fridayLecture()
        let draft = ActivityDraft(editing: stored)
        let occurrence = try fridayOccurrence(of: stored)

        XCTAssertEqual(draft.resizingOccurrence(occurrence, toEnd: occurrence.start), draft)
        XCTAssertEqual(draft.resizingOccurrence(occurrence, toEnd: onFriday(8, 0)), draft)
        XCTAssertEqual(draft.resizingOccurrence(occurrence, toStart: occurrence.end), draft)
        XCTAssertEqual(draft.resizingOccurrence(occurrence, toStart: onFriday(10, 0)), draft)
    }
}
