import Foundation

/// The leave-home formula, and nothing else: leave home = ideal arrival - travel time.
///
/// The ideal arrival already includes study, parking, and buffer time, so nothing extra is
/// subtracted, and the activity's start is never used. The subtraction is in elapsed time,
/// so a trip that crosses midnight leaves on the previous day and a trip across a
/// daylight-saving change still takes exactly the travel time.
public enum DepartureCalculator {
    /// `nil` only for a nonfinite arrival; `CommuteDuration` is already validated.
    public static func leaveHome(idealArrival: Date, travelTime: CommuteDuration) -> Date? {
        guard idealArrival.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let departure = idealArrival.addingTimeInterval(-travelTime.seconds)
        return departure.timeIntervalSinceReferenceDate.isFinite ? departure : nil
    }
}

/// Why a provider's estimate was not used.
public enum CommuteEstimateIssue: Error, Equatable, Sendable {
    /// Zero, negative, nonfinite, or longer than 12 hours.
    case travelTime(CommuteDurationIssue)
    /// The estimate time is not a finite date.
    case timestamp
    /// The source label is empty, so the value could not be labeled.
    case missingSourceLabel
    /// The ideal arrival is not a finite date.
    case arrival
}

/// Where the user stands relative to a calculated leave-home time.
public enum DepartureTiming: Equatable, Sendable {
    /// Leaving at the calculated time still reaches campus by the ideal arrival.
    case upcoming
    /// The leave-home time has passed but the ideal arrival has not: the arrival target may
    /// be missed. The app never moves the leave-home time to "now".
    case departurePassed
    /// The ideal arrival itself has passed.
    case arrivalPassed
}

/// A calculated, read-only leave-home time for one trip, with the estimate it came from.
public struct DepartureCalculation: Equatable, Sendable {
    public let idealArrival: Date
    public let travelTime: CommuteDuration
    public let leaveHome: Date
    public let sourceLabel: String
    public let estimatedAt: Date
    public let isSimulated: Bool
    /// The backend recommendation this calculation shows as is, or `nil` on the demo path,
    /// where `leaveHome` comes from the local formula.
    public let recommendation: DepartureRecommendation?

    /// Validates a provider estimate and applies the formula. Fails with the first issue found.
    public static func make(idealArrival: Date, estimate: CommuteEstimate) -> Result<DepartureCalculation, CommuteEstimateIssue> {
        let travelTime: CommuteDuration
        switch CommuteDuration.validated(seconds: estimate.travelTime) {
        case .success(let duration):
            travelTime = duration
        case .failure(let issue):
            return .failure(.travelTime(issue))
        }
        guard estimate.estimatedAt.timeIntervalSinceReferenceDate.isFinite else { return .failure(.timestamp) }
        let label = estimate.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return .failure(.missingSourceLabel) }
        guard let leaveHome = DepartureCalculator.leaveHome(idealArrival: idealArrival, travelTime: travelTime) else {
            return .failure(.arrival)
        }
        return .success(DepartureCalculation(
            idealArrival: idealArrival,
            travelTime: travelTime,
            leaveHome: leaveHome,
            sourceLabel: label,
            estimatedAt: estimate.estimatedAt,
            isSimulated: estimate.isSimulated,
            recommendation: nil
        ))
    }

    /// Wraps a backend recommendation without any local arithmetic: `leaveHome` is the
    /// recommended departure exactly as the backend gave it, and `DepartureCalculator` is never
    /// called. `travelTime` is the predicted arrival minus the recommended departure and is
    /// used for display only. `estimatedAt` is when the device received the answer, which is
    /// what freshness is judged by; a fixture source counts as simulated. Fails when a date is
    /// not finite or the predicted arrival is not after the recommended departure.
    public static func make(idealArrival: Date, recommendation: DepartureRecommendation) -> Result<DepartureCalculation, CommuteEstimateIssue> {
        guard idealArrival.timeIntervalSinceReferenceDate.isFinite else { return .failure(.arrival) }
        let dates = [recommendation.recommendedDeparture, recommendation.predictedArrival, recommendation.generatedAt, recommendation.receivedAt]
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { return .failure(.timestamp) }
        let travelTime: CommuteDuration
        switch CommuteDuration.validated(seconds: recommendation.predictedArrival.timeIntervalSince(recommendation.recommendedDeparture)) {
        case .success(let duration):
            travelTime = duration
        case .failure(let issue):
            return .failure(.travelTime(issue))
        }
        return .success(DepartureCalculation(
            idealArrival: idealArrival,
            travelTime: travelTime,
            leaveHome: recommendation.recommendedDeparture,
            sourceLabel: recommendation.source.label,
            estimatedAt: recommendation.receivedAt,
            isSimulated: recommendation.source.baseline == .fixture,
            recommendation: recommendation
        ))
    }

    /// True when the backend says the ideal arrival can no longer be reached.
    public var isArrivalUnreachable: Bool {
        recommendation?.lateBy != nil
    }

    /// Timing at `now`. Leaving exactly at the leave-home time is still on time.
    public func timing(at now: Date) -> DepartureTiming {
        if now <= leaveHome { return .upcoming }
        if now <= idealArrival { return .departurePassed }
        return .arrivalPassed
    }

    /// True when leaving home and arriving fall on different local days in `zone`, such as
    /// a 12:30 AM arrival with a 60-minute commute.
    public func leavesOnEarlierDay(in zone: TimeZone) -> Bool {
        LocalDate.of(leaveHome, in: zone) < LocalDate.of(idealArrival, in: zone)
    }

    /// True when the zone's UTC offset differs between leaving and arriving: a
    /// daylight-saving change happens during the trip.
    public func crossesClockChange(in zone: TimeZone) -> Bool {
        zone.secondsFromGMT(for: leaveHome) != zone.secondsFromGMT(for: idealArrival)
    }
}

