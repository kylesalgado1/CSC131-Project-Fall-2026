import CoreLocation
import Foundation

/// A named point on the map together with the time zone it keeps its schedule in. In this
/// prototype step the only instance is the labeled demo campus.
public struct SampleLocation: Hashable, Sendable {
    public let name: String
    /// Short, user-visible explanation of where the value comes from.
    public let provenance: String
    public let latitude: Double
    public let longitude: Double
    /// Zone this location keeps its schedule in, such as "America/Los_Angeles".
    public let timeZoneIdentifier: String
    /// Stable id used when activities reference this location as their destination.
    public let destinationID: DestinationID

    public init(
        name: String,
        provenance: String,
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String,
        destinationID: DestinationID
    ) {
        self.name = name
        self.provenance = provenance
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.destinationID = destinationID
    }

    public var geoCoordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    public var coordinate: CLLocationCoordinate2D {
        geoCoordinate.locationCoordinate
    }

    /// True when both components are finite and inside the WGS-84 ranges.
    public var hasValidCoordinate: Bool {
        geoCoordinate.isValid
    }

    public static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        GeoCoordinate.isValid(latitude: latitude, longitude: longitude)
    }

    public var hasKnownTimeZone: Bool {
        TimeZone(identifier: timeZoneIdentifier) != nil
    }

    /// The location's zone, falling back to the device zone if the identifier is unknown here.
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    /// The destination value that activities at this location store.
    public var destination: Destination {
        Destination(id: destinationID, name: name, coordinate: geoCoordinate)
    }

    /// Demo campus used by the standalone prototype. This is sample content: Settings shows it
    /// as the SAMPLE campus until the user enters their own (step 0006), and "Reset to sample
    /// locations" restores it. Its zone is the campus time zone either way.
    public static let demoCampus = SampleLocation(
        name: "Sample campus",
        provenance: "Demo location: Sacramento State area, Sacramento, CA. Not a user setting.",
        latitude: 38.5610,
        longitude: -121.4237,
        timeZoneIdentifier: "America/Los_Angeles",
        destinationID: DestinationID("demo-campus")
    )

    /// Demo home used by the standalone prototype (step 0006): a coarse point near central Elk
    /// Grove, south of the sample campus, not a real address. Settings labels it SAMPLE until
    /// the user enters their own home.
    public static let demoHome = SampleLocation(
        name: "Sample home",
        provenance: "Demo location: central Elk Grove, CA area. Not a real address or a user setting.",
        latitude: 38.4088,
        longitude: -121.3716,
        timeZoneIdentifier: "America/Los_Angeles",
        destinationID: DestinationID("demo-home")
    )
}
