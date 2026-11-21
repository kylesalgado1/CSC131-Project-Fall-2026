import XCTest
@testable import WaitItOutUX

final class WeekCalculatorTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()

    func testNormalizesAnyCalendarToSundayFirstGregorian() {
        var monday = Calendar(identifier: .iso8601)
        monday.firstWeekday = 2
        monday.timeZone = TestFixtures.utc
        let normalized = WeekCalculator(calendar: monday)
        XCTAssertEqual(normalized.calendar.identifier, .gregorian)
        XCTAssertEqual(normalized.calendar.firstWeekday, 1)
        XCTAssertEqual(normalized.calendar.minimumDaysInFirstWeek, 1)
        XCTAssertEqual(normalized.timeZone, TestFixtures.utc)
    }

    func testWeekContainingFridayStartsOnPrecedingSunday() {
        let week = calculator.week(containing: TestFixtures.fridayNoon)
        XCTAssertEqual(week.start, Date(timeIntervalSince1970: 1_792_911_600)) // Sun 2026-10-25 00:00 PDT
        XCTAssertEqual(week.end, Date(timeIntervalSince1970: 1_793_516_400))   // Sun 2026-11-01 00:00 PDT
        XCTAssertEqual(week.dayStarts.count, 7)
        XCTAssertEqual(week.dayStarts.first, week.start)
        XCTAssertEqual(calculator.weekdayIndex(of: week.start), 0)
        XCTAssertEqual(calculator.weekdayIndex(of: week.lastDayStart), 6)
        XCTAssertTrue(week.contains(TestFixtures.fridayNoon))
    }

    func testEveryInstantOfSundayThroughSaturdayMapsToSameWeek() {
        let reference = calculator.week(containing: TestFixtures.fridayNoon)
        let sundayMidnight = TestFixtures.date(2026, 10, 25, 0, 0, 0)
        let saturdayLastSecond = TestFixtures.date(2026, 10, 31, 23, 59, 59)
        XCTAssertEqual(calculator.week(containing: sundayMidnight), reference)
        XCTAssertEqual(calculator.week(containing: saturdayLastSecond), reference)
        XCTAssertTrue(reference.contains(saturdayLastSecond))
        XCTAssertFalse(reference.contains(reference.end))
    }

    func testNextSundayMidnightStartsNewWeek() {
        let reference = calculator.week(containing: TestFixtures.fridayNoon)
        let nextSunday = TestFixtures.date(2026, 11, 1, 0, 0, 0)
        let following = calculator.week(containing: nextSunday)
        XCTAssertNotEqual(following, reference)
        XCTAssertEqual(following.start, reference.end)
        XCTAssertEqual(following.start, nextSunday)
    }

    func testNavigationIsSymmetricAcrossMonthBoundary() {
        let octoberWeek = calculator.week(containing: TestFixtures.fridayNoon)
        let novemberWeek = calculator.nextWeek(after: octoberWeek)
        XCTAssertEqual(novemberWeek.start, Date(timeIntervalSince1970: 1_793_516_400))
        XCTAssertEqual(calculator.previousWeek(before: novemberWeek), octoberWeek)
        XCTAssertEqual(calculator.week(octoberWeek, offsetBy: 0), octoberWeek)
        XCTAssertEqual(calculator.week(octoberWeek, offsetBy: 3), calculator.nextWeek(after: calculator.nextWeek(after: novemberWeek)))
        XCTAssertEqual(calculator.week(novemberWeek, offsetBy: -1), octoberWeek)
    }

    func testWeekCrossingYearBoundary() {
        let newYearsEve = TestFixtures.date(2026, 12, 31, 9)
        let week = calculator.week(containing: newYearsEve)
        XCTAssertEqual(week.start, Date(timeIntervalSince1970: 1_798_358_400)) // Sun 2026-12-27 PST
        XCTAssertEqual(week.end, Date(timeIntervalSince1970: 1_798_963_200))   // Sun 2027-01-03 PST
        let components = calculator.calendar.dateComponents([.year, .month, .day], from: week.lastDayStart)
        XCTAssertEqual(components.year, 2027)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(calculator.week(containing: TestFixtures.date(2027, 1, 2, 23, 59, 59)), week)
    }

    func testWeekContainingFallBackTransitionIsOneHourLonger() {
        let week = calculator.week(containing: TestFixtures.date(2026, 11, 1, 0, 0, 0))
        XCTAssertEqual(week.start, Date(timeIntervalSince1970: 1_793_516_400)) // 00:00 PDT
        XCTAssertEqual(week.end, Date(timeIntervalSince1970: 1_794_124_800))   // 00:00 PST a week later
        XCTAssertEqual(week.end.timeIntervalSince(week.start), 7 * 86_400 + 3_600)
        XCTAssertEqual(week.dayStarts[1].timeIntervalSince(week.dayStarts[0]), 25 * 3_600)
        XCTAssertEqual(week.dayStarts[2].timeIntervalSince(week.dayStarts[1]), 24 * 3_600)
    }

    func testWeekContainingSpringForwardTransitionIsOneHourShorter() {
        let week = calculator.week(containing: TestFixtures.date(2026, 3, 8, 15))
        XCTAssertEqual(week.start, Date(timeIntervalSince1970: 1_772_956_800)) // Sun 2026-03-08 00:00 PST
        XCTAssertEqual(week.end, Date(timeIntervalSince1970: 1_773_558_000))   // Sun 2026-03-15 00:00 PDT
        XCTAssertEqual(week.end.timeIntervalSince(week.start), 7 * 86_400 - 3_600)
        XCTAssertEqual(week.dayStarts[1].timeIntervalSince(week.dayStarts[0]), 23 * 3_600)
        for day in week.dayStarts {
            XCTAssertEqual(calculator.startOfDay(for: day), day, "Each entry must be a local midnight")
        }
    }

    func testDayStartsAreConsecutiveLocalDays() {
        let week = calculator.week(containing: TestFixtures.fridayNoon)
        for (index, day) in week.dayStarts.enumerated() {
            XCTAssertEqual(calculator.weekdayIndex(of: day), index)
            let components = calculator.calendar.dateComponents([.hour, .minute, .second], from: day)
            XCTAssertEqual(components.hour, 0)
            XCTAssertEqual(components.minute, 0)
            XCTAssertEqual(components.second, 0)
        }
    }

    func testDifferentTimeZonesDisagreeNearMidnight() {
        // 2026-11-01 03:30 UTC is still Saturday evening in the Pacific zone.
        let instant = TestFixtures.date(2026, 11, 1, 3, 30, 0, in: TestFixtures.utc)
        let utcWeek = WeekCalculator(timeZone: TestFixtures.utc, locale: TestFixtures.enUS).week(containing: instant)
        let pacificWeek = calculator.week(containing: instant)
        XCTAssertEqual(utcWeek.start, TestFixtures.date(2026, 11, 1, in: TestFixtures.utc))
        XCTAssertEqual(pacificWeek.start, TestFixtures.date(2026, 10, 25))
        XCTAssertTrue(utcWeek.start > pacificWeek.start)
    }

    func testIsSameDayRespectsCalculatorTimeZone() {
        let lateSaturday = TestFixtures.date(2026, 10, 31, 23, 30)
        let earlySunday = TestFixtures.date(2026, 11, 1, 0, 30)
        XCTAssertFalse(calculator.isSameDay(lateSaturday, earlySunday))
        XCTAssertTrue(calculator.isSameDay(lateSaturday, TestFixtures.date(2026, 10, 31, 1)))
    }
}
