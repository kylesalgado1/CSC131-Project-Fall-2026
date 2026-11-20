import XCTest
@testable import WaitItOutUX

final class OccurrenceExpanderTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private let monday9 = TestFixtures.mondayNine
    /// Sun 2026-10-25 to Sun 2026-11-01 (exclusive), Pacific.
    private lazy var octoberWeek = calculator.week(containing: TestFixtures.fridayNoon)
    /// Sun 2026-11-01 to Sun 2026-11-08 (exclusive); contains the fall-back transition.
    private lazy var novemberWeek = calculator.nextWeek(after: octoberWeek)
    /// Mon/Wed/Fri 9:00 to 9:50, arrival 8:15, anchored Mon 2026-10-26.
    private lazy var mwf = TestFixtures.activity(title: "MWF", start: monday9, repeatWeekdays: [.monday, .wednesday, .friday])

    func testEmptyInputsProduceNothing() {
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [], in: octoberWeek.range), [])
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [mwf], in: monday9..<monday9), [])
    }

    func testOneTimeActivityInsideTheWeek() throws {
        let activity = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_376_000)) // Fri 2026-10-30 09:00 PDT
        let occurrences = OccurrenceExpander.occurrences(of: [activity], in: octoberWeek.range)
        XCTAssertEqual(occurrences.count, 1)
        let occurrence = try XCTUnwrap(occurrences.first)
        XCTAssertEqual(occurrence.id.rawValue, "\(activity.id.uuidString)@2026-10-30")
        XCTAssertEqual(occurrence.start, activity.start)
        XCTAssertEqual(occurrence.end, activity.end)
        XCTAssertEqual(occurrence.idealArrival, activity.idealArrival)
        XCTAssertEqual(occurrence.activity, activity)
        XCTAssertFalse(occurrence.isRecurring)
        XCTAssertEqual(occurrence.activityInterval, activity.start..<activity.end)
        XCTAssertEqual(occurrence.plannedInterval, activity.idealArrival..<activity.end)
    }

    func testOneTimeActivityOutsideTheWeekIsExcluded() {
        let nextMonday = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_638_800)) // Mon 2026-11-02 09:00 PST
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [nextMonday], in: octoberWeek.range), [])
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [nextMonday], in: novemberWeek.range).count, 1)
    }

    func testSaturdayAndSundayBoundaries() {
        let lateSaturday = TestFixtures.activity(start: TestFixtures.date(2026, 10, 31, 23, 30), end: TestFixtures.date(2026, 10, 31, 23, 59))
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [lateSaturday], in: octoberWeek.range).count, 1)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [lateSaturday], in: novemberWeek.range).count, 0)

        let sundayMidnight = TestFixtures.activity(start: TestFixtures.date(2026, 11, 1, 0, 0), end: TestFixtures.date(2026, 11, 1, 0, 30), arrival: TestFixtures.date(2026, 11, 1, 0, 0))
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [sundayMidnight], in: octoberWeek.range).count, 0, "The week end is exclusive")
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [sundayMidnight], in: novemberWeek.range).count, 1)

        let endsAtMidnight = TestFixtures.activity(start: TestFixtures.date(2026, 10, 31, 23, 0), end: TestFixtures.date(2026, 11, 1, 0, 0))
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [endsAtMidnight], in: octoberWeek.range).count, 1)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [endsAtMidnight], in: novemberWeek.range).count, 0, "Ending exactly on the boundary belongs to the earlier week only")
    }

    func testOvernightActivityAppearsOnceInEachWeekItTouches() throws {
        let overnight = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_512_800), end: Date(timeIntervalSince1970: 1_793_520_000)) // Sat 23:00 PDT to Sun 01:00 PDT
        let before = OccurrenceExpander.occurrences(of: [overnight], in: octoberWeek.range)
        let after = OccurrenceExpander.occurrences(of: [overnight], in: novemberWeek.range)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(before.first?.id, after.first?.id)
        XCTAssertEqual(before.first?.id.date.description, "2026-10-31")
        XCTAssertTrue(try XCTUnwrap(after.first).activityIntersects(novemberWeek.range))
        let both = OccurrenceExpander.occurrences(of: [overnight], in: octoberWeek.start..<novemberWeek.end)
        XCTAssertEqual(both.count, 1, "A range covering both weeks still yields the occurrence once")
    }

    func testArrivalOnThePreviousDayCountsAsIntersecting() throws {
        let earlySunday = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_518_200),   // Sun 2026-11-01 00:30 PDT
            end: Date(timeIntervalSince1970: 1_793_520_900),     // 01:15 PDT
            arrival: Date(timeIntervalSince1970: 1_793_515_500)  // Sat 2026-10-31 23:45 PDT
        )
        let inOctoberWeek = OccurrenceExpander.occurrences(of: [earlySunday], in: octoberWeek.range)
        XCTAssertEqual(inOctoberWeek.count, 1, "The planned time starts on Saturday night")
        let occurrence = try XCTUnwrap(inOctoberWeek.first)
        XCTAssertTrue(occurrence.intersects(octoberWeek.range))
        XCTAssertFalse(occurrence.activityIntersects(octoberWeek.range))
        XCTAssertEqual(occurrence.id.date.description, "2026-11-01", "Identity follows the activity's own start day")
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [earlySunday], in: novemberWeek.range).count, 1)
    }

    func testWeeklyMondayWednesdayFridayWithinOneWeek() {
        let occurrences = OccurrenceExpander.occurrences(of: [mwf], in: octoberWeek.range)
        XCTAssertEqual(occurrences.map(\.start), [
            Date(timeIntervalSince1970: 1_793_030_400), // Mon 09:00 PDT
            Date(timeIntervalSince1970: 1_793_203_200), // Wed 09:00 PDT
            Date(timeIntervalSince1970: 1_793_376_000)  // Fri 09:00 PDT
        ])
        XCTAssertEqual(occurrences.map { $0.end.timeIntervalSince($0.start) }, [3_000, 3_000, 3_000])
        XCTAssertEqual(occurrences.map { $0.start.timeIntervalSince($0.idealArrival) }, [2_700, 2_700, 2_700])
        XCTAssertEqual(occurrences.map(\.id.date.description), ["2026-10-26", "2026-10-28", "2026-10-30"])
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 3)
        XCTAssertTrue(occurrences.allSatisfy(\.isRecurring))
        XCTAssertEqual(occurrences.first?.start, mwf.start, "The first day is the stored activity itself")
    }

    func testRepeatsNeverStartBeforeTheActivitysFirstDay() {
        let previousWeek = calculator.previousWeek(before: octoberWeek)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [mwf], in: previousWeek.range), [])
        // Anchored on a Wednesday: the Monday of that same week has no occurrence.
        let wednesdayAnchor = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_793_203_200), repeatWeekdays: [.monday, .wednesday, .friday])
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [wednesdayAnchor], in: octoberWeek.range).map(\.id.date.description), ["2026-10-28", "2026-10-30"])
    }

    func testRepeatsAcrossMonthBoundaryAndFallBackKeepTheWallClockStart() {
        let occurrences = OccurrenceExpander.occurrences(of: [mwf], in: novemberWeek.range)
        XCTAssertEqual(occurrences.count, 3)
        XCTAssertEqual(occurrences.first?.start, Date(timeIntervalSince1970: 1_793_638_800), "Mon 2026-11-02 09:00 PST, 17:00 UTC")
        XCTAssertEqual(occurrences.first?.start.timeIntervalSince(monday9), 7 * 86_400 + 3_600, "One week plus the hour gained when clocks fell back")
        for occurrence in occurrences {
            XCTAssertEqual(WallTime.of(occurrence.start, in: TestFixtures.pacific), WallTime(hour: 9, minute: 0))
            XCTAssertEqual(WallTime.of(occurrence.end, in: TestFixtures.pacific), WallTime(hour: 9, minute: 50))
            XCTAssertEqual(WallTime.of(occurrence.idealArrival, in: TestFixtures.pacific), WallTime(hour: 8, minute: 15))
        }
        XCTAssertEqual(occurrences.map(\.id.date.description), ["2026-11-02", "2026-11-04", "2026-11-06"])
    }

    func testRepeatsAcrossTheYearBoundary() {
        let tth = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_127_600),   // Tue 2026-10-27 12:00 PDT
            end: Date(timeIntervalSince1970: 1_793_146_500),     // 17:15 PDT
            arrival: Date(timeIntervalSince1970: 1_793_124_900), // 11:15 PDT
            repeatWeekdays: [.tuesday, .thursday]
        )
        let newYearWeek = calculator.week(containing: TestFixtures.date(2026, 12, 31, 9))
        let occurrences = OccurrenceExpander.occurrences(of: [tth], in: newYearWeek.range)
        XCTAssertEqual(occurrences.map(\.start), [Date(timeIntervalSince1970: 1_798_574_400), Date(timeIntervalSince1970: 1_798_747_200)], "Tue Dec 29 and Thu Dec 31, 12:00 PST")
        XCTAssertEqual(occurrences.map(\.id.date.description), ["2026-12-29", "2026-12-31"])
        XCTAssertEqual(occurrences.map { $0.end.timeIntervalSince($0.start) }, [5.25 * 3_600, 5.25 * 3_600])
        let followingWeek = calculator.nextWeek(after: newYearWeek)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [tth], in: followingWeek.range).map(\.id.date.description), ["2027-01-05", "2027-01-07"])
    }

    func testWeeklyOvernightActivityIsNotDuplicatedAcrossTheFallBackWeek() {
        let saturdays = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_793_512_800), // Sat 2026-10-31 23:00 PDT
            end: Date(timeIntervalSince1970: 1_793_520_000),   // Sun 2026-11-01 01:00 PDT
            repeatWeekdays: [.saturday]
        )
        let occurrences = OccurrenceExpander.occurrences(of: [saturdays], in: novemberWeek.range)
        XCTAssertEqual(occurrences.map(\.id.date.description), ["2026-10-31", "2026-11-07"])
        XCTAssertEqual(occurrences.map(\.start), [Date(timeIntervalSince1970: 1_793_512_800), Date(timeIntervalSince1970: 1_794_121_200)], "The second start is 23:00 PST")
        XCTAssertEqual(occurrences.map { $0.end.timeIntervalSince($0.start) }, [7_200, 7_200], "Elapsed duration is preserved across the transition")
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 2)
    }

    func testSkippedStartTimeOnTheSpringForwardDayMovesToTheEndOfTheGap() {
        let sundays = TestFixtures.activity(
            start: Date(timeIntervalSince1970: 1_772_361_000), // Sun 2026-03-01 02:30 PST
            end: Date(timeIntervalSince1970: 1_772_361_000 + 1_800),
            arrival: Date(timeIntervalSince1970: 1_772_361_000 - 600),
            repeatWeekdays: [.sunday]
        )
        let transitionWeek = calculator.week(containing: TestFixtures.date(2026, 3, 8, 15))
        let onTransitionDay = OccurrenceExpander.occurrences(of: [sundays], in: transitionWeek.range)
        XCTAssertEqual(onTransitionDay.map(\.start), [Date(timeIntervalSince1970: 1_772_964_000)], "03:00 PDT, the first instant after the gap")
        XCTAssertEqual(onTransitionDay.first.map { $0.end.timeIntervalSince($0.start) }, 1_800)
        XCTAssertEqual(onTransitionDay.first.map { $0.start.timeIntervalSince($0.idealArrival) }, 600)
        let nextWeek = OccurrenceExpander.occurrences(of: [sundays], in: calculator.nextWeek(after: transitionWeek).range)
        XCTAssertEqual(nextWeek.map(\.start), [Date(timeIntervalSince1970: 1_773_567_000)], "Sun 2026-03-15 02:30 PDT")
    }

    func testRepeatedStartTimeOnTheFallBackDayUsesTheFirstOccurrence() {
        let sundays = TestFixtures.activity(start: Date(timeIntervalSince1970: 1_792_917_000), repeatWeekdays: [.sunday]) // Sun 2026-10-25 01:30 PDT
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [sundays], in: novemberWeek.range).map(\.start), [Date(timeIntervalSince1970: 1_793_521_800)], "01:30 PDT, the first of the two")
        let weekAfter = calculator.nextWeek(after: novemberWeek)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [sundays], in: weekAfter.range).map(\.start), [Date(timeIntervalSince1970: 1_794_130_200)], "01:30 PST")
    }

    func testOccurrenceIdentityIsStableAcrossDifferentRequests() {
        let weekOnly = OccurrenceExpander.occurrences(of: [mwf], in: novemberWeek.range)
        let fiveWeeks = OccurrenceExpander.occurrences(of: [mwf], in: octoberWeek.start..<calculator.week(octoberWeek, offsetBy: 5).start)
        XCTAssertEqual(fiveWeeks.count, 15)
        let overlap = fiveWeeks.filter { novemberWeek.range.contains($0.start) }
        XCTAssertEqual(overlap, weekOnly)
        XCTAssertEqual(Set(fiveWeeks.map(\.id)).count, 15)
        let rawValues = fiveWeeks.map(\.id.rawValue)
        XCTAssertEqual(rawValues.compactMap(OccurrenceID.init(rawValue:)), fiveWeeks.map(\.id), "Ids survive a text round trip")
    }

    func testOverlappingActivitiesAreAllReturnedInOrder() {
        let lecture = TestFixtures.activity(title: "Lecture", start: monday9, end: monday9.addingTimeInterval(2 * 3_600))
        let meeting = TestFixtures.activity(title: "Meeting", start: monday9.addingTimeInterval(1_800), end: monday9.addingTimeInterval(3_600))
        let sameStartLonger = TestFixtures.activity(title: "Alpha", start: monday9, end: monday9.addingTimeInterval(3 * 3_600))
        let occurrences = OccurrenceExpander.occurrences(of: [meeting, lecture, sameStartLonger, mwf], in: octoberWeek.range)
        XCTAssertEqual(occurrences.map(\.activity.title), ["MWF", "Lecture", "Alpha", "Meeting", "MWF", "MWF"])
    }

    func testInvalidInputsProduceNothingInsteadOfCrashing() {
        var unknownZone = mwf
        unknownZone.timeZoneIdentifier = "Mars/Olympus_Mons"
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [unknownZone], in: octoberWeek.range), [])
        var zeroLength = mwf
        zeroLength.end = zeroLength.start
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [zeroLength], in: octoberWeek.range), [])
        var noDays = mwf
        noDays.repeatWeekdays = []
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [noDays], in: octoberWeek.range), [])
        var arrivalAfterStart = mwf
        arrivalAfterStart.idealArrival = arrivalAfterStart.start.addingTimeInterval(60)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [arrivalAfterStart], in: octoberWeek.range), [])
        var nonFinite = mwf
        nonFinite.start = Date(timeIntervalSince1970: .nan)
        XCTAssertEqual(OccurrenceExpander.occurrences(of: [nonFinite], in: octoberWeek.range), [])
    }

    func testLongRequestsAreTrimmedToTheMaximumSpan() throws {
        let threeYears = octoberWeek.start..<octoberWeek.start.addingTimeInterval(3 * 366 * 86_400)
        let occurrences = OccurrenceExpander.occurrences(of: [mwf], in: threeYears)
        XCTAssertEqual(occurrences.count, 157, "Mon, Wed, Fri days from 2026-10-26 through 2027-10-25")
        XCTAssertEqual(occurrences.last?.id.date.description, "2027-10-25")
        XCTAssertLessThan(try XCTUnwrap(occurrences.last).start, octoberWeek.start.addingTimeInterval(OccurrenceExpander.maximumSpan))
    }

    func testMalformedOccurrenceIntervalsNeverInvert() {
        let occurrence = ActivityOccurrence(
            id: OccurrenceID(activityID: UUID(), date: LocalDate(dayNumber: 0)),
            activity: mwf,
            start: monday9,
            end: monday9.addingTimeInterval(-60),
            idealArrival: monday9.addingTimeInterval(60)
        )
        XCTAssertTrue(occurrence.activityInterval.isEmpty)
        XCTAssertEqual(occurrence.plannedInterval.lowerBound, monday9)
        XCTAssertFalse(occurrence.intersects(octoberWeek.range))
    }

    func testWeekIntervalDayRangesTileTheWeek() {
        let ranges = novemberWeek.dayRanges
        XCTAssertEqual(ranges.count, 7)
        XCTAssertEqual(ranges.first?.lowerBound, novemberWeek.start)
        XCTAssertEqual(ranges.last?.upperBound, novemberWeek.end)
        XCTAssertEqual(ranges[0].upperBound.timeIntervalSince(ranges[0].lowerBound), 25 * 3_600, "Fall-back Sunday lasts 25 hours")
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(earlier.upperBound, later.lowerBound)
        }
        let occurrencesByDay = ranges.map { day in OccurrenceExpander.occurrences(of: [mwf], in: novemberWeek.range).filter { $0.intersects(day) }.count }
        XCTAssertEqual(occurrencesByDay, [0, 1, 0, 1, 0, 1, 0])
    }
}
