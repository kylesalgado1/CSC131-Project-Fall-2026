import Foundation

/// Human-readable titles for a `WeekInterval`. Pure: output depends only on the inputs.
public struct WeekTitleFormatter: Sendable {
    public let calculator: WeekCalculator
    public let locale: Locale

    public init(calculator: WeekCalculator, locale: Locale = .autoupdatingCurrent) {
        self.calculator = calculator
        self.locale = locale
    }

    /// Short title such as "Oct 25 – 31, 2026" or "Dec 27, 2026 – Jan 2, 2027".
    public func title(for week: WeekInterval) -> String {
        let style = Date.IntervalFormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .day()
            .month(.abbreviated)
            .year()
        return (week.start..<week.lastDayStart).formatted(style)
    }

    /// Spoken form for VoiceOver, such as "Week of Sunday, October 25 through Saturday, October 31, 2026".
    public func accessibilityTitle(for week: WeekInterval) -> String {
        let first = dayStyle(includeYear: false).format(week.start)
        let last = dayStyle(includeYear: true).format(week.lastDayStart)
        return "Week of \(first) through \(last)"
    }

    /// Label for a single day cell, such as "Sunday, October 25".
    public func dayLabel(for day: Date) -> String {
        dayStyle(includeYear: false).format(day)
    }

    private func dayStyle(includeYear: Bool) -> Date.FormatStyle {
        var style = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
        if includeYear {
            style = style.year()
        }
        return style
    }
}
