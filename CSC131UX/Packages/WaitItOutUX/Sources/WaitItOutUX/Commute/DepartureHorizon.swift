import Foundation

/// Which saved occurrences get a leave-home calculation. Pure: the caller passes `now`.
///
/// Work is bounded to occurrences that are not over yet and whose planned time, ideal
/// arrival through end, begins within the next seven days. In-progress occurrences stay in,
/// so their details still show the leave-home time and a missed-target note.
public enum DepartureHorizon {
    public static let lookaheadDays = 7
    /// An elapsed window measured from `now`, not a wall-clock time, so it needs no calendar.
    public static let lookahead: TimeInterval = TimeInterval(lookaheadDays) * 24 * 3_600

    /// Half-open window from `now` to `now` plus the lookahead.
    public static func window(at now: Date) -> Range<Date> {
        now..<now.addingTimeInterval(lookahead)
    }

    /// Occurrences of `activities` that need a leave-home time at `now`, ordered by ideal
    /// arrival, then start, then id.
    public static func upcomingOccurrences(of activities: [Activity], at now: Date) -> [ActivityOccurrence] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        return OccurrenceExpander.occurrences(of: activities, in: window(at: now))
            .filter { $0.end > now }
            .sorted(by: isOrderedBefore)
    }

    /// The trip to plan next: the first upcoming occurrence that has not started. Its
    /// leave-home time may already have passed; the UI then says the target may be missed.
    public static func nextTrip(in upcoming: [ActivityOccurrence], at now: Date) -> ActivityOccurrence? {
        upcoming.sorted(by: isOrderedBefore).first { $0.start > now }
    }

    /// True when `occurrence` is inside the horizon at `now`.
    public static func covers(_ occurrence: ActivityOccurrence, at now: Date) -> Bool {
        occurrence.end > now && occurrence.intersects(window(at: now))
    }

    static func isOrderedBefore(_ lhs: ActivityOccurrence, _ rhs: ActivityOccurrence) -> Bool {
        if lhs.idealArrival != rhs.idealArrival { return lhs.idealArrival < rhs.idealArrival }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
