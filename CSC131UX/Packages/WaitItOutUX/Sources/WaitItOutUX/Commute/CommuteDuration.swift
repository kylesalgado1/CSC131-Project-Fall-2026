import Foundation

/// Why a commute duration was rejected. Used for the Settings test duration and for every
/// travel time a provider reports, so neither can reach the departure calculation unchecked.
public enum CommuteDurationIssue: Error, Equatable, Sendable {
    /// Settings text that is blank.
    case empty
    /// Settings text that is not a number at all.
    case notANumber
    /// Settings text with a fraction, such as "12.5".
    case notWholeMinutes
    /// NaN or infinity.
    case notFinite
    /// Zero or negative.
    case notPositive
    /// Longer than `CommuteDuration.maximumSeconds`. Also catches values so large that
    /// subtracting them from an arrival would overflow the date range.
    case tooLong

    public var message: String {
        switch self {
        case .empty:
            return "Enter the test commute in minutes."
        case .notANumber:
            return "Enter the test commute as a whole number of minutes, such as 45."
        case .notWholeMinutes:
            return "Use whole minutes, such as 45."
        case .notFinite:
            return "The commute must be a finite number of minutes."
        case .notPositive:
            return "The commute must be longer than 0 minutes."
        case .tooLong:
            return "The commute can be at most \(CommuteDuration.maximumMinutes) minutes (12 hours)."
        }
    }
}

/// A validated door-to-door travel time: finite, longer than zero, and at most 12 hours.
/// The only way to obtain one is through validation, so `DepartureCalculator` never sees
/// zero, negative, nonfinite, or overflowing durations.
public struct CommuteDuration: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Longest accepted commute, in whole minutes: 12 hours.
    public static let maximumMinutes = 720
    /// Longest accepted commute, in seconds.
    public static let maximumSeconds = TimeInterval(maximumMinutes) * 60
    /// The Settings test commute before the user changes it: 60 minutes.
    public static let testDefault = CommuteDuration(validSeconds: 3_600)

    /// Elapsed seconds of travel. Real time, not wall-clock time, so a trip across a
    /// daylight-saving change still takes exactly this long.
    public let seconds: TimeInterval

    private init(validSeconds: TimeInterval) {
        seconds = validSeconds
    }

    /// Throws `CommuteDurationIssue` for a nonfinite, non-positive, or too-long value.
    public init(seconds: TimeInterval) throws {
        switch Self.validated(seconds: seconds) {
        case .success(let duration):
            self = duration
        case .failure(let issue):
            throw issue
        }
    }

    /// Throws `CommuteDurationIssue` unless `minutes` is between 1 and `maximumMinutes`.
    public static func minutes(_ minutes: Int) throws -> CommuteDuration {
        guard minutes > 0 else { throw CommuteDurationIssue.notPositive }
        guard minutes <= maximumMinutes else { throw CommuteDurationIssue.tooLong }
        return CommuteDuration(validSeconds: TimeInterval(minutes) * 60)
    }

    public static func validated(seconds: TimeInterval) -> Result<CommuteDuration, CommuteDurationIssue> {
        guard seconds.isFinite else { return .failure(.notFinite) }
        guard seconds > 0 else { return .failure(.notPositive) }
        guard seconds <= maximumSeconds else { return .failure(.tooLong) }
        return .success(CommuteDuration(validSeconds: seconds))
    }

    /// Parses the Settings field: whole minutes from 1 to `maximumMinutes`. Surrounding
    /// spaces are ignored; "0", "-5", "12.5", "abc", "nan", and "99999999999999999999" are
    /// rejected with the matching issue.
    public static func parseMinutes(_ text: String) -> Result<CommuteDuration, CommuteDurationIssue> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let value = Double(trimmed) else { return .failure(.notANumber) }
        guard value.isFinite else { return .failure(.notFinite) }
        guard value > 0 else { return .failure(.notPositive) }
        guard value.rounded() == value else { return .failure(.notWholeMinutes) }
        guard value <= Double(maximumMinutes) else { return .failure(.tooLong) }
        return validated(seconds: value * 60)
    }

    /// The duration rounded to whole minutes, for display and the Settings field.
    public var wholeMinutes: Int {
        Int((seconds / 60).rounded())
    }

    public var description: String {
        "\(wholeMinutes) min"
    }

    public static func < (lhs: CommuteDuration, rhs: CommuteDuration) -> Bool {
        lhs.seconds < rhs.seconds
    }

    public init(from decoder: Decoder) throws {
        let seconds = try decoder.singleValueContainer().decode(Double.self)
        switch Self.validated(seconds: seconds) {
        case .success(let duration):
            self = duration
        case .failure(let issue):
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid commute duration: \(issue.message)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}
