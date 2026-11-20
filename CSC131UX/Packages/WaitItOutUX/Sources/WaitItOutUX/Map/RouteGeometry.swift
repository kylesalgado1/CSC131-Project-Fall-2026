import Foundation

/// A driving route between home and campus, as a provider reported it. The Map draws it only
/// when a provider supplies one; a straight line is never presented as a route.
public struct RouteGeometry: Equatable, Sendable {
    /// What an unnamed source is called.
    public static let unknownSourceLabel = "the team backend"

    /// The path from start to end: at least two valid points.
    public let points: [GeoCoordinate]
    public let distanceMiles: Double
    /// Who planned the route: "TomTom", "OpenStreetMap (OSRM)", "Test fixture", or
    /// `unknownSourceLabel`.
    public let sourceLabel: String
    /// True when the backend's primary router failed and its fallback answered, so traffic was
    /// not considered.
    public let isFallback: Bool
    /// True for test fixture data.
    public let isFixture: Bool

    public init(points: [GeoCoordinate], distanceMiles: Double, sourceLabel: String, isFallback: Bool, isFixture: Bool) {
        self.points = points
        self.distanceMiles = distanceMiles
        self.sourceLabel = sourceLabel
        self.isFallback = isFallback
        self.isFixture = isFixture
    }

    /// The point halfway along the list of points, where the Map puts the route's label.
    public var middlePoint: GeoCoordinate? {
        points.isEmpty ? nil : points[points.count / 2]
    }
}

/// Why a route provider could not answer.
public enum RouteProviderFailure: Error, Equatable, Sendable {
    /// The server has no route feature. Asking again cannot help until the server address or
    /// the data mode changes.
    case notSupported
}

/// The route-geometry boundary. The host injects `BackendRouteProvider`; without a provider
/// the Map keeps its schematic line.
///
/// Throw `RouteProviderFailure.notSupported` when the server cannot provide routes at all, a
/// `CommuteProviderFailure` for network and service failures (the model retries the transient
/// kinds), and honor task cancellation.
public protocol RouteProviding: Sendable {
    func route(from origin: GeoCoordinate, to destination: GeoCoordinate) async throws -> RouteGeometry
}

/// What the Map shows between home and campus.
public enum RouteState: Equatable, Sendable {
    /// No route is requested: demo data mode, or no route provider. The dashed schematic line.
    case schematic
    /// A route was requested and has not arrived. The dashed schematic line meanwhile.
    case loading
    /// A provider's driving route.
    case route(RouteGeometry)
    /// The route could not be loaded. The dashed schematic line, with its schematic labels.
    case unavailable

    /// The route to draw, or `nil` when the schematic line applies.
    public var geometry: RouteGeometry? {
        if case .route(let geometry) = self { return geometry }
        return nil
    }
}

/// Words for the Map's line between home and campus and its status. Pure, so the exact
/// sentences are testable; the views only place them.
public enum MapRouteText {
    /// The label on the map for a real route: "Route via TomTom".
    public static func annotation(for route: RouteGeometry) -> String {
        "Route via \(route.sourceLabel)"
    }

    /// The places card's note for a real route: "Driving route from the team backend (TomTom),
    /// 12 mi." with ", test fixture data" for a fixture and "; fallback route, traffic not
    /// considered" for a fallback. `distance` is the already formatted road distance.
    public static func note(for route: RouteGeometry, distance: String) -> String {
        var text = "Driving route from the team backend"
        if route.sourceLabel != RouteGeometry.unknownSourceLabel {
            text += " (\(route.sourceLabel))"
        }
        text += ", \(distance)"
        if route.isFixture {
            text += ", test fixture data"
        }
        if route.isFallback {
            text += "; fallback route, traffic not considered"
        }
        return text + "."
    }

    /// The places card's note for the dashed line. `distance` is the straight-line distance.
    public static func schematicNote(distance: String) -> String {
        "The dashed line is a schematic connection, not a driving route. Straight-line distance \(distance)."
    }

    /// The map's spoken description of the line between the two pins.
    public static func mapLineDescription(for state: RouteState) -> String {
        if let route = state.geometry {
            return "joined by the driving route from the team backend via \(route.sourceLabel)"
        }
        return "joined by a schematic line that is not a driving route"
    }

    /// The places card's status line. In the demo it says that nothing is looked up; with the
    /// live backend it says what comes from the backend and what the dashed line means while no
    /// route is shown.
    public static func status(showsBothPlaces: Bool, usesLiveBackend: Bool, route: RouteState) -> String {
        let position = showsBothPlaces
            ? "Home and campus are both in view."
            : "Panned away from home and campus."
        guard usesLiveBackend else {
            return position + " Pins come from Settings; no device location, routing, or live traffic is used. Map tiles need a network connection; the trip summary works without them."
        }
        let line: String
        switch route {
        case .route:
            line = "Leave-home times and the driving route come from the team backend over the network."
        case .loading:
            line = "Leave-home times come from the team backend over the network. The driving route is loading; until it arrives the dashed line is only a schematic connection."
        case .unavailable:
            line = "Leave-home times come from the team backend over the network. The driving route could not be loaded, so the dashed line is only a schematic connection."
        case .schematic:
            line = "Leave-home times come from the team backend over the network. This server setup provides no driving route, so the dashed line is only a schematic connection."
        }
        return position + " Pins come from Settings; no device location is used. " + line + " Map tiles need a network connection too."
    }
}
