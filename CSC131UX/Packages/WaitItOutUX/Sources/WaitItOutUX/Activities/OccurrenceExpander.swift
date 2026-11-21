import Foundation

/// Pure expansion of activities into dated occurrences for a bounded interval.
///
/// **Inclusion.** An occurrence belongs to a requested half-open interval when any part of
/// its planned time, ideal arrival through end, falls inside it. Overnight activities and
/// previous-day arrivals therefore appear in both weeks they touch, once in each, with the
/// same id in both.
///
/// **Repeats.** A repeating activity happens on each selected weekday, starting with the
/// activity's own first day and with no end date in this prototype step. Each occurrence
/// starts at the stored activity's wall-clock start time, in the activity's time zone, on
/// that local day; it keeps the stored activity's elapsed duration and arrival lead exactly.
/// Days are counted on the calendar, never as multiples of 86 400 seconds, so weeks that
/// contain a daylight-saving transition stay aligned to the clock.
///
/// **Daylight-saving policy.** The wall-clock start is resolved by `LocalTimeResolver`: a
/// start time that happens twice resolves to its first occurrence; a start time that never
/// happens resolves to the first instant after the gap. Because end and arrival are elapsed
/// offsets from the resolved start, an activity that spans the transition itself keeps its
/// duration, and its clock-face end time shifts by the transition instead.
///
/// **Bounds.** Expansion only visits days that can intersect the requested interval. A
/// request longer than `maximumSpan` is trimmed to its first `maximumSpan` seconds.
public enum OccurrenceExpander {
    /// Longest interval expanded in one call: 366 days.
    public static let maximumSpan: TimeInterval = 366 * 86_400

    /// Occurrences of every activity that intersect `range`, sorted by start.
    public static func occurrences(of activities: [Activity], in range: Range<Date>) -> [ActivityOccurrence] {
        activities
            .flatMap { occurrences(of: $0, in: range) }
            .sorted(by: isOrderedBefore)
    }

    /// Occurrences of one activity that intersect `range`, in date order. Activities whose
    /// zone is unknown, whose duration is not positive, or whose repeat set is empty produce
    /// nothing; they never pass validation, so this only guards direct callers.
    public static func occurrences(of activity: Activity, in range: Range<Date>) -> [ActivityOccurrence] {
        guard !range.isEmpty, let zone = activity.timeZone else { return [] }
        let duration = activity.duration
        let lead = activity.arrivalLead
        guard duration.isFinite, duration > 0, lead.isFinite, lead >= 0 else { return [] }

        let bounded = bound(range)
        let anchor = LocalDateTime.of(activity.start, in: zone)
        let first = ActivityOccurrence(
            id: OccurrenceID(activityID: activity.id, date: anchor.date),
            activity: activity,
            start: activity.start,
            end: activity.end,
            idealArrival: activity.idealArrival
        )

        guard let weekdays = activity.repeatWeekdays else {
            return first.intersects(bounded) ? [first] : []
        }
        guard !weekdays.isEmpty else { return [] }

        // Any intersecting occurrence starts no earlier than range start minus duration and
        // no later than range end plus lead. Widen by a day on each side to absorb zone
        // offsets and the resolver policy, then never look before the series' first day.
        var firstDay = LocalDate.of(bounded.lowerBound.addingTimeInterval(-duration), in: zone).adding(days: -1)
        let lastDay = LocalDate.of(bounded.upperBound.addingTimeInterval(lead), in: zone).adding(days: 1)
        if firstDay < anchor.date {
            firstDay = anchor.date
        }
        guard firstDay <= lastDay else { return [] }

        var result: [ActivityOccurrence] = []
        for dayNumber in firstDay.dayNumber...lastDay.dayNumber {
            let day = LocalDate(dayNumber: dayNumber)
            guard weekdays.contains(day.weekday) else { continue }
            let occurrence: ActivityOccurrence
            if day == anchor.date {
                occurrence = first
            } else {
                let start = LocalTimeResolver.instant(of: anchor.time, on: day, in: zone)
                occurrence = ActivityOccurrence(
                    id: OccurrenceID(activityID: activity.id, date: day),
                    activity: activity,
                    start: start,
                    end: start.addingTimeInterval(duration),
                    idealArrival: start.addingTimeInterval(-lead)
                )
            }
            if occurrence.intersects(bounded) {
                result.append(occurrence)
            }
        }
        return result
    }

    /// Deterministic order: start, then end, then title, then id.
    public static func isOrderedBefore(_ lhs: ActivityOccurrence, _ rhs: ActivityOccurrence) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.activity.title != rhs.activity.title { return lhs.activity.title < rhs.activity.title }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func bound(_ range: Range<Date>) -> Range<Date> {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span.isFinite, span > maximumSpan else { return range }
        return range.lowerBound..<range.lowerBound.addingTimeInterval(maximumSpan)
    }
}
