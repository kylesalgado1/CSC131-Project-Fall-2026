import XCTest
@testable import WaitItOutUX

/// Stage S1: the backend recommendation as a domain value. A recommendation is shown as the
/// backend gave it (no local arithmetic), a kept out-of-date recommendation is never current,
/// a "not yet" answer is not a failure, and freshness follows the backend's rhythm.
///
/// Fixture: an ideal arrival of Mon 2026-10-26 8:15 AM PDT, a recommended departure of
/// 7:15 AM, and a predicted arrival of 8:00 AM (45 minutes of driving, 15 to spare).
final class DepartureRecommendationTests: XCTestCase {
    private let sixAM = TestFixtures.date(2026, 10, 26, 6, 0)
    private let sevenFifteen = TestFixtures.date(2026, 10, 26, 7, 15)
    private let eight = TestFixtures.date(2026, 10, 26, 8, 0)
    private let eightFifteen = TestFixtures.date(2026, 10, 26, 8, 15)

    private func recommendation(
        advice: DepartureAdvice = .leaveLater,
        departure: Date? = nil,
        arrival: Date? = nil,
        lateBy: TimeInterval? = nil,
        receivedAt: Date? = nil,
        source: RecommendationSource = TestBackend.liveSource,
        isStale: Bool = false,
        isMonitored: Bool = false
    ) -> DepartureRecommendation {
        TestBackend.recommendation(
            advice: advice,
            departure: departure ?? sevenFifteen,
            arrival: arrival ?? eight,
            lateBy: lateBy,
            margin: 15 * 60,
            generatedAt: receivedAt ?? sixAM,
            source: source,
            isStale: isStale,
            isMonitored: isMonitored
        )
    }

    private func calculation(_ recommendation: DepartureRecommendation, arrival: Date? = nil) throws -> DepartureCalculation {
        try DepartureCalculation.make(idealArrival: arrival ?? eightFifteen, recommendation: recommendation).get()
    }

    private func request() -> CommuteRequest {
        CommuteRequest(
            occurrenceID: OccurrenceID(activityID: UUID(), date: LocalDate.of(eightFifteen, in: TestFixtures.pacific)),
            origin: CommutePlaces.sample.home,
            destination: TestFixtures.demoDestination,
            arriveBy: eightFifteen
        )
    }

    // MARK: Source

    func testSourceLabelsNameWhatTheBackendReported() {
        typealias Source = RecommendationSource
        XCTAssertEqual(Source(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true).label, "Live traffic (TomTom) via the team backend")
        XCTAssertEqual(Source(baseline: .tomTom, usedFallback: false, hasLiveTraffic: false).label, "Typical traffic (TomTom); live traffic unavailable")
        XCTAssertEqual(Source(baseline: .pems, usedFallback: true, hasLiveTraffic: false).label, "Historical traffic (PeMS fallback); TomTom unavailable")
        XCTAssertEqual(Source(baseline: .pems, usedFallback: false, hasLiveTraffic: false).label, "Historical traffic (PeMS)")
        XCTAssertEqual(Source(baseline: .fixture, usedFallback: false, hasLiveTraffic: true).label, "Test fixture traffic, not live")
        XCTAssertEqual(Source(baseline: .unknown, usedFallback: false, hasLiveTraffic: false).label, "Team backend")
        XCTAssertEqual(Source.unknown, Source(baseline: .unknown, usedFallback: false, hasLiveTraffic: false))

        XCTAssertFalse(Source(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true).isDegraded)
        XCTAssertTrue(Source(baseline: .tomTom, usedFallback: false, hasLiveTraffic: false).isDegraded, "No live traffic")
        XCTAssertTrue(Source(baseline: .pems, usedFallback: true, hasLiveTraffic: true).isDegraded, "A fallback source")
        XCTAssertTrue(Source(baseline: .fixture, usedFallback: false, hasLiveTraffic: true).isDegraded, "Fixture data")
        XCTAssertFalse(Source(baseline: .tomTom, usedFallback: false, hasLiveTraffic: false).label.hasPrefix("Live"), "Live traffic is never claimed without it")
        XCTAssertEqual(RecommendationConfidence.high.title, "High")
        XCTAssertEqual(RecommendationConfidence.medium.title, "Medium")
        XCTAssertEqual(RecommendationConfidence.low.title, "Low")
    }

    // MARK: make(idealArrival:recommendation:)

