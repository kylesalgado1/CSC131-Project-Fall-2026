import Foundation

/// What the backend advises, mirroring its verdict actions that carry a departure.
public enum DepartureAdvice: String, Equatable, Sendable {
    /// Leave at the recommended departure, which is the moment the backend answered.
    case leaveNow
    /// Wait a short while: traffic eases and the arrival target is still met.
    case wait
    /// Leave at a planned later time.
    case leaveLater
}

/// How sure the backend is about a recommendation.
public enum RecommendationConfidence: String, Equatable, Sendable {
    case high
    case medium
    case low

    /// "High", "Medium", or "Low".
    public var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// Where the backend's traffic figures came from, shown honestly in the UI.
public struct RecommendationSource: Equatable, Sendable {
    /// Which source produced the typical drive times.
    public enum Baseline: String, Equatable, Sendable {
        case tomTom
        case pems
        case fixture
        case unknown
    }

    public let baseline: Baseline
    /// True when the backend's primary source failed and its fallback answered.
    public let usedFallback: Bool
    /// True when live conditions were available for the answer.
    public let hasLiveTraffic: Bool

    public init(baseline: Baseline, usedFallback: Bool, hasLiveTraffic: Bool) {
        self.baseline = baseline
        self.usedFallback = usedFallback
        self.hasLiveTraffic = hasLiveTraffic
    }

    /// What a server that does not report its source is taken to be: unknown, without live traffic.
    public static let unknown = RecommendationSource(baseline: .unknown, usedFallback: false, hasLiveTraffic: false)

    /// Short words shown next to every recommendation. Never claims live traffic that the
    /// backend did not report.
    public var label: String {
        switch baseline {
        case .fixture:
            return "Test fixture traffic, not live"
        case .tomTom:
            return hasLiveTraffic
                ? "Live traffic (TomTom) via the team backend"
                : "Typical traffic (TomTom); live traffic unavailable"
        case .pems:
            return usedFallback
                ? "Historical traffic (PeMS fallback); TomTom unavailable"
                : "Historical traffic (PeMS)"
        case .unknown:
            return "Team backend"
        }
    }

    /// True for a fallback source, missing live traffic, or fixture data.
    public var isDegraded: Bool {
        usedFallback || !hasLiveTraffic || baseline == .fixture
    }
}

/// A complete departure recommendation from the team backend. The app shows it as is: the
/// recommended departure is the leave-home time, and nothing is added or subtracted locally.
public struct DepartureRecommendation: Equatable, Sendable {
    /// How long the backend's `reason` sentence may be shown. It is worded relative to
    /// `generatedAt` ("leaving in 11 hours"), so it is hidden once it is older than this.
    public static let reasonLifetime: TimeInterval = 2 * 60

    public let advice: DepartureAdvice
    /// Shown as the leave-home time verbatim.
    public let recommendedDeparture: Date
    public let predictedArrival: Date
    /// The backend's sentence, verbatim.
    public let reason: String
    public let confidence: RecommendationConfidence
    public let confidenceReason: String
    public let notes: [String]
    /// Set when the arrival target is no longer achievable: how late the predicted arrival is.
    public let lateBy: TimeInterval?
    /// Time to spare before the ideal arrival.
    public let margin: TimeInterval?
    /// The backend's stamp, for display.
    public let generatedAt: Date
    /// Device clock when the app obtained or confirmed it. Drives freshness.
    public let receivedAt: Date
    public let source: RecommendationSource
    /// True when the server could not refresh it on schedule.
    public let isStale: Bool
    /// True when it is the server-side monitored trip's recommendation.
    public let isMonitored: Bool

    public init(
        advice: DepartureAdvice,
        recommendedDeparture: Date,
        predictedArrival: Date,
        reason: String,
        confidence: RecommendationConfidence,
        confidenceReason: String,
        notes: [String] = [],
        lateBy: TimeInterval? = nil,
        margin: TimeInterval? = nil,
        generatedAt: Date,
        receivedAt: Date,
        source: RecommendationSource,
        isStale: Bool = false,
        isMonitored: Bool = false
    ) {
        self.advice = advice
        self.recommendedDeparture = recommendedDeparture
        self.predictedArrival = predictedArrival
        self.reason = reason
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.notes = notes
        self.lateBy = lateBy
        self.margin = margin
        self.generatedAt = generatedAt
        self.receivedAt = receivedAt
        self.source = source
        self.isStale = isStale
        self.isMonitored = isMonitored
    }

    /// True while the backend's relative `reason` sentence still reads correctly at `now`.
    /// Judged on the device clock from `receivedAt`, the device's equivalent of `generatedAt`,
    /// so a server clock that runs ahead or behind cannot hide or prolong the sentence.
    public func isReasonCurrent(at now: Date) -> Bool {
        max(0, now.timeIntervalSince(receivedAt)) <= Self.reasonLifetime
    }
}
