import Foundation

extension Calendar {
    /// Gregorian calendar pinned to UTC. UTC has no offset transitions, so civil-date and
    /// clock arithmetic on it is exact. The package uses it as its day engine and applies
    /// each time zone's offset explicitly, instead of adding multiples of 86 400 seconds.
    static let utcGregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
}

/// A calendar day without a clock time or zone, such as 2026-10-30.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    /// Days since 1970-01-01. Arithmetic and ordering use this value.
    public let dayNumber: Int

    /// Fails for components that do not name a real day, such as February 30.
    public init?(year: Int, month: Int, day: Int) {
        let calendar = Calendar.utcGregorian
        guard let instant = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let check = calendar.dateComponents([.year, .month, .day], from: instant)
        guard check.year == year, check.month == month, check.day == day else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
        dayNumber = Self.dayNumber(forUTCInstant: instant)
    }

    public init(dayNumber: Int) {
        let instant = Date(timeIntervalSince1970: TimeInterval(dayNumber) * 86_400)
        let components = Calendar.utcGregorian.dateComponents([.year, .month, .day], from: instant)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
        self.dayNumber = dayNumber
    }

    /// Parses the `description` form, "2026-10-30".
    public init?(description: String) {
        let parts = description.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// The local calendar day that contains `instant` in `zone`. A non-finite instant maps
    /// to 1970-01-01 instead of trapping; validation rejects such dates before use.
    public static func of(_ instant: Date, in zone: TimeZone) -> LocalDate {
        guard instant.timeIntervalSinceReferenceDate.isFinite else { return LocalDate(dayNumber: 0) }
        let shifted = instant.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: instant)))
        return LocalDate(dayNumber: dayNumber(forUTCInstant: shifted))
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(dayNumber: dayNumber + days)
    }

    /// Signed number of days from this day to `other`.
    public func days(until other: LocalDate) -> Int {
        other.dayNumber - dayNumber
    }

    public var weekday: Weekday {
        Weekday(rawValue: Calendar.utcGregorian.component(.weekday, from: utcMidnight)) ?? .sunday
    }

    /// Midnight of this day on the UTC clock: a zone-free anchor for arithmetic.
    public var utcMidnight: Date {
        Date(timeIntervalSince1970: TimeInterval(dayNumber) * 86_400)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func dayNumber(forUTCInstant instant: Date) -> Int {
        let days = (instant.timeIntervalSince1970 / 86_400).rounded(.down)
        guard days.isFinite, abs(days) < 1.0e15 else { return 0 }
        return Int(days)
    }
}

/// A time of day on a wall clock, independent of date and zone.
public struct WallTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// Fails for components outside 0...23 hours and 0...59 minutes or seconds.
    public init?(hour: Int, minute: Int, second: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return nil
        }
        self.init(validHour: hour, minute: minute, second: second)
    }

    private init(validHour hour: Int, minute: Int, second: Int) {
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public static let midnight = WallTime(validHour: 0, minute: 0, second: 0)

    /// Clock reading of `instant` in `zone`. A non-finite instant reads as midnight.
    public static func of(_ instant: Date, in zone: TimeZone) -> WallTime {
        guard instant.timeIntervalSinceReferenceDate.isFinite else { return .midnight }
        let shifted = instant.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: instant)))
        let components = Calendar.utcGregorian.dateComponents([.hour, .minute, .second], from: shifted)
        return WallTime(validHour: components.hour ?? 0, minute: components.minute ?? 0, second: components.second ?? 0)
    }

    public var secondsFromMidnight: Int {
        hour * 3_600 + minute * 60 + second
    }

    public static func < (lhs: WallTime, rhs: WallTime) -> Bool {
        lhs.secondsFromMidnight < rhs.secondsFromMidnight
    }

    public var description: String {
        String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}

/// A local date and wall time together, still without a zone.
public struct LocalDateTime: Hashable, Sendable {
    public let date: LocalDate
    public let time: WallTime

    public init(date: LocalDate, time: WallTime) {
        self.date = date
        self.time = time
    }

    /// The clock reading of `instant` in `zone`.
    public static func of(_ instant: Date, in zone: TimeZone) -> LocalDateTime {
        LocalDateTime(date: .of(instant, in: zone), time: .of(instant, in: zone))
    }
}

/// How a wall-clock reading behaves in a zone on a given day.
public enum WallTimeKind: Equatable, Sendable {
    /// The reading happens exactly once.
    case unique
    /// Clocks fell back, so the reading happens twice.
    case repeated
    /// Clocks sprang forward, so the reading never happens.
    case skipped
}

