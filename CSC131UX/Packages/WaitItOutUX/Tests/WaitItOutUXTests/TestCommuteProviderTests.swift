import XCTest
@testable import WaitItOutUX

/// Step 0005: the prototype's simulated commute provider. In the Normal scenario every answer is
/// the configured test duration (60 minutes until Settings changes it), labeled as simulated,
/// stamped by the injected clock, and cancellable during its optional simulated delay. Step 0006
/// replaced the old behavior switch with scenarios; `TestCommuteScenarioTests` covers Slow and
/// the scenario details.
final class TestCommuteProviderTests: XCTestCase {
    private func makeRequest(arriveBy arrival: Date = TestFixtures.date(2026, 10, 26, 8, 15)) -> CommuteRequest {
        CommuteRequest(
            occurrenceID: OccurrenceID(activityID: UUID(), date: LocalDate.of(arrival, in: TestFixtures.pacific)),
            origin: CommutePlaces.sample.home,
            destination: SampleLocation.demoCampus.destination,
            arriveBy: arrival
        )
    }

    /// The estimate inside `response`, or `nil` when the provider answered without one.
    private func answeredEstimate(_ response: CommuteEstimateResponse) -> CommuteEstimate? {
        if case .estimate(let answer) = response { return answer }
        return nil
    }

    func testDefaultConfigurationIsSixtyMinutesWithoutDelay() {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        XCTAssertEqual(provider.configuration, TestCommuteProvider.Configuration())
        XCTAssertEqual(provider.configuration.duration, .testDefault)
        XCTAssertEqual(provider.configuration.duration.wholeMinutes, 60)
        XCTAssertEqual(provider.configuration.scenario, .normal)
        XCTAssertEqual(provider.configuration.simulatedDelay, .zero)
        XCTAssertEqual(provider.configuration.slowDelay, .zero)
    }

    func testEstimateIsTheConfiguredDurationLabeledAsSimulated() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let response = try await provider.estimateCommute(for: makeRequest())
        XCTAssertEqual(response, .estimate(CommuteEstimate(
            travelTime: 3_600,
            sourceLabel: TestCommuteProvider.sourceLabel,
            estimatedAt: TestFixtures.fridayNoon,
            isSimulated: true
        )))
        let answer = try XCTUnwrap(answeredEstimate(response))
        XCTAssertEqual(answer.travelTime, CommuteDuration.testDefault.seconds)
        XCTAssertEqual(answer.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertTrue(answer.sourceLabel.contains("simulated"))
        XCTAssertTrue(answer.sourceLabel.contains("not live traffic"))
        XCTAssertEqual(answer.estimatedAt, TestFixtures.fridayNoon)
        XCTAssertTrue(answer.isSimulated)
    }

    func testEstimateTimeFollowsTheInjectedClock() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let provider = TestCommuteProvider(clock: clock)
        let request = makeRequest()

        let firstResponse = try await provider.estimateCommute(for: request)
        let first = try XCTUnwrap(answeredEstimate(firstResponse))
        XCTAssertEqual(first.estimatedAt, TestFixtures.fridayNoon)

        clock.advance(by: 90 * 60)
        let secondResponse = try await provider.estimateCommute(for: request)
        let second = try XCTUnwrap(answeredEstimate(secondResponse))
        XCTAssertEqual(second.estimatedAt, TestFixtures.fridayNoon.addingTimeInterval(90 * 60))
        XCTAssertEqual(second.travelTime, first.travelTime, "Only the stamp follows the clock")

