import XCTest
@testable import WaitItOutUX

final class CalendarLayoutModeTests: XCTestCase {
    func testCompactWidthsShowTheSelectedDay() {
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 393, isAccessibilitySize: false), .selectedDay, "iPhone portrait")
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 375, isAccessibilitySize: false), .selectedDay, "iPhone SE portrait")
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 0, isAccessibilitySize: false), .selectedDay)
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: .nan, isAccessibilitySize: false), .selectedDay)
    }

    func testWideWidthsShowSevenColumns() {
        XCTAssertEqual(CalendarLayoutMode.fullWeekMinimumWidth, 52 + 7 * 88)
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 668, isAccessibilitySize: false), .fullWeek)
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 667, isAccessibilitySize: false), .selectedDay)
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 1_024, isAccessibilitySize: false), .fullWeek, "iPad")
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 932, isAccessibilitySize: false), .fullWeek, "Large iPhone in landscape")
    }

    func testAccessibilityTextSizesAlwaysShowTheSelectedDay() {
        XCTAssertEqual(CalendarLayoutMode.resolve(availableWidth: 1_024, isAccessibilitySize: true), .selectedDay)
    }

    func testBlockDetailGrowsWithHeight() {
        XCTAssertEqual(BlockDetail.resolve(height: 20), .compact)
        XCTAssertEqual(BlockDetail.resolve(height: 39.9), .compact)
        XCTAssertEqual(BlockDetail.resolve(height: 40), .titleAndTime)
        XCTAssertEqual(BlockDetail.resolve(height: 50), .titleAndTime, "A 50-minute class at 60 points per hour shows title and time")
        XCTAssertEqual(BlockDetail.resolve(height: 72), .full)
        XCTAssertEqual(BlockDetail.resolve(height: 315), .full)
    }
}
