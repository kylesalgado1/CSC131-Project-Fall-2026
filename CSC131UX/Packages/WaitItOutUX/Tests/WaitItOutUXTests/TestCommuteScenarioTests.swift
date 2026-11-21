import XCTest
@testable import WaitItOutUX

/// Step 0006: the test provider's deterministic Normal, Slow, Unavailable, and Error scenarios.
final class TestCommuteScenarioTests: XCTestCase {
    private func makeRequest() -> CommuteRequest {
        let arrival = TestFixtures.date(2026, 10, 26, 8, 15)
        return CommuteRequest(
            occurrenceID: OccurrenceID(activityID: UUID(), date: LocalDate.of(arrival, in: TestFixtures.pacific)),
            origin: CommutePlaces.sample.home,
            destination: SampleLocation.demoCampus.destination,
            arriveBy: arrival
        )
    }

    private func estimate(_ response: CommuteEstimateResponse) -> CommuteEstimate? {
        if case .estimate(let value) = response { return value }
        return nil
    }

    func testTravelTimePerScenarioIsPureAndDeterministic() throws {
        let sixty = CommuteDuration.testDefault
        XCTAssertEqual(TestCommuteProvider.Scenario.normal.travelTime(for: sixty), sixty)
        XCTAssertEqual(TestCommuteProvider.Scenario.slow.travelTime(for: sixty), try CommuteDuration.minutes(90))
        XCTAssertEqual(TestCommuteProvider.Scenario.slow.travelTime(for: try CommuteDuration.minutes(45)), try CommuteDuration.minutes(68), "Rounded up")
        XCTAssertEqual(TestCommuteProvider.Scenario.slow.travelTime(for: try CommuteDuration.minutes(1)), try CommuteDuration.minutes(2))
        XCTAssertEqual(TestCommuteProvider.Scenario.slow.travelTime(for: try CommuteDuration.minutes(600)), try CommuteDuration.minutes(720), "Capped at 12 hours")
        XCTAssertNil(TestCommuteProvider.Scenario.unavailable.travelTime(for: sixty))
        XCTAssertNil(TestCommuteProvider.Scenario.error.travelTime(for: sixty))
        XCTAssertEqual(TestCommuteProvider.Scenario.allCases.map(\.title), ["Normal", "Slow", "Unavailable", "Error"])
        for scenario in TestCommuteProvider.Scenario.allCases {
            XCTAssertFalse(scenario.summary.isEmpty, scenario.title)
        }
    }

    func testEachScenarioAnswersAsDocumented() async throws {
        let provider = TestCommuteProvider(clock: FixedWallClock(TestFixtures.fridayNoon))
        let request = makeRequest()

        let normalResponse = try await provider.estimateCommute(for: request)
        let normal = try XCTUnwrap(estimate(normalResponse))
        XCTAssertEqual(normal.travelTime, 3_600)
        XCTAssertEqual(normal.sourceLabel, TestCommuteProvider.sourceLabel)
        XCTAssertTrue(normal.isSimulated)

        provider.setScenario(.slow)
        XCTAssertEqual(provider.configuration.scenario, .slow)
        let slowResponse = try await provider.estimateCommute(for: request)
        let slow = try XCTUnwrap(estimate(slowResponse))
        XCTAssertEqual(slow.travelTime, 5_400)
        XCTAssertEqual(slow.sourceLabel, TestCommuteProvider.slowSourceLabel)
        XCTAssertTrue(slow.isSimulated)
        XCTAssertEqual(slow.estimatedAt, TestFixtures.fridayNoon)

        provider.setScenario(.unavailable)
        let unavailable = try await provider.estimateCommute(for: request)
        XCTAssertEqual(unavailable, .unavailable(message: TestCommuteProvider.unavailableMessage))
        XCTAssertTrue(TestCommuteProvider.unavailableMessage.contains("simulated"))

        provider.setScenario(.error)
        do {
            _ = try await provider.estimateCommute(for: request)
            XCTFail("The Error scenario throws")
        } catch {
            XCTAssertTrue(error is TestCommuteProviderError, "\(error)")
        }
    }

    func testSlowDelayAppliesOnlyToTheSlowScenarioAndIsCancellable() async throws {
        let provider = TestCommuteProvider(
            clock: FixedWallClock(TestFixtures.fridayNoon),
            configuration: .init(slowDelay: .seconds(10))
        )
        let request = makeRequest()
        let started = ContinuousClock.now
        _ = try await provider.estimateCommute(for: request)
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(5), "Normal ignores the slow delay")

        provider.setScenario(.slow)
        let task = Task { try await provider.estimateCommute(for: request) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(5), "Cancelling ends the slow pause")
        if case .success(let response) = result {
            XCTFail("Expected cancellation, got \(response)")
        }
    }
}
