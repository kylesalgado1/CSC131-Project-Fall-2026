import Foundation

/// Text for the activity editor and the calendar's unsaved-change bar (step 0004). Pure:
/// output depends only on the inputs. The editor builds its formatter in the activity's zone
/// so this text matches its pickers; the calendar bar uses the calendar's zone.
extension OccurrenceFormatter {
    /// "Ends the next day, Saturday, October 31", or `nil` when the activity ends on the day it
    /// starts. Ending exactly at midnight counts as the start day.
    public func endDayNote(start: Date, end: Date) -> String? {
        guard end > start else { return nil }
        let days = dayDistance(from: start, to: end.addingTimeInterval(-1))
        guard days > 0 else { return nil }
        return days == 1 ? "Ends the next day, \(dayText(end))" : "Ends \(dayText(end))"
    }

    /// "Arrival is on Friday, October 30, the day before the activity", or `nil` when the
    /// ideal arrival and the start fall on the same day.
    public func arrivalDayNote(arrival: Date, start: Date) -> String? {
        let days = dayDistance(from: arrival, to: start)
        guard days != 0 else { return nil }
        if days == 1 {
            return "Arrival is on \(dayText(arrival)), the day before the activity"
        }
        return "Arrival is on \(dayText(arrival)), not on the day of the activity"
    }

    /// "45 minutes before start", "At the start time", or "After the start time" for a draft
    /// whose arrival is still invalid.
    public func leadText(arrival: Date, start: Date) -> String {
        let lead = start.timeIntervalSince(arrival)
        guard lead.isFinite else { return "At the start time" }
        if lead < 0 { return "After the start time" }
        if lead == 0 { return "At the start time" }
        return "\(durationText(lead)) before start"
    }

    /// Time range of a draft: "9:30 – 10:20 AM", with weekdays when it crosses midnight.
    public func draftTimeRange(_ draft: ActivityDraft) -> String {
        guard draft.end > draft.start else { return clockTime(draft.start) }
        let sameDay = dayDistance(from: draft.start, to: draft.end.addingTimeInterval(-1)) == 0
        let style = Date.IntervalFormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .hour()
            .minute()
        return (draft.start..<draft.end).formatted(sameDay ? style : style.weekday(.abbreviated))
    }

    /// "9:00 – 10:00 AM" for an interval, such as the one a creation drag covers.
    public func timeRangeText(_ range: Range<Date>) -> String {
        let style = Date.IntervalFormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .hour()
            .minute()
        return range.formatted(style)
    }

    /// When a draft happens: "Every Mon, Wed, Fri" for a series, or the full date of a
    /// one-time activity.
    public func draftScheduleText(_ draft: ActivityDraft) -> String {
        if let weekdays = draft.repeatWeekdays, !weekdays.isEmpty {
            let summary = Weekday.summary(of: weekdays, in: calculator.calendar)
            return weekdays.count == Weekday.allCases.count ? "Every day" : "Every \(summary)"
        }
        return fullDate(draft.start)
    }

    /// "Arrive by 8:45 AM", adding the weekday when the arrival is on an earlier day.
    public func draftArrivalText(_ draft: ActivityDraft) -> String {
        guard dayDistance(from: draft.idealArrival, to: draft.start) != 0 else {
            return "Arrive by \(clockTime(draft.idealArrival))"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.abbreviated)
            .hour()
            .minute()
        return "Arrive by \(style.format(draft.idealArrival))"
    }

    /// Spoken and written summary for the unsaved-change bar, such as
    /// "9:30 – 10:20 AM, Every Mon, Wed, Fri, arrive by 8:45 AM".
    public func draftSummary(_ draft: ActivityDraft) -> String {
        "\(draftTimeRange(draft)), \(draftScheduleText(draft)), \(draftArrivalText(draft).lowercased())"
    }

    /// Signed number of calendar days, in the formatter's zone, from `earlier` to `later`.
    func dayDistance(from earlier: Date, to later: Date) -> Int {
        let zone = calculator.timeZone
        return LocalDate.of(earlier, in: zone).days(until: LocalDate.of(later, in: zone))
    }

    /// "Saturday, October 31".
    func dayText(_ date: Date) -> String {
        Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .format(date)
    }
}
