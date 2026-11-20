import CoreLocation
import Foundation

/// A WGS-84 point. Validation is explicit so callers can reject NaN, infinite, or
/// out-of-range values before they reach storage or the map.
public struct GeoCoordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// True when both components are finite and inside the WGS-84 ranges.
    public var isValid: Bool {
        Self.isValid(latitude: latitude, longitude: longitude)
    }

    public static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude)
            && (-180.0...180.0).contains(longitude)
    }

    /// MapKit form of the same point.
    public var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Stable identifier of a destination. The prototype uses readable raw values such as
/// `demo-campus`; later steps add the user's own campus and home under their own ids.
public struct DestinationID: Hashable, Sendable, RawRepresentable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where an activity takes place. Activities carry a copy of their destination so that
/// validation and display need no lookup; the id lets a later step re-point every activity
/// when the campus location itself is edited.
public struct Destination: Hashable, Codable, Sendable, Identifiable {
    public let id: DestinationID
    public var name: String
    public var coordinate: GeoCoordinate

    public init(id: DestinationID, name: String, coordinate: GeoCoordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}
