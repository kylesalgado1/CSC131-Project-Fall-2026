import Foundation

/// The trip-monitoring boundary. The server watches the user's upcoming trips and sends the
/// alerts; the app tells it which trips exist and shows what it reports. `BackendSession`
/// implements the boundary over the team backend, and `WaitItOutModel+Monitoring.swift` decides
/// which trips should be monitored and keeps the server in line with them.

/// One trip the server should monitor: only what the server uses to plan it and to word its
/// alerts (the title, the two coordinates, the ideal arrival, and the time zone). Nothing else
/// about the activity is sent: not its start time, and not the destination's name. Text is
/// valid by construction: the title is trimmed and cut to `maximumTextLength` Unicode scalars,
/// an empty title becomes `fallbackTitle`, and an unusable time-zone identifier becomes
/// `fallbackTimeZoneIdentifier`, so the server never refuses a trip for its wording.
public struct MonitoredTrip: Equatable, Sendable {
    /// The most Unicode scalars the server accepts in a title.
    public static let maximumTextLength = 120
    /// The title sent for an activity without one; the server uses it in notification text.
    public static let fallbackTitle = "Activity"
    /// The most characters the server accepts in a time-zone identifier.
    public static let maximumTimeZoneLength = 64
    /// Sent when an identifier is empty or too long for the server.
    public static let fallbackTimeZoneIdentifier = "UTC"

    /// The occurrence's stable identity; its raw value is the trip id on the server.
    public let id: OccurrenceID
    public let title: String
    public let origin: GeoCoordinate
    public let destination: GeoCoordinate
    /// The ideal arrival: the deadline the backend plans for.
    public let arriveBy: Date
    /// IANA identifier the server formats notification times in.
    public let timeZoneIdentifier: String

    public init(
        id: OccurrenceID,
        title: String,
        origin: GeoCoordinate,
        destination: GeoCoordinate,
        arriveBy: Date,
        timeZoneIdentifier: String
    ) {
        self.id = id
        let boundedTitle = Self.boundedText(title)
        self.title = boundedTitle.isEmpty ? Self.fallbackTitle : boundedTitle
        self.origin = origin
        self.destination = destination
        self.arriveBy = arriveBy
        let zone = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeZoneIdentifier = zone.isEmpty || zone.unicodeScalars.count > Self.maximumTimeZoneLength
            ? Self.fallbackTimeZoneIdentifier
            : zone
    }

    /// `text` trimmed and cut to `maximumTextLength` Unicode scalars, then trimmed again so a
    /// cut never leaves trailing white space.
    static func boundedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > maximumTextLength else { return trimmed }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: trimmed.unicodeScalars.prefix(maximumTextLength))
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where the server stands with one trip.
public enum TripPhase: String, Equatable, Sendable {
    /// Beyond the planning horizon; no plan yet.
    case scheduled
    /// Inside the horizon, waiting for the first recommendation.
    case planning
    /// Has a recommendation; active monitoring has not started.
    case planned
    /// Actively monitored: the phase in which alerts are sent.
    case monitoring
    /// The user said "I've left".
    case departed
    /// The arrival target passed.
    case ended
}

/// The server's recommendation for a monitored trip. Server fields only, so two plans are
/// equal exactly when the server's plan did not change.
public struct MonitoredPlan: Equatable, Sendable {
    public let advice: DepartureAdvice
    public let departAt: Date
    public let arriveAt: Date
    public let driveMinutes: Double
    /// The backend verdict's sentence, verbatim; relative to `evaluatedAt`.
    public let reason: String
    public let confidence: RecommendationConfidence
    public let confidenceReason: String
    public let notes: [String]
    /// Set when even leaving at `departAt` misses the arrival target.
    public let lateBy: TimeInterval?
    /// Time to spare before the arrival target.
    public let margin: TimeInterval?
    /// When the server computed this, on the server's clock.
    public let evaluatedAt: Date
    public let source: RecommendationSource
    /// True when the server could not refresh on schedule; the values are the last known ones.
    public let isStale: Bool

    public init(
        advice: DepartureAdvice,
        departAt: Date,
        arriveAt: Date,
        driveMinutes: Double,
        reason: String,
        confidence: RecommendationConfidence,
        confidenceReason: String,
        notes: [String],
        lateBy: TimeInterval?,
        margin: TimeInterval?,
        evaluatedAt: Date,
        source: RecommendationSource,
        isStale: Bool
    ) {
        self.advice = advice
        self.departAt = departAt
        self.arriveAt = arriveAt
        self.driveMinutes = driveMinutes
        self.reason = reason
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.notes = notes
        self.lateBy = lateBy
        self.margin = margin
        self.evaluatedAt = evaluatedAt
        self.source = source
        self.isStale = isStale
    }
}

