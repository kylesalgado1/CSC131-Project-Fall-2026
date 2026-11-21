import XCTest
@testable import WaitItOutUX

/// Step 0005: which saved occurrences get a leave-home calculation (those not over yet whose
/// planned time, ideal arrival through end, begins within seven days of elapsed time from now)
/// and which one the Map plans as the next trip.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. Clocks fall back on Sun 2026-11-01, so the
/// seven-day window ends Fri 2026-11-06 at 11:00 AM PST, not at noon.
final class DepartureHorizonTests: XCTestCase {
    private let now = TestFixtures.fridayNoon
    /// Mon/Wed/Fri 9:00 to 9:50, ideal arrival 8:15, first occurrence Mon 2026-10-26.
    private lazy var mwf = TestFixtures.activity(title: "MWF", start: TestFixtures.mondayNine, repeatWeekdays: [.monday, .wednesday, .friday])

    private func localDate(_ year: Int, _ month: Int, _ day: Int) throws -> LocalDate {
        try XCTUnwrap(LocalDate(year: year, month: month, day: day))
    }

    /// The single occurrence of a one-time activity, built by the expander.
    private func onlyOccurrence(of activity: Activity) throws -> ActivityOccurrence {
        let occurrences = OccurrenceExpander.occurrences(of: activity, in: activity.idealArrival..<activity.end)
        XCTAssertEqual(occurrences.count, 1)
        return try XCTUnwrap(occurrences.first)
    }

    // MARK: Window

    func testLookaheadIsSevenDaysOfElapsedTime() {
        XCTAssertEqual(DepartureHorizon.lookaheadDays, 7)
        XCTAssertEqual(DepartureHorizon.lookahead, 7 * 24 * 3_600)
        let window = DepartureHorizon.window(at: now)
        XCTAssertEqual(window, now..<now.addingTimeInterval(7 * 24 * 3_600))
        XCTAssertEqual(window.lowerBound, now)
        XCTAssertEqual(window.upperBound, TestFixtures.date(2026, 11, 6, 11, 0), "The hour gained at fall back moves the clock-face end to 11:00 AM")
    }

    // MARK: Upcoming occurrences

