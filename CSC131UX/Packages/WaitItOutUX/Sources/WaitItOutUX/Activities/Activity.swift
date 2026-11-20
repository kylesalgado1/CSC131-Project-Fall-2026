import Foundation

/// Who created an activity. Sample content is always labeled and can be cleared on its own
/// without touching anything the user created.
public enum ActivitySource: String, Codable, Sendable, Hashable {
    case user
    case sample
}

/// A scheduled campus activity.
///
/// The user sets the activity's start and end first and the ideal campus arrival second.
/// There is deliberately no stored departure or leave-home time: a later step computes it
/// from `idealArrival` and a commute estimate, and shows it read-only.
///
/// `start`, `end`, and `idealArrival` are instants. `timeZoneIdentifier` names the zone whose
/// wall clock the schedule is expressed in. Weekly repeats keep the wall-clock start time in
/// that zone on every selected weekday; see `OccurrenceExpander` for the exact rules.
public struct Activity: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    /// When the user wants to be on campus. Already includes any study, parking, or buffer
    /// time the user cares about; nothing else is added later.
    public var idealArrival: Date
    public var destination: Destination
    public var timeZoneIdentifier: String
    /// Weekdays on which the activity repeats every week, or `nil` for a one-time activity.
    /// When present it must be nonempty and must contain the weekday of `start`.
    public var repeatWeekdays: Set<Weekday>?
    public var source: ActivitySource

    public init(
        id: UUID = UUID(),
        title: String,
        start: Date,
        end: Date,
        idealArrival: Date,
        destination: Destination,
        timeZoneIdentifier: String,
        repeatWeekdays: Set<Weekday>? = nil,
        source: ActivitySource = .user
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.idealArrival = idealArrival
        self.destination = destination
        self.timeZoneIdentifier = timeZoneIdentifier
        self.repeatWeekdays = repeatWeekdays
        self.source = source
    }

    public var isRecurring: Bool {
        repeatWeekdays != nil
    }

    public var isSample: Bool {
        source == .sample
    }

    /// The schedule's zone, or `nil` when the identifier is unknown on this device.
    public var timeZone: TimeZone? {
        TimeZone(identifier: timeZoneIdentifier)
    }

    /// Length of the activity. Zero or negative only for invalid drafts.
    public var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    /// How long before the activity starts the user wants to be on campus.
    public var arrivalLead: TimeInterval {
        start.timeIntervalSince(idealArrival)
    }

    /// Calendar day of `start` in the activity's zone; `nil` when the zone is unknown.
    public var startLocalDate: LocalDate? {
        timeZone.map { LocalDate.of(start, in: $0) }
    }

    /// Weekday of `start` in the activity's zone; `nil` when the zone is unknown.
    public var startWeekday: Weekday? {
        startLocalDate?.weekday
    }
}
