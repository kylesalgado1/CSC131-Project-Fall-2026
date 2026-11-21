import XCTest
@testable import WaitItOutUX

final class OverlapLayoutTests: XCTestCase {
    private func item(_ id: String, _ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> OverlapLayout.Item<String> {
        OverlapLayout.Item(id: id, interval: TestFixtures.date(2026, 10, 30, startHour, startMinute)..<TestFixtures.date(2026, 10, 30, endHour, endMinute))
    }

    func testEmptyInputGivesNoPlacements() {
        XCTAssertTrue(OverlapLayout.placements(for: [OverlapLayout.Item<String>]()).isEmpty)
    }

    func testNonOverlappingItemsEachTakeTheFullWidth() {
        let placements = OverlapLayout.placements(for: [item("a", 9, 0, 9, 50), item("b", 12, 0, 17, 15)])
        XCTAssertEqual(placements["a"], .solo)
        XCTAssertEqual(placements["b"], .solo)
        XCTAssertEqual(OverlapPlacement.solo.widthFraction, 1)
        XCTAssertEqual(OverlapPlacement.solo.leadingFraction, 0)
    }

    func testTouchingItemsDoNotOverlap() {
        let placements = OverlapLayout.placements(for: [item("a", 9, 0, 10, 0), item("b", 10, 0, 11, 0)])
        XCTAssertEqual(placements["a"], .solo)
        XCTAssertEqual(placements["b"], .solo)
    }

    func testTwoOverlappingItemsShareTheWidth() {
        let placements = OverlapLayout.placements(for: [item("b", 9, 30, 10, 30), item("a", 9, 0, 10, 0)])
        XCTAssertEqual(placements["a"], OverlapPlacement(column: 0, columnCount: 2), "Earlier start takes the first column regardless of input order")
        XCTAssertEqual(placements["b"], OverlapPlacement(column: 1, columnCount: 2))
        XCTAssertEqual(placements["b"]?.leadingFraction, 0.5)
        XCTAssertEqual(placements["b"]?.widthFraction, 0.5)
    }

    func testChainedOverlapReusesAFreedColumn() {
        // Office hours 9:30-10:30, seminar 10:00-11:30, advising 10:30-11:00: advising does not
        // overlap office hours, so it reuses column 0 and the cluster needs only two columns.
        let placements = OverlapLayout.placements(for: [item("office", 9, 30, 10, 30), item("seminar", 10, 0, 11, 30), item("advising", 10, 30, 11, 0)])
        XCTAssertEqual(placements["office"], OverlapPlacement(column: 0, columnCount: 2))
        XCTAssertEqual(placements["seminar"], OverlapPlacement(column: 1, columnCount: 2))
        XCTAssertEqual(placements["advising"], OverlapPlacement(column: 0, columnCount: 2))
    }

    func testThreeSimultaneousItemsNeedThreeColumnsAndNoneIsHidden() {
        let placements = OverlapLayout.placements(for: [item("a", 9, 0, 10, 0), item("b", 9, 0, 10, 0), item("c", 9, 0, 10, 0)])
        XCTAssertEqual(placements.count, 3)
        XCTAssertEqual(Set(placements.values.map(\.column)), [0, 1, 2])
        XCTAssertTrue(placements.values.allSatisfy { $0.columnCount == 3 })
        XCTAssertEqual(placements["a"]?.column, 0, "Identical intervals keep their input order")
        XCTAssertEqual(placements["c"]?.column, 2)
    }

    func testSeparateClustersAreLaidOutIndependently() {
        let placements = OverlapLayout.placements(for: [item("a", 9, 0, 10, 0), item("b", 9, 30, 10, 30), item("c", 13, 0, 14, 0)])
        XCTAssertEqual(placements["a"]?.columnCount, 2)
        XCTAssertEqual(placements["b"]?.columnCount, 2)
        XCTAssertEqual(placements["c"], .solo, "The afternoon item is not squeezed by the morning overlap")
    }

    func testLongItemSpanningSeveralShortOnesKeepsOneColumn() {
        let placements = OverlapLayout.placements(for: [item("lab", 12, 0, 17, 15), item("x", 13, 0, 13, 15), item("y", 15, 0, 15, 30)])
        XCTAssertEqual(placements["lab"], OverlapPlacement(column: 0, columnCount: 2))
        XCTAssertEqual(placements["x"], OverlapPlacement(column: 1, columnCount: 2))
        XCTAssertEqual(placements["y"], OverlapPlacement(column: 1, columnCount: 2), "The short items reuse the second column after each other")
    }

    func testZeroLengthItemStillGetsAColumn() {
        let point = TestFixtures.date(2026, 10, 30, 9, 30)
        let placements = OverlapLayout.placements(for: [item("a", 9, 0, 10, 0), OverlapLayout.Item(id: "p", interval: point..<point)])
        XCTAssertEqual(placements["p"], OverlapPlacement(column: 1, columnCount: 2))
    }

    func testPlacementNormalizesColumnCount() {
        XCTAssertEqual(OverlapPlacement(column: 0, columnCount: 0).columnCount, 1)
    }
}
