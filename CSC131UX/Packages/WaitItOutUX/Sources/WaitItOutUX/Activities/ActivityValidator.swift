import Foundation

/// The editor field an issue belongs to, so inline errors can sit next to the right control.
public enum ActivityField: Hashable, Sendable {
    case title
    case destination
    case times
    case arrival
    case timeZone
    case recurrence
}

/// One reason an activity cannot be saved. Messages are user-facing and actionable.
public enum ActivityValidationIssue: Hashable, Sendable {
    case emptyTitle
    case emptyDestinationName
    case invalidCoordinate
    case invalidDate
    case endNotAfterStart
    case durationTooLong
    case arrivalAfterStart
    case arrivalTooEarly
    case unknownTimeZone(String)
    case noRepeatWeekdays
    case repeatWeekdaysExcludeStartDay(Weekday)

    public var field: ActivityField {
        switch self {
        case .emptyTitle:
            return .title
        case .emptyDestinationName, .invalidCoordinate:
            return .destination
        case .invalidDate, .endNotAfterStart, .durationTooLong:
            return .times
        case .arrivalAfterStart, .arrivalTooEarly:
            return .arrival
        case .unknownTimeZone:
            return .timeZone
        case .noRepeatWeekdays, .repeatWeekdaysExcludeStartDay:
            return .recurrence
        }
    }

    public var message: String {
        switch self {
        case .emptyTitle:
            return "Enter a title."
        case .emptyDestinationName:
            return "Choose a destination that has a name."
        case .invalidCoordinate:
            return "The destination needs a real map location: latitude between -90 and 90, longitude between -180 and 180."
        case .invalidDate:
            return "Start, end, and ideal arrival must be real dates."
        case .endNotAfterStart:
            return "The end time must be after the start time."
        case .durationTooLong:
            return "An activity can last at most 24 hours."
        case .arrivalAfterStart:
            return "Ideal arrival must be at or before the start time."
        case .arrivalTooEarly:
            return "Ideal arrival can be at most 24 hours before the start."
        case .unknownTimeZone(let identifier):
            return "Unknown time zone: \(identifier.isEmpty ? "none" : identifier)."
        case .noRepeatWeekdays:
            return "Choose at least one day for a repeating activity."
        case .repeatWeekdaysExcludeStartDay(let weekday):
            return "Repeat days must include \(weekday.name(in: .autoupdatingCurrent)), the day the activity starts."
        }
    }
}

/// Thrown by `ActivityValidator.validate` and `WaitItOutModel.saveActivity` for invalid input.
public struct ActivityValidationError: Error, Equatable, Sendable {
    public let issues: [ActivityValidationIssue]

    public init(issues: [ActivityValidationIssue]) {
        self.issues = issues
    }
}

/// Pure validation of activities. Every rule is checked so the editor can show all problems
/// at once; order of the returned issues follows the editor's field order.
public enum ActivityValidator {
    /// Longest permitted activity. Keeps overnight activities possible and recurrence bounded.
    public static let maximumDuration: TimeInterval = 24 * 3_600
    /// Longest permitted gap between ideal arrival and start. Allows arrival on the previous day.
    public static let maximumArrivalLead: TimeInterval = 24 * 3_600

    public static func issues(in activity: Activity) -> [ActivityValidationIssue] {
        var issues: [ActivityValidationIssue] = []

        if activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyTitle)
        }

        if activity.destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyDestinationName)
        }
        if !activity.destination.coordinate.isValid {
            issues.append(.invalidCoordinate)
        }

        let datesAreFinite = [activity.start, activity.end, activity.idealArrival]
            .allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
        if !datesAreFinite {
            issues.append(.invalidDate)
        } else {
            if activity.end <= activity.start {
                issues.append(.endNotAfterStart)
            } else if activity.duration > maximumDuration {
                issues.append(.durationTooLong)
            }
            if activity.idealArrival > activity.start {
                issues.append(.arrivalAfterStart)
            } else if activity.arrivalLead > maximumArrivalLead {
                issues.append(.arrivalTooEarly)
            }
        }

        let zone = activity.timeZone
        if zone == nil {
            issues.append(.unknownTimeZone(activity.timeZoneIdentifier))
        }

        if let weekdays = activity.repeatWeekdays {
            if weekdays.isEmpty {
                issues.append(.noRepeatWeekdays)
            } else if datesAreFinite, let startWeekday = activity.startWeekday, !weekdays.contains(startWeekday) {
                issues.append(.repeatWeekdaysExcludeStartDay(startWeekday))
            }
        }

        return issues
    }

    public static func isValid(_ activity: Activity) -> Bool {
        issues(in: activity).isEmpty
    }

    /// Throws `ActivityValidationError` listing every issue when the activity is invalid.
    public static func validate(_ activity: Activity) throws {
        let found = issues(in: activity)
        if !found.isEmpty {
            throw ActivityValidationError(issues: found)
        }
    }
}
