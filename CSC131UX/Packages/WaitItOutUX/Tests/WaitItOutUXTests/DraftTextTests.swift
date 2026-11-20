import XCTest
@testable import WaitItOutUX

/// Editor and unsaved-change bar text. Strings that contain clock times are checked with
/// `contains` because the formatter may separate the time and the AM/PM marker with a
/// narrow no-break space.
final class DraftTextTests: XCTestCase {
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)

    private func onFriday(_ hour: Int, _ minute: Int) -> Date {
        TestFixtures.date(2026, 10, 30, hour, minute)
    }

    private func onSaturday(_ hour: Int, _ minute: Int) -> Date {
        TestFixtures.date(2026, 10, 31, hour, minute)
    }

    private func seriesDraft(_ weekdays: Set<Weekday>) -> ActivityDraft {
        ActivityDraft(editing: TestFixtures.activity(start: TestFixtures.mondayNine, repeatWeekdays: weekdays))
    }

    // MARK: End day note

    func testEndDayNoteIsNilOnTheSameDay() {
        XCTAssertNil(formatter.endDayNote(start: onFriday(9, 0), end: onFriday(9, 50)))
    }

    func testEndDayNoteIsNilWhenEndingExactlyAtMidnight() {
        XCTAssertNil(formatter.endDayNote(start: onFriday(23, 0), end: onSaturday(0, 0)))
    }

    func testEndDayNoteIsNilWhenTheEndIsNotAfterTheStart() {
        XCTAssertNil(formatter.endDayNote(start: onFriday(9, 0), end: onFriday(8, 0)))
    }

    func testEndDayNoteNamesTheNextDay() {
        XCTAssertEqual(
            formatter.endDayNote(start: onFriday(23, 0), end: onSaturday(1, 0)),
            "Ends the next day, Saturday, October 31"
        )
    }

    // MARK: Arrival day note

    func testArrivalDayNoteIsNilOnTheSameDay() {
        XCTAssertNil(formatter.arrivalDayNote(arrival: onFriday(8, 15), start: onFriday(9, 0)))
    }

    func testArrivalDayNoteNamesThePreviousDay() {
        XCTAssertEqual(
            formatter.arrivalDayNote(arrival: onFriday(23, 45), start: onSaturday(0, 30)),
            "Arrival is on Friday, October 30, the day before the activity"
        )
    }

    // MARK: Lead text

    func testLeadText() {
        XCTAssertEqual(formatter.leadText(arrival: onFriday(8, 15), start: onFriday(9, 0)), "45 minutes before start")
        XCTAssertEqual(formatter.leadText(arrival: onFriday(7, 30), start: onFriday(9, 0)), "1 hour 30 minutes before start")
        XCTAssertEqual(formatter.leadText(arrival: onFriday(9, 0), start: onFriday(9, 0)), "At the start time")
        XCTAssertEqual(formatter.leadText(arrival: onFriday(9, 10), start: onFriday(9, 0)), "After the start time")
    }

    // MARK: Schedule and summary

    func testDraftScheduleTextForASeries() {
        XCTAssertEqual(formatter.draftScheduleText(seriesDraft([.monday, .wednesday, .friday])), "Every Mon, Wed, Fri")
    }

    func testDraftScheduleTextForEveryDay() {
        XCTAssertEqual(formatter.draftScheduleText(seriesDraft(Set(Weekday.allCases))), "Every day")
    }

    func testDraftScheduleTextForAOneTimeActivityIsItsDate() {
        let draft = ActivityDraft(editing: TestFixtures.activity(start: onFriday(9, 0)))
        let text = formatter.draftScheduleText(draft)

        XCTAssertTrue(text.contains("October 30"), text)
        XCTAssertFalse(text.hasPrefix("Every"), text)
    }

    func testDraftSummaryForASeries() {
        let summary = formatter.draftSummary(seriesDraft([.monday, .wednesday, .friday]))

        XCTAssertTrue(summary.contains("9:00"), summary)
        XCTAssertTrue(summary.contains("9:50"), summary)
        XCTAssertTrue(summary.contains("Every Mon, Wed, Fri"), summary)
        XCTAssertTrue(summary.contains("arrive by"), summary)
        XCTAssertTrue(summary.contains("8:15"), summary)
    }

    func testDraftTimeRangeAndArrivalTextAfterAMove() {
        var draft = ActivityDraft(editing: TestFixtures.activity(start: onFriday(9, 0)))
        draft.setStart(onFriday(9, 30))

        let range = formatter.draftTimeRange(draft)
        XCTAssertTrue(range.contains("9:30"), range)
        XCTAssertTrue(range.contains("10:20"), range)

        let arrival = formatter.draftArrivalText(draft)
        XCTAssertTrue(arrival.hasPrefix("Arrive by "), arrival)
        XCTAssertTrue(arrival.contains("8:45"), arrival)
    }

    func testDraftArrivalTextNamesTheWeekdayOfAnEarlierDayArrival() {
        var draft = ActivityDraft(
            title: "Early shift",
            start: onSaturday(0, 30),
            end: onSaturday(1, 20),
            destination: TestFixtures.demoDestination,
            timeZone: TestFixtures.pacific
        )
        draft.setArrival(onFriday(23, 45))

        let arrival = formatter.draftArrivalText(draft)
        XCTAssertTrue(arrival.hasPrefix("Arrive by "), arrival)
        XCTAssertTrue(arrival.contains("Fri"), arrival)
        XCTAssertTrue(arrival.contains("11:45"), arrival)
    }
}
