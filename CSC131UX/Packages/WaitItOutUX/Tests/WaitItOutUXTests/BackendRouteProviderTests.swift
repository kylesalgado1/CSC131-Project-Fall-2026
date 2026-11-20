import XCTest
@testable import WaitItOutUX

/// Stage S1: route geometry from POST /route, and the words the Map uses for the line between
/// home and campus. A straight line is never presented as a route: the route wording appears
/// only for geometry a provider supplied.
final class BackendRouteProviderTests: XCTestCase {
    private let clock = FixedWallClock(TestFixtures.fridayNoon)
    private let home = CommutePlaces.sample.home.coordinate
    private let campus = CommutePlaces.sample.campus.coordinate

    private func provider(_ transport: ScriptedHTTPTransport) -> BackendRouteProvider {
        BackendRouteProvider(client: TestBackend.client(transport: transport, clock: clock))
    }

    private func route(for reply: ScriptedReply) async throws -> RouteGeometry {
        try await provider(ScriptedHTTPTransport(reply)).route(from: home, to: campus)
    }

    /// "notSupported", a provider failure kind, or `nil` when the call succeeded.
    private func failure(for reply: ScriptedReply) async -> String? {
        do {
            _ = try await route(for: reply)
            return nil
        } catch RouteProviderFailure.notSupported {
            return "notSupported"
        } catch let failure as CommuteProviderFailure {
            return "\(failure.kind)"
        } catch {
            return "other"
        }
    }

    private let threePoints = [(38.4088, -121.3716), (38.5, -121.4), (38.561, -121.4237)]

    // MARK: Request and mapping