    func testUpcomingOccurrencesSkipFinishedOnesAndReachSevenDaysAhead() throws {
        let series = mwf
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [series], at: now)
        let monday = try localDate(2026, 11, 2)
        let wednesday = try localDate(2026, 11, 4)
        let friday = try localDate(2026, 11, 6)
        XCTAssertEqual(upcoming.map(\.id.date), [monday, wednesday, friday], "Fri Oct 30 ended at 9:50 AM; Fri Nov 6 at 9:00 AM is within seven days")
        XCTAssertEqual(upcoming.map(\.id.date.description), ["2026-11-02", "2026-11-04", "2026-11-06"])
        XCTAssertFalse(upcoming.map(\.id.date.description).contains("2026-10-30"))
        XCTAssertTrue(upcoming.allSatisfy { $0.activity.id == series.id })
        XCTAssertTrue(upcoming.allSatisfy { $0.end > now }, "Nothing that is already over")
        XCTAssertTrue(upcoming.allSatisfy { $0.idealArrival >= now })
        XCTAssertEqual(upcoming.map(\.idealArrival), upcoming.map(\.idealArrival).sorted(), "Ordered by ideal arrival")
    }

    func testInProgressOccurrenceStaysInTheHorizon() throws {
        let series = mwf
        let nineTwenty = TestFixtures.date(2026, 10, 30, 9, 20)
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [series], at: nineTwenty)
        XCTAssertEqual(
            upcoming.map(\.id.date.description),
            ["2026-10-30", "2026-11-02", "2026-11-04", "2026-11-06"],
            "Fri Nov 6 arrives at 8:15 AM PST, just before the window ends at 8:20 AM PST"
        )
        let inProgress = try XCTUnwrap(upcoming.first)
        XCTAssertEqual(inProgress.id.date, try localDate(2026, 10, 30))
        XCTAssertLessThan(inProgress.start, nineTwenty)
        XCTAssertGreaterThan(inProgress.end, nineTwenty)
        XCTAssertTrue(DepartureHorizon.covers(inProgress, at: nineTwenty))
    }

    func testFinishedOccurrencesAreExcluded() throws {
        let morning = TestFixtures.activity(title: "Morning", start: TestFixtures.date(2026, 10, 30, 9, 0))
        let endsAtNoon = TestFixtures.activity(title: "Ends at noon", start: TestFixtures.date(2026, 10, 30, 11, 0), end: now)
        XCTAssertTrue(DepartureHorizon.upcomingOccurrences(of: [morning, endsAtNoon], at: now).isEmpty)
        XCTAssertFalse(DepartureHorizon.covers(try onlyOccurrence(of: morning), at: now))
        XCTAssertFalse(DepartureHorizon.covers(try onlyOccurrence(of: endsAtNoon), at: now), "Ending exactly now counts as over")
    }

    func testOccurrencesBeyondSevenDaysAreExcluded() throws {
        let tomorrow = TestFixtures.activity(title: "Tomorrow", start: TestFixtures.date(2026, 10, 31, 10, 0))
        let eightDaysAhead = TestFixtures.activity(title: "Eight days ahead", start: TestFixtures.date(2026, 11, 7, 12, 0))
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [eightDaysAhead, tomorrow], at: now)
        XCTAssertEqual(upcoming.map(\.activity.id), [tomorrow.id])
        XCTAssertTrue(DepartureHorizon.covers(try onlyOccurrence(of: tomorrow), at: now))
        XCTAssertFalse(DepartureHorizon.covers(try onlyOccurrence(of: eightDaysAhead), at: now))
    }

    func testHorizonEdgeIsMeasuredAtTheIdealArrival() throws {
        let windowEnd = DepartureHorizon.window(at: now).upperBound
        let arrivesJustInside = TestFixtures.activity(
            title: "Arrives inside",
            start: TestFixtures.date(2026, 11, 6, 11, 30),
            arrival: TestFixtures.date(2026, 11, 6, 10, 59)
        )
        let arrivesAtTheEdge = TestFixtures.activity(
            title: "Arrives at the edge",
            start: TestFixtures.date(2026, 11, 6, 11, 30),
            arrival: windowEnd
        )
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [arrivesAtTheEdge, arrivesJustInside], at: now)
        XCTAssertEqual(upcoming.map(\.activity.id), [arrivesJustInside.id], "Planned time starts at the ideal arrival, and the window end is exclusive")
        XCTAssertTrue(DepartureHorizon.covers(try onlyOccurrence(of: arrivesJustInside), at: now))
        XCTAssertFalse(DepartureHorizon.covers(try onlyOccurrence(of: arrivesAtTheEdge), at: now))
    }

    func testNoActivitiesOrANonfiniteNowGiveNothing() {
        XCTAssertTrue(DepartureHorizon.upcomingOccurrences(of: [], at: now).isEmpty)
        XCTAssertTrue(DepartureHorizon.upcomingOccurrences(of: [mwf], at: Date(timeIntervalSinceReferenceDate: .nan)).isEmpty)
        XCTAssertNil(DepartureHorizon.nextTrip(in: [], at: now))
    }

    // MARK: Next trip

    func testNextTripIsTheFirstOccurrenceThatHasNotStarted() throws {
        let series = mwf
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [series], at: now)
        let next = try XCTUnwrap(DepartureHorizon.nextTrip(in: upcoming, at: now))
        XCTAssertEqual(next.id.date, try localDate(2026, 11, 2))
        XCTAssertGreaterThan(next.start, now)
        XCTAssertEqual(DepartureHorizon.nextTrip(in: Array(upcoming.reversed()), at: now), next, "Input order does not matter")
    }

    func testNextTripKeepsAnOccurrenceWhoseArrivalHasPassedButHasNotStarted() throws {
        let series = mwf
        let eightThirty = TestFixtures.date(2026, 10, 30, 8, 30)
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [series], at: eightThirty)
        XCTAssertEqual(upcoming.map(\.id.date.description), ["2026-10-30", "2026-11-02", "2026-11-04"])
        let next = try XCTUnwrap(DepartureHorizon.nextTrip(in: upcoming, at: eightThirty))
        XCTAssertEqual(next.id.date, try localDate(2026, 10, 30))
        XCTAssertLessThan(next.idealArrival, eightThirty, "The arrival target has passed")
        XCTAssertGreaterThan(next.start, eightThirty, "The activity itself has not started")
    }

    func testNextTripSkipsAnOccurrenceThatHasStarted() throws {
        let series = mwf
        let nineTwenty = TestFixtures.date(2026, 10, 30, 9, 20)
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [series], at: nineTwenty)
        let next = try XCTUnwrap(DepartureHorizon.nextTrip(in: upcoming, at: nineTwenty))
        XCTAssertEqual(next.id.date, try localDate(2026, 11, 2))
        let inProgress = try XCTUnwrap(upcoming.first)
        XCTAssertNil(DepartureHorizon.nextTrip(in: [inProgress], at: nineTwenty), "Nothing left that has not started")

        let nine = TestFixtures.date(2026, 10, 30, 9, 0)
        let atStart = DepartureHorizon.upcomingOccurrences(of: [series], at: nine)
        XCTAssertEqual(atStart.first?.id.date, try localDate(2026, 10, 30))
        XCTAssertEqual(DepartureHorizon.nextTrip(in: atStart, at: nine)?.id.date, try localDate(2026, 11, 2), "Starting exactly now counts as started")
    }

    func testNextTripPrefersTheEarlierIdealArrivalOverTheEarlierStart() throws {
        let arrivesFirst = TestFixtures.activity(
            title: "Arrives first",
            start: TestFixtures.date(2026, 11, 2, 10, 0),
            arrival: TestFixtures.date(2026, 11, 2, 8, 0)
        )
        let startsFirst = TestFixtures.activity(
            title: "Starts first",
            start: TestFixtures.date(2026, 11, 2, 9, 0),
            arrival: TestFixtures.date(2026, 11, 2, 8, 30)
        )
        let window = DepartureHorizon.window(at: now)
        XCTAssertEqual(
            OccurrenceExpander.occurrences(of: [arrivesFirst, startsFirst], in: window).map(\.activity.title),
            ["Starts first", "Arrives first"],
            "The expander orders by start"
        )
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [startsFirst, arrivesFirst], at: now)
        XCTAssertEqual(upcoming.map(\.activity.title), ["Arrives first", "Starts first"], "The horizon orders by ideal arrival")
        let next = try XCTUnwrap(DepartureHorizon.nextTrip(in: Array(upcoming.reversed()), at: now))
        XCTAssertEqual(next.activity.id, arrivesFirst.id)
    }

    func testEqualIdealArrivalsAreOrderedByStart() {
        let laterStart = TestFixtures.activity(
            title: "Later start",
            start: TestFixtures.date(2026, 11, 2, 9, 0),
            arrival: TestFixtures.date(2026, 11, 2, 8, 15)
        )
        let earlierStart = TestFixtures.activity(
            title: "Earlier start",
            start: TestFixtures.date(2026, 11, 2, 8, 45),
            arrival: TestFixtures.date(2026, 11, 2, 8, 15)
        )
        let upcoming = DepartureHorizon.upcomingOccurrences(of: [laterStart, earlierStart], at: now)
        XCTAssertEqual(upcoming.map(\.activity.title), ["Earlier start", "Later start"])
        XCTAssertEqual(DepartureHorizon.nextTrip(in: upcoming, at: now)?.activity.id, earlierStart.id)
    }
}
