import XCTest
@testable import WaitItOutUX

final class DayTimelineLayoutTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var octoberWeek = calculator.week(containing: TestFixtures.fridayNoon)
    private lazy var novemberWeek = calculator.nextWeek(after: octoberWeek)
    /// Fri 2026-10-30, an ordinary 24-hour day.
    private lazy var friday = octoberWeek.dayRanges[5]
    private lazy var fridayLayout = DayTimelineLayout(day: friday, hourHeight: 60)

    func testOrdinaryDayHasTwentyFourRowsAndProportionalOffsets() {
        XCTAssertEqual(fridayLayout.hourCount, 24)
        XCTAssertEqual(fridayLayout.height, 1_440)
        XCTAssertEqual(fridayLayout.dayLength, 86_400)
        XCTAssertEqual(fridayLayout.offset(for: TestFixtures.date(2026, 10, 30, 9, 0)), 540)
        XCTAssertEqual(fridayLayout.offset(for: TestFixtures.date(2026, 10, 30, 9, 50)), 590)
        XCTAssertEqual(fridayLayout.offset(for: TestFixtures.date(2026, 10, 30, 12, 0)), 720)
        XCTAssertEqual(fridayLayout.offset(for: friday.lowerBound), 0)
        XCTAssertEqual(fridayLayout.offset(for: friday.upperBound), 1_440)
        XCTAssertEqual(fridayLayout.hourMarks.count, 24)
        XCTAssertEqual(fridayLayout.hourMarks[9].offset, 540)
        XCTAssertEqual(fridayLayout.hourMarks[9].instant, TestFixtures.date(2026, 10, 30, 9, 0))
        XCTAssertEqual(fridayLayout.hourIndex(containing: TestFixtures.date(2026, 10, 30, 9, 59)), 9)
    }

    func testOffsetsAreClampedToTheColumn() {
        XCTAssertEqual(fridayLayout.offset(for: TestFixtures.date(2026, 10, 29, 23, 0)), 0, "Before the day maps to the top edge")
        XCTAssertEqual(fridayLayout.offset(for: TestFixtures.date(2026, 11, 2, 9, 0)), 1_440, "After the day maps to the bottom edge")
        XCTAssertEqual(fridayLayout.hourIndex(containing: TestFixtures.date(2026, 11, 2, 9, 0)), 23)
        XCTAssertEqual(fridayLayout.hourIndex(containing: TestFixtures.date(2026, 10, 1)), 0)
    }

    func testDateAtOffsetInvertsOffset() {
        let nine = TestFixtures.date(2026, 10, 30, 9, 0)
        XCTAssertEqual(fridayLayout.date(atOffset: 540), nine)
        XCTAssertEqual(fridayLayout.date(atOffset: fridayLayout.offset(for: nine)), nine)
        XCTAssertEqual(fridayLayout.date(atOffset: -50), friday.lowerBound)
        XCTAssertEqual(fridayLayout.date(atOffset: 10_000), friday.upperBound)
        XCTAssertEqual(fridayLayout.date(atOffset: .nan), friday.lowerBound)
    }

    func testFallBackDayHasTwentyFiveRowsLabeledByItsOwnClock() {
        let sunday = novemberWeek.dayRanges[0]
        let layout = DayTimelineLayout(day: sunday, hourHeight: 60)
        XCTAssertEqual(layout.dayLength, 25 * 3_600)
        XCTAssertEqual(layout.hourCount, 25)
        XCTAssertEqual(layout.height, 1_500)
        XCTAssertEqual(layout.offset(for: Date(timeIntervalSince1970: 1_793_525_400)), 150, "1:30 AM PST is two and a half elapsed hours after midnight PDT")
        XCTAssertEqual(WallTime.of(layout.hourMarks[1].instant, in: TestFixtures.pacific), WallTime(hour: 1, minute: 0))
        XCTAssertEqual(WallTime.of(layout.hourMarks[2].instant, in: TestFixtures.pacific), WallTime(hour: 1, minute: 0), "The repeated hour gets its own row")
        XCTAssertEqual(WallTime.of(layout.hourMarks[3].instant, in: TestFixtures.pacific), WallTime(hour: 2, minute: 0))
        XCTAssertEqual(layout.hourMarks.last?.offset, 1_440)
    }

    func testSpringForwardDayHasTwentyThreeRowsAndNoTwoAM() {
        let marchWeek = calculator.week(containing: TestFixtures.date(2026, 3, 8, 15))
        let layout = DayTimelineLayout(day: marchWeek.dayRanges[0], hourHeight: 60)
        XCTAssertEqual(layout.hourCount, 23)
        XCTAssertEqual(layout.height, 1_380)
        let wallHours = layout.hourMarks.map { WallTime.of($0.instant, in: TestFixtures.pacific).hour }
        XCTAssertFalse(wallHours.contains(2))
        XCTAssertEqual(wallHours.prefix(4), [0, 1, 3, 4])
    }

    func testFrameSizesBlocksByDurationWithAMinimumHeight() throws {
        let lecture = try XCTUnwrap(fridayLayout.frame(for: TestFixtures.date(2026, 10, 30, 9, 0)..<TestFixtures.date(2026, 10, 30, 9, 50)))
        XCTAssertEqual(lecture.minY, 540)
        XCTAssertEqual(lecture.height, 50)
        XCTAssertEqual(lecture.maxY, 590)
        XCTAssertFalse(lecture.isClippedAtStart)
        XCTAssertFalse(lecture.isClippedAtEnd)

        let short = try XCTUnwrap(fridayLayout.frame(for: TestFixtures.date(2026, 10, 30, 13, 0)..<TestFixtures.date(2026, 10, 30, 13, 15)))
        XCTAssertEqual(short.minY, 780)
        XCTAssertEqual(short.height, 44, "Short activities keep a readable, tappable height")

        let lab = try XCTUnwrap(fridayLayout.frame(for: TestFixtures.date(2026, 10, 30, 12, 0)..<TestFixtures.date(2026, 10, 30, 17, 15)))
        XCTAssertEqual(lab.height, 315)
    }

    func testMinimumHeightNearTheBottomShiftsTheBlockUpInsteadOfOverflowing() throws {
        let late = try XCTUnwrap(fridayLayout.frame(for: TestFixtures.date(2026, 10, 30, 23, 45)..<friday.upperBound))
        XCTAssertEqual(late.height, 44)
        XCTAssertEqual(late.maxY, 1_440)
        XCTAssertEqual(late.minY, 1_396)
        XCTAssertFalse(late.isClippedAtEnd, "Ending exactly at midnight does not continue into the next day")
    }

    func testOvernightIntervalIsClippedToEachDay() throws {
        let overnight = Date(timeIntervalSince1970: 1_793_512_800)..<Date(timeIntervalSince1970: 1_793_520_000) // Sat 23:00 to Sun 01:00 PDT
        let saturday = DayTimelineLayout(day: octoberWeek.dayRanges[6], hourHeight: 60)
        let onSaturday = try XCTUnwrap(saturday.frame(for: overnight))
        XCTAssertEqual(onSaturday.minY, 1_380)
        XCTAssertEqual(onSaturday.height, 60)
        XCTAssertFalse(onSaturday.isClippedAtStart)
        XCTAssertTrue(onSaturday.isClippedAtEnd)
        XCTAssertEqual(onSaturday.visibleInterval, overnight.lowerBound..<octoberWeek.end)

        let sunday = DayTimelineLayout(day: novemberWeek.dayRanges[0], hourHeight: 60)
        let onSunday = try XCTUnwrap(sunday.frame(for: overnight))
        XCTAssertEqual(onSunday.minY, 0)
        XCTAssertEqual(onSunday.height, 60)
        XCTAssertTrue(onSunday.isClippedAtStart)
        XCTAssertFalse(onSunday.isClippedAtEnd)
        XCTAssertEqual(onSunday.visibleInterval, novemberWeek.start..<overnight.upperBound)
    }

    func testIntervalsOutsideTheDayOrEmptyHaveNoFrame() {
        XCTAssertNil(fridayLayout.frame(for: TestFixtures.date(2026, 10, 29, 9)..<TestFixtures.date(2026, 10, 29, 10)))
        XCTAssertNil(fridayLayout.frame(for: friday.upperBound..<friday.upperBound.addingTimeInterval(3_600)), "Starting at the next midnight belongs to the next day")
        let nine = TestFixtures.date(2026, 10, 30, 9)
        XCTAssertNil(fridayLayout.frame(for: nine..<nine))
    }

    func testTwentyFourHourActivityFillsTheWholeColumn() throws {
        let allDay = try XCTUnwrap(fridayLayout.frame(for: friday))
        XCTAssertEqual(allDay.minY, 0)
        XCTAssertEqual(allDay.height, 1_440)
        let longer = try XCTUnwrap(fridayLayout.frame(for: TestFixtures.date(2026, 10, 29, 20)..<TestFixtures.date(2026, 10, 31, 4)))
        XCTAssertEqual(longer.height, 1_440)
        XCTAssertTrue(longer.isClippedAtStart)
        XCTAssertTrue(longer.isClippedAtEnd)
    }

    func testSharedGutterFollowsAnOrdinaryDayAndOnlyTheTransitionDayLabelsItsOwnRows() throws {
        let november = novemberWeek.dayRanges.map { DayTimelineLayout(day: $0, hourHeight: 60) }
        let gutter = try XCTUnwrap(DayTimelineLayout.sharedGutter(for: november))
        XCTAssertEqual(gutter.hourCount, 24)
        XCTAssertEqual(gutter.day, novemberWeek.dayRanges[1], "Monday, the first ordinary day, labels the gutter of the fall-back week")
        XCTAssertEqual(november.indices.filter { november[$0].rowsDiffer(from: gutter) }, [0], "Only the 25-hour Sunday labels its own rows")

        let marchWeek = calculator.week(containing: TestFixtures.date(2026, 3, 8, 15))
        let march = marchWeek.dayRanges.map { DayTimelineLayout(day: $0, hourHeight: 60) }
        let marchGutter = try XCTUnwrap(DayTimelineLayout.sharedGutter(for: march))
        XCTAssertEqual(marchGutter.hourCount, 24)
        XCTAssertEqual(march.indices.filter { march[$0].rowsDiffer(from: marchGutter) }, [0], "Only the 23-hour Sunday labels its own rows")

        let october = octoberWeek.dayRanges.map { DayTimelineLayout(day: $0, hourHeight: 60) }
        let octoberGutter = try XCTUnwrap(DayTimelineLayout.sharedGutter(for: october))
        XCTAssertEqual(octoberGutter.day, octoberWeek.dayRanges[0], "An ordinary week's gutter follows its Sunday")
        XCTAssertTrue(october.allSatisfy { !$0.rowsDiffer(from: octoberGutter) }, "No column of an ordinary week labels its own rows")

        XCTAssertNil(DayTimelineLayout.sharedGutter(for: []))
        let onlySunday = [DayTimelineLayout(day: novemberWeek.dayRanges[0], hourHeight: 60)]
        XCTAssertEqual(DayTimelineLayout.sharedGutter(for: onlySunday)?.hourCount, 25, "Without an ordinary day the first layout labels the gutter, as in the selected-day layout")
        XCTAssertFalse(fridayLayout.rowsDiffer(from: fridayLayout))
    }

    func testDegenerateInputsDoNotTrap() {
        let empty = DayTimelineLayout(day: friday.lowerBound..<friday.lowerBound, hourHeight: 60)
        XCTAssertEqual(empty.hourCount, 1)
        XCTAssertEqual(empty.height, 60)
        let silly = DayTimelineLayout(day: friday, hourHeight: .nan, minimumBlockHeight: -5)
        XCTAssertEqual(silly.hourHeight, 1)
        XCTAssertEqual(silly.minimumBlockHeight, 0)
        let huge = DayTimelineLayout(day: Date.distantPast..<Date.distantFuture, hourHeight: 60)
        XCTAssertEqual(huge.hourCount, 48)
        let scaled = DayTimelineLayout(day: friday, hourHeight: 90)
        XCTAssertEqual(scaled.offset(for: TestFixtures.date(2026, 10, 30, 9, 0)), 810, "Positions scale with the row height for large text")
    }
}
