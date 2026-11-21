import Foundation

/// One trip to estimate: from `origin` (the user's home) to `destination`, arriving by
/// `arriveBy`, the occurrence's ideal campus arrival. The activity's start is deliberately
/// absent, so no provider can plan around it. Providers must not read anything else from the app.
public struct CommuteRequest: Hashable, Sendable {
    /// The occurrence the trip serves. Lets a provider correlate answers; never shown.
    public let occurrenceID: OccurrenceID
    /// Where the trip starts: the home set in Settings (step 0006). Always a usable place.
    public let origin: CommutePlace
    public let destination: Destination
    /// The ideal campus arrival. It already includes study, parking, and buffer time.
    public let arriveBy: Date

    public init(occurrenceID: OccurrenceID, origin: CommutePlace, destination: Destination, arriveBy: Date) {
        self.occurrenceID = occurrenceID
        self.origin = origin
        self.destination = destination
        self.arriveBy = arriveBy
    }

    /// The trip for one stored occurrence: from `origin` to `destination` (the activity's own
    /// destination unless the caller resolves it, as the model does for the campus), arriving
    /// by the occurrence's ideal arrival.
    public init(occurrence: ActivityOccurrence, origin: CommutePlace, destination: Destination? = nil) {
        self.init(
            occurrenceID: occurrence.id,
            origin: origin,
            destination: destination ?? occurrence.activity.destination,
            arriveBy: occurrence.idealArrival
        )
    }

    /// The trip for a pending draft: its first occurrence as the editor shows it.
    public init(draft: ActivityDraft, origin: CommutePlace, destination: Destination? = nil, fallbackZone: TimeZone) {
        let day = draft.startDate ?? LocalDate.of(draft.start, in: fallbackZone)
        self.init(
            occurrenceID: OccurrenceID(activityID: draft.id, date: day),
            origin: origin,
            destination: destination ?? draft.destination,
            arriveBy: draft.idealArrival
        )
    }

    /// True when the destination has a name and a valid coordinate, so a provider can be
    /// asked. Otherwise the app reports "no destination" without calling the provider. The
    /// origin needs no check: `CommutePlace` is valid by construction.
    public var hasUsableDestination: Bool {
        !destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && destination.coordinate.isValid
    }

    /// Compares coordinates and the arrival by bit pattern, so a request whose stored
    /// coordinate is NaN still equals itself. Such a request is never sent, but it must not
    /// look changed on every refresh.
    public static func == (lhs: CommuteRequest, rhs: CommuteRequest) -> Bool {
        lhs.occurrenceID == rhs.occurrenceID
            && lhs.origin == rhs.origin
            && lhs.destination.id == rhs.destination.id
            && lhs.destination.name == rhs.destination.name
            && lhs.destination.coordinate.latitude.bitPattern == rhs.destination.coordinate.latitude.bitPattern
            && lhs.destination.coordinate.longitude.bitPattern == rhs.destination.coordinate.longitude.bitPattern
            && lhs.arriveBy.timeIntervalSinceReferenceDate.bitPattern == rhs.arriveBy.timeIntervalSinceReferenceDate.bitPattern
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(occurrenceID)
        hasher.combine(origin)
        hasher.combine(destination.id)
        hasher.combine(destination.name)
        hasher.combine(destination.coordinate.latitude.bitPattern)
        hasher.combine(destination.coordinate.longitude.bitPattern)
        hasher.combine(arriveBy.timeIntervalSinceReferenceDate.bitPattern)
    }
}

/// A provider's answer for one trip, exactly as reported. `WaitItOutModel` validates it
/// before use (see `DepartureCalculation.make`), so a provider never has to.
public struct CommuteEstimate: Equatable, Sendable {
    /// Door-to-door travel time in seconds. Rejected unless finite, above zero, and at most
    /// `CommuteDuration.maximumSeconds`.
    public let travelTime: TimeInterval
    /// Short words the UI shows next to every leave-home time, such as
    /// "Test commute (simulated, not live traffic)". Must not be empty.
    public let sourceLabel: String
    /// When the provider produced this estimate, read from its injected clock.
    public let estimatedAt: Date
    /// True for test or demo values. The UI then adds a TEST DATA badge; a live provider
    /// sets `false` and its label names the real source.
    public let isSimulated: Bool

