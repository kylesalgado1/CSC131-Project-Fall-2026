import XCTest
@testable import WaitItOutUX

/// Text the time grid and detail sheet show, rendered in en_US and the Pacific zone.
final class CalendarFormattingTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var formatter = OccurrenceFormatter(calculator: calculator, locale: TestFixtures.enUS)
    private lazy var week = calculator.week(containing: TestFixtures.fridayNoon)

    private func occurrence(of activity: Activity, in range: Range<Date>) throws -> ActivityOccurrence {
        try XCTUnwrap(OccurrenceExpander.occurrences(of: [activity], in: range).first)
    }

    func testHourLabelsFollowTheWallClockIncludingTheRepeatedHour() {
        XCTAssertTrue(formatter.hourLabel(for: TestFixtures.date(2026, 10, 30, 9)).contains("9"))
        XCTAssertTrue(formatter.hourLabel(for: TestFixtures.date(2026, 10, 30, 9)).contains("AM"))
        XCTAssertTrue(formatter.hourLabel(for: TestFixtures.date(2026, 10, 30, 15)).contains("3"))
        XCTAssertTrue(formatter.hourLabel(for: TestFixtures.date(2026, 10, 30, 15)).contains("PM"))
        let fallBack = DayTimelineLayout(day: calculator.nextWeek(after: week).dayRanges[0], hourHeight: 60)
        let labels = fallBack.hourMarks.map { formatter.hourLabel(for: $0.instant) }
        XCTAssertEqual(labels.count, 25)
        XCTAssertEqual(labels[1], labels[2], "Both 1 AM rows carry the same label")
        XCTAssertNotEqual(labels[2], labels[3])
    }

    func testDurationText() {
        XCTAssertEqual(formatter.durationText(50 * 60), "50 minutes")
        XCTAssertEqual(formatter.durationText(60 * 60), "1 hour")
        XCTAssertEqual(formatter.durationText(5.25 * 3_600), "5 hours 15 minutes")
        XCTAssertEqual(formatter.durationText(2 * 3_600), "2 hours")
        XCTAssertEqual(formatter.durationText(60), "1 minute")
        XCTAssertEqual(formatter.durationText(0), "0 minutes")
        XCTAssertEqual(formatter.durationText(-30), "0 minutes")
        XCTAssertEqual(formatter.durationText(.nan), "0 minutes")
    }

    func testArrivalMarkerAndDetailTextForASameDayActivity() throws {
        let activity = TestFixtures.activity(
            title: "Lecture",
            start: TestFixtures.mondayNine,
            end: TestFixtures.mondayNine.addingTimeInterval(3_000),
            arrival: TestFixtures.mondayNine.addingTimeInterval(-2_700)
        )
        let monday = week.dayRanges[1]
        let occurrence = try self.occurrence(of: activity, in: monday)
        let marker = formatter.arrivalMarkerText(for: occurrence, on: monday)
        XCTAssertTrue(marker.hasPrefix("Arrive "), marker)
        XCTAssertTrue(marker.contains("8:15"), marker)
        XCTAssertFalse(marker.contains("start"), marker)
        let spoken = formatter.arrivalMarkerAccessibilityLabel(for: occurrence, on: monday)
        XCTAssertTrue(spoken.hasPrefix("Ideal arrival "), spoken)
        XCTAssertTrue(spoken.contains("for Lecture"), spoken)
        XCTAssertFalse(spoken.contains("which starts"), spoken)
        XCTAssertFalse(formatter.detailArrivalText(for: occurrence).contains("on "), "Same-day arrival shows the time only")
        XCTAssertTrue(formatter.detailArrivalText(for: occurrence).contains("8:15"))
        XCTAssertEqual(formatter.arrivalLeadText(for: occurrence), "45 minutes before start")
        XCTAssertEqual(formatter.fullDate(occurrence.start), "Monday, October 26, 2026")
    }

    func testArrivalMarkerForAnActivityThatStartsTheNextDay() throws {
        let earlySunday = TestFixtures.activity(
            title: "Early start",
            start: Date(timeIntervalSince1970: 1_793_518_200),   // Sun 00:30 PDT
            end: Date(timeIntervalSince1970: 1_793_520_900),     // Sun 01:15 PDT
            arrival: Date(timeIntervalSince1970: 1_793_515_500)  // Sat 23:45 PDT
        )
        let saturday = week.dayRanges[6]
        let occurrence = try self.occurrence(of: earlySunday, in: saturday)
        let marker = formatter.arrivalMarkerText(for: occurrence, on: saturday)
        XCTAssertTrue(marker.contains("11:45"), marker)
        XCTAssertTrue(marker.contains("Sun"), marker)
        XCTAssertTrue(marker.contains("12:30"), marker)
        XCTAssertTrue(marker.hasSuffix("start"), marker)
        let spoken = formatter.arrivalMarkerAccessibilityLabel(for: occurrence, on: saturday)
        XCTAssertTrue(spoken.contains("which starts"), spoken)
        XCTAssertTrue(spoken.contains("Sun"), spoken)
        let detail = formatter.detailArrivalText(for: occurrence)
        XCTAssertTrue(detail.contains("11:45"), detail)
        XCTAssertTrue(detail.contains("on Saturday, October 31"), detail)
    }

    func testArrivalLeadOfZeroReadsAsAtTheStart() throws {
        let activity = TestFixtures.activity(start: TestFixtures.mondayNine, arrival: TestFixtures.mondayNine)
        let occurrence = try self.occurrence(of: activity, in: week.dayRanges[1])
        XCTAssertEqual(formatter.arrivalLeadText(for: occurrence), "At the start time")
    }

    func testDaySummaryAndCurrentTimeLabel() {
        XCTAssertEqual(formatter.daySummary(blockCount: 0, arrivalOnlyCount: 0), "No activities")
        XCTAssertEqual(formatter.daySummary(blockCount: 1, arrivalOnlyCount: 0), "1 activity")
        XCTAssertEqual(formatter.daySummary(blockCount: 3, arrivalOnlyCount: 0), "3 activities")
        XCTAssertEqual(formatter.daySummary(blockCount: 0, arrivalOnlyCount: 1), "No activities, plus an arrival for an activity that starts the next day")
        XCTAssertTrue(formatter.daySummary(blockCount: 2, arrivalOnlyCount: 2).contains("plus 2 arrivals"))
        let label = formatter.currentTimeLabel(for: TestFixtures.fridayNoon)
        XCTAssertTrue(label.hasPrefix("Current time, "), label)
        XCTAssertTrue(label.contains("12:00"), label)
        XCTAssertTrue(formatter.clockTime(TestFixtures.fridayNoon).contains("12:00"))
    }
}