/// Why no leave-home time is shown, when nothing failed.
public enum DepartureUnavailableReason: Equatable, Sendable {
    /// The activity has no usable destination; the provider was not asked.
    case noDestination
    /// The provider answered without an estimate. The message is the provider's own.
    case noEstimate(message: String)
    /// The occurrence is over.
    case activityEnded
    /// The occurrence lies beyond the planning horizon (`DepartureHorizon.lookaheadDays`).
    case beyondHorizon
    /// The occurrence previews an unsaved change; departures are calculated for saved activities.
    case unsavedChanges
    /// Nothing can be recommended yet, and that changes with time: the trip lies beyond the
    /// backend's forecast, or the backend sees no need to plan yet. The message is the
    /// provider's; the model asks again once the clock reaches `askAgainAt`.
    case notYetPlannable(message: String, askAgainAt: Date)
}

/// Why a calculation failed.
public enum DepartureFailure: Equatable, Sendable {
    /// The provider threw. The app offers Try Again.
    case providerFailed
    /// The provider answered with a value the app refuses to use.
    case invalidEstimate(CommuteEstimateIssue)
    /// A network-backed provider said why it could not answer.
    case provider(CommuteProviderFailure.Kind)
    /// The server itself reports that it could not refresh the recommendation on schedule.
    case staleServerData

    /// True for failures the live pipeline retries on its own (see
    /// `CommuteProviderFailure.Kind.isTransient`).
    public var isTransient: Bool {
        if case .provider(let kind) = self { return kind.isTransient }
        return false
    }
}

/// Result state of one leave-home calculation: loading, refreshing, success, unavailable,
/// error, or a kept out-of-date recommendation.
public enum DepartureState: Equatable, Sendable {
    /// A request is in flight and there is no earlier answer for this trip.
    case loading
    /// A request for the same trip is in flight, after the provider settings changed or the
    /// estimate went stale (step 0006). The earlier calculation is kept so the screen does not
    /// go blank, and every view marks it out of date. It is never a current leave-home time.
    case refreshing(DepartureCalculation)
    case success(DepartureCalculation)
    case unavailable(DepartureUnavailableReason)
    case error(DepartureFailure)
    /// The last recommendation, kept after a refresh failed or when the server reports it out
    /// of date; never presented as current.
    case stale(DepartureCalculation, DepartureFailure)

    /// The current leave-home calculation; `nil` while loading or refreshing, for a kept
    /// out-of-date recommendation, and when unavailable.
    public var calculation: DepartureCalculation? {
        if case .success(let calculation) = self { return calculation }
        return nil
    }

    /// The out-of-date calculation shown while refreshing or after a failed refresh, or `nil`.
    public var staleCalculation: DepartureCalculation? {
        switch self {
        case .refreshing(let calculation), .stale(let calculation, _):
            return calculation
        case .loading, .success, .unavailable, .error:
            return nil
        }
    }

    /// Why the last request failed, for `.error` and `.stale`; `nil` otherwise.
    public var failure: DepartureFailure? {
        switch self {
        case .error(let failure), .stale(_, let failure):
            return failure
        case .loading, .refreshing, .success, .unavailable:
            return nil
        }
    }

    /// True while a request is in flight: loading or refreshing.
    public var isLoading: Bool {
        switch self {
        case .loading, .refreshing:
            return true
        case .success, .unavailable, .error, .stale:
            return false
        }
    }

    /// True for failures only, which Try Again can change: `.error` and a kept out-of-date
    /// recommendation (`.stale`). A provider that answers without an estimate is not offered
    /// Try Again (step 0006): asking again gives the same answer, and any change to the trip or
    /// the provider settings recalculates automatically.
    public var isRetryable: Bool {
        switch self {
        case .error, .stale:
            return true
        case .loading, .refreshing, .success, .unavailable:
            return false
        }
    }

    /// Maps a provider's answer for `request` to a state. Pure; the model calls it for every
    /// answer that is still current.
    public static func resolving(_ response: CommuteEstimateResponse, for request: CommuteRequest) -> DepartureState {
        switch response {
        case .estimate(let estimate):
            switch DepartureCalculation.make(idealArrival: request.arriveBy, estimate: estimate) {
            case .success(let calculation):
                return .success(calculation)
            case .failure(let issue):
                return .error(.invalidEstimate(issue))
            }
        case .recommendation(let recommendation):
            switch DepartureCalculation.make(idealArrival: request.arriveBy, recommendation: recommendation) {
            case .success(let calculation):
                // A recommendation the server could not refresh is kept but never shown as current.
                return recommendation.isStale ? .stale(calculation, .staleServerData) : .success(calculation)
            case .failure(let issue):
                return .error(.invalidEstimate(issue))
            }
        case .unavailable(let message):
            return .unavailable(.noEstimate(message: message))
        case .notYet(let message, let askAgainAt):
            return .unavailable(.notYetPlannable(message: message, askAgainAt: askAgainAt))
        }
    }
}
