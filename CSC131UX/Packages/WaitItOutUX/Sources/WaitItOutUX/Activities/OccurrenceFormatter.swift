import Foundation

/// Human-readable text for occurrences as seen from one calendar day. Pure: output depends
/// only on the inputs, and times are rendered in the calculator's zone.
public struct OccurrenceFormatter: Sendable {
    public let calculator: WeekCalculator
    public let locale: Locale

    public init(calculator: WeekCalculator, locale: Locale = .autoupdatingCurrent) {
        self.calculator = calculator
        self.locale = locale
    }

    /// "9:00 – 9:50 AM" when the activity lies within `day`; otherwise the weekday is added
    /// to each end, such as "Sat 11:00 PM – Sun 1:00 AM".
    public func timeRange(for occurrence: ActivityOccurrence, on day: Range<Date>) -> String {
        let within = occurrence.start >= day.lowerBound && occurrence.end <= day.upperBound
        let style = within ? intervalStyle : intervalStyle.weekday(.abbreviated)
        return occurrence.activityInterval.formatted(style)
    }

    /// "Arrive by 8:15 AM", with the weekday added when arrival falls outside `day`, and an
    /// explicit start when the activity itself begins on a later day.
    public func arrivalText(for occurrence: ActivityOccurrence, on day: Range<Date>) -> String {
        let arrival = occurrence.idealArrival
        let arrivalText = day.contains(arrival) ? time(arrival) : weekdayTime(arrival)
        if occurrence.start >= day.upperBound {
            return "Arrive by \(arrivalText) for the \(weekdayTime(occurrence.start)) start"
        }
        return "Arrive by \(arrivalText)"
    }

    /// "Repeats Mon, Wed, Fri", or `nil` for a one-time activity.
    public func recurrenceText(for activity: Activity) -> String? {
        activity.repeatWeekdays.map { "Repeats \(Weekday.summary(of: $0, in: calculator.calendar))" }
    }

    /// Names the activity's zone when it differs from the calendar's zone, or `nil`.
    public func timeZoneNote(for activity: Activity) -> String? {
        guard activity.timeZoneIdentifier != calculator.timeZone.identifier else { return nil }
        let scheduled = activity.timeZone.map(zoneName) ?? activity.timeZoneIdentifier
        return "Scheduled in \(scheduled); shown in \(zoneName(calculator.timeZone))"
    }

    /// Spoken form for VoiceOver, such as
    /// "Sample morning class, sample data, 9:00 AM to 9:50 AM, arrive by 8:15 AM, repeats Monday, Wednesday, Friday".
    public func accessibilityLabel(for occurrence: ActivityOccurrence, on day: Range<Date>) -> String {
        var parts = [occurrence.activity.title]
        if occurrence.isSample {
            parts.append("sample data")
        }
        let within = occurrence.start >= day.lowerBound && occurrence.end <= day.upperBound
        let startText = within ? time(occurrence.start) : weekdayTime(occurrence.start)
        let endText = within ? time(occurrence.end) : weekdayTime(occurrence.end)
        parts.append("\(startText) to \(endText)")
        parts.append(arrivalText(for: occurrence, on: day).lowercased())
        if let weekdays = occurrence.activity.repeatWeekdays {
            parts.append("repeats \(Weekday.spokenSummary(of: weekdays, in: calculator.calendar))")
        }
        if let note = timeZoneNote(for: occurrence.activity) {
            parts.append(note.lowercased())
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Time grid and details (step 0003)

    /// Label for an hour row, such as "9 AM" or "09" depending on the locale. The fall-back
    /// day labels two rows "1 AM" and the spring-forward day has no "2 AM" row.
    public func hourLabel(for instant: Date) -> String {
        Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .hour(.defaultDigits(amPM: .abbreviated))
            .format(instant)
    }

    /// "9:00 AM": a single clock time in the calendar's zone.
    public func clockTime(_ date: Date) -> String {
        time(date)
    }

    /// Spoken form of the current-time line, such as "Current time, 12:00 PM".
    public func currentTimeLabel(for now: Date) -> String {
        "Current time, \(time(now))"
    }

    /// Full date such as "Friday, October 30, 2026".
    public func fullDate(_ date: Date) -> String {
        Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .year()
            .format(date)
    }

    /// "50 minutes", "1 hour", "5 hours 15 minutes". Whole minutes only; invalid lengths read "0 minutes".
    public func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "0 minutes" }
        let totalMinutes = Int((duration / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(CountPhrase.make(hours, singular: "hour", plural: "hours"))
        }
        if minutes > 0 || hours == 0 {
            parts.append(CountPhrase.make(minutes, singular: "minute", plural: "minutes"))
        }
        return parts.joined(separator: " ")
    }

    /// Short text for the arrival marker on the time grid: "Arrive 8:15 AM", or when the
    /// activity itself starts on a later day, "Arrive 11:45 PM for Sun 12:30 AM start".
    public func arrivalMarkerText(for occurrence: ActivityOccurrence, on day: Range<Date>) -> String {
        if occurrence.start >= day.upperBound {
            return "Arrive \(time(occurrence.idealArrival)) for \(weekdayTime(occurrence.start)) start"
        }
        return "Arrive \(time(occurrence.idealArrival))"
    }

    /// Spoken form of the arrival marker, naming the activity it belongs to.
    public func arrivalMarkerAccessibilityLabel(for occurrence: ActivityOccurrence, on day: Range<Date>) -> String {
        let when = day.contains(occurrence.idealArrival) ? time(occurrence.idealArrival) : weekdayTime(occurrence.idealArrival)
        var text = "Ideal arrival \(when) for \(occurrence.activity.title)"
        if occurrence.start >= day.upperBound {
            text += ", which starts \(weekdayTime(occurrence.start))"
        }
        return text
    }

    /// Arrival line for the detail sheet. Adds the date when arrival is on a different day
    /// than the activity's start, such as "11:45 PM on Saturday, October 31".
    public func detailArrivalText(for occurrence: ActivityOccurrence) -> String {
        if calculator.isSameDay(occurrence.idealArrival, occurrence.start) {
            return time(occurrence.idealArrival)
        }
        let dateText = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .format(occurrence.idealArrival)
        return "\(time(occurrence.idealArrival)) on \(dateText)"
    }

    /// How long before the start the user wants to be on campus: "45 minutes before start".
    public func arrivalLeadText(for occurrence: ActivityOccurrence) -> String {
        let lead = occurrence.start.timeIntervalSince(occurrence.idealArrival)
        guard lead > 0 else { return "At the start time" }
        return "\(durationText(lead)) before start"
    }

    /// Summary of one day for VoiceOver and the selected-day title: "2 activities", "No
    /// activities", with a note when only an arrival for a later activity falls on the day.
    public func daySummary(blockCount: Int, arrivalOnlyCount: Int) -> String {
        var text = blockCount == 0 ? "No activities" : CountPhrase.make(blockCount, singular: "activity", plural: "activities")
        if arrivalOnlyCount > 0 {
            text += arrivalOnlyCount == 1 ? ", plus an arrival for an activity that starts the next day" : ", plus \(arrivalOnlyCount) arrivals for activities that start the next day"
        }
        return text
    }

    private var intervalStyle: Date.IntervalFormatStyle {
        Date.IntervalFormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .hour()
            .minute()
    }

    private var timeStyle: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .hour()
            .minute()
    }

    private func time(_ date: Date) -> String {
        timeStyle.format(date)
    }

    private func weekdayTime(_ date: Date) -> String {
        timeStyle.weekday(.abbreviated).format(date)
    }

    private func zoneName(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: locale) ?? zone.identifier
    }
}