/// Turns a wall-clock reading in a zone back into an instant, with one explicit policy for
/// the two daylight-saving edge cases:
///
/// - A reading that exists twice, because clocks fell back, resolves to its **first**
///   occurrence: the earlier instant, still on daylight time.
/// - A reading that never happens, because clocks sprang forward, resolves to the first
///   instant after the gap, which is the transition itself. On a day when clocks jump from
///   02:00 to 03:00, the reading 02:30 resolves to 03:00.
///
/// Put together: the result is always the earliest instant whose local clock reads the
/// requested time or later. The rule never reorders two readings, so start, end, and arrival
/// resolved on the same day keep their order.
public enum LocalTimeResolver {
    private struct OffsetSegment {
        let begins: Date
        let offset: Int
    }

    /// The instant at which the clock in `zone` reads `time` on `date`, under the policy above.
    public static func instant(of time: WallTime, on date: LocalDate, in zone: TimeZone) -> Date {
        let utcReading = utcReading(of: time, on: date)
        let segments = offsetSegments(around: utcReading, in: zone)
        if let earliest = matchingInstants(for: utcReading, segments: segments, zone: zone).min() {
            return earliest
        }
        if let transition = gapTransition(containing: utcReading, segments: segments) {
            return transition
        }
        return utcReading.addingTimeInterval(-TimeInterval(zone.secondsFromGMT(for: utcReading)))
    }

    public static func instant(of dateTime: LocalDateTime, in zone: TimeZone) -> Date {
        instant(of: dateTime.time, on: dateTime.date, in: zone)
    }

    /// Whether `time` on `date` is unique, repeated, or skipped in `zone`.
    public static func classify(_ time: WallTime, on date: LocalDate, in zone: TimeZone) -> WallTimeKind {
        let utcReading = utcReading(of: time, on: date)
        let segments = offsetSegments(around: utcReading, in: zone)
        let matches = Set(matchingInstants(for: utcReading, segments: segments, zone: zone))
        switch matches.count {
        case 0: return .skipped
        case 1: return .unique
        default: return .repeated
        }
    }

    /// The requested reading interpreted as if the zone were UTC. Every candidate instant in
    /// the real zone is this value minus one of the zone's offsets.
    private static func utcReading(of time: WallTime, on date: LocalDate) -> Date {
        date.utcMidnight.addingTimeInterval(TimeInterval(time.secondsFromMidnight))
    }

    /// The UTC offsets in effect from one day before to one day after `utcReading`, in the
    /// order they apply. Offsets never exceed 14 hours, so every candidate instant lies in
    /// this window and its offset is one of these.
    private static func offsetSegments(around utcReading: Date, in zone: TimeZone) -> [OffsetSegment] {
        let windowStart = utcReading.addingTimeInterval(-86_400)
        let windowEnd = utcReading.addingTimeInterval(86_400)
        var segments = [OffsetSegment(begins: windowStart, offset: zone.secondsFromGMT(for: windowStart))]
        var cursor = windowStart
        var steps = 0
        while steps < 8, let transition = zone.nextDaylightSavingTimeTransition(after: cursor), transition < windowEnd {
            segments.append(OffsetSegment(begins: transition, offset: zone.secondsFromGMT(for: transition)))
            cursor = transition
            steps += 1
        }
        return segments
    }

    /// Candidate instants whose clock reading in `zone` really is the requested one.
    private static func matchingInstants(for utcReading: Date, segments: [OffsetSegment], zone: TimeZone) -> [Date] {
        segments.compactMap { segment in
            let candidate = utcReading.addingTimeInterval(-TimeInterval(segment.offset))
            return zone.secondsFromGMT(for: candidate) == segment.offset ? candidate : nil
        }
    }

    /// For a skipped reading, the forward transition whose gap swallows it.
    private static func gapTransition(containing utcReading: Date, segments: [OffsetSegment]) -> Date? {
        for index in segments.indices.dropFirst() {
            let before = segments[index - 1].offset
            let after = segments[index].offset
            guard after > before else { continue }
            let transition = segments[index].begins
            let gapStart = transition.addingTimeInterval(TimeInterval(before))
            let gapEnd = transition.addingTimeInterval(TimeInterval(after))
            if utcReading >= gapStart && utcReading < gapEnd {
                return transition
            }
        }
        return nil
    }
}
