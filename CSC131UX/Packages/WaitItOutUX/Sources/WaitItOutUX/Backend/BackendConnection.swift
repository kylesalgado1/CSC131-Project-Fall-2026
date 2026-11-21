import Foundation

/// Where the connection to the team backend stands, for the Settings "Data source" status
/// row. Never stored and never measured by a request of its own: it is read from what the
/// screens already hold (leave-home answers, the trip synchronization, the Map's route), so
/// "connected" is claimed only for a server that actually answered.
public enum BackendConnection: Equatable, Sendable {
    /// One failed request: when it was made and what went wrong, in complete sentences.
    public struct Failure: Equatable, Sendable {
        public let at: Date
        public let problem: String

        public init(at: Date, problem: String) {
            self.at = at
            self.problem = problem
        }
    }

    /// The Demo data mode is chosen, so the backend is not asked for leave-home times.
    case demo
    /// No server address is set.
    case notConfigured
    /// An address is set and nothing has been answered or has failed yet.
    case unanswered(host: String)
    /// The newest thing known about the server is an answer, received at `at`.
    case connected(host: String, at: Date)
    /// The newest thing known about the server is a failed request.
    case failing(host: String, at: Date, problem: String)

    /// Pure: the newest event decides. A failure as new as the last answer counts as the
    /// failure, so a server that just stopped answering is never called connected.
    public static func resolve(isLive: Bool, address: URL?, lastAnswerAt: Date?, lastFailure: Failure?) -> BackendConnection {
        guard isLive else { return .demo }
        guard let address else { return .notConfigured }
        let host = hostText(of: address)
        if let lastFailure {
            guard let lastAnswerAt, lastAnswerAt > lastFailure.at else {
                return .failing(host: host, at: lastFailure.at, problem: lastFailure.problem)
            }
            return .connected(host: host, at: lastAnswerAt)
        }
        if let lastAnswerAt {
            return .connected(host: host, at: lastAnswerAt)
        }
        return .unanswered(host: host)
    }

    /// "backend.example", or "localhost:3000" when the address names a port.
    public static func hostText(of address: URL) -> String {
        let host = address.host ?? address.absoluteString
        guard let port = address.port else { return host }
        return "\(host):\(port)"
    }
}

extension OccurrenceFormatter {
    /// The Settings "Data source" status row: "Connected to backend.example. Last answer
    /// 7:02 AM.", "Not configured. Enter a server address to use live data.", or the last
    /// failure with its time. Times name the day when it is not today.
    public func backendStatusText(for connection: BackendConnection, at now: Date) -> String {
        switch connection {
        case .demo:
            return "Not in use: the Demo data mode is on."
        case .notConfigured:
            return "Not configured. Enter a server address to use live data."
        case .unanswered(let host):
            return "Using \(host). No answer has arrived yet."
        case .connected(let host, let at):
            return "Connected to \(host). Last answer \(monitoringTime(at, at: now))."
        case .failing(let host, let at, let problem):
            return "The last request to \(host) failed (\(monitoringTime(at, at: now))). \(problem)"
        }
    }
}

extension WaitItOutModel {
    /// The host's own server address, which an empty Settings field uses; `nil` when the host
    /// has none or supplied no live backend.
    public var defaultBackendURL: URL? {
        liveBackend?.configuration.defaultBaseURL
    }

    /// Where the connection to the team backend stands, read from the state the screens
    /// already show: the newest leave-home answer or failure, the trip synchronization, and the
    /// Map's route. Nothing is requested for it. A monitored plan is not counted as an answer
    /// (its time is the server's evaluation, not a contact); the synchronization that
    /// delivered it is. Neither is what the provider says by itself without a request: that
    /// an ideal arrival has passed, or that a trip lies beyond the forecast.
    public var backendConnection: BackendConnection {
        guard usesLiveBackend else { return .demo }
        var lastAnswerAt: Date?
        var lastFailure: BackendConnection.Failure?
        func answered(_ date: Date) {
            if lastAnswerAt.map({ date > $0 }) ?? true {
                lastAnswerAt = date
            }
        }
        func failed(_ date: Date, _ problem: String) {
            if lastFailure.map({ date > $0.at }) ?? true {
                lastFailure = BackendConnection.Failure(at: date, problem: problem)
            }
        }
        func received(_ calculation: DepartureCalculation) {
            if let recommendation = calculation.recommendation, !recommendation.isMonitored {
                answered(recommendation.receivedAt)
            }
        }
        let formatter = OccurrenceFormatter(calculator: weekCalculator, locale: weekCalculator.calendar.locale ?? .autoupdatingCurrent)
        var entries = Array(departures.values)
        if let draftDeparture {
            entries.append(draftDeparture)
        }
        for entry in entries {
            switch entry.state {
            case .success(let calculation), .refreshing(let calculation):
                received(calculation)
            case .stale(let calculation, let failure):
                received(calculation)
                if failure != .staleServerData {
                    failed(entry.attemptedAt, formatter.departureFailureSentence(failure))
                }
            case .error(let failure):
                failed(entry.attemptedAt, formatter.departureFailureSentence(failure))
            case .unavailable(.noEstimate(let message)):
                // The backend answered that it cannot plan this trip. The provider's own
                // sentence for an arrival that has passed involved no request at all.
                if message != BackendCommuteProvider.arrivalPassedMessage {
                    answered(entry.attemptedAt)
                }
            case .loading, .unavailable:
                break
            }
        }
        switch monitoringStatus {
        case .active(let acknowledgedAt, _):
            answered(acknowledgedAt)
        case .failed(let failure, let lastAcknowledgedAt):
            if let lastAcknowledgedAt {
                answered(lastAcknowledgedAt)
            }
            if Self.isConnectionFailure(failure), let attemptedAt = monitoringTracking.lastAttemptAt {
                failed(attemptedAt, MonitoringText.failureSentence(failure))
            }
        case .off, .paused, .settingsUnreadable, .pending:
            break
        }
        if routeState.geometry != nil, let loadedAt = routeTracking.loadedAt {
            answered(loadedAt)
        }
        return BackendConnection.resolve(isLive: true, address: backendBaseURL, lastAnswerAt: lastAnswerAt, lastFailure: lastFailure)
    }

    /// True for the synchronization failures that say something about reaching the server. A
    /// refused set or a server without monitoring did answer, so it is not a connection failure.
    nonisolated static func isConnectionFailure(_ failure: TripMonitoringFailure) -> Bool {
        switch failure {
        case .offline, .timedOut, .server, .invalidResponse:
            return true
        case .notConfigured, .unavailableOnServer, .rejected, .reregistered, .notRegistered, .superseded,
             .notMonitored, .credentialStorage:
            return false
        }
    }
}
