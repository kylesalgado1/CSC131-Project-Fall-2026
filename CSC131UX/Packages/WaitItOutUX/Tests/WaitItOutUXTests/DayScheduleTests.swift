import XCTest
@testable import WaitItOutUX

final class DayScheduleTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var octoberWeek = calculator.week(containing: TestFixtures.fridayNoon)
    private lazy var novemberWeek = calculator.nextWeek(after: octoberWeek)
    private lazy var samples = SampleActivities.make(weekContaining: TestFixtures.fridayNoon, timeZone: TestFixtures.pacific, destination: TestFixtures.demoDestination)

    private func schedule(day: Range<Date>, activities: [Activity], hourHeight: CGFloat = 60) -> DaySchedule {
        let week = calculator.week(containing: day.lowerBound)
        let occurrences = OccurrenceExpander.occurrences(of: activities, in: week.range)
        return DaySchedule.make(day: day, occurrences: occurrences, layout: DayTimelineLayout(day: day, hourHeight: hourHeight))
    }

    func testEmptyDay() {
        let sunday = schedule(day: octoberWeek.dayRanges[0], activities: samples)
        XCTAssertTrue(sunday.isEmpty)
        XCTAssertEqual(sunday.blocks, [])
        XCTAssertEqual(sunday.arrivalMarkers, [])
        XCTAssertEqual(sunday.occurrences, [])
        XCTAssertEqual(sunday.suggestedScrollHour(currentTime: nil), 8, "Empty days open at 8 AM")
        XCTAssertTrue(schedule(day: octoberWeek.dayRanges[1], activities: []).isEmpty)
    }

    func testSampleMondayHasOneBlockAndAnArrivalMarkerAboveIt() throws {
        let monday = schedule(day: octoberWeek.dayRanges[1], activities: samples)
        XCTAssertEqual(monday.blocks.count, 1)
        XCTAssertEqual(monday.occurrences.count, 1)
        let block = try XCTUnwrap(monday.blocks.first)
        XCTAssertEqual(block.occurrence.activity.title, "Sample morning class")
        XCTAssertEqual(block.frame.minY, 540)
        XCTAssertEqual(block.frame.height, 50, "The block covers 9:00 to 9:50 only; the arrival lead does not stretch it")
        XCTAssertEqual(block.placement, .solo)
        let marker = try XCTUnwrap(monday.arrivalMarkers.first)
        XCTAssertEqual(marker.id, block.id)
        XCTAssertEqual(marker.offset, 495, "8:15 AM")
        XCTAssertEqual(marker.leaderEndOffset, 540, "The leader runs down to the block's top")
        XCTAssertFalse(marker.isForLaterDay)
        XCTAssertEqual(monday.arrivalOnlyMarkers, [])
        XCTAssertEqual(monday.suggestedScrollHour(currentTime: nil), 9, "Opens at the first block's hour")
        XCTAssertEqual(monday.suggestedScrollHour(currentTime: TestFixtures.fridayNoon), 9, "A current time on another day does not change that")
    }

    func testTodayScrollsToAnHourBeforeTheCurrentTime() {
        let friday = schedule(day: octoberWeek.dayRanges[5], activities: samples)
        XCTAssertEqual(friday.suggestedScrollHour(currentTime: TestFixtures.fridayNoon), 11)
        XCTAssertEqual(friday.suggestedScrollHour(currentTime: TestFixtures.date(2026, 10, 30, 0, 20)), 0)
    }

    func testOverlappingActivitiesShareColumnsWithoutHidingAny() throws {
        let friday = octoberWeek.dayRanges[5]
        let office = TestFixtures.activity(title: "Office hours", start: TestFixtures.date(2026, 10, 30, 9, 30), end: TestFixtures.date(2026, 10, 30, 10, 30))
        let seminar = TestFixtures.activity(title: "Seminar", start: TestFixtures.date(2026, 10, 30, 10, 0), end: TestFixtures.date(2026, 10, 30, 11, 30))
        let advising = TestFixtures.activity(title: "Advising", start: TestFixtures.date(2026, 10, 30, 10, 30), end: TestFixtures.date(2026, 10, 30, 11, 0))
        let day = schedule(day: friday, activities: [advising, seminar, office] + samples)
        XCTAssertEqual(day.blocks.map(\.occurrence.activity.title), ["Sample morning class", "Office hours", "Seminar", "Advising"], "Sorted by start")
        let byTitle = Dictionary(uniqueKeysWithValues: day.blocks.map { ($0.occurrence.activity.title, $0) })
        XCTAssertEqual(byTitle["Sample morning class"]?.placement, OverlapPlacement(column: 0, columnCount: 2), "The 9:00 to 9:50 class overlaps office hours from 9:30")
        XCTAssertEqual(byTitle["Office hours"]?.placement, OverlapPlacement(column: 1, columnCount: 2))
        XCTAssertEqual(byTitle["Seminar"]?.placement, OverlapPlacement(column: 0, columnCount: 2), "Seminar reuses the class column after 9:50")
        XCTAssertEqual(byTitle["Advising"]?.placement, OverlapPlacement(column: 1, columnCount: 2), "Advising reuses the office hours column after 10:30")
        XCTAssertEqual(day.arrivalMarkers.count, 4, "Every activity keeps its own arrival marker")
        let seminarMarker = try XCTUnwrap(day.arrivalMarkers.first { $0.occurrence.activity.title == "Seminar" })
        XCTAssertEqual(seminarMarker.placement, byTitle["Seminar"]?.placement, "Markers sit in their block's column")
        XCTAssertEqual(seminarMarker.offset, 555, "9:15 AM, forty-five minutes before 10:00")
    }

    func testOvernightActivityIsClippedOnBothDaysWithOneMarker() throws {
        let overnight = TestFixtures.activity(
            title: "Night session",
            start: Date(timeIntervalSince1970: 1_793_512_800),          // Sat 23:00 PDT
            end: Date(timeIntervalSince1970: 1_793_520_000),            // Sun 01:00 PDT
            arrival: Date(timeIntervalSince1970: 1_793_512_800 - 2_700) // Sat 22:15 PDT
        )
        let saturday = schedule(day: octoberWeek.dayRanges[6], activities: [overnight])
        let onSaturday = try XCTUnwrap(saturday.blocks.first)
        XCTAssertEqual(onSaturday.frame.minY, 1_380)
        XCTAssertEqual(onSaturday.frame.height, 60)
        XCTAssertTrue(onSaturday.frame.isClippedAtEnd)
        XCTAssertEqual(saturday.arrivalMarkers.count, 1)
        XCTAssertEqual(saturday.arrivalMarkers.first?.offset, 1_335)
        XCTAssertEqual(saturday.arrivalMarkers.first?.leaderEndOffset, 1_380)

        let sunday = schedule(day: novemberWeek.dayRanges[0], activities: [overnight])
        let onSunday = try XCTUnwrap(sunday.blocks.first)
        XCTAssertEqual(onSunday.id, onSaturday.id, "Same occurrence on both days")
        XCTAssertEqual(onSunday.frame.minY, 0)
        XCTAssertEqual(onSunday.frame.height, 60)
        XCTAssertTrue(onSunday.frame.isClippedAtStart)
        XCTAssertTrue(sunday.arrivalMarkers.isEmpty, "The arrival was on Saturday, so Sunday shows no marker")
    }

    func testArrivalOnThePreviousDayShowsAMarkerAloneWithALeaderToMidnight() throws {
        let earlySunday = TestFixtures.activity(
            title: "Early start",
            start: Date(timeIntervalSince1970: 1_793_518_200),   // Sun 00:30 PDT
            end: Date(timeIntervalSince1970: 1_793_520_900),     // Sun 01:15 PDT
            arrival: Date(timeIntervalSince1970: 1_793_515_500)  // Sat 23:45 PDT
        )
        let saturday = schedule(day: octoberWeek.dayRanges[6], activities: [earlySunday])
        XCTAssertTrue(saturday.blocks.isEmpty, "The activity itself is not on Saturday")
        XCTAssertFalse(saturday.isEmpty)
        XCTAssertEqual(saturday.occurrences.count, 1)
        let marker = try XCTUnwrap(saturday.arrivalOnlyMarkers.first)
        XCTAssertTrue(marker.isForLaterDay)
        XCTAssertEqual(marker.offset, 1_425)
        XCTAssertEqual(marker.leaderEndOffset, 1_440)
        XCTAssertEqual(marker.placement, .solo)

        let sunday = schedule(day: novemberWeek.dayRanges[0], activities: [earlySunday])
        XCTAssertEqual(sunday.blocks.count, 1)
        XCTAssertEqual(sunday.blocks.first?.frame.minY, 30)
        XCTAssertEqual(sunday.blocks.first?.frame.height, 45)
        XCTAssertTrue(sunday.arrivalMarkers.isEmpty)
    }

    func testArrivalEqualToStartHasNoMarker() {
        let noLead = TestFixtures.activity(start: TestFixtures.date(2026, 10, 30, 9), arrival: TestFixtures.date(2026, 10, 30, 9))
        let friday = schedule(day: octoberWeek.dayRanges[5], activities: [noLead])
        XCTAssertEqual(friday.blocks.count, 1)
        XCTAssertTrue(friday.arrivalMarkers.isEmpty)
    }

    func testLongActivityAndCrowdedDayAcrossTheFallBackTransition() throws {
        let sunday = novemberWeek.dayRanges[0]
        let allDay = TestFixtures.activity(title: "All day", start: sunday.lowerBound, end: sunday.upperBound, arrival: sunday.lowerBound)
        let night = TestFixtures.activity(title: "Late", start: Date(timeIntervalSince1970: 1_793_525_400), end: Date(timeIntervalSince1970: 1_793_525_400 + 1_800)) // 1:30 to 2:00 AM PST
        let day = schedule(day: sunday, activities: [allDay, night])
        XCTAssertEqual(day.layout.hourCount, 25)
        let full = try XCTUnwrap(day.blocks.first { $0.occurrence.activity.title == "All day" })
        XCTAssertEqual(full.frame.minY, 0)
        XCTAssertEqual(full.frame.height, 1_500, "A 25-hour day column is filled by a 25-hour activity")
        XCTAssertEqual(full.placement, OverlapPlacement(column: 0, columnCount: 2))
        let late = try XCTUnwrap(day.blocks.first { $0.occurrence.activity.title == "Late" })
        XCTAssertEqual(late.frame.minY, 150)
        XCTAssertEqual(late.frame.height, 44)
        XCTAssertEqual(late.placement, OverlapPlacement(column: 1, columnCount: 2))
    }

    func testLargeTextScalesPositionsWithTheRowHeight() throws {
        let monday = schedule(day: octoberWeek.dayRanges[1], activities: samples, hourHeight: 96)
        let block = try XCTUnwrap(monday.blocks.first)
        XCTAssertEqual(block.frame.minY, 864)
        XCTAssertEqual(block.frame.height, 80)
        XCTAssertEqual(monday.arrivalMarkers.first?.offset, 792)
        XCTAssertEqual(monday.layout.height, 2_304)
    }
}
