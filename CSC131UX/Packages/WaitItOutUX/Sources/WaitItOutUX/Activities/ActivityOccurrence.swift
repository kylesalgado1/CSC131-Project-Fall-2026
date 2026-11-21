import Foundation

/// Identity of one occurrence: the activity plus the local calendar day, in the activity's
/// zone, on which that occurrence starts. The same occurrence gets the same id in every
/// expansion and across app launches, which later steps rely on for reminders.
public struct OccurrenceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let activityID: UUID
    public let date: LocalDate

    public init(activityID: UUID, date: LocalDate) {
        self.activityID = activityID
        self.date = date
    }

    /// Text form such as `6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-10-30`.
    public var rawValue: String {
        "\(activityID.uuidString)@\(date.description)"
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let activityID = UUID(uuidString: String(parts[0])),
              let date = LocalDate(description: String(parts[1])) else {
            return nil
        }
        self.init(activityID: activityID, date: date)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = OccurrenceID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Malformed occurrence id: \(raw)")
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One dated instance of an activity: the single instance of a one-time activity, or one
/// weekday's instance of a repeating one.
public struct ActivityOccurrence: Identifiable, Hashable, Sendable {
    public let id: OccurrenceID
    public let activity: Activity
    public let start: Date
    public let end: Date
    public let idealArrival: Date

    public init(id: OccurrenceID, activity: Activity, start: Date, end: Date, idealArrival: Date) {
        self.id = id
        self.activity = activity
        self.start = start
        self.end = end
        self.idealArrival = idealArrival
    }

    public var isRecurring: Bool { activity.isRecurring }
    public var isSample: Bool { activity.isSample }

    /// The activity itself, start inclusive to end exclusive.
    public var activityInterval: Range<Date> {
        start..<max(start, end)
    }

    /// Ideal arrival through the end of the activity: everything the user plans around.
    public var plannedInterval: Range<Date> {
        min(idealArrival, start)..<max(start, end)
    }

    /// True when any part of the planned time, arrival through end, falls inside `range`.
    public func intersects(_ range: Range<Date>) -> Bool {
        plannedInterval.overlaps(range)
    }

    /// True when the activity itself, not just the arrival lead, falls inside `range`.
    public func activityIntersects(_ range: Range<Date>) -> Bool {
        activityInterval.overlaps(range)
    }
}
