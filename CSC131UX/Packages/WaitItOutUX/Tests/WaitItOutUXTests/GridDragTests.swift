import CoreGraphics
import XCTest
@testable import WaitItOutUX

final class GridDragTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    /// Fri 2026-10-30, an ordinary 24-hour day. With 60 points per hour, offset 540 is 9:00 AM.
    private lazy var friday = calculator.week(containing: TestFixtures.fridayNoon).dayRanges[5]
    private lazy var layout = DayTimelineLayout(day: friday, hourHeight: 60)
    private lazy var grid = GridDrag(layout: layout, timeZone: TestFixtures.pacific)

    private func onFriday(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        TestFixtures.date(2026, 10, 30, hour, minute, second)
    }

    /// A draft of Fri 09:00 to 09:50 with ideal arrival 08:15, and its Friday occurrence.
    private func lectureDraftAndOccurrence() throws -> (ActivityDraft, ActivityOccurrence) {
        let lecture = TestFixtures.activity(start: onFriday(9, 0))
        let occurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: lecture, in: friday).first)
        return (ActivityDraft(editing: lecture), occurrence)
    }

    func testFixtureLayoutIsAnOrdinaryFriday() {
        XCTAssertEqual(friday.lowerBound, TestFixtures.date(2026, 10, 30, 0, 0))
        XCTAssertEqual(friday.upperBound, TestFixtures.date(2026, 10, 31, 0, 0))
        XCTAssertEqual(layout.offset(for: onFriday(9, 0)), 540)
        XCTAssertEqual(grid.snapInterval, 15 * 60)
    }

    // MARK: Snapping

    func testSnapRoundsToTheNearestQuarterHour() {
        XCTAssertEqual(grid.snap(onFriday(9, 7)), onFriday(9, 0))
        XCTAssertEqual(grid.snap(onFriday(9, 8)), onFriday(9, 15))
        XCTAssertEqual(grid.snap(onFriday(9, 7, 30)), onFriday(9, 15), "Exactly half way rounds away from zero")
        XCTAssertEqual(grid.snap(onFriday(9, 15)), onFriday(9, 15))
        XCTAssertEqual(grid.snap(onFriday(9, 0)), onFriday(9, 0))
    }

    func testIsIntentional() {
        XCTAssertFalse(GridDrag.isIntentional(9.9))
        XCTAssertTrue(GridDrag.isIntentional(10))
        XCTAssertTrue(GridDrag.isIntentional(-10))
        XCTAssertFalse(GridDrag.isIntentional(.nan))
        XCTAssertFalse(GridDrag.isIntentional(.infinity))
    }

    // MARK: Creation

    func testCreationIntervalSnapsBothEnds() {
        XCTAssertEqual(grid.creationInterval(fromOffset: 540, toOffset: 600), onFriday(9, 0)..<onFriday(10, 0))
    }

    func testCreationIntervalWorksUpward() {
        XCTAssertEqual(grid.creationInterval(fromOffset: 600, toOffset: 540), onFriday(9, 0)..<onFriday(10, 0))
    }

    func testTinyDragCreatesNothing() {
        XCTAssertNil(grid.creationInterval(fromOffset: 540, toOffset: 545))
        XCTAssertNil(grid.creationInterval(fromOffset: 540, toOffset: .nan))
    }

    func testShortCreationIsAtLeastOneSnapInterval() {
        XCTAssertEqual(grid.creationInterval(fromOffset: 540, toOffset: 552), onFriday(9, 0)..<onFriday(9, 15))
        // 8:56 and 9:07 both snap to 9:00, so the end is pushed one snap interval later.
        XCTAssertEqual(grid.creationInterval(fromOffset: 536, toOffset: 547), onFriday(9, 0)..<onFriday(9, 15))
    }

    func testCreationPastTheBottomEndsAtMidnight() throws {
        let interval = try XCTUnwrap(grid.creationInterval(fromOffset: 540, toOffset: 10_000))
        XCTAssertEqual(interval.lowerBound, onFriday(9, 0))
        XCTAssertEqual(interval.upperBound, layout.day.upperBound)
        XCTAssertEqual(interval.upperBound, TestFixtures.date(2026, 10, 31, 0, 0))
    }

    func testCreationNearTheBottomIsClampedInsideTheDay() {
        XCTAssertEqual(
            grid.creationInterval(fromOffset: 1_430, toOffset: 1_440),
            onFriday(23, 45)..<TestFixtures.date(2026, 10, 31, 0, 0)
        )
        // 23:55 snaps to midnight; the interval is pulled back so it still fits in the day.
        XCTAssertEqual(
            grid.creationInterval(fromOffset: 1_435, toOffset: 10_000),
            onFriday(23, 45)..<TestFixtures.date(2026, 10, 31, 0, 0)
        )
    }

    // MARK: Dragging blocks

    func testTinyTranslationLeavesTheDraftUnchanged() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()

        XCTAssertEqual(grid.draft(draft, dragging: occurrence, kind: .move, translation: 5), draft)
        XCTAssertEqual(grid.draft(draft, dragging: occurrence, kind: .resizeStart, translation: -9), draft)
        XCTAssertEqual(grid.draft(draft, dragging: occurrence, kind: .resizeEnd, translation: 9.9), draft)
    }

    func testMoveKeepsDurationAndArrivalLead() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let moved = grid.draft(draft, dragging: occurrence, kind: .move, translation: 30)

        XCTAssertEqual(moved.start, onFriday(9, 30))
        XCTAssertEqual(moved.end, onFriday(10, 20))
        XCTAssertEqual(moved.idealArrival, onFriday(8, 45))
    }

    func testMoveUpIsClampedToTheStartOfTheDay() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let moved = grid.draft(draft, dragging: occurrence, kind: .move, translation: -10_000)

        XCTAssertEqual(moved.start, layout.day.lowerBound)
        XCTAssertEqual(moved.start, onFriday(0, 0))
        XCTAssertEqual(moved.end, onFriday(0, 50))
        XCTAssertEqual(moved.idealArrival, TestFixtures.date(2026, 10, 29, 23, 15))
    }

    func testMoveDownIsClampedToTheLastSnapIntervalOfTheDay() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let moved = grid.draft(draft, dragging: occurrence, kind: .move, translation: 10_000)

        XCTAssertEqual(moved.start, onFriday(23, 45))
        XCTAssertEqual(moved.end, TestFixtures.date(2026, 10, 31, 0, 35), "The end may run past midnight")
        XCTAssertEqual(moved.idealArrival, onFriday(23, 0))
    }

    func testResizeEndMovesOnlyTheEnd() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeEnd, translation: 10)

        XCTAssertEqual(resized.start, onFriday(9, 0))
        XCTAssertEqual(resized.end, onFriday(10, 0))
        XCTAssertEqual(resized.idealArrival, onFriday(8, 15))
    }

    func testResizeEndKeepsOneSnapIntervalAfterTheStart() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeEnd, translation: -100)

        XCTAssertEqual(resized.start, onFriday(9, 0))
        XCTAssertEqual(resized.end, onFriday(9, 15))
        XCTAssertEqual(resized.idealArrival, onFriday(8, 15))
    }

    func testResizeEndToTheBottomReachesMidnight() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeEnd, translation: 10_000)

        XCTAssertEqual(resized.start, onFriday(9, 0))
        XCTAssertEqual(resized.end, layout.day.upperBound)
        XCTAssertEqual(resized.idealArrival, onFriday(8, 15))
        XCTAssertFalse(resized.endsOnLaterDay)
        XCTAssertTrue(resized.isValid)
    }

    func testResizeStartMovesTheStartAndTheArrival() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeStart, translation: -60)

        XCTAssertEqual(resized.start, onFriday(8, 0))
        XCTAssertEqual(resized.end, onFriday(9, 50))
        XCTAssertEqual(resized.idealArrival, onFriday(7, 15))
    }

    func testResizeStartKeepsOneSnapIntervalBeforeTheEnd() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeStart, translation: 100)

        XCTAssertEqual(resized.start, onFriday(9, 35))
        XCTAssertEqual(resized.end, onFriday(9, 50))
        XCTAssertEqual(resized.idealArrival, onFriday(8, 50))
    }

    func testOccurrenceThatStartedTheDayBeforeCannotBeMovedHere() throws {
        let overnight = TestFixtures.activity(
            start: TestFixtures.date(2026, 10, 29, 23, 0),
            end: onFriday(1, 0)
        )
        let occurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: overnight, in: friday).first)
        let draft = ActivityDraft(editing: overnight)

        XCTAssertNil(grid.movedStart(of: occurrence, translation: 60))
        XCTAssertNil(grid.resizedStart(of: occurrence, translation: 60))
        XCTAssertEqual(grid.draft(draft, dragging: occurrence, kind: .move, translation: 60), draft)
        XCTAssertEqual(grid.draft(draft, dragging: occurrence, kind: .resizeStart, translation: 60), draft)

        // Its end is in this column, so the bottom handle still works.
        XCTAssertEqual(grid.resizedEnd(of: occurrence, translation: 60), onFriday(2, 0))
        let resized = grid.draft(draft, dragging: occurrence, kind: .resizeEnd, translation: 60)
        XCTAssertEqual(resized.start, TestFixtures.date(2026, 10, 29, 23, 0))
        XCTAssertEqual(resized.end, onFriday(2, 0))
    }

    func testFallBackDaySnapsOnTheWallClock() {
        let fallBackDay = TestFixtures.date(2026, 11, 1, 0, 0)..<TestFixtures.date(2026, 11, 2, 0, 0)
        let fallBackLayout = DayTimelineLayout(day: fallBackDay, hourHeight: 60)
        let fallBackGrid = GridDrag(layout: fallBackLayout, timeZone: TestFixtures.pacific)
        XCTAssertEqual(fallBackLayout.hourCount, 25)
        XCTAssertEqual(fallBackLayout.dayLength, 90_000)

        // 1:37 AM PST, the second 1 AM hour, is 09:37 UTC.
        let secondOneThirtySeven = Date(timeIntervalSince1970: 1_793_525_820)
        XCTAssertEqual(secondOneThirtySeven, TestFixtures.date(2026, 11, 1, 9, 37, in: TestFixtures.utc))
        // 1:30 AM PST is 09:30 UTC.
        let secondOneThirty = Date(timeIntervalSince1970: 1_793_525_400)

        let snapped = fallBackGrid.snap(secondOneThirtySeven)
        XCTAssertEqual(snapped, secondOneThirty)
        XCTAssertEqual(TestFixtures.pacific.secondsFromGMT(for: snapped), -8 * 3_600, "Stays in PST")

        // 1:37 AM PST is 157 elapsed minutes after midnight, so 157 points down the column.
        XCTAssertEqual(fallBackGrid.snappedDate(atOffset: 157), secondOneThirty)

        // 1:37 AM PDT, the first 1 AM hour, is 08:37 UTC and snaps to 1:30 AM PDT, 08:30 UTC.
        XCTAssertEqual(fallBackGrid.snap(Date(timeIntervalSince1970: 1_793_522_220)), Date(timeIntervalSince1970: 1_793_521_800))
    }

    // MARK: Draft preview

    func testDraftPreviewIsEmptyWithoutAScheduleChange() throws {
        XCTAssertTrue(DraftPreview.originalFrames(for: nil, layout: layout).isEmpty)

        let fridayDate = try XCTUnwrap(LocalDate(year: 2026, month: 10, day: 30))
        let newDraft = ActivityDraft.newActivity(
            on: fridayDate,
            now: TestFixtures.fridayNoon,
            timeZone: TestFixtures.pacific,
            destination: TestFixtures.demoDestination
        )
        XCTAssertTrue(DraftPreview.originalFrames(for: newDraft, layout: layout).isEmpty)

        let (draft, _) = try lectureDraftAndOccurrence()
        XCTAssertTrue(DraftPreview.originalFrames(for: draft, layout: layout).isEmpty)

        var renamed = draft
        renamed.title = "Renamed lecture"
        XCTAssertTrue(renamed.hasChanges)
        XCTAssertFalse(renamed.changesSchedule)
        XCTAssertTrue(DraftPreview.originalFrames(for: renamed, layout: layout).isEmpty)
    }

    func testDraftPreviewShowsTheStoredPositionOfAMovedActivity() throws {
        let (draft, occurrence) = try lectureDraftAndOccurrence()
        let moved = grid.draft(draft, dragging: occurrence, kind: .move, translation: 120)
        XCTAssertEqual(moved.start, onFriday(11, 0))

        let frames = DraftPreview.originalFrames(for: moved, layout: layout)
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.minY, 540, accuracy: 0.001)
        XCTAssertEqual(frame.height, 50, accuracy: 0.001)
        XCTAssertEqual(frame.visibleInterval, onFriday(9, 0)..<onFriday(9, 50))
        XCTAssertFalse(frame.isClippedAtStart)
        XCTAssertFalse(frame.isClippedAtEnd)
    }
}
