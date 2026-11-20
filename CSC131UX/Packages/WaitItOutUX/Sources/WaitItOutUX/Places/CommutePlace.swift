import Foundation

/// Which configured place a value describes. Every trip goes from home to campus.
public enum PlaceRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case home
    case campus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .campus: return "Campus"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .campus: return "building.columns.fill"
        }
    }
}

/// The editor field a place issue belongs to.
public enum PlaceField: Hashable, Sendable {
    case name
    case latitude
    case longitude
}

/// One reason a home or campus value cannot be used. Messages are user-facing.
public enum PlaceIssue: Hashable, Sendable {
    case emptyName
    case emptyLatitude
    case latitudeNotANumber
    case latitudeOutOfRange
    case emptyLongitude
    case longitudeNotANumber
    case longitudeOutOfRange

    public var field: PlaceField {
        switch self {
        case .emptyName:
            return .name
        case .emptyLatitude, .latitudeNotANumber, .latitudeOutOfRange:
            return .latitude
        case .emptyLongitude, .longitudeNotANumber, .longitudeOutOfRange:
            return .longitude
        }
    }

    public var message: String {
        switch self {
        case .emptyName:
            return "Enter a name."
        case .emptyLatitude:
            return "Enter a latitude."
        case .latitudeNotANumber:
            return "Enter the latitude in decimal degrees, such as 38.5610."
        case .latitudeOutOfRange:
            return "Latitude must be between -90 and 90."
        case .emptyLongitude:
            return "Enter a longitude."
        case .longitudeNotANumber:
            return "Enter the longitude in decimal degrees, such as -121.4237."
        case .longitudeOutOfRange:
            return "Longitude must be between -180 and 180."
        }
    }
}

/// Thrown when a place is built from unusable values. Lists every issue at once.
public struct PlaceValidationError: Error, Equatable, Sendable {
    public let issues: [PlaceIssue]

    public init(issues: [PlaceIssue]) {
        self.issues = issues
    }
}

/// A named WGS-84 point set in Settings: the user's home or campus (step 0006).
///
/// Valid by construction, like `CommuteDuration`: the name is nonempty after trimming and the
/// coordinate is finite and in range, so the model, the Map, and every `CommuteRequest` can
/// rely on it. Values are typed in Settings; no location permission, geocoding, or network
/// lookup is involved.
public struct CommutePlace: Hashable, Sendable, Codable {
    /// Trimmed, never empty.
    public let name: String
    /// Finite, latitude -90...90, longitude -180...180.
    public let coordinate: GeoCoordinate

    /// Throws `PlaceValidationError` listing every issue.
    public init(name: String, coordinate: GeoCoordinate) throws {
        let found = Self.issues(name: name, coordinate: coordinate)
        guard found.isEmpty else { throw PlaceValidationError(issues: found) }
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.coordinate = coordinate
    }

    /// The labeled demo location as a place. `nil` only if the sample itself is unusable.
    public init?(sample: SampleLocation) {
        guard let place = try? CommutePlace(name: sample.name, coordinate: sample.geoCoordinate) else { return nil }
        self = place
    }

    public static func issues(name: String, coordinate: GeoCoordinate) -> [PlaceIssue] {
        var issues: [PlaceIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if !coordinate.latitude.isFinite {
            issues.append(.latitudeNotANumber)
        } else if !(-90.0...90.0).contains(coordinate.latitude) {
            issues.append(.latitudeOutOfRange)
        }
        if !coordinate.longitude.isFinite {
            issues.append(.longitudeNotANumber)
        } else if !(-180.0...180.0).contains(coordinate.longitude) {
            issues.append(.longitudeOutOfRange)
        }
        return issues
    }

    /// "38.5610, -121.4237": four decimals (about 11 meters), always with a period, so the
    /// comma between the two numbers is never ambiguous.
    public var coordinateText: String {
        "\(PlaceInput.formatDegrees(coordinate.latitude, fractionDigits: 4)), \(PlaceInput.formatDegrees(coordinate.longitude, fractionDigits: 4))"
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case coordinate
    }

    /// Decoding validates too, so stored data can never produce an unusable place.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let coordinate = try container.decode(GeoCoordinate.self, forKey: .coordinate)
        guard Self.issues(name: name, coordinate: coordinate).isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unusable home or campus value")
            )
        }
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.coordinate = coordinate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate, forKey: .coordinate)
    }
}

/// Home and campus together. Part of `UserPreferences`, so the settings store keeps them.
public struct CommutePlaces: Equatable, Sendable, Codable {
    public var home: CommutePlace
    public var campus: CommutePlace

    public init(home: CommutePlace, campus: CommutePlace) {
        self.home = home
        self.campus = campus
    }

    public subscript(role: PlaceRole) -> CommutePlace {
        get {
            switch role {
            case .home: return home
            case .campus: return campus
            }
        }
        set {
            switch role {
            case .home: home = newValue
            case .campus: campus = newValue
            }
        }
    }

    /// The labeled sample pair built from two demo locations. A location that is somehow
    /// unusable falls back to the package's own demo value.
    public static func sample(home: SampleLocation, campus: SampleLocation) -> CommutePlaces {
        CommutePlaces(
            home: CommutePlace(sample: home) ?? Self.sample.home,
            campus: CommutePlace(sample: campus) ?? Self.sample.campus
        )
    }

    /// The package's demo pair: `SampleLocation.demoHome` and `SampleLocation.demoCampus`.
    public static let sample = CommutePlaces(home: .demoHome, campus: .demoCampus)

    private enum CodingKeys: String, CodingKey {
        case home
        case campus
    }

    /// A missing or unusable stored place falls back to its sample value instead of failing
    /// the whole settings load; the other place is kept.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = (try? container.decodeIfPresent(CommutePlace.self, forKey: .home)) ?? Self.sample.home
        campus = (try? container.decodeIfPresent(CommutePlace.self, forKey: .campus)) ?? Self.sample.campus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(home, forKey: .home)
        try container.encode(campus, forKey: .campus)
    }
}

extension CommutePlace {
    /// Known-good literals only: the package's demo values, which the tests pin.
    fileprivate init(validName: String, latitude: Double, longitude: Double) {
        name = validName
        coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Same values as `SampleLocation.demoHome`.
    static let demoHome = CommutePlace(validName: "Sample home", latitude: 38.4088, longitude: -121.3716)
    /// Same values as `SampleLocation.demoCampus`.
    static let demoCampus = CommutePlace(validName: "Sample campus", latitude: 38.5610, longitude: -121.4237)
}
