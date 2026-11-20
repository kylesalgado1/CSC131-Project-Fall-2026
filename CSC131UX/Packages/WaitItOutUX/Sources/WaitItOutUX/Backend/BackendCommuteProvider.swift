import Foundation

/// The live `CommuteEstimating` provider: asks the team backend's POST /verdict and returns
/// its decision as a complete `DepartureRecommendation`. The backend decides the departure;
/// nothing here subtracts a travel time or adds a buffer.
///
/// Order of work for one request:
/// 1. An ideal arrival that has passed is answered locally, without a request.
/// 2. When a monitored-trip source answers for the request (the server still keeps its plan
///    for that trip current, see `MonitoredTripState.currentPlan`), its answer is used, so
///    screens and notifications agree.
/// 3. A trip beyond the backend's planning horizon is answered locally with `.notYet`, without
///    a request, and asked again when it enters the horizon. This respects the backend's
///    forecast reach without spending its traffic quota on far-off occurrences. The horizon is
///    the one the server reported through the monitored-trip source, when there is one.
/// 4. Otherwise POST /verdict with the origin, the destination, and the ideal arrival.
public final class BackendCommuteProvider: CommuteEstimating, @unchecked Sendable {
    /// How far ahead of the arrival target the backend can plan a departure when the server
    /// has not said otherwise: 690 minutes (11 hours 30 minutes).
    public static let defaultPlanningHorizon: TimeInterval = 690 * 60
    /// How long a "no need to plan yet" verdict is kept before the backend is asked again.
    public static let noRushRecheckInterval: TimeInterval = 10 * 60

    /// Shown when the backend has no traffic data for the route and sent no sentence of its own.
    public static let noCoverageMessage = "There is not enough traffic data for this route yet."
    /// Shown when the ideal arrival has already passed.
    public static let arrivalPassedMessage = "The ideal arrival time has passed."

    private let client: BackendClient
    private let clock: any WallClock
    private let monitoredTrips: (any MonitoredTripSource)?
    private let describe: @Sendable (Date) -> String
    private let lock = NSLock()
    private var horizon: TimeInterval

    /// - Parameters:
    ///   - monitoredTrips: answers from the server's monitored trips, when there are any.
    ///   - planningHorizon: the backend's planning reach; `setPlanningHorizon` updates it later.
    ///   - describe: how a date is written inside the "will appear after" sentence. The default
    ///     uses the device's locale and time zone, such as "Mon, Nov 2, 7:45 PM".
    public init(
        client: BackendClient,
        clock: any WallClock,
        monitoredTrips: (any MonitoredTripSource)? = nil,
        planningHorizon: TimeInterval = BackendCommuteProvider.defaultPlanningHorizon,
        describe: @escaping @Sendable (Date) -> String = BackendCommuteProvider.deviceTimeDescription
    ) {
        self.client = client
        self.clock = clock
        self.monitoredTrips = monitoredTrips
        self.describe = describe
        horizon = Self.usableHorizon(planningHorizon)
    }

