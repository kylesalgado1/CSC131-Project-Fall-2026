import XCTest
@testable import WaitItOutUX

/// Step 0005: leave home = ideal arrival - travel time. Covers the formula itself, midnight
/// and daylight-saving trips, validation of provider estimates, timing relative to now, the
/// mapping from provider answers to departure states, and which states Try Again can change
/// (step 0006: only failures; a refreshing state keeps its earlier calculation out of date).
///
/// Wall-clock expectations are read back through Foundation's own Pacific calendar, not the
/// package's resolver, so the two cannot agree on a shared mistake.
final class DepartureCalculatorTests: XCTestCase {
    private let pacific = TestFixtures.pacific
    /// Mon 2026-10-26 8:15 AM PDT, the ideal arrival of a 9:00 AM lecture.
    private let eightFifteen = TestFixtures.date(2026, 10, 26, 8, 15)
    /// Mon 2026-10-26 7:15 AM PDT.
    private let sevenFifteen = TestFixtures.date(2026, 10, 26, 7, 15)
    private let pacificCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestFixtures.pacific
        return calendar
    }()

    /// Month, day, hour, and minute on a Pacific wall clock; empty for `nil`.
    private func pacificReading(_ date: Date?) -> [Int] {
        guard let date else { return [] }
        let parts = pacificCalendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return [parts.month ?? -1, parts.day ?? -1, parts.hour ?? -1, parts.minute ?? -1]
    }

    /// The calculation for `arrival` with `minutes` of travel, validated the way the model does it.
    private func departure(arrivingAt arrival: Date, minutes: Double = 60) throws -> DepartureCalculation {
        try DepartureCalculation.make(idealArrival: arrival, estimate: testEstimate(minutes: minutes)).get()
    }

    private func makeRequest(arriveBy arrival: Date = TestFixtures.date(2026, 10, 26, 8, 15), to destination: Destination = TestFixtures.demoDestination) throws -> CommuteRequest {
        let day = try XCTUnwrap(LocalDate(year: 2026, month: 10, day: 26))
        return CommuteRequest(
            occurrenceID: OccurrenceID(activityID: UUID(), date: day),
            origin: CommutePlaces.sample.home,
            destination: destination,
            arriveBy: arrival
        )
    }

    // MARK: The formula

    func testEightFifteenArrivalWithSixtyMinutesLeavesAtSevenFifteen() throws {
        XCTAssertEqual(eightFifteen, Date(timeIntervalSince1970: 1_793_027_700))
        let leave = try XCTUnwrap(DepartureCalculator.leaveHome(idealArrival: eightFifteen, travelTime: .testDefault))
        XCTAssertEqual(leave, sevenFifteen)
        XCTAssertEqual(leave, Date(timeIntervalSince1970: 1_793_024_100))
        XCTAssertEqual(pacificReading(leave), [10, 26, 7, 15])
        XCTAssertEqual(eightFifteen.timeIntervalSince(leave), 3_600)
    }

    func testElevenFifteenArrivalWithSixtyMinutesLeavesAtTenFifteen() throws {
        let arrival = TestFixtures.date(2026, 10, 27, 11, 15)
        let leave = try XCTUnwrap(DepartureCalculator.leaveHome(idealArrival: arrival, travelTime: .testDefault))
        XCTAssertEqual(leave, TestFixtures.date(2026, 10, 27, 10, 15))
        XCTAssertEqual(pacificReading(leave), [10, 27, 10, 15])

        // The same trip a week later, on standard time: Tue 2026-11-03.
        let novemberArrival = Date(timeIntervalSince1970: 1_793_733_300)
        XCTAssertEqual(pacificReading(novemberArrival), [11, 3, 11, 15])
        let novemberLeave = DepartureCalculator.leaveHome(idealArrival: novemberArrival, travelTime: .testDefault)
        XCTAssertEqual(novemberLeave, Date(timeIntervalSince1970: 1_793_729_700))
        XCTAssertEqual(pacificReading(novemberLeave), [11, 3, 10, 15])
    }

    func testChangingTheTravelTimeMovesTheLeaveHomeTime() throws {
        let cases: [(minutes: Int, leave: Date, reading: [Int])] = [
            (45, TestFixtures.date(2026, 10, 26, 7, 30), [10, 26, 7, 30]),
            (90, TestFixtures.date(2026, 10, 26, 6, 45), [10, 26, 6, 45]),
            (1, TestFixtures.date(2026, 10, 26, 8, 14), [10, 26, 8, 14]),
            (60, TestFixtures.date(2026, 10, 26, 7, 15), [10, 26, 7, 15]),
            (720, TestFixtures.date(2026, 10, 25, 20, 15), [10, 25, 20, 15])
        ]
        for (minutes, expected, reading) in cases {
            let travelTime = try CommuteDuration.minutes(minutes)
            let leave = DepartureCalculator.leaveHome(idealArrival: eightFifteen, travelTime: travelTime)
            XCTAssertEqual(leave, expected, "\(minutes) minutes")
            XCTAssertEqual(pacificReading(leave), reading, "\(minutes) minutes")
            XCTAssertEqual(leave, eightFifteen.addingTimeInterval(-TimeInterval(minutes) * 60), "\(minutes) minutes")
        }
    }

    func testNonfiniteArrivalHasNoLeaveHomeTime() {
        XCTAssertNil(DepartureCalculator.leaveHome(idealArrival: Date(timeIntervalSinceReferenceDate: .nan), travelTime: .testDefault))
        XCTAssertNil(DepartureCalculator.leaveHome(idealArrival: Date(timeIntervalSinceReferenceDate: .infinity), travelTime: .testDefault))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: Date(timeIntervalSinceReferenceDate: .nan), estimate: testEstimate(minutes: 60)), .failure(.arrival))
    }

    // MARK: Midnight

    func testArrivalJustAfterMidnightLeavesTheEveningBefore() throws {
        let calculation = try departure(arrivingAt: TestFixtures.date(2026, 10, 27, 0, 30))
        XCTAssertEqual(calculation.leaveHome, TestFixtures.date(2026, 10, 26, 23, 30))
        XCTAssertEqual(pacificReading(calculation.leaveHome), [10, 26, 23, 30])
        XCTAssertTrue(calculation.leavesOnEarlierDay(in: pacific))
        XCTAssertFalse(calculation.leavesOnEarlierDay(in: TestFixtures.utc), "In UTC both instants fall on Oct 27")
        XCTAssertFalse(calculation.crossesClockChange(in: pacific))
    }

    func testMidnightArrivalLeavesAtElevenTheNightBefore() throws {
        let calculation = try departure(arrivingAt: TestFixtures.date(2026, 10, 1, 0, 0))
        XCTAssertEqual(calculation.leaveHome, TestFixtures.date(2026, 9, 30, 23, 0))
        XCTAssertEqual(pacificReading(calculation.leaveHome), [9, 30, 23, 0])
        XCTAssertTrue(calculation.leavesOnEarlierDay(in: pacific))
    }

    func testTripsWithinOneDayDoNotLeaveOnAnEarlierDay() throws {
        let morning = try departure(arrivingAt: eightFifteen)
        XCTAssertEqual(morning.leaveHome, sevenFifteen)
        XCTAssertFalse(morning.leavesOnEarlierDay(in: pacific))
        XCTAssertFalse(morning.crossesClockChange(in: pacific))

        let leavesAtMidnight = try departure(arrivingAt: TestFixtures.date(2026, 10, 27, 1, 0))
        XCTAssertEqual(leavesAtMidnight.leaveHome, TestFixtures.date(2026, 10, 27, 0, 0))
        XCTAssertFalse(leavesAtMidnight.leavesOnEarlierDay(in: pacific), "Midnight already belongs to the arrival day")
    }

    // MARK: Daylight saving

    func testFallBackTripAfterTheRepeatedHourKeepsElapsedTime() throws {
        let arrival = Date(timeIntervalSince1970: 1_793_529_000) // Sun 2026-11-01 02:30 PST
        XCTAssertEqual(pacificReading(arrival), [11, 1, 2, 30])
        let calculation = try departure(arrivingAt: arrival)
        XCTAssertEqual(calculation.leaveHome, Date(timeIntervalSince1970: 1_793_525_400), "01:30 PST, the second 1:30 AM")
        XCTAssertEqual(pacificReading(calculation.leaveHome), [11, 1, 1, 30])
        XCTAssertEqual(pacific.secondsFromGMT(for: calculation.leaveHome), -8 * 3_600)
        XCTAssertFalse(calculation.crossesClockChange(in: pacific))
        XCTAssertFalse(calculation.leavesOnEarlierDay(in: pacific))
    }

    func testFallBackTripAcrossTheTransitionLeavesAtTheFirstOneThirty() throws {
        let arrival = Date(timeIntervalSince1970: 1_793_525_400) // Sun 2026-11-01 01:30 PST, the second 1:30 AM
        let calculation = try departure(arrivingAt: arrival)
        XCTAssertEqual(calculation.leaveHome, Date(timeIntervalSince1970: 1_793_521_800), "01:30 PDT, the first 1:30 AM")
        XCTAssertEqual(arrival.timeIntervalSince(calculation.leaveHome), 3_600)
        XCTAssertEqual(pacificReading(calculation.leaveHome), [11, 1, 1, 30])
        XCTAssertEqual(pacificReading(arrival), [11, 1, 1, 30], "Both ends of the trip read 1:30 AM")
        XCTAssertEqual(pacific.secondsFromGMT(for: calculation.leaveHome), -7 * 3_600)
        XCTAssertEqual(pacific.secondsFromGMT(for: arrival), -8 * 3_600)
        XCTAssertTrue(calculation.crossesClockChange(in: pacific))
        XCTAssertFalse(calculation.leavesOnEarlierDay(in: pacific))
    }

    func testSpringForwardTripAcrossTheGapTakesExactlyTheTravelTime() throws {
        let arrival = Date(timeIntervalSince1970: 1_772_965_800) // Sun 2026-03-08 03:30 PDT
        let calculation = try departure(arrivingAt: arrival)
        XCTAssertEqual(calculation.leaveHome, Date(timeIntervalSince1970: 1_772_962_200), "01:30 PST")
        XCTAssertEqual(arrival.timeIntervalSince(calculation.leaveHome), 3_600, "Elapsed time is exactly the travel time")
        XCTAssertEqual(pacificReading(arrival), [3, 8, 3, 30])
        XCTAssertEqual(pacificReading(calculation.leaveHome), [3, 8, 1, 30], "The wall clock moves two hours for a one-hour trip")
        XCTAssertTrue(calculation.crossesClockChange(in: pacific))
        XCTAssertFalse(calculation.leavesOnEarlierDay(in: pacific))
    }

    func testDayAfterFallBackLeavesOnStandardTime() throws {
        let arrival = Date(timeIntervalSince1970: 1_793_636_100) // Mon 2026-11-02 08:15 PST
        XCTAssertEqual(arrival, TestFixtures.date(2026, 11, 2, 8, 15))
        let leave = DepartureCalculator.leaveHome(idealArrival: arrival, travelTime: .testDefault)
        XCTAssertEqual(leave, Date(timeIntervalSince1970: 1_793_632_500))
        XCTAssertEqual(pacificReading(leave), [11, 2, 7, 15])
        XCTAssertFalse(try departure(arrivingAt: arrival).crossesClockChange(in: pacific))
    }

    // MARK: Validating provider estimates

    func testMakeRejectsUnusableTravelTimes() {
        let cases: [(travelTime: TimeInterval, issue: CommuteDurationIssue)] = [
            (0, .notPositive),
            (-60, .notPositive),
            (Double.nan, .notFinite),
            (Double.infinity, .notFinite),
            (-Double.infinity, .notFinite),
            (1e300, .tooLong),
            (CommuteDuration.maximumSeconds + 1, .tooLong)
        ]
        for (travelTime, issue) in cases {
            let estimate = CommuteEstimate(travelTime: travelTime, sourceLabel: "Unit test estimate", estimatedAt: TestFixtures.fridayNoon, isSimulated: true)
            XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: estimate), .failure(.travelTime(issue)), "\(travelTime)")
        }
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 0)), .failure(.travelTime(.notPositive)))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: -5)), .failure(.travelTime(.notPositive)))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: .nan)), .failure(.travelTime(.notFinite)))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: .infinity)), .failure(.travelTime(.notFinite)))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 721)), .failure(.travelTime(.tooLong)))
    }

    func testMakeRejectsAnUnstampedOrUnlabeledEstimate() {
        let neverStamped = testEstimate(minutes: 60, at: Date(timeIntervalSinceReferenceDate: .infinity))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: neverStamped), .failure(.timestamp))
        let nanStamped = testEstimate(minutes: 60, at: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: nanStamped), .failure(.timestamp))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 60, label: "")), .failure(.missingSourceLabel))
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 60, label: " \n\t ")), .failure(.missingSourceLabel))
    }

    func testMakeReportsTheFirstIssueFound() {
        let everythingWrong = CommuteEstimate(travelTime: 0, sourceLabel: " ", estimatedAt: Date(timeIntervalSinceReferenceDate: .nan), isSimulated: true)
        XCTAssertEqual(DepartureCalculation.make(idealArrival: Date(timeIntervalSinceReferenceDate: .nan), estimate: everythingWrong), .failure(.travelTime(.notPositive)))
        let unstampedAndUnlabeled = CommuteEstimate(travelTime: 3_600, sourceLabel: "", estimatedAt: Date(timeIntervalSinceReferenceDate: .nan), isSimulated: true)
        XCTAssertEqual(DepartureCalculation.make(idealArrival: eightFifteen, estimate: unstampedAndUnlabeled), .failure(.timestamp))
    }

    func testMakeKeepsTheEstimateDetailsAndTrimsTheLabel() throws {
        let stamp = TestFixtures.date(2026, 10, 25, 20, 0)
        let simulated = try DepartureCalculation.make(
            idealArrival: eightFifteen,
            estimate: testEstimate(minutes: 60, at: stamp, label: "  Test commute (simulated)\n")
        ).get()
        XCTAssertEqual(simulated.sourceLabel, "Test commute (simulated)")
        XCTAssertEqual(simulated.estimatedAt, stamp)
        XCTAssertTrue(simulated.isSimulated)
        XCTAssertEqual(simulated.travelTime, .testDefault)
        XCTAssertEqual(simulated.idealArrival, eightFifteen)
        XCTAssertEqual(simulated.leaveHome, sevenFifteen)

        let live = try DepartureCalculation.make(
            idealArrival: eightFifteen,
            estimate: CommuteEstimate(travelTime: 2_700, sourceLabel: "Team provider", estimatedAt: stamp, isSimulated: false)
        ).get()
        XCTAssertFalse(live.isSimulated)
        XCTAssertEqual(live.sourceLabel, "Team provider")
        XCTAssertEqual(live.travelTime, try CommuteDuration.minutes(45))
        XCTAssertEqual(live.leaveHome, TestFixtures.date(2026, 10, 26, 7, 30))
    }

    // MARK: Timing

    func testTimingAroundTheLeaveHomeTimeAndTheArrival() throws {
        let calculation = try departure(arrivingAt: eightFifteen)
        let leave = calculation.leaveHome
        XCTAssertEqual(calculation.timing(at: leave.addingTimeInterval(-3_600)), .upcoming)
        XCTAssertEqual(calculation.timing(at: leave), .upcoming, "Leaving exactly on time still reaches campus by the ideal arrival")
        XCTAssertEqual(calculation.timing(at: leave.addingTimeInterval(1)), .departurePassed)
        XCTAssertEqual(calculation.timing(at: eightFifteen.addingTimeInterval(-1)), .departurePassed)
        XCTAssertEqual(calculation.timing(at: eightFifteen), .departurePassed)
        XCTAssertEqual(calculation.timing(at: eightFifteen.addingTimeInterval(1)), .arrivalPassed)
        XCTAssertEqual(calculation.timing(at: TestFixtures.date(2026, 10, 26, 9, 0)), .arrivalPassed)
    }

    func testLeaveHomeTimeIsNeverReplacedByNow() throws {
        let calculation = try departure(arrivingAt: eightFifteen)
        let request = try makeRequest()
        for minutesAfterLeaveHome in [-30, 0, 1, 30, 60, 61, 600] {
            let now = sevenFifteen.addingTimeInterval(TimeInterval(minutesAfterLeaveHome) * 60)
            // A later now changes only the timing, never the time: only now at or before 7:15 is upcoming.
            XCTAssertEqual(calculation.timing(at: now) == .upcoming, minutesAfterLeaveHome <= 0, "\(minutesAfterLeaveHome)")
            // An estimate made later, even after the leave-home time, still gives 7:15.
            let resolved = DepartureState.resolving(.estimate(testEstimate(minutes: 60, at: now)), for: request)
            XCTAssertEqual(resolved.calculation?.leaveHome, sevenFifteen, "\(minutesAfterLeaveHome)")
            XCTAssertEqual(resolved.calculation?.estimatedAt, now)
        }
    }

    // MARK: Departure states

    func testResolvingMapsEachProviderAnswerToAState() throws {
        let request = try makeRequest()
        let success = DepartureState.resolving(.estimate(testEstimate(minutes: 60)), for: request)
        let calculation = try XCTUnwrap(success.calculation)
        XCTAssertEqual(calculation.leaveHome, sevenFifteen)
        XCTAssertEqual(success, .success(calculation))
        XCTAssertFalse(success.isLoading)

        XCTAssertEqual(DepartureState.resolving(.estimate(testEstimate(minutes: 0)), for: request), .error(.invalidEstimate(.travelTime(.notPositive))))
        XCTAssertEqual(DepartureState.resolving(.estimate(testEstimate(minutes: .nan)), for: request), .error(.invalidEstimate(.travelTime(.notFinite))))
        XCTAssertEqual(DepartureState.resolving(.estimate(testEstimate(minutes: 721)), for: request), .error(.invalidEstimate(.travelTime(.tooLong))))
        XCTAssertEqual(DepartureState.resolving(.estimate(testEstimate(minutes: 60, label: " ")), for: request), .error(.invalidEstimate(.missingSourceLabel)))
        XCTAssertEqual(DepartureState.resolving(.unavailable(message: "x"), for: request), .unavailable(.noEstimate(message: "x")))
        XCTAssertNil(DepartureState.resolving(.unavailable(message: "x"), for: request).calculation)
    }

    func testLeaveHomeUsesTheIdealArrivalNeverTheActivityStart() throws {
        let lecture = TestFixtures.activity(start: TestFixtures.mondayNine) // 9:00 to 9:50, ideal arrival 8:15
        let occurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: lecture, in: lecture.idealArrival..<lecture.end).first)
        let request = CommuteRequest(occurrence: occurrence, origin: CommutePlaces.sample.home)
        XCTAssertEqual(request.arriveBy, eightFifteen)
        XCTAssertEqual(request.origin, CommutePlaces.sample.home, "Every trip starts at home")
        XCTAssertEqual(request.destination, lecture.destination, "Without a resolved destination the stored copy is used")
        XCTAssertEqual(request.occurrenceID, occurrence.id)
        let calculation = try XCTUnwrap(DepartureState.resolving(.estimate(testEstimate(minutes: 60)), for: request).calculation)
        XCTAssertEqual(calculation.leaveHome, sevenFifteen)
        XCTAssertEqual(pacificReading(calculation.leaveHome), [10, 26, 7, 15])
        XCTAssertNotEqual(calculation.leaveHome, TestFixtures.date(2026, 10, 26, 8, 0), "Start minus travel time would be 8:00")
        XCTAssertEqual(request.arriveBy.timeIntervalSince(calculation.leaveHome), 3_600, "Nothing beyond the travel time is subtracted")
    }

    func testOnlyErrorsAreRetryable() throws {
        let calculation = try departure(arrivingAt: eightFifteen)
        XCTAssertTrue(DepartureState.error(.providerFailed).isRetryable)
        XCTAssertTrue(DepartureState.error(.invalidEstimate(.travelTime(.notPositive))).isRetryable)
        XCTAssertTrue(DepartureState.error(.invalidEstimate(.missingSourceLabel)).isRetryable)
        XCTAssertFalse(
            DepartureState.unavailable(.noEstimate(message: "No route")).isRetryable,
            "Step 0006: asking again gives the same answer, so no Try Again is offered"
        )

        XCTAssertFalse(DepartureState.loading.isRetryable)
        XCTAssertFalse(DepartureState.refreshing(calculation).isRetryable)
        XCTAssertFalse(DepartureState.success(calculation).isRetryable)
        XCTAssertFalse(DepartureState.unavailable(.noDestination).isRetryable)
        XCTAssertFalse(DepartureState.unavailable(.activityEnded).isRetryable)
        XCTAssertFalse(DepartureState.unavailable(.beyondHorizon).isRetryable)
        XCTAssertFalse(DepartureState.unavailable(.unsavedChanges).isRetryable)

        XCTAssertTrue(DepartureState.loading.isLoading)
        XCTAssertNil(DepartureState.loading.calculation)
        XCTAssertNil(DepartureState.loading.staleCalculation)
        XCTAssertEqual(DepartureState.success(calculation).calculation, calculation)
        XCTAssertNil(DepartureState.success(calculation).staleCalculation)
        XCTAssertFalse(DepartureState.success(calculation).isLoading)

        // Refreshing keeps the earlier calculation, marked out of date, never as the current time.
        let refreshing = DepartureState.refreshing(calculation)
        XCTAssertTrue(refreshing.isLoading)
        XCTAssertNil(refreshing.calculation, "An out-of-date time is never the current leave-home time")
        XCTAssertEqual(refreshing.staleCalculation, calculation)
        XCTAssertNotEqual(refreshing, .success(calculation))
        XCTAssertNotEqual(refreshing, .loading)
        XCTAssertNil(DepartureState.error(.providerFailed).staleCalculation)
        XCTAssertFalse(DepartureState.error(.providerFailed).isLoading)
        XCTAssertFalse(DepartureState.unavailable(.noEstimate(message: "No route")).isLoading)
    }

    func testUsableDestinationNeedsANameAndAValidCoordinate() throws {
        XCTAssertTrue(try makeRequest(to: SampleLocation.demoCampus.destination).hasUsableDestination)
        let valid = GeoCoordinate(latitude: 38.5610, longitude: -121.4237)
        let unusable = [
            Destination(id: DestinationID("unnamed"), name: "", coordinate: valid),
            Destination(id: DestinationID("blank"), name: "  \n", coordinate: valid),
            Destination(id: DestinationID("polar"), name: "Too far north", coordinate: GeoCoordinate(latitude: 91, longitude: -121.4237)),
            Destination(id: DestinationID("nan"), name: "Nowhere", coordinate: GeoCoordinate(latitude: .nan, longitude: -121.4237)),
            Destination(id: DestinationID("east"), name: "Too far east", coordinate: GeoCoordinate(latitude: 38.5610, longitude: 181))
        ]
        for destination in unusable {
            XCTAssertFalse(try makeRequest(to: destination).hasUsableDestination, destination.id.rawValue)
        }

        // A NaN coordinate never equals itself as a Double; the request still equals itself.
        let nanRequest = try makeRequest(to: unusable[3])
        XCTAssertEqual(nanRequest, nanRequest)
        XCTAssertEqual(Set([nanRequest, nanRequest]).count, 1)
        XCTAssertNotEqual(nanRequest, try makeRequest(to: unusable[3]), "A different occurrence is a different request")
    }
}