    public init(travelTime: TimeInterval, sourceLabel: String, estimatedAt: Date, isSimulated: Bool) {
        self.travelTime = travelTime
        self.sourceLabel = sourceLabel
        self.estimatedAt = estimatedAt
        self.isSimulated = isSimulated
    }
}

/// What a provider can answer without failing.
public enum CommuteEstimateResponse: Equatable, Sendable {
    /// A travel time for the trip: the explicit demo path. The app applies its local formula.
    case estimate(CommuteEstimate)
    /// A backend recommendation: shown as is, no local arithmetic.
    case recommendation(DepartureRecommendation)
    /// The provider works but has no estimate for this trip (no route, outside coverage).
    /// `message` is one user-facing sentence and must say when the answer is simulated.
    case unavailable(message: String)
    /// There is nothing to recommend yet, and that changes with time: the trip lies beyond the
    /// backend's forecast, or the backend says there is no need to plan yet. The app shows
    /// `message` and asks again once the clock reaches `askAgainAt`.
    case notYet(message: String, askAgainAt: Date)
}

/// Why a network-backed provider could not answer. Thrown from `estimateCommute(for:)`; the
/// app turns each kind into its own sentence and decides which ones are retried automatically.
public struct CommuteProviderFailure: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No backend address is set.
        case notConfigured
        /// The backend could not be reached.
        case offline
        /// The backend did not answer in time.
        case timedOut
        /// The backend's routing service could not plan the trip.
        case routingUnavailable
        /// The backend answered with an error status.
        case server(status: Int)
        /// The answer could not be read.
        case invalidResponse
        /// The backend did not accept this device's credential.
        case unauthorized

        /// True for failures that can clear on their own, which the live pipeline retries
        /// automatically with a backoff: no connection, a timeout, the routing service, and
        /// server errors (HTTP 500 and above). Everything else waits for Try Again or a
        /// changed input.
        public var isTransient: Bool {
            switch self {
            case .offline, .timedOut, .routingUnavailable:
                return true
            case .server(let status):
                return status >= 500
            case .notConfigured, .invalidResponse, .unauthorized:
                return false
            }
        }
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }
}

/// The commute-estimation boundary. The prototype injects `TestCommuteProvider`; the team
/// replaces it in its own composition root without touching the package. Every request
/// carries the typed home origin and campus destination from Settings (step 0006), so a
/// route-aware provider has what it needs without reaching into the app.
///
/// Contract:
/// - `estimateCommute(for:)` may suspend for as long as it needs and is called off the main
///   actor. It must be safe to call concurrently for different requests.
/// - A provider returns either a travel time (`.estimate`, the explicit demo path, to which
///   the app applies its local formula) or a complete backend recommendation
///   (`.recommendation`, shown as is with no local arithmetic).
/// - Return `.estimate` with the raw travel time, a nonempty source label, the time the
///   estimate was made, and whether it is simulated. The app validates the value and treats
///   zero, negative, nonfinite, or longer-than-12-hour times as an invalid estimate.
/// - Return `.unavailable` when there is simply no estimate for the trip; the app explains it
///   without a retry control. Return `.notYet` when that will change at a known time; the app
///   asks again then. Throw for real failures (network, service, authorization): a
///   `CommuteProviderFailure` gets its own sentence, anything else a generic error, both with
///   Try Again.
/// - Honor task cancellation when practical. The app cancels requests whose activity was
///   edited or deleted, whose arrival or destination changed, or whose provider settings
///   changed, and it discards any answer that arrives for a superseded request, so a late
///   or out-of-order answer can never overwrite a newer one.
/// - For `.estimate`, report the travel time only. Never subtract or add study, parking, or
///   buffer time: the ideal arrival already contains it, and the app computes the leave-home
///   time as ideal arrival minus travel time. For `.recommendation`, the recommended departure
///   is the backend's decision and the app never recomputes it.
public protocol CommuteEstimating: Sendable {
    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse
}