        clock.set(TestFixtures.mondayNine)
        let thirdResponse = try await provider.estimateCommute(for: request)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(thirdResponse)).estimatedAt, TestFixtures.mondayNine)
    }

    func testDurationChangeAppliesToTheNextRequest() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let request = makeRequest()
        let before = try await provider.estimateCommute(for: request)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(before)).travelTime, 3_600)

        let fortyFive = try CommuteDuration.minutes(45)
        provider.setDuration(fortyFive)
        XCTAssertEqual(provider.configuration.duration, fortyFive)
        XCTAssertEqual(provider.configuration.scenario, .normal)

        let after = try await provider.estimateCommute(for: request)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(after)).travelTime, 2_700)
    }

    func testUnavailableScenarioAnswersWithTheSimulatedMessage() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let request = makeRequest()
        provider.setScenario(.unavailable)
        XCTAssertEqual(provider.configuration.scenario, .unavailable)

        let response = try await provider.estimateCommute(for: request)
        XCTAssertEqual(response, .unavailable(message: TestCommuteProvider.unavailableMessage))
        XCTAssertTrue(TestCommuteProvider.unavailableMessage.contains("simulated"))
        XCTAssertEqual(DepartureState.resolving(response, for: request), .unavailable(.noEstimate(message: TestCommuteProvider.unavailableMessage)))
    }

    func testErrorScenarioThrowsUntilResetToNormal() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let request = makeRequest()
        provider.setScenario(.error)
        XCTAssertEqual(provider.configuration.scenario, .error)
        do {
            let response = try await provider.estimateCommute(for: request)
            XCTFail("Expected a simulated outage, got \(response)")
        } catch {
            XCTAssertTrue(error is TestCommuteProviderError, "\(error)")
            XCTAssertEqual(error as? TestCommuteProviderError, TestCommuteProviderError())
        }

        provider.setScenario(.normal)
        let recovered = try await provider.estimateCommute(for: request)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(recovered)).travelTime, 3_600)
    }

    func testCancellingDuringTheSimulatedDelayEndsTheRequestEarly() async throws {
        let provider = TestCommuteProvider(
            clock: FixedWallClock(TestFixtures.fridayNoon),
            configuration: .init(simulatedDelay: .seconds(10))
        )
        XCTAssertEqual(provider.configuration.simulatedDelay, .seconds(10))
        let request = makeRequest()
        let started = ContinuousClock.now
        let task = Task { try await provider.estimateCommute(for: request) }
        // Give the request time to enter its pause, then cancel it.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        let elapsed = started.duration(to: ContinuousClock.now)

        XCTAssertLessThan(elapsed, .seconds(5), "Cancelling ends the 10-second pause early")
        switch result {
        case .success(let response):
            XCTFail("Expected CancellationError, got \(response)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testRequestFromAnAlreadyCancelledTaskThrowsCancellationError() async {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        XCTAssertEqual(provider.configuration.simulatedDelay, .zero)
        let request = makeRequest()
        let started = ContinuousClock.now
        let task = Task { () async throws -> CommuteEstimateResponse in
            // The pause ends only when the test cancels this task, so the provider is always
            // asked from an already-cancelled task, even though it has no simulated delay.
            try? await Task.sleep(for: .seconds(10))
            return try await provider.estimateCommute(for: request)
        }
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(5))
        switch result {
        case .success(let response):
            XCTFail("Expected CancellationError, got \(response)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testShortSimulatedDelayStillAnswers() async throws {
        let thirty = try CommuteDuration.minutes(30)
        let provider = TestCommuteProvider(
            clock: FixedWallClock(TestFixtures.fridayNoon),
            configuration: .init(duration: thirty, simulatedDelay: .milliseconds(20))
        )
        let response = try await provider.estimateCommute(for: makeRequest())
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(response)).travelTime, 1_800)
    }

    func testRequestsAreAnsweredIndependently() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let morning = makeRequest(arriveBy: TestFixtures.date(2026, 10, 26, 8, 15))
        let evening = makeRequest(arriveBy: TestFixtures.date(2026, 10, 27, 18, 0))
        XCTAssertNotEqual(morning, evening)

        async let first = provider.estimateCommute(for: morning)
        async let second = provider.estimateCommute(for: evening)
        let (morningAnswer, eveningAnswer) = try await (first, second)

        XCTAssertEqual(try XCTUnwrap(answeredEstimate(morningAnswer)).travelTime, 3_600)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(eveningAnswer)).travelTime, 3_600)
        XCTAssertEqual(try XCTUnwrap(answeredEstimate(eveningAnswer)).estimatedAt, TestFixtures.fridayNoon, "Stamped by the clock, not the arrival")
    }

    func testProviderAnswerGivesTheLeaveHomeTimeThroughTheFormula() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let request = makeRequest()
        let response = try await provider.estimateCommute(for: request)
        let calculation = try XCTUnwrap(DepartureState.resolving(response, for: request).calculation)
        XCTAssertEqual(calculation.leaveHome, TestFixtures.date(2026, 10, 26, 7, 15))
        XCTAssertEqual(calculation.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertEqual(calculation.estimatedAt, TestFixtures.fridayNoon)
        XCTAssertTrue(calculation.isSimulated)
    }
}