    /// The backend's planning reach in use now.
    public var planningHorizon: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return horizon
    }

    /// Adopts the planning reach the server reported. Unusable values are ignored.
    public func setPlanningHorizon(_ planningHorizon: TimeInterval) {
        guard planningHorizon.isFinite, planningHorizon > 0 else { return }
        lock.lock()
        horizon = planningHorizon
        lock.unlock()
    }

    public func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        let now = clock.now()
        guard request.arriveBy > now else {
            return .unavailable(message: Self.arrivalPassedMessage)
        }
        if let monitored = try await monitoredTrips?.answer(for: request) {
            return monitored
        }
        // The server's own limit, once a snapshot reported it, replaces the configured reach.
        var reach = planningHorizon
        if let reported = await monitoredTrips?.planningHorizon(), reported.isFinite, reported > 0 {
            reach = reported
        }
        if request.arriveBy.timeIntervalSince(now) > reach {
            let askAgainAt = request.arriveBy.addingTimeInterval(-reach)
            return .notYet(message: Self.beyondHorizonMessage(horizon: reach, availableAfter: describe(askAgainAt)), askAgainAt: askAgainAt)
        }
        let answer = try await client.verdict(
            origin: request.origin.coordinate,
            destination: request.destination.coordinate,
            arriveBy: request.arriveBy
        )
        switch answer {
        case .noCoverage(let message):
            return .unavailable(message: message ?? Self.noCoverageMessage)
        case .verdict(let response):
            return try Self.response(for: response, receivedAt: clock.now(), describe: describe)
        }
    }

    // MARK: Mapping (pure)

    /// Maps a verdict to the app's answer. Wire spellings are mapped explicitly; an unknown
    /// action or a missing required field is an unreadable answer, while an unknown or missing
    /// source is simply "unknown".
    static func response(
        for response: WireVerdictResponse,
        receivedAt: Date,
        describe: (Date) -> String
    ) throws -> CommuteEstimateResponse {
        let verdict = response.verdict
        guard let reason = verdict.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw CommuteProviderFailure(.invalidResponse)
        }
        if verdict.action == "no_rush" {
            // The backend's sentence is relative to when it was written, so it carries its time.
            return .notYet(
                message: "\(reason) Checked \(describe(receivedAt)).",
                askAgainAt: receivedAt.addingTimeInterval(noRushRecheckInterval)
            )
        }
        let advice: DepartureAdvice
        let departure: WireDeparture?
        switch verdict.action {
        case "leave_now":
            advice = .leaveNow
            departure = verdict.leaveNow
        case "wait":
            advice = .wait
            departure = verdict.recommended
        case "leave_later":
            advice = .leaveLater
            departure = verdict.recommended
        default:
            throw CommuteProviderFailure(.invalidResponse)
        }
        guard let departure,
              let confidence = confidence(for: verdict.confidence),
              let generatedAt = verdict.generatedAt else {
            throw CommuteProviderFailure(.invalidResponse)
        }
        var lateBy: TimeInterval?
        if advice == .leaveNow, let minutes = verdict.lateByMinutes, minutes.isFinite, minutes > 0 {
            lateBy = minutes * 60
        }
        var margin: TimeInterval?
        if let minutes = verdict.deadline?.marginMinutes, minutes.isFinite, minutes >= 0 {
            margin = minutes * 60
        }
        return .recommendation(DepartureRecommendation(
            advice: advice,
            recommendedDeparture: departure.departAt,
            predictedArrival: departure.arriveAt,
            reason: reason,
            confidence: confidence,
            confidenceReason: verdict.confidenceReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            notes: (verdict.notes ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            lateBy: lateBy,
            margin: margin,
            generatedAt: generatedAt,
            receivedAt: receivedAt,
            source: source(for: response.source),
            isStale: false,
            isMonitored: false
        ))
    }

    /// "High", "Medium", or "Low" in any letter case; anything else is `nil`.
    static func confidence(for text: String?) -> RecommendationConfidence? {
        switch text?.lowercased() {
        case "high":
            return .high
        case "medium":
            return .medium
        case "low":
            return .low
        default:
            return nil
        }
    }

    /// The wire's source mapped explicitly. A missing source, as an older server sends, is
    /// unknown without live traffic; an unknown baseline string is not a failure.
    static func source(for wire: WireSource?) -> RecommendationSource {
        guard let wire else { return .unknown }
        let baseline: RecommendationSource.Baseline
        switch wire.baseline?.lowercased() {
        case "tomtom":
            baseline = .tomTom
        case "pems":
            baseline = .pems
        case "fixture":
            baseline = .fixture
        default:
            baseline = .unknown
        }
        return RecommendationSource(baseline: baseline, usedFallback: wire.fallback ?? false, hasLiveTraffic: wire.live ?? false)
    }

    /// "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear
    /// after Mon, Nov 2, 7:45 PM." The hours come from `horizon`.
    static func beyondHorizonMessage(horizon: TimeInterval, availableAfter: String) -> String {
        "The traffic forecast reaches about \(hoursText(horizon)) ahead. A leave-home time will appear after \(availableAfter)."
    }

    /// "11.5 hours", "12 hours", "1 hour": hours to one decimal, without a trailing ".0".
    static func hoursText(_ interval: TimeInterval) -> String {
        let tenths = Int((max(0, interval) / 360).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        if fraction == 0 {
            return whole == 1 ? "1 hour" : "\(whole) hours"
        }
        return "\(whole).\(fraction) hours"
    }

    /// The default wording of a date inside a sentence: the device's locale and time zone.
    public static let deviceTimeDescription: @Sendable (Date) -> String = { date in
        date.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private static func usableHorizon(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : defaultPlanningHorizon
    }
}