/// The last alert the server handled for a trip. "Sent" means the push service accepted it,
/// never that it was delivered.
public struct TripAlert: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case headsUp
        case update
        case leaveNow
        case late
    }

    public enum Status: String, Equatable, Sendable {
        case queued
        case sent
        case dropped
        case failed
    }

    public let kind: Kind
    public let status: Status
    public let at: Date
    public let reason: String?

    public init(kind: Kind, status: Status, at: Date, reason: String?) {
        self.kind = kind
        self.status = status
        self.at = at
        self.reason = reason
    }
}

/// One trip as the server reports it. Server fields only (no device-clock stamps), so equality
/// means "the server's state changed".
public struct MonitoredTripState: Equatable, Sendable {
    public let id: OccurrenceID
    public let arriveBy: Date
    public let phase: TripPhase
    public let plan: MonitoredPlan?
    /// The backend's own explanation when there is no departure to recommend yet.
    public let noPlanReason: String?
    /// For a scheduled trip: when it enters the planning horizon.
    public let planAvailableAt: Date?
    public let monitoringStartsAt: Date?
    public let monitoringStartedAt: Date?
    public let headsUpAt: Date?
    /// Set only when the push service accepted the heads-up.
    public let headsUpSentAt: Date?
    /// Set only when the push service accepted the time-to-leave alert.
    public let leaveAlertSentAt: Date?
    public let lastAlert: TripAlert?
    public let endsAt: Date
    public let nextCheckAt: Date?
    /// The last evaluation failure, cleared by the next success.
    public let lastErrorCode: String?
    public let lastErrorAt: Date?

    public init(
        id: OccurrenceID,
        arriveBy: Date,
        phase: TripPhase,
        plan: MonitoredPlan?,
        noPlanReason: String?,
        planAvailableAt: Date?,
        monitoringStartsAt: Date?,
        monitoringStartedAt: Date?,
        headsUpAt: Date?,
        headsUpSentAt: Date?,
        leaveAlertSentAt: Date?,
        lastAlert: TripAlert?,
        endsAt: Date,
        nextCheckAt: Date?,
        lastErrorCode: String?,
        lastErrorAt: Date?
    ) {
        self.id = id
        self.arriveBy = arriveBy
        self.phase = phase
        self.plan = plan
        self.noPlanReason = noPlanReason
        self.planAvailableAt = planAvailableAt
        self.monitoringStartsAt = monitoringStartsAt
        self.monitoringStartedAt = monitoringStartedAt
        self.headsUpAt = headsUpAt
        self.headsUpSentAt = headsUpSentAt
        self.leaveAlertSentAt = leaveAlertSentAt
        self.lastAlert = lastAlert
        self.endsAt = endsAt
        self.nextCheckAt = nextCheckAt
        self.lastErrorCode = lastErrorCode
        self.lastErrorAt = lastErrorAt
    }

    /// The plan a screen may show as the server's current recommendation at `now`, or `nil`
    /// when the screen has to ask the backend directly. `BackendSession.answer(for:)` and the
    /// model's snapshot comparison both decide through this one rule, so they never disagree.
    /// Every condition has to hold:
    /// - the server is actively monitoring the trip, the phase in which it sends alerts;
    /// - the server runs its monitoring worker (`monitorEnabled`): without it nobody re-checks
    ///   the plan;
    /// - the server could refresh the plan on schedule (it is not stale);
    /// - the plan's departure is still ahead of `now`, on the device clock the screens word
    ///   every time against;
    /// - no time-to-leave or late alert was sent or queued. After either the server stops
    ///   re-checking the trip, so its plan is a record of what was announced, and only a
    ///   direct request can say "leave now" or "no longer reachable" for the present moment.
    public func currentPlan(monitorEnabled: Bool, at now: Date) -> MonitoredPlan? {
        guard phase == .monitoring, monitorEnabled, let plan, !plan.isStale, plan.departAt > now,
              leaveAlertSentAt == nil else {
            return nil
        }
        if let kind = lastAlert?.kind, kind == .leaveNow || kind == .late {
            return nil
        }
        return plan
    }
}

