import XCTest
@testable import WaitItOutUX

final class OccurrenceFormatterTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var formatter = OccurrenceFormatter(calculator: calculator, locale: TestFixtures.enUS)
    private lazy var week = calculator.week(containing: TestFixtures.fridayNoon)

    private func firstOccurrence(of activity: Activity, in range: Range<Date>) throws -> ActivityOccurrence {
        try XCTUnwrap(OccurrenceExpander.occurrences(of: [activity], in: range).first)
    }

    func testSameDayTimeRangeArrivalAndSpokenForm() throws {
        let activity = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_030_400),
            end: Date(timeIntervalSince1970: 1_793_033_400),
            arrival: Date(timeIntervalSince1970: 1_793_027_700),
            repeatWeekdays: [.monday, .wednesday, .friday],
            source: .sample
        )
        let monday = week.dayRanges[1]
        let occurrence = try firstOccurrence(of: activity, in: monday)
        let range = formatter.timeRange(for: occurrence, on: monday)
        XCTAssertTrue(range.contains("9:00"), range)
        XCTAssertTrue(range.contains("9:50"), range)
        XCTAssertTrue(range.contains("AM"), range)
        XCTAssertFalse(range.contains("Mon"), range)
        let arrival = formatter.arrivalText(for: occurrence, on: monday)
        XCTAssertTrue(arrival.hasPrefix("Arrive by"), arrival)
        XCTAssertTrue(arrival.contains("8:15"), arrival)
        XCTAssertFalse(arrival.contains("for the"), arrival)
        XCTAssertEqual(formatter.recurrenceText(for: activity), "Repeats Mon, Wed, Fri")
        XCTAssertNil(formatter.timeZoneNote(for: activity))
        let spoken = formatter.accessibilityLabel(for: occurrence, on: monday)
        XCTAssertTrue(spoken.hasPrefix("Lecture, sample data, "), spoken)
        XCTAssertTrue(spoken.contains("9:00"), spoken)
        XCTAssertTrue(spoken.contains(" to "), spoken)
        XCTAssertTrue(spoken.contains("9:50"), spoken)
        XCTAssertTrue(spoken.contains("arrive by"), spoken)
        XCTAssertTrue(spoken.hasSuffix("repeats Monday, Wednesday, Friday"), spoken)
    }

    func testOvernightOccurrenceShowsWeekdaysOnBothDays() throws {
        let overnight = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_512_800),           // Sat 23:00 PDT
            end: Date(timeIntervalSince1970: 1_793_520_000),             // Sun 01:00 PDT
            arrival: Date(timeIntervalSince1970: 1_793_512_800 - 2_700)  // Sat 22:15 PDT
        )
        let saturday = week.dayRanges[6]
        let occurrence = try firstOccurrence(of: overnight, in: saturday)
        let onSaturday = formatter.timeRange(for: occurrence, on: saturday)
        XCTAssertTrue(onSaturday.contains("Sat"), onSaturday)
        XCTAssertTrue(onSaturday.contains("Sun"), onSaturday)
        XCTAssertTrue(onSaturday.contains("11:00"), onSaturday)
        XCTAssertTrue(onSaturday.contains("1:00"), onSaturday)
        let sunday = calculator.nextWeek(after: week).dayRanges[0]
        XCTAssertEqual(formatter.timeRange(for: occurrence, on: sunday), onSaturday)
        XCTAssertFalse(formatter.arrivalText(for: occurrence, on: saturday).contains("Sat"))
        let arrivalOnSunday = formatter.arrivalText(for: occurrence, on: sunday)
        XCTAssertTrue(arrivalOnSunday.contains("Sat"), arrivalOnSunday)
        XCTAssertTrue(arrivalOnSunday.contains("10:15"), arrivalOnSunday)
        XCTAssertNil(formatter.recurrenceText(for: overnight))
        let spoken = formatter.accessibilityLabel(for: occurrence, on: sunday)
        XCTAssertFalse(spoken.contains("sample data"), spoken)
        XCTAssertTrue(spoken.contains("Sat"), spoken)
    }

    func testArrivalOnlyDayExplainsTheLaterStart() throws {
        let earlySunday = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_518_200),   // Sun 00:30 PDT
            end: Date(timeIntervalSince1970: 1_793_520_900),     // Sun 01:15 PDT
            arrival: Date(timeIntervalSince1970: 1_793_515_500)  // Sat 23:45 PDT
        )
        let saturday = week.dayRanges[6]
        let occurrence = try firstOccurrence(of: earlySunday, in: saturday)
        let arrival = formatter.arrivalText(for: occurrence, on: saturday)
        XCTAssertTrue(arrival.contains("11:45"), arrival)
        XCTAssertTrue(arrival.contains("for the"), arrival)
        XCTAssertTrue(arrival.contains("Sun"), arrival)
        XCTAssertTrue(arrival.contains("12:30"), arrival)
    }

    func testTimeZoneNoteAppearsOnlyForForeignZones() {
        let utcActivity = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_005_200), timeZone: TestFixtures.utc)
        let note = formatter.timeZoneNote(for: utcActivity)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.hasPrefix("Scheduled in") == true, note ?? "")
        XCTAssertTrue(note?.contains("shown in") == true, note ?? "")
        XCTAssertNil(formatter.timeZoneNote(for: TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_005_200))))
    }

    func testWeekdaySummariesAndOrdering() {
        let calendar = calculator.calendar
        XCTAssertEqual(Weekday.summary(of: [.friday, .monday, .wednesday], in: calendar), "Mon, Wed, Fri")
        XCTAssertEqual(Weekday.summary(of: Set(Weekday.allCases), in: calendar), "every day")
        XCTAssertEqual(Weekday.spokenSummary(of: [.tuesday, .thursday], in: calendar), "Tuesday, Thursday")
        XCTAssertEqual(Weekday.ordered([.saturday, .sunday]), [.sunday, .saturday])
        XCTAssertEqual(Weekday.monday.sundayFirstIndex, 1)
        XCTAssertEqual(Weekday.saturday.rawValue, 7)
        XCTAssertTrue(Weekday.sunday < Weekday.saturday)
        XCTAssertEqual(Weekday.sunday.name(in: calendar), "Sunday")
        XCTAssertEqual(Weekday.allCases.map(\.rawValue), Array(1...7))
    }
}