    func testTheRouteRequestCarriesTheTwoPoints() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 12.4)))
        let geometry = try await provider(transport).route(from: home, to: campus)

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/route")
        XCTAssertEqual(Set(sent.jsonObject().keys), ["origin", "destination"])
        XCTAssertEqual(sent.number("origin", "lat"), 38.4088)
        XCTAssertEqual(sent.number("origin", "lng"), -121.3716)
        XCTAssertEqual(sent.number("destination", "lat"), 38.561)
        XCTAssertEqual(sent.number("destination", "lng"), -121.4237)

        XCTAssertEqual(geometry.points, [home, GeoCoordinate(latitude: 38.5, longitude: -121.4), campus])
        XCTAssertEqual(geometry.distanceMiles, 12.4)
        XCTAssertEqual(geometry.sourceLabel, "TomTom")
        XCTAssertFalse(geometry.isFallback)
        XCTAssertFalse(geometry.isFixture)
        XCTAssertEqual(geometry.middlePoint, GeoCoordinate(latitude: 38.5, longitude: -121.4))
    }

    func testRouteSourcesAreMappedExplicitly() async throws {
        let osrm = try await route(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 13, source: "osrm", fallback: true)))
        XCTAssertEqual(osrm.sourceLabel, "OpenStreetMap (OSRM)")
        XCTAssertTrue(osrm.isFallback)
        XCTAssertFalse(osrm.isFixture)

        let fixture = try await route(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 13, source: "fixture")))
        XCTAssertEqual(fixture.sourceLabel, "Test fixture")
        XCTAssertTrue(fixture.isFixture)

        let unknown = try await route(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 13, source: "unknown")))
        XCTAssertEqual(unknown.sourceLabel, "the team backend", "An unknown source is not a failure")
        let other = try await route(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 13, source: "here")))
        XCTAssertEqual(other.sourceLabel, "the team backend")
        let absent = try await route(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: 13, source: nil)))
        XCTAssertEqual(absent.sourceLabel, RouteGeometry.unknownSourceLabel)
        XCTAssertFalse(absent.isFixture)
    }

    func testUnusableGeometryIsAnInvalidResponse() async throws {
        let onePoint = await failure(for: .http(status: 200, body: TestBackend.routeBody(points: [(38.4, -121.3)], distanceMiles: 1)))
        XCTAssertEqual(onePoint, "invalidResponse", "Fewer than two points is not a route")
        let none = await failure(for: .http(status: 200, body: TestBackend.routeBody(points: [], distanceMiles: 0)))
        XCTAssertEqual(none, "invalidResponse")
        let outOfRange = await failure(for: .http(status: 200, body: TestBackend.routeBody(points: [(38.4, -121.3), (95, -121.3), (38.4, 200)], distanceMiles: 3)))
        XCTAssertEqual(outOfRange, "invalidResponse", "Only one of the three points is on the globe")
        let noDistance = await failure(for: .http(status: 200, body: #"{"points":[{"lat":38.4,"lng":-121.3},{"lat":38.5,"lng":-121.4}],"source":"tomtom","fallback":false}"#))
        XCTAssertEqual(noDistance, "invalidResponse")
        let negative = await failure(for: .http(status: 200, body: TestBackend.routeBody(points: threePoints, distanceMiles: -1)))
        XCTAssertEqual(negative, "invalidResponse")
        let notJSON = await failure(for: .http(status: 200, body: "route"))
        XCTAssertEqual(notJSON, "invalidResponse")

        // A stray bad point is dropped while two good ones remain.
        let mixed = try await route(for: .http(status: 200, body: #"{"points":[{"lat":38.4,"lng":-121.3},{"lat":120,"lng":0},{"lng":5},{"lat":38.5,"lng":-121.4}],"distanceMiles":9.5,"source":"tomtom","fallback":false}"#))
        XCTAssertEqual(mixed.points, [GeoCoordinate(latitude: 38.4, longitude: -121.3), GeoCoordinate(latitude: 38.5, longitude: -121.4)])
    }

    func testAServerWithoutRoutesIsNotSupported() async {
        let oldServer = await failure(for: .http(status: 404, body: #"{"message":"Route POST:/route not found","error":"Not Found","statusCode":404}"#))
        XCTAssertEqual(oldServer, "notSupported", "A 404 that is not the API's own not_found: the server predates the endpoint")
        let plain = await failure(for: .http(status: 404, body: "Not Found"))
        XCTAssertEqual(plain, "notSupported")
        let noPathProvider = await failure(for: .http(status: 503, body: TestBackend.errorBody("route_unavailable", "Route geometry is not set up on this server.")))
        XCTAssertEqual(noPathProvider, "notSupported")

        let apiNotFound = await failure(for: .http(status: 404, body: TestBackend.errorBody("not_found", "No such thing.")))
        XCTAssertEqual(apiNotFound, "server(status: 404)")
        let routing = await failure(for: .http(status: 502, body: TestBackend.errorBody("routing_unavailable", "The routing service is unavailable.")))
        XCTAssertEqual(routing, "routingUnavailable")
        let sleeping = await failure(for: .http(status: 503, body: ""))
        XCTAssertEqual(sleeping, "server(status: 503)", "A gateway's 503 is worth retrying")
        let offline = await failure(for: .urlError(.notConnectedToInternet))
        XCTAssertEqual(offline, "offline")
    }

    // MARK: Words

    func testRouteWordsNameTheSourceAndNeverCallAStraightLineARoute() {
        let tomTom = TestBackend.route()
        XCTAssertEqual(MapRouteText.annotation(for: tomTom), "Route via TomTom")
        XCTAssertEqual(MapRouteText.note(for: tomTom, distance: "12 mi"), "Driving route from the team backend (TomTom), 12 mi.")

        let fixture = RouteGeometry(points: tomTom.points, distanceMiles: 12, sourceLabel: "Test fixture", isFallback: false, isFixture: true)
        XCTAssertEqual(MapRouteText.note(for: fixture, distance: "12 mi"), "Driving route from the team backend (Test fixture), 12 mi, test fixture data.")

        let fallback = RouteGeometry(points: tomTom.points, distanceMiles: 12, sourceLabel: "OpenStreetMap (OSRM)", isFallback: true, isFixture: false)
        XCTAssertEqual(
            MapRouteText.note(for: fallback, distance: "12 mi"),
            "Driving route from the team backend (OpenStreetMap (OSRM)), 12 mi; fallback route, traffic not considered."
        )
        XCTAssertEqual(MapRouteText.annotation(for: fallback), "Route via OpenStreetMap (OSRM)")

        let unnamed = RouteGeometry(points: tomTom.points, distanceMiles: 12, sourceLabel: RouteGeometry.unknownSourceLabel, isFallback: false, isFixture: false)
        XCTAssertEqual(MapRouteText.note(for: unnamed, distance: "12 mi"), "Driving route from the team backend, 12 mi.")
        XCTAssertEqual(MapRouteText.annotation(for: unnamed), "Route via the team backend")

        // The prototype's schematic legend, unchanged.
        XCTAssertEqual(
            MapRouteText.schematicNote(distance: "17 km"),
            "The dashed line is a schematic connection, not a driving route. Straight-line distance 17 km."
        )
        XCTAssertEqual(MapRouteText.mapLineDescription(for: .schematic), "joined by a schematic line that is not a driving route")
        XCTAssertEqual(MapRouteText.mapLineDescription(for: .loading), "joined by a schematic line that is not a driving route")
        XCTAssertEqual(MapRouteText.mapLineDescription(for: .unavailable), "joined by a schematic line that is not a driving route")
        XCTAssertEqual(MapRouteText.mapLineDescription(for: .route(tomTom)), "joined by the driving route from the team backend via TomTom")

        XCTAssertEqual(RouteState.route(tomTom).geometry, tomTom)
        XCTAssertNil(RouteState.schematic.geometry)
        XCTAssertNil(RouteState.loading.geometry)
        XCTAssertNil(RouteState.unavailable.geometry)
        XCTAssertNil(RouteGeometry(points: [], distanceMiles: 0, sourceLabel: "TomTom", isFallback: false, isFixture: false).middlePoint)
    }

    func testTheMapStatusIsTheDemoTextInDemoAndTruthfulWhenLive() {
        // Demo: the prototype's sentences, byte for byte, whatever the route state.
        let demoInView = "Home and campus are both in view. Pins come from Settings; no device location, routing, or live traffic is used. Map tiles need a network connection; the trip summary works without them."
        let demoPanned = "Panned away from home and campus. Pins come from Settings; no device location, routing, or live traffic is used. Map tiles need a network connection; the trip summary works without them."
        XCTAssertEqual(MapRouteText.status(showsBothPlaces: true, usesLiveBackend: false, route: .schematic), demoInView)
        XCTAssertEqual(MapRouteText.status(showsBothPlaces: false, usesLiveBackend: false, route: .schematic), demoPanned)

        let states: [RouteState] = [.schematic, .loading, .unavailable, .route(TestBackend.route())]
        for state in states {
            let live = MapRouteText.status(showsBothPlaces: true, usesLiveBackend: true, route: state)
            XCTAssertTrue(live.hasPrefix("Home and campus are both in view. "), live)
            XCTAssertTrue(live.contains("team backend over the network"), live)
            XCTAssertFalse(live.contains("no device location, routing, or live traffic"), "Live mode does not claim to be offline: \(live)")
            XCTAssertTrue(live.contains("no device location is used"), live)
        }
        let withRoute = MapRouteText.status(showsBothPlaces: true, usesLiveBackend: true, route: .route(TestBackend.route()))
        XCTAssertTrue(withRoute.contains("the driving route come from the team backend"), withRoute)
        XCTAssertFalse(withRoute.contains("schematic"), withRoute)
        for state in [RouteState.schematic, .loading, .unavailable] {
            let text = MapRouteText.status(showsBothPlaces: false, usesLiveBackend: true, route: state)
            XCTAssertTrue(text.hasPrefix("Panned away from home and campus. "), text)
            XCTAssertTrue(text.contains("the dashed line is only a schematic connection"), "Without a route the line stays labeled schematic: \(text)")
        }
        XCTAssertTrue(MapRouteText.status(showsBothPlaces: true, usesLiveBackend: true, route: .unavailable).contains("could not be loaded"))
        XCTAssertTrue(MapRouteText.status(showsBothPlaces: true, usesLiveBackend: true, route: .loading).contains("is loading"))
    }
}