/// Whether alerts can reach this device, as the server sees it.
public struct PushDeliveryStatus: Equatable, Sendable {
    /// The server has push credentials.
    public let serverConfigured: Bool
    /// This device has a usable push token on file.
    public let deviceRegistered: Bool
    /// The notification permission the device last reported.
    public let authorized: Bool
    /// The server's own note: the push service rejected this device's token, or its last send
    /// failed.
    public let lastFailure: String?
    /// Why this device could not register with the push service, in the system's words, while
    /// the server has no token for it. A failure on this device, not a send by the server, so
    /// it is kept apart from `lastFailure`.
    public let registrationFailure: String?

    public init(
        serverConfigured: Bool,
        deviceRegistered: Bool,
        authorized: Bool,
        lastFailure: String?,
        registrationFailure: String? = nil
    ) {
        self.serverConfigured = serverConfigured
        self.deviceRegistered = deviceRegistered
        self.authorized = authorized
        self.lastFailure = lastFailure
        self.registrationFailure = registrationFailure
    }
}

/// The server's monitoring numbers, so the app never hard-codes them.
public struct MonitoringLimits: Equatable, Sendable {
    /// How far ahead of the arrival target the backend can plan a departure.
    public let planningHorizon: TimeInterval
    /// How long before the recommended departure active monitoring starts.
    public let monitorLead: TimeInterval
    /// How long before the recommended departure the heads-up is sent.
    public let headsUpLead: TimeInterval
    /// The smallest change of the recommended departure worth an update alert.
    public let meaningfulShift: TimeInterval
    public let maxTrips: Int

    public init(planningHorizon: TimeInterval, monitorLead: TimeInterval, headsUpLead: TimeInterval, meaningfulShift: TimeInterval, maxTrips: Int) {
        self.planningHorizon = planningHorizon
        self.monitorLead = monitorLead
        self.headsUpLead = headsUpLead
        self.meaningfulShift = meaningfulShift
        self.maxTrips = maxTrips
    }

    /// Used until the server reports its own: 690, 120, 90, and 5 minutes, and 50 trips.
    public static let fallback = MonitoringLimits(
        planningHorizon: 690 * 60,
        monitorLead: 120 * 60,
        headsUpLead: 90 * 60,
        meaningfulShift: 5 * 60,
        maxTrips: 50
    )
}

/// Whether the server's monitoring worker can be relied on.
public struct MonitorHealth: Equatable, Sendable {
    /// This server runs the monitoring worker.
    public let enabled: Bool
    /// An always-on instance was declared, or an external scheduler ticked recently. When
    /// false, alerts can be late or missing while the app is closed.
    public let dependable: Bool
    public let lastTickAt: Date?

    public init(enabled: Bool, dependable: Bool, lastTickAt: Date?) {
        self.enabled = enabled
        self.dependable = dependable
        self.lastTickAt = lastTickAt
    }
}

/// Everything the server acknowledged in one answer.
public struct MonitoringSnapshot: Equatable, Sendable {
    /// How long a snapshot may answer for a monitored trip: 3 minutes on the device clock.
    /// The model refreshes it every minute while a trip is monitored; once two refreshes in a
    /// row are missing, the screens stop presenting the server's plan as current and ask the
    /// backend directly instead.
    public static let lifetime: TimeInterval = 3 * 60

    public let trips: [OccurrenceID: MonitoredTripState]
    public let push: PushDeliveryStatus
    public let limits: MonitoringLimits
    /// Device clock when the answer arrived.
    public let acknowledgedAt: Date
    /// The server's clock in that answer.
    public let serverTime: Date
    public let monitor: MonitorHealth

    public init(
        trips: [OccurrenceID: MonitoredTripState],
        push: PushDeliveryStatus,
        limits: MonitoringLimits,
        acknowledgedAt: Date,
        serverTime: Date,
        monitor: MonitorHealth
    ) {
        self.trips = trips
        self.push = push
        self.limits = limits
        self.acknowledgedAt = acknowledgedAt
        self.serverTime = serverTime
        self.monitor = monitor
    }
}

public enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// Why a monitoring call failed.
public enum TripMonitoringFailure: Error, Equatable, Sendable {
    case notConfigured
    case offline
    case timedOut
    case server(status: Int)
    case invalidResponse
    /// The server has no trip monitoring: its tables are not set up yet (HTTP 503
    /// `monitoring_unavailable`), or it predates the endpoints (a 404 that is not the API's
    /// own). Not retried on the minute ticks; asked again when the app is opened or brought to
    /// the foreground, by a toggle, and by Try Again.
    case unavailableOnServer
    /// The server did not accept the trips; the message is the server's.
    case rejected(message: String)
    /// The server no longer knows this device, so its credential was dropped. The call that
    /// discovered it throws this; the caller must synchronize again, which registers the
    /// device anew and sends every trip again.
    case reregistered
    /// This installation has no server credential, so there was nothing to do.
    case notRegistered
    /// The trip was rescheduled since; monitoring continues for the new time.
    case superseded
    /// The server holds no such trip, so there was nothing to read or end.
    case notMonitored
    /// This device's server credential could not be read or saved.
    case credentialStorage

    /// True for failures that can clear on their own, which the model retries on the minute
    /// ticks: no connection, a timeout, a server error (HTTP 500 and above, which includes the
    /// server's 503 `temporarily_unavailable`), and "too many requests". Everything else waits
    /// for Try Again or a changed input.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut:
            return true
        case .server(let status):
            return status >= 500 || status == 429
        case .notConfigured, .invalidResponse, .unavailableOnServer, .rejected, .reregistered,
             .notRegistered, .superseded, .notMonitored, .credentialStorage:
            return false
        }
    }
}

/// The monitoring service the model talks to.
public protocol TripMonitoring: Sendable {
    /// Makes the server monitor exactly these trips (an idempotent snapshot; an empty list
    /// withdraws monitoring). Returns what the server acknowledged.
    func synchronize(_ trips: [MonitoredTrip]) async throws -> MonitoringSnapshot
    /// Reads the server's current state without changing it.
    func refresh() async throws -> MonitoringSnapshot
    func refreshTrip(_ id: OccurrenceID) async throws -> MonitoredTripState?
    /// "I've left": ends monitoring for the trip whose arrival target is still `arriveBy`.
    func markDeparted(_ id: OccurrenceID, arriveBy: Date) async -> Result<MonitoredTripState, TripMonitoringFailure>
    /// Deletes this installation and its trips from the server at `address` and forgets its
    /// credential for that server. `nil` means the server in use now. Without a credential
    /// there is nothing to do, and no device is ever registered just to be removed. The
    /// credential is forgotten only when the server confirmed the removal, no longer knows the
    /// device, or predates these endpoints; after any other answer it is kept and the call
    /// throws, so the removal can be tried again.
    func unregister(from address: URL?) async throws
    /// Stops the alerts of the server in use without removing this installation: an empty
    /// snapshot under the credential it already has there. Never registers a device and
    /// reports no push token: without a credential, or when the server no longer knows the
    /// device, nothing is monitored there and the call returns normally.
    func withdrawTrips() async throws
    /// Every other server this installation still holds a credential for: servers an address
    /// change left behind that have not confirmed its removal yet. The credential is kept
    /// until they do, so this list outlives a restart.
    func serversLeftBehind() async -> [URL]
    func notificationPermission() async -> NotificationPermission
    /// Shows the system prompt when undetermined; registers for remote notifications when granted.
    func requestNotificationPermission() async -> NotificationPermission
    /// Re-checks permission and registers with the push service again. Never prompts.
    func refreshPushRegistration() async
}

public extension TripMonitoring {
    /// Deletes this installation from the server in use now.
    func unregister() async throws {
        try await unregister(from: nil)
    }

    /// A service that keeps no credentials of its own knows of no server left behind.
    func serversLeftBehind() async -> [URL] {
        []
    }
}

/// Lets the commute provider answer from the server's monitored trip, so screens and
/// notifications agree. `nil` means "not monitored: ask the backend directly".
public protocol MonitoredTripSource: Sendable {
    func answer(for request: CommuteRequest) async throws -> CommuteEstimateResponse?
    /// How far ahead of the arrival target the server plans a departure, when it has said so.
    func planningHorizon() async -> TimeInterval?
}

public extension MonitoredTripSource {
    /// A source that does not know the server's limits leaves the provider's own value in use.
    func planningHorizon() async -> TimeInterval? {
        nil
    }
}

/// Implemented by the host over the system notification and application APIs. The package
/// never names those APIs.
public protocol PushRegistering: Sendable {
    func authorizationStatus() async -> NotificationPermission
    func requestPermission() async -> NotificationPermission
    @MainActor func registerForRemoteNotifications()
    /// "sandbox" or "production".
    var apnsEnvironment: String { get }
}
