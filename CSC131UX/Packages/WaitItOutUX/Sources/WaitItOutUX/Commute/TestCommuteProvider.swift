import Foundation
import os

/// Thrown by `TestCommuteProvider` in its Error scenario.
public struct TestCommuteProviderError: Error, Equatable, Sendable {
    public init() {}
}

/// The prototype's commute provider. It measures nothing: every trip takes the configured
/// test duration (60 minutes until Settings changes it), shaped by a deterministic scenario,
/// stamped with the injected clock, and labeled as simulated. It is a stand-in that the team
/// replaces with a live provider.
///
/// Configurable for demos, previews, and tests: the duration, a scenario (Normal, Slow,
/// Unavailable, Error; step 0006), and simulated delays so loading is visible. Configuration
/// changes apply to the next request; the model re-requests after a change, so views never
/// need to know which scenario is active to behave correctly.
public final class TestCommuteProvider: CommuteEstimating {
    /// Deterministic estimate scenarios for the Settings "Prototype testing" section.
    public enum Scenario: String, CaseIterable, Codable, Sendable, Identifiable {
        /// Every trip takes the test duration.
        case normal
        /// Simulated heavy traffic: every trip takes `slowTrafficFactor` times the test
        /// duration (whole minutes, rounded up, at most 12 hours), and the answer waits for
        /// `Configuration.slowDelay`, so loading and refreshing stay on screen for a while.
        case slow
        /// Answers that there is no estimate for the trip.
        case unavailable
        /// Throws `TestCommuteProviderError`, like a provider outage.
        case error

        /// How much longer every trip takes in the Slow scenario.
        public static let slowTrafficFactor = 1.5

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .normal: return "Normal"
            case .slow: return "Slow"
            case .unavailable: return "Unavailable"
            case .error: return "Error"
            }
        }

        /// One sentence for Settings describing what the scenario simulates.
        public var summary: String {
            switch self {
            case .normal:
                return "Every trip takes the test commute duration."
            case .slow:
                return "Simulated heavy traffic: every trip takes 50% longer, and each estimate takes a few seconds to arrive."
            case .unavailable:
                return "The test provider answers without an estimate, so no leave-home time is shown."
            case .error:
                return "The test provider fails like an outage. Try Again asks again and keeps failing until you choose another scenario."
            }
        }

        /// The simulated travel time for a configured test duration, or `nil` when the
        /// scenario gives no estimate.
        public func travelTime(for duration: CommuteDuration) -> CommuteDuration? {
            switch self {
            case .normal:
                return duration
            case .slow:
                let minutes = (Double(duration.wholeMinutes) * Self.slowTrafficFactor).rounded(.up)
                let capped = min(Int(minutes), CommuteDuration.maximumMinutes)
                return (try? CommuteDuration.minutes(capped)) ?? duration
            case .unavailable, .error:
                return nil
            }
        }
    }

    public struct Configuration: Equatable, Sendable {
        public var duration: CommuteDuration
        public var scenario: Scenario
        /// Pause before answering in the Normal, Unavailable, and Error scenarios. Cancelling
        /// the request ends the pause early.
        public var simulatedDelay: Duration
        /// Pause before answering in the Slow scenario.
        public var slowDelay: Duration

        public init(
            duration: CommuteDuration = .testDefault,
            scenario: Scenario = .normal,
            simulatedDelay: Duration = .zero,
            slowDelay: Duration = .zero
        ) {
            self.duration = duration
            self.scenario = scenario
            self.simulatedDelay = simulatedDelay
            self.slowDelay = slowDelay
        }
    }

    /// Shown next to every leave-home time the Normal scenario produces.
    public static let sourceLabel = "Test commute (simulated, not live traffic)"
    /// Shown next to every leave-home time the Slow scenario produces.
    public static let slowSourceLabel = "Test commute, Slow scenario (simulated heavy traffic, not live)"
    public static let unavailableMessage = "The test commute provider returned no estimate for this trip (simulated Unavailable scenario). Choose Normal in Settings under Prototype testing to get one."

    private let clock: any WallClock
    private let state: OSAllocatedUnfairLock<Configuration>

    public init(clock: any WallClock, configuration: Configuration = Configuration()) {
        self.clock = clock
        state = OSAllocatedUnfairLock(initialState: configuration)
    }

    public var configuration: Configuration {
        state.withLock { $0 }
    }

    public func setDuration(_ duration: CommuteDuration) {
        state.withLock { $0.duration = duration }
    }

    public func setScenario(_ scenario: Scenario) {
        state.withLock { $0.scenario = scenario }
    }

    public func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        let current = configuration
        let delay = current.scenario == .slow ? current.slowDelay : current.simulatedDelay
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        switch current.scenario {
        case .normal, .slow:
            let travelTime = current.scenario.travelTime(for: current.duration) ?? current.duration
            return .estimate(CommuteEstimate(
                travelTime: travelTime.seconds,
                sourceLabel: current.scenario == .slow ? Self.slowSourceLabel : Self.sourceLabel,
                estimatedAt: clock.now(),
                isSimulated: true
            ))
        case .unavailable:
            return .unavailable(message: Self.unavailableMessage)
        case .error:
            throw TestCommuteProviderError()
        }
    }
}
