import XCTest
@testable import WaitItOutUX

/// Selection, scroll state, and day navigation that the Calendar tab keeps in the shared model.
@MainActor
final class WaitItOutModelCalendarTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    /// Fri 2026-10-30 00:00 PDT.
    private let fridayStart = Date(timeIntervalSince1970: 1_793_343_600)

    func testSelectedDayStartsOnTodayWithinTheCurrentWeek() {
        let model = TestFixtures.makeModel()
        XCTAssertEqual(model.selectedDay, fridayStart)
        XCTAssertEqual(model.selectedDayIndex, 5)
        XCTAssertEqual(model.selectedDayRange, model.visibleWeek.dayRanges[5])
        XCTAssertTrue(model.isShowingToday)
        XCTAssertTrue(model.isToday(TestFixtures.fridayNoon))
        XCTAssertFalse(model.isToday(fridayStart.addingTimeInterval(-1)))
        XCTAssertNil(model.calendarScrollHour, "The Calendar picks its first scroll row when shown")
    }

    func testSelectDayAtIndexStaysInTheVisibleWeek() {
        let model = TestFixtures.makeModel()
        model.selectDay(at: 1)
        XCTAssertEqual(model.selectedDay, model.visibleWeek.dayStarts[1])
        XCTAssertEqual(model.selectedDayIndex, 1)
        XCTAssertFalse(model.isShowingToday)
        XCTAssertTrue(model.isShowingCurrentWeek)
        model.selectDay(at: 9)
        XCTAssertEqual(model.selectedDayIndex, 1, "Out-of-range indices are ignored")
        model.selectDay(at: -1)
        XCTAssertEqual(model.selectedDayIndex, 1)
        model.selectDay(at: 0)
        XCTAssertEqual(model.selectedDay, model.visibleWeek.start)
    }

    func testWeekNavigationKeepsTheWeekdayAcrossTheFallBackWeek() {
        let model = TestFixtures.makeModel()
        model.showNextWeek()
        XCTAssertEqual(model.selectedDayIndex, 5)
        XCTAssertEqual(model.selectedDay, Date(timeIntervalSince1970: 1_793_952_000), "Fri 2026-11-06 00:00 PST")
        XCTAssertEqual(model.selectedDay, model.visibleWeek.dayStarts[5])
        XCTAssertFalse(model.isShowingToday)
        model.showPreviousWeek()
        XCTAssertEqual(model.selectedDay, fridayStart)
        XCTAssertTrue(model.isShowingToday)
    }

    func testSelectDayOutsideTheWeekMovesTheWeekAndCrossesTheYearBoundary() {
        let model = TestFixtures.makeModel()
        model.selectDay(TestFixtures.date(2026, 12, 31, 9))
        XCTAssertEqual(model.selectedDay, Date(timeIntervalSince1970: 1_798_704_000), "Thu 2026-12-31 00:00 PST")
        XCTAssertEqual(model.selectedDayIndex, 4)
        XCTAssertEqual(model.visibleWeek, calculator.week(containing: TestFixtures.date(2026, 12, 31, 9)))
        XCTAssertFalse(model.isShowingCurrentWeek)
        model.showNextWeek()
        XCTAssertEqual(model.visibleWeek.start, Date(timeIntervalSince1970: 1_798_963_200), "Sun 2027-01-03")
        XCTAssertEqual(model.selectedDay, Date(timeIntervalSince1970: 1_799_308_800), "Thu 2027-01-07 keeps the weekday")
        model.selectDay(TestFixtures.date(2027, 1, 5, 23, 59))
        XCTAssertEqual(model.selectedDayIndex, 2, "A day inside the visible week only changes the selection")
        XCTAssertEqual(model.visibleWeek.start, Date(timeIntervalSince1970: 1_798_963_200))
    }

    func testTodayReturnsToTheCurrentWeekAndDay() {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let model = TestFixtures.makeModel(clock: clock)
        model.showNextWeek()
        model.selectDay(at: 2)
        model.showCurrentWeek()
        XCTAssertEqual(model.selectedDay, fridayStart)
        XCTAssertTrue(model.isShowingToday)
        clock.advance(by: 3 * 86_400) // Mon 2026-11-02 11:00 PST
        XCTAssertFalse(model.isShowingToday, "The selection does not move on its own when time passes")
        model.showCurrentWeek()
        XCTAssertEqual(model.selectedDay, Date(timeIntervalSince1970: 1_793_606_400), "Mon 2026-11-02 00:00 PST")
        XCTAssertEqual(model.selectedDayIndex, 1)
        XCTAssertTrue(model.isShowingToday)
    }

    func testSelectionAndScrollStateSurviveTabSwitches() {
        let model = TestFixtures.makeModel(initialTab: .calendar)
        model.selectDay(at: 3)
        model.showNextWeek()
        model.calendarScrollHour = 11
        model.selectedTab = .map
        model.selectedTab = .settings
        model.selectedTab = .calendar
        XCTAssertEqual(model.selectedDayIndex, 3)
        XCTAssertFalse(model.isShowingCurrentWeek)
        XCTAssertEqual(model.calendarScrollHour, 11)
    }

    func testOccurrencesOnADayFollowTheRepository() async {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        XCTAssertEqual(model.occurrences(on: model.selectedDayRange), [])
        await model.loadSampleActivities()
        XCTAssertEqual(model.occurrences(on: model.visibleWeek.dayRanges[1]).map(\.activity.title), ["Sample morning class"])
        XCTAssertEqual(model.occurrences(on: model.visibleWeek.dayRanges[2]).map(\.activity.title), ["Sample afternoon lab"])
        XCTAssertEqual(model.occurrences(on: model.visibleWeek.dayRanges[6]), [])
        XCTAssertEqual(model.occurrences(on: model.selectedDayRange).count, 1, "Friday has the morning class")
        await model.clearSampleActivities()
        XCTAssertEqual(model.occurrences(on: model.visibleWeek.dayRanges[1]), [])
    }

    func testInvalidSelectionDatesAreIgnored() {
        let model = TestFixtures.makeModel()
        model.selectDay(Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertEqual(model.selectedDay, fridayStart)
        XCTAssertTrue(model.isShowingCurrentWeek)
    }

    func testWeekIntervalDayLookups() {
        let week = calculator.week(containing: TestFixtures.fridayNoon)
        XCTAssertEqual(week.dayRange(at: 0), week.dayRanges[0])
        XCTAssertEqual(week.dayRange(at: 6)?.upperBound, week.end)
        XCTAssertNil(week.dayRange(at: 7))
        XCTAssertNil(week.dayRange(at: -1))
        XCTAssertEqual(week.dayIndex(containing: TestFixtures.fridayNoon), 5)
        XCTAssertEqual(week.dayIndex(containing: week.start), 0)
        XCTAssertNil(week.dayIndex(containing: week.end), "The week end is exclusive")
        XCTAssertNil(week.dayIndex(containing: week.start.addingTimeInterval(-1)))
    }
}
