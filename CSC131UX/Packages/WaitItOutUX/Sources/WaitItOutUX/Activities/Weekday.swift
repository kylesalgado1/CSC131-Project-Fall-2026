import Foundation

/// Day of the week numbered like `Calendar.component(.weekday)`: 1 is Sunday, 7 is Saturday.
public enum Weekday: Int, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    public var id: Int { rawValue }

    /// Zero-based position in a Sunday-first week; matches `WeekCalculator.weekdayIndex(of:)`.
    public var sundayFirstIndex: Int { rawValue - 1 }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Localized full name such as "Monday", using the calendar's locale.
    public func name(in calendar: Calendar) -> String {
        symbol(from: calendar.weekdaySymbols)
    }

    /// Localized short name such as "Mon", using the calendar's locale.
    public func shortName(in calendar: Calendar) -> String {
        symbol(from: calendar.shortWeekdaySymbols)
    }

    private func symbol(from symbols: [String]) -> String {
        symbols.indices.contains(sundayFirstIndex) ? symbols[sundayFirstIndex] : String(describing: self)
    }

    /// The days in Sunday-first display order.
    public static func ordered(_ days: Set<Weekday>) -> [Weekday] {
        days.sorted()
    }

    /// Short names joined for display, such as "Mon, Wed, Fri", or "every day" for all seven.
    public static func summary(of days: Set<Weekday>, in calendar: Calendar) -> String {
        if days.count == allCases.count {
            return "every day"
        }
        return ordered(days).map { $0.shortName(in: calendar) }.joined(separator: ", ")
    }

    /// Full names joined for VoiceOver, such as "Monday, Wednesday, Friday".
    public static func spokenSummary(of days: Set<Weekday>, in calendar: Calendar) -> String {
        if days.count == allCases.count {
            return "every day"
        }
        return ordered(days).map { $0.name(in: calendar) }.joined(separator: ", ")
    }
}
