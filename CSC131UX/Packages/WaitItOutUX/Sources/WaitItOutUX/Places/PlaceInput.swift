import Foundation

/// The text a user types for one place in Settings: a name and two decimal-degree
/// coordinates. Pure: parsing and validation depend only on the strings, so the place editor
/// can show every issue as it is typed and the model can refuse anything unusable.
public struct PlaceInput: Equatable, Sendable {
    public var name: String
    public var latitude: String
    public var longitude: String

    public init(name: String, latitude: String, longitude: String) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The fields for an existing place, with up to six decimals (about 11 centimeters).
    public init(place: CommutePlace) {
        name = place.name
        latitude = Self.formatDegrees(place.coordinate.latitude, fractionDigits: 6)
        longitude = Self.formatDegrees(place.coordinate.longitude, fractionDigits: 6)
    }

    /// Every issue, in field order: name, latitude, longitude.
    public var issues: [PlaceIssue] {
        switch place() {
        case .success:
            return []
        case .failure(let error):
            return error.issues
        }
    }

    public var isValid: Bool { issues.isEmpty }

    /// The validated place, or every issue at once.
    public func place() -> Result<CommutePlace, PlaceValidationError> {
        var issues: [PlaceIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        let latitudeValue = Self.degrees(latitude, empty: .emptyLatitude, notANumber: .latitudeNotANumber, range: -90...90, outOfRange: .latitudeOutOfRange)
        let longitudeValue = Self.degrees(longitude, empty: .emptyLongitude, notANumber: .longitudeNotANumber, range: -180...180, outOfRange: .longitudeOutOfRange)
        if case .issue(let issue) = latitudeValue { issues.append(issue) }
        if case .issue(let issue) = longitudeValue { issues.append(issue) }
        guard issues.isEmpty,
              case .value(let lat) = latitudeValue,
              case .value(let lon) = longitudeValue else {
            return .failure(PlaceValidationError(issues: issues))
        }
        do {
            return .success(try CommutePlace(name: name, coordinate: GeoCoordinate(latitude: lat, longitude: lon)))
        } catch let error as PlaceValidationError {
            return .failure(error)
        } catch {
            return .failure(PlaceValidationError(issues: [.emptyName]))
        }
    }

    /// Parses strict decimal degrees: an optional sign, digits, and at most one decimal
    /// separator (a period, or a comma when there is no period). Surrounding spaces are
    /// ignored and a typographic minus counts as a minus. Rejects exponents, hexadecimal,
    /// "nan", "inf", degree symbols, and compass letters, which `Double(_:)` alone would
    /// partly accept. Returns `nil` for anything else.
    public static func parseDegrees(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(of: "\u{2212}", with: "-")
        if !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 {
            trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
        }
        guard !trimmed.isEmpty else { return nil }
        var body = Substring(trimmed)
        if let first = body.first, first == "-" || first == "+" {
            body = body.dropFirst()
        }
        let digits = body.filter(\.isASCIIDigit)
        guard !digits.isEmpty,
              body.filter({ $0 == "." }).count <= 1,
              body.allSatisfy({ $0.isASCIIDigit || $0 == "." }) else {
            return nil
        }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Decimal degrees with a period and no grouping, trimmed of trailing zeros beyond the
    /// first decimal: 38.561, -121.4237, 0.0.
    public static func formatDegrees(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "" }
        let digits = max(1, min(8, fractionDigits))
        var text = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 2 {
            text.removeLast()
        }
        if text == "-0.0" {
            return "0.0"
        }
        return text
    }

    /// One parsed coordinate field. Not a `Result`: `PlaceIssue` is not an `Error`.
    private enum ParsedDegrees {
        case value(Double)
        case issue(PlaceIssue)
    }

    private static func degrees(
        _ text: String,
        empty: PlaceIssue,
        notANumber: PlaceIssue,
        range: ClosedRange<Double>,
        outOfRange: PlaceIssue
    ) -> ParsedDegrees {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .issue(empty) }
        guard let value = parseDegrees(text) else { return .issue(notANumber) }
        guard range.contains(value) else { return .issue(outOfRange) }
        return .value(value)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