    func testARecommendationIsUsedVerbatimWithNoLocalArithmetic() throws {
        let advised = recommendation()
        let made = try calculation(advised)
        XCTAssertEqual(made.leaveHome, sevenFifteen, "The recommended departure is the leave-home time")
        XCTAssertEqual(made.idealArrival, eightFifteen)
        XCTAssertEqual(made.travelTime.seconds, 45 * 60, "Predicted arrival minus recommended departure, for display only")
        // The local formula would give 8:15 minus 45 minutes = 7:30. It is not applied.
        let formula = try XCTUnwrap(DepartureCalculator.leaveHome(idealArrival: eightFifteen, travelTime: made.travelTime))
        XCTAssertEqual(formula, TestFixtures.date(2026, 10, 26, 7, 30))
        XCTAssertNotEqual(made.leaveHome, formula, "The backend's margin is kept; nothing is recomputed")
        XCTAssertEqual(made.recommendation, advised)
        XCTAssertEqual(made.sourceLabel, "Live traffic (TomTom) via the team backend")
        XCTAssertFalse(made.isSimulated)
        XCTAssertFalse(made.isArrivalUnreachable)

        let received = sixAM.addingTimeInterval(3)
        let stamped = try calculation(TestBackend.recommendation(departure: sevenFifteen, arrival: eight, generatedAt: sixAM, receivedAt: received))
        XCTAssertEqual(stamped.estimatedAt, received, "Freshness is judged from when the device received it")

        let fixture = try calculation(recommendation(source: RecommendationSource(baseline: .fixture, usedFallback: false, hasLiveTraffic: false)))
        XCTAssertTrue(fixture.isSimulated, "Fixture data is labeled as test data")
        XCTAssertEqual(fixture.sourceLabel, "Test fixture traffic, not live")

        let late = try calculation(recommendation(advice: .leaveNow, lateBy: 40 * 60))
        XCTAssertTrue(late.isArrivalUnreachable)

        // The demo path still goes through the formula and carries no recommendation.
        let demo = try DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 45)).get()
        XCTAssertEqual(demo.leaveHome, TestFixtures.date(2026, 10, 26, 7, 30))
        XCTAssertNil(demo.recommendation)
        XCTAssertFalse(demo.isArrivalUnreachable)
    }

    func testUnusableRecommendationsAreRejected() {
        func issue(_ advised: DepartureRecommendation, arrival: Date? = nil) -> CommuteEstimateIssue? {
            switch DepartureCalculation.make(idealArrival: arrival ?? eightFifteen, recommendation: advised) {
            case .success:
                return nil
            case .failure(let issue):
                return issue
            }
        }
        let notADate = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertNil(issue(recommendation()))
        XCTAssertEqual(issue(recommendation(departure: eight, arrival: eight)), .travelTime(.notPositive), "Arriving the moment you leave")
        XCTAssertEqual(issue(recommendation(departure: eight, arrival: sevenFifteen)), .travelTime(.notPositive), "Arriving before leaving")
        XCTAssertEqual(issue(recommendation(departure: sixAM, arrival: sixAM.addingTimeInterval(12 * 3_600 + 60))), .travelTime(.tooLong))
        XCTAssertEqual(issue(recommendation(departure: notADate)), .timestamp)
        XCTAssertEqual(issue(recommendation(arrival: notADate)), .timestamp)
        XCTAssertEqual(issue(recommendation(receivedAt: notADate)), .timestamp)
        XCTAssertEqual(issue(recommendation(), arrival: notADate), .arrival)
    }

    // MARK: States

    func testResolvingMapsRecommendationsStaleDataAndNotYet() throws {
        let trip = request()
        let advised = recommendation()
        let made = try calculation(advised)
        XCTAssertEqual(DepartureState.resolving(.recommendation(advised), for: trip), .success(made))

        // The server could not refresh it: kept, but never current.
        let old = recommendation(isStale: true)
        let kept = try calculation(old)
        let stale = DepartureState.resolving(.recommendation(old), for: trip)
        XCTAssertEqual(stale, .stale(kept, .staleServerData))
        XCTAssertNil(stale.calculation)

        XCTAssertEqual(
            DepartureState.resolving(.recommendation(recommendation(departure: eight, arrival: eight)), for: trip),
            .error(.invalidEstimate(.travelTime(.notPositive)))
        )

        let askAgainAt = sixAM.addingTimeInterval(600)
        let notYet = DepartureState.resolving(.notYet(message: "Not yet.", askAgainAt: askAgainAt), for: trip)
        XCTAssertEqual(notYet, .unavailable(.notYetPlannable(message: "Not yet.", askAgainAt: askAgainAt)))
        XCTAssertFalse(notYet.isRetryable, "Nothing failed, so there is no Try Again")
        XCTAssertNil(notYet.failure)
    }

    func testAKeptRecommendationIsNeverCurrent() throws {
        let made = try calculation(recommendation())
        let stale = DepartureState.stale(made, .provider(.offline))
        XCTAssertNil(stale.calculation, "A kept recommendation is not the current leave-home time")
        XCTAssertEqual(stale.staleCalculation, made)
        XCTAssertEqual(stale.failure, .provider(.offline))
        XCTAssertTrue(stale.isRetryable, "Try Again is offered")
        XCTAssertFalse(stale.isLoading)
        XCTAssertNotEqual(stale, .success(made))

        XCTAssertEqual(DepartureState.refreshing(made).staleCalculation, made)
        XCTAssertNil(DepartureState.refreshing(made).failure)
        XCTAssertEqual(DepartureState.error(.provider(.timedOut)).failure, .provider(.timedOut))
        XCTAssertNil(DepartureState.success(made).failure)
        XCTAssertNil(DepartureState.loading.failure)
    }

    func testOnlyTransientFailuresAreRetriedAutomatically() {
        typealias Kind = CommuteProviderFailure.Kind
        let transient: [Kind] = [.offline, .timedOut, .routingUnavailable, .server(status: 500), .server(status: 502), .server(status: 503)]
        let lasting: [Kind] = [.notConfigured, .invalidResponse, .unauthorized, .server(status: 400), .server(status: 404), .server(status: 422), .server(status: 499)]
        for kind in transient {
            XCTAssertTrue(kind.isTransient, "\(kind)")
            XCTAssertTrue(DepartureFailure.provider(kind).isTransient, "\(kind)")
        }
        for kind in lasting {
            XCTAssertFalse(kind.isTransient, "\(kind)")
            XCTAssertFalse(DepartureFailure.provider(kind).isTransient, "\(kind)")
        }
        XCTAssertFalse(DepartureFailure.providerFailed.isTransient)
        XCTAssertFalse(DepartureFailure.staleServerData.isTransient)
        XCTAssertFalse(DepartureFailure.invalidEstimate(.timestamp).isTransient)
        XCTAssertEqual(CommuteProviderFailure(.offline).kind, .offline)
    }

    func testRetryBackoffIsOneTwoThenFiveMinutes() {
        XCTAssertEqual(DepartureRetry.delay(afterAttempt: 1), 60)
        XCTAssertEqual(DepartureRetry.delay(afterAttempt: 2), 120)
        XCTAssertEqual(DepartureRetry.delay(afterAttempt: 3), 300)
        XCTAssertEqual(DepartureRetry.delay(afterAttempt: 12), 300)
        XCTAssertEqual(DepartureRetry.delay(afterAttempt: 0), 60)
    }

    // MARK: Freshness

    func testADemoEstimateStillLivesTenMinutes() throws {
        let demo = try DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 45, at: sixAM)).get()
        XCTAssertEqual(EstimateFreshness.lifetime(for: demo, at: sixAM), 600)
        XCTAssertFalse(EstimateFreshness.needsRefresh(demo, at: sixAM.addingTimeInterval(599)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(demo, at: sixAM.addingTimeInterval(600)))
        // A passed demo leave-home time is not a reason to ask again; the warning covers it.
        let fresh = try DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 45, at: TestFixtures.date(2026, 10, 26, 7, 29))).get()
        XCTAssertFalse(EstimateFreshness.needsRefresh(fresh, at: TestFixtures.date(2026, 10, 26, 7, 35)))
    }

    func testARecommendationFollowsTheBackendsRhythm() throws {
        // More than 3 hours before the departure: the backend's far slots sit on a half-hour grid.
        let far = try calculation(
            TestBackend.recommendation(departure: TestFixtures.date(2026, 10, 26, 12, 0), arrival: TestFixtures.date(2026, 10, 26, 12, 45), generatedAt: sixAM),
            arrival: TestFixtures.date(2026, 10, 26, 13, 0)
        )
        XCTAssertEqual(EstimateFreshness.lifetime(for: far, at: sixAM), 30 * 60)
        XCTAssertFalse(EstimateFreshness.needsRefresh(far, at: sixAM.addingTimeInterval(30 * 60 - 1)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(far, at: sixAM.addingTimeInterval(30 * 60)))
        // Exactly 3 hours ahead is no longer "far".
        XCTAssertEqual(EstimateFreshness.lifetime(for: far, at: TestFixtures.date(2026, 10, 26, 9, 0)), 870)
        XCTAssertEqual(EstimateFreshness.lifetime(for: far, at: TestFixtures.date(2026, 10, 26, 8, 59)), 30 * 60)

        // Within 3 hours: one backend slot of 15 minutes, less half a minute tick, so the
        // fifteenth whole-minute tick after an ask is the one that asks again.
        let near = try calculation(recommendation())
        XCTAssertEqual(EstimateFreshness.nearLifetime, 15 * 60 - 30)
        XCTAssertEqual(EstimateFreshness.lifetime(for: near, at: sixAM), 870)
        XCTAssertFalse(EstimateFreshness.needsRefresh(near, at: sixAM.addingTimeInterval(14 * 60)), "The fourteenth tick keeps it")
        XCTAssertFalse(EstimateFreshness.needsRefresh(near, at: sixAM.addingTimeInterval(869)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(near, at: sixAM.addingTimeInterval(870)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(near, at: sixAM.addingTimeInterval(15 * 60)), "The fifteenth tick asks again, one slot on")
    }

    func testANearDepartureIsAgedFromWhenItWasAsked() throws {
        // Asked on the 6:00 tick; the answer took 40 seconds to arrive.
        let slow = try calculation(TestBackend.recommendation(
            departure: sevenFifteen,
            arrival: eight,
            generatedAt: sixAM.addingTimeInterval(40),
            receivedAt: sixAM.addingTimeInterval(40)
        ))
        let fifteenthTick = sixAM.addingTimeInterval(15 * 60)
        XCTAssertFalse(
            EstimateFreshness.needsRefresh(slow, at: fifteenthTick),
            "Aged from its arrival it would miss the tick one slot on and be asked a minute late"
        )
        XCTAssertTrue(
            EstimateFreshness.needsRefresh(slow, at: fifteenthTick, askedAt: sixAM),
            "Aged from when it was asked, the next ask lands exactly one slot later"
        )
        XCTAssertFalse(EstimateFreshness.needsRefresh(slow, at: sixAM.addingTimeInterval(14 * 60), askedAt: sixAM))

        // Only a nearby planned departure is aged that way: a far one, a "leave now" answer,
        // and a demo estimate keep their own ages.
        let far = try calculation(
            TestBackend.recommendation(departure: TestFixtures.date(2026, 10, 26, 12, 0), arrival: TestFixtures.date(2026, 10, 26, 12, 45), generatedAt: sixAM.addingTimeInterval(40), receivedAt: sixAM.addingTimeInterval(40)),
            arrival: TestFixtures.date(2026, 10, 26, 13, 0)
        )
        XCTAssertFalse(EstimateFreshness.needsRefresh(far, at: sixAM.addingTimeInterval(30 * 60), askedAt: sixAM))
        XCTAssertTrue(EstimateFreshness.needsRefresh(far, at: sixAM.addingTimeInterval(30 * 60 + 40), askedAt: sixAM))
        let leaveNow = try calculation(TestBackend.recommendation(
            advice: .leaveNow,
            departure: sixAM.addingTimeInterval(40),
            arrival: sixAM.addingTimeInterval(40 + 45 * 60),
            generatedAt: sixAM.addingTimeInterval(40)
        ))
        XCTAssertFalse(EstimateFreshness.needsRefresh(leaveNow, at: sixAM.addingTimeInterval(5 * 60), askedAt: sixAM))
        XCTAssertTrue(EstimateFreshness.needsRefresh(leaveNow, at: sixAM.addingTimeInterval(5 * 60 + 40), askedAt: sixAM))
        let demo = try DepartureCalculation.make(idealArrival: eightFifteen, estimate: testEstimate(minutes: 45, at: sixAM.addingTimeInterval(40))).get()
        XCTAssertFalse(EstimateFreshness.needsRefresh(demo, at: sixAM.addingTimeInterval(10 * 60), askedAt: sixAM))
    }

    func testALeaveNowAnswerLivesAFixedFiveMinutes() throws {
        let sevenTwenty = TestFixtures.date(2026, 10, 26, 7, 20)
        let leaveNow = try calculation(TestBackend.recommendation(
            advice: .leaveNow,
            departure: sevenTwenty,
            arrival: TestFixtures.date(2026, 10, 26, 8, 5),
            generatedAt: sevenTwenty
        ))
        XCTAssertEqual(EstimateFreshness.lifetime(for: leaveNow, at: sevenTwenty), 5 * 60)
        for minute in 1...4 {
            XCTAssertFalse(
                EstimateFreshness.needsRefresh(leaveNow, at: sevenTwenty.addingTimeInterval(TimeInterval(minute) * 60)),
                "Its departure has passed by definition, which is not a reason to ask again (minute \(minute))"
            )
        }
        XCTAssertTrue(EstimateFreshness.needsRefresh(leaveNow, at: sevenTwenty.addingTimeInterval(300)))
    }

    func testAPassedPlannedDepartureIsHandedBackAfterAMinute() throws {
        // Received at 7:10 for a 7:15 departure.
        let sevenTen = TestFixtures.date(2026, 10, 26, 7, 10)
        let planned = try calculation(TestBackend.recommendation(departure: sevenFifteen, arrival: eight, generatedAt: sevenTen))
        XCTAssertFalse(EstimateFreshness.needsRefresh(planned, at: sevenFifteen), "Leaving exactly on time is still on time")
        XCTAssertTrue(EstimateFreshness.needsRefresh(planned, at: sevenFifteen.addingTimeInterval(1)), "Passed, and the answer is 5 minutes old")

        // An answer that is itself under a minute old is given that minute first.
        let justNow = try calculation(TestBackend.recommendation(
            advice: .wait,
            departure: sevenFifteen,
            arrival: eight,
            generatedAt: sevenFifteen.addingTimeInterval(10)
        ))
        XCTAssertFalse(EstimateFreshness.needsRefresh(justNow, at: sevenFifteen.addingTimeInterval(69)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(justNow, at: sevenFifteen.addingTimeInterval(70)))
    }

    func testAMonitoredPlanIsLeftToTheServerUntilItsDeparturePassed() throws {
        let monitored = try calculation(recommendation(isMonitored: true))
        XCTAssertFalse(EstimateFreshness.needsRefresh(monitored, at: sixAM.addingTimeInterval(3_600)), "The server pushes its changes")
        XCTAssertFalse(EstimateFreshness.needsRefresh(monitored, at: sevenFifteen), "Leaving exactly on time is still on time")
        XCTAssertTrue(
            EstimateFreshness.needsRefresh(monitored, at: sevenFifteen.addingTimeInterval(120)),
            "After its departure the server no longer re-checks the plan, so it is handed back like any other answer"
        )
        // A monitored "leave now" plan is kept for its five minutes, not asked every tick.
        let sevenTwenty = TestFixtures.date(2026, 10, 26, 7, 20)
        let leaveNow = try calculation(TestBackend.recommendation(
            advice: .leaveNow,
            departure: sevenTwenty,
            arrival: TestFixtures.date(2026, 10, 26, 8, 5),
            generatedAt: sevenTwenty,
            isMonitored: true
        ))
        XCTAssertFalse(EstimateFreshness.needsRefresh(leaveNow, at: sevenTwenty.addingTimeInterval(4 * 60)))
        XCTAssertTrue(EstimateFreshness.needsRefresh(leaveNow, at: sevenTwenty.addingTimeInterval(5 * 60)))

        let ordinary = try calculation(recommendation())
        XCTAssertFalse(EstimateFreshness.needsRefresh(ordinary, at: eightFifteen), "The arrival target has been reached")
        XCTAssertFalse(EstimateFreshness.needsRefresh(ordinary, at: eightFifteen.addingTimeInterval(3_600)))
    }

    func testTheBackendsRelativeSentenceIsCurrentForTwoMinutes() {
        let advised = TestBackend.recommendation(departure: sevenFifteen, arrival: eight, generatedAt: sixAM.addingTimeInterval(-500), receivedAt: sixAM)
        XCTAssertEqual(DepartureRecommendation.reasonLifetime, 120)
        XCTAssertTrue(advised.isReasonCurrent(at: sixAM))
        XCTAssertTrue(advised.isReasonCurrent(at: sixAM.addingTimeInterval(120)))
        XCTAssertFalse(advised.isReasonCurrent(at: sixAM.addingTimeInterval(121)))
        XCTAssertTrue(advised.isReasonCurrent(at: sixAM.addingTimeInterval(-30)), "A device clock that stepped back does not hide it")
    }
}
