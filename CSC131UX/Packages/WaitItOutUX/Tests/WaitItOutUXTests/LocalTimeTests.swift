import XCTest
@testable import WaitItOutUX

final class LocalTimeTests: XCTestCase {
    private let pacific = TestFixtures.pacific
    private let utc = TestFixtures.utc

    private func local(_ year: Int, _ month: Int, _ day: Int) throws -> LocalDate {
        try XCTUnwrap(LocalDate(year: year, month: month, day: day))
    }

    private func wall(_ hour: Int, _ minute: Int, _ second: Int = 0) throws -> WallTime {
        try XCTUnwrap(WallTime(hour: hour, minute: minute, second: second))
    }

    func testLocalDateRejectsImpossibleDays() {
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 30))
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 29))
        XCTAssertNotNil(LocalDate(year: 2024, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 2026, month: 13, day: 1))
        XCTAssertNil(LocalDate(year: 2026, month: 4, day: 31))
        XCTAssertNil(LocalDate(year: 2026, month: 1, day: 0))
    }

    func testLocalDateArithmeticAndWeekdays() throws {
        let friday = try local(2026, 10, 30)
        XCTAssertEqual(friday.weekday, .friday)
        XCTAssertEqual(friday.description, "2026-10-30")
        XCTAssertEqual(friday.dayNumber, 20_756)
        let sunday = friday.adding(days: 2)
        XCTAssertEqual(sunday, try local(2026, 11, 1))
        XCTAssertEqual(sunday.weekday, .sunday)
        XCTAssertEqual(friday.adding(days: -30), try local(2026, 9, 30))
        XCTAssertEqual(friday.days(until: try local(2027, 1, 2)), 64)
        XCTAssertEqual(try local(2027, 1, 2).weekday, .saturday)
        XCTAssertTrue(friday < sunday)
        XCTAssertEqual(LocalDate(dayNumber: 0), try local(1970, 1, 1))
        XCTAssertEqual(try local(1970, 1, 1).weekday, .thursday)
        XCTAssertEqual(try local(1969, 12, 31).dayNumber, -1)
        XCTAssertEqual(try local(2026, 12, 31).adding(days: 1), try local(2027, 1, 1))
    }

    func testLocalDateOfInstantFollowsTheZone() {
        let instant = TestFixtures.date(2026, 11, 1, 3, 30, 0, in: utc)
        XCTAssertEqual(LocalDate.of(instant, in: utc), LocalDate(year: 2026, month: 11, day: 1))
        XCTAssertEqual(LocalDate.of(instant, in: pacific), LocalDate(year: 2026, month: 10, day: 31))
        XCTAssertEqual(LocalDate.of(instant, in: pacific).weekday, .saturday)
        XCTAssertEqual(LocalDate.of(Date(timeIntervalSince1970: .nan), in: pacific), LocalDate(dayNumber: 0), "Non-finite instants do not trap")
    }

    func testLocalDateDescriptionRoundTrips() throws {
        let date = try local(2026, 10, 30)
        XCTAssertEqual(LocalDate(description: date.description), date)
        XCTAssertNil(LocalDate(description: "2026-10"))
        XCTAssertNil(LocalDate(description: "2026-02-30"))
        XCTAssertNil(LocalDate(description: "abc"))
    }

    func testWallTimeValidationAndReading() throws {
        XCTAssertNil(WallTime(hour: 24, minute: 0))
        XCTAssertNil(WallTime(hour: 9, minute: 60))
        XCTAssertNil(WallTime(hour: -1, minute: 0))
        XCTAssertNil(WallTime(hour: 9, minute: 0, second: 60))
        let nine = try wall(9, 0)
        XCTAssertEqual(nine.secondsFromMidnight, 32_400)
        XCTAssertEqual(nine.description, "09:00:00")
        XCTAssertEqual(WallTime.of(TestFixtures.mondayNine, in: pacific), nine)
        XCTAssertEqual(WallTime.of(TestFixtures.mondayNine, in: utc), try wall(16, 0))
        XCTAssertTrue(WallTime.midnight < nine)
        XCTAssertEqual(WallTime.of(Date(timeIntervalSince1970: .nan), in: pacific), .midnight)
        XCTAssertEqual(LocalDateTime.of(TestFixtures.mondayNine, in: pacific), LocalDateTime(date: try local(2026, 10, 26), time: nine))
    }

    func testResolverReturnsOrdinaryInstants() throws {
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(9, 0), on: try local(2026, 10, 26), in: pacific), TestFixtures.mondayNine)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(9, 0), on: try local(2026, 11, 2), in: pacific), Date(timeIntervalSince1970: 1_793_638_800))
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(9, 0), on: try local(2026, 10, 26), in: utc), Date(timeIntervalSince1970: 1_793_005_200))
        XCTAssertEqual(LocalTimeResolver.classify(try wall(9, 0), on: try local(2026, 11, 1), in: pacific), .unique)
        // 9:00 on the fall-back day itself is already standard time.
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(9, 0), on: try local(2026, 11, 1), in: pacific), Date(timeIntervalSince1970: 1_793_552_400))
        // Midnight on the day after the transition, the start of a 25-hour day's successor.
        XCTAssertEqual(LocalTimeResolver.instant(of: .midnight, on: try local(2026, 11, 2), in: pacific), Date(timeIntervalSince1970: 1_793_606_400))
    }

    func testRepeatedWallTimeResolvesToItsFirstOccurrence() throws {
        let fallBackDay = try local(2026, 11, 1)
        let halfPastOne = try wall(1, 30)
        XCTAssertEqual(LocalTimeResolver.classify(halfPastOne, on: fallBackDay, in: pacific), .repeated)
        let resolved = LocalTimeResolver.instant(of: halfPastOne, on: fallBackDay, in: pacific)
        XCTAssertEqual(resolved, Date(timeIntervalSince1970: 1_793_521_800), "01:30 PDT, not 01:30 PST an hour later")
        XCTAssertEqual(pacific.secondsFromGMT(for: resolved), -7 * 3_600)
        XCTAssertEqual(WallTime.of(resolved, in: pacific), halfPastOne)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(1, 30), on: try local(2026, 11, 8), in: pacific), Date(timeIntervalSince1970: 1_794_130_200))
    }

    func testSkippedWallTimeResolvesToTheEndOfTheGap() throws {
        let springForwardDay = try local(2026, 3, 8)
        XCTAssertEqual(LocalTimeResolver.classify(try wall(2, 30), on: springForwardDay, in: pacific), .skipped)
        XCTAssertEqual(LocalTimeResolver.classify(try wall(1, 59), on: springForwardDay, in: pacific), .unique)
        XCTAssertEqual(LocalTimeResolver.classify(try wall(3, 0), on: springForwardDay, in: pacific), .unique)
        let transition = Date(timeIntervalSince1970: 1_772_964_000) // 03:00 PDT, the first instant after the gap
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(2, 0), on: springForwardDay, in: pacific), transition)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(2, 30), on: springForwardDay, in: pacific), transition)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(2, 59, 59), on: springForwardDay, in: pacific), transition)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(3, 0), on: springForwardDay, in: pacific), transition)
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(1, 59), on: springForwardDay, in: pacific), Date(timeIntervalSince1970: 1_772_963_940))
        XCTAssertEqual(LocalTimeResolver.instant(of: try wall(2, 30), on: try local(2026, 3, 15), in: pacific), Date(timeIntervalSince1970: 1_773_567_000))
    }

    func testResolverNeverReordersReadingsOnTransitionDays() throws {
        for day in [try local(2026, 3, 8), try local(2026, 11, 1)] {
            var previous = LocalTimeResolver.instant(of: .midnight, on: day, in: pacific)
            for minutes in stride(from: 1, through: 24 * 60 - 1, by: 7) {
                let time = try wall(minutes / 60, minutes % 60)
                let instant = LocalTimeResolver.instant(of: time, on: day, in: pacific)
                XCTAssertGreaterThanOrEqual(instant, previous, "\(day) \(time)")
                previous = instant
            }
        }
    }

    func testResolverRoundTripsReadingsTakenFromInstants() {
        let samples: [TimeInterval] = [1_793_030_400, 1_793_521_800, 1_793_638_800, 1_772_963_940, 1_772_964_000, 1_798_574_400]
        for seconds in samples {
            let instant = Date(timeIntervalSince1970: seconds)
            let reading = LocalDateTime.of(instant, in: pacific)
            XCTAssertEqual(LocalTimeResolver.instant(of: reading, in: pacific), instant, "\(seconds)")
        }
    }

    func testZonesWithoutTransitionsResolveDirectly() throws {
        XCTAssertEqual(LocalTimeResolver.classify(try wall(2, 30), on: try local(2026, 3, 8), in: utc), .unique)
        XCTAssertEqual(LocalTimeResolver.instant(of: .midnight, on: try local(2026, 3, 8), in: utc), TestFixtures.date(2026, 3, 8, in: utc))
    }
}
