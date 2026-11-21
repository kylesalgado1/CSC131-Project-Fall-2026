import XCTest
@testable import WaitItOutUX

final class WeekTitleFormatterTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var formatter = WeekTitleFormatter(calculator: calculator, locale: TestFixtures.enUS)

    func testTitleWithinOneMonthMentionsBothDaysAndYear() {
        let title = formatter.title(for: calculator.week(containing: TestFixtures.fridayNoon))
        XCTAssertTrue(title.contains("Oct"), title)
        XCTAssertTrue(title.contains("25"), title)
        XCTAssertTrue(title.contains("31"), title)
        XCTAssertTrue(title.contains("2026"), title)
    }

    func testTitleAcrossYearBoundaryMentionsBothYears() {
        let title = formatter.title(for: calculator.week(containing: TestFixtures.date(2026, 12, 31)))
        XCTAssertTrue(title.contains("Dec"), title)
        XCTAssertTrue(title.contains("27"), title)
        XCTAssertTrue(title.contains("Jan"), title)
        XCTAssertTrue(title.contains("2026"), title)
        XCTAssertTrue(title.contains("2027"), title)
    }

    func testAccessibilityTitleSpellsOutWeekdays() {
        let spoken = formatter.accessibilityTitle(for: calculator.week(containing: TestFixtures.fridayNoon))
        XCTAssertTrue(spoken.hasPrefix("Week of Sunday, October 25"), spoken)
        XCTAssertTrue(spoken.contains("through Saturday, October 31, 2026"), spoken)
    }

    func testDayLabel() {
        XCTAssertEqual(formatter.dayLabel(for: TestFixtures.date(2026, 10, 30)), "Friday, October 30")
    }
}
