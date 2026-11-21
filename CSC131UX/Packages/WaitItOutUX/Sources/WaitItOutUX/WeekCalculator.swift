import Foundation

/// A Sunday-to-Saturday week expressed in a specific calendar and time zone.
///
/// `start` is the first instant of Sunday, `end` is the first instant of the following
/// Sunday (exclusive). `dayStarts` always has seven entries, Sunday through Saturday,
/// each being the first instant of that local day. Day lengths are not assumed to be
/// 24 hours, so weeks that contain a daylight-saving transition are represented correctly.
public struct WeekInterval: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let dayStarts: [Date]

    init(start: Date, end: Date, dayStarts: [Date]) {
        self.start = start
        self.end = end
        self.dayStarts = dayStarts
    }

    /// Half-open range covering the whole week.
    public var range: Range<Date> {
        start..<end
    }

    /// The first instant of Saturday (the last day of the week).
    public var lastDayStart: Date {
        dayStarts.last ?? start
    }

    public func contains(_ date: Date) -> Bool {
        range.contains(date)
    }

    /// Seven half-open day ranges, Sunday through Saturday, each from one local midnight to
    /// the next. Together they tile `range` exactly, including weeks with a 23- or 25-hour day.
    public var dayRanges: [Range<Date>] {
        let bounds = dayStarts + [end]
        return zip(bounds, bounds.dropFirst()).compactMap { lower, upper in
            lower < upper ? lower..<upper : nil
        }
    }

    /// The day range at a Sunday-first index, or `nil` when the index is outside 0...6.
    public func dayRange(at index: Int) -> Range<Date>? {
        let ranges = dayRanges
        return ranges.indices.contains(index) ? ranges[index] : nil
    }

    /// Sunday-first index of the day that contains `date`, or `nil` when it lies outside the week.
    public func dayIndex(containing date: Date) -> Int? {
        dayRanges.firstIndex { $0.contains(date) }
    }
}

/// Pure week arithmetic. Construct one per time zone; it never reads the current time.
public struct WeekCalculator: Sendable {
    /// Calendar normalized so Sunday is weekday 1 and the first day of every week.
    public let calendar: Calendar

    /// Creates a calculator from any calendar. The calendar is copied and normalized to a
    /// Gregorian, Sunday-first week in the calendar's own time zone and locale.
    public init(calendar: Calendar = .autoupdatingCurrent) {
        var normalized = Calendar(identifier: .gregorian)
        normalized.timeZone = calendar.timeZone
        normalized.locale = calendar.locale
        normalized.firstWeekday = 1
        normalized.minimumDaysInFirstWeek = 1
        self.calendar = normalized
    }

    /// Convenience for a specific time zone.
    public init(timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) {
        var base = Calendar(identifier: .gregorian)
        base.timeZone = timeZone
        base.locale = locale
        self.init(calendar: base)
    }

    public var timeZone: TimeZone {
        calendar.timeZone
    }

    /// The Sunday-Saturday week that contains `date`.
    public func week(containing date: Date) -> WeekInterval {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart) // 1 = Sunday ... 7 = Saturday
        let offsetFromSunday = weekday - 1
        let sunday: Date
        if offsetFromSunday == 0 {
            sunday = dayStart
        } else if let shifted = calendar.date(byAdding: .day, value: -offsetFromSunday, to: dayStart) {
            sunday = calendar.startOfDay(for: shifted)
        } else {
            sunday = dayStart
        }
        return makeWeek(startingAtSunday: sunday)
    }

    /// The week `offset` weeks after (`offset > 0`) or before (`offset < 0`) `week`.
    public func week(_ week: WeekInterval, offsetBy offset: Int) -> WeekInterval {
        guard offset != 0 else { return week }
        guard let shifted = calendar.date(byAdding: .weekOfYear, value: offset, to: week.start) else {
            return week
        }
        return self.week(containing: shifted)
    }

    public func nextWeek(after week: WeekInterval) -> WeekInterval {
        self.week(week, offsetBy: 1)
    }

    public func previousWeek(before week: WeekInterval) -> WeekInterval {
        self.week(week, offsetBy: -1)
    }

    /// Zero-based index within the week, 0 = Sunday ... 6 = Saturday.
    public func weekdayIndex(of date: Date) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    public func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func makeWeek(startingAtSunday sunday: Date) -> WeekInterval {
        var days: [Date] = [sunday]
        days.reserveCapacity(7)
        var cursor = sunday
        for _ in 1..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
            days.append(cursor)
        }
        let end: Date
        if let nextSunday = calendar.date(byAdding: .day, value: 7, to: sunday) {
            end = calendar.startOfDay(for: nextSunday)
        } else {
            end = sunday
        }
        return WeekInterval(start: sunday, end: end, dayStarts: days)
    }
}
