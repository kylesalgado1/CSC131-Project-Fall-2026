import Foundation

/// Route geometry from the team backend's POST /route.
public struct BackendRouteProvider: RouteProviding {
    private let client: BackendClient

    public init(client: BackendClient) {
        self.client = client
    }

    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate) async throws -> RouteGeometry {
        let response = try await client.route(origin: origin, destination: destination)
        return try Self.geometry(from: response)
    }

    /// Maps the wire answer. Points that are missing a component or out of range are dropped;
    /// fewer than two usable points, or a distance that is not a finite, non-negative number,
    /// is an unreadable answer.
    static func geometry(from response: WireRouteResponse) throws -> RouteGeometry {
        let points = response.points.compactMap { point -> GeoCoordinate? in
            guard let latitude = point.lat, let longitude = point.lng else { return nil }
            let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
            return coordinate.isValid ? coordinate : nil
        }
        guard points.count >= 2, let distance = response.distanceMiles, distance.isFinite, distance >= 0 else {
            throw CommuteProviderFailure(.invalidResponse)
        }
        let source = response.source?.lowercased()
        return RouteGeometry(
            points: points,
            distanceMiles: distance,
            sourceLabel: sourceLabel(for: source),
            isFallback: response.fallback ?? false,
            isFixture: source == "fixture"
        )
    }

    /// The wire's route source spelled for people. An unknown or missing source is not a failure.
    static func sourceLabel(for source: String?) -> String {
        switch source {
        case "tomtom":
            return "TomTom"
        case "osrm":
            return "OpenStreetMap (OSRM)"
        case "fixture":
            return "Test fixture"
        default:
            return RouteGeometry.unknownSourceLabel
        }
    }
}
