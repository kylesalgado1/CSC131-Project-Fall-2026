import XCTest
@testable import WaitItOutUX

/// Stage S1: the Map's route state. A driving route is shown only when the live backend
/// supplied one; in every other state the model reports that the schematic line applies. A
/// failure keeps the schematic line, a late answer for old places is dropped, a server without
/// routes is not asked again until the source changes, and the demo never asks at all.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT.
@MainActor
final class WaitItOutModelRouteTests: XCTestCase {
    private func clock() -> ManualWallClock {
        ManualWallClock(TestFixtures.date(2026, 10, 26, 6, 0))
    }

    private func idleBackend() -> ScriptedCommuteEstimator {
        ScriptedCommuteEstimator { _ in .unavailable(message: "No trips in this test.") }
    }

    private func place(_ name: String, _ latitude: Double, _ longitude: Double) throws -> CommutePlace {
        try CommutePlace(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
    }

    private let home = CommutePlaces.sample.home.coordinate
    private let campus = CommutePlaces.sample.campus.coordinate

    // MARK: Loading

    func testTheRouteLoadsOnceAfterTheSettings() async throws {
        let routes = ScriptedRouteProvider { _, _ in TestBackend.route() }
        let model = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes)
        XCTAssertEqual(model.routeState, .schematic, "Nothing is asked before the settings are read")

        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(TestBackend.route()))

        let asked = await routes.requests
        XCTAssertEqual(asked, [RoutePair(origin: home, destination: campus)], "Home to campus, as set in Settings")

        // Nothing new to ask: the schedule load, ticks, and repeated calls do not ask again.
        await model.loadActivities()
        model.refreshDepartures()
        model.refreshRoute()
        await model.waitForRoute()
        let count = await routes.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testWithoutALiveBackendOrInDemoNoRouteIsAsked() async throws {
        // No live backend at all.
        let standalone = TestFixtures.makeModel()
        await standalone.loadPreferences()
        standalone.refreshRoute(force: true)
        await standalone.waitForRoute()
        XCTAssertEqual(standalone.routeState, .schematic)

        // A live backend in Demo mode.
        let routes = ScriptedRouteProvider { _, _ in TestBackend.route() }
        let store = InMemoryPreferencesStore(initial: UserPreferences(dataMode: .demo))
        let demo = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes, store: store)
        await demo.loadPreferences()
        await demo.waitForRoute()
        demo.appDidBecomeActive()
        await demo.waitForRoute()
        XCTAssertEqual(demo.routeState, .schematic)
        var count = await routes.requestCount()
        XCTAssertEqual(count, 0, "Demo mode never calls the backend")

        // A live backend without a route provider keeps the schematic line too.
        let noRoutes = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend())
        await noRoutes.loadPreferences()
        await noRoutes.waitForRoute()
        XCTAssertEqual(noRoutes.routeState, .schematic)
        count = await routes.requestCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: Failures

    func testAFailedRouteKeepsTheSchematicLineAndIsRetriedOnTheTicks() async throws {
        let time = clock()
        let routes = ScriptedRouteProvider { _, _ in throw CommuteProviderFailure(.timedOut) }
        let model = TestBackend.makeLiveModel(clock: time, liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .unavailable, "No route: the map keeps the dashed line and its schematic labels")
        XCTAssertNil(model.routeState.geometry)

        // A transient failure is asked again on a tick a minute later, then two minutes later.
        time.advance(by: 59)
        model.refreshDepartures()
        await model.waitForRoute()
        var count = await routes.requestCount()
        XCTAssertEqual(count, 1)
        time.advance(by: 1)
        model.refreshDepartures()
        await model.waitForRoute()
        count = await routes.requestCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.routeState, .unavailable)
        time.advance(by: 119)
        model.refreshDepartures()
        await model.waitForRoute()
        count = await routes.requestCount()
        XCTAssertEqual(count, 2)

        await routes.setResponder { _, _ in TestBackend.route() }
        time.advance(by: 1)
        model.refreshDepartures()
        await model.waitForRoute()
        count = await routes.requestCount()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(model.routeState, .route(TestBackend.route()), "The server woke up: the route appears without any tap")
    }

    func testALastingRouteFailureWaitsForTheForeground() async throws {
        let time = clock()
        let routes = ScriptedRouteProvider { _, _ in throw CommuteProviderFailure(.invalidResponse) }
        let model = TestBackend.makeLiveModel(clock: time, liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .unavailable)
        for _ in 0..<10 {
            time.advance(by: 60)
            model.refreshDepartures()
            await model.waitForRoute()
        }
        var count = await routes.requestCount()
        XCTAssertEqual(count, 1, "An unreadable answer is not retried on ticks")

        await routes.setResponder { _, _ in TestBackend.route() }
        model.appDidBecomeActive()
        await model.waitForRoute()
        count = await routes.requestCount()
        XCTAssertEqual(count, 2, "Coming back to the app asks again")
        XCTAssertEqual(model.routeState, .route(TestBackend.route()))
    }

    func testAServerWithoutRoutesIsNotAskedAgainUntilTheSourceChanges() async throws {
        let time = clock()
        let routes = ScriptedRouteProvider { _, _ in throw RouteProviderFailure.notSupported }
        let model = TestBackend.makeLiveModel(clock: time, liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .unavailable)

        for _ in 0..<10 {
            time.advance(by: 60)
            model.refreshDepartures()
            await model.waitForRoute()
        }
        time.advance(by: 3_600)
        model.appDidBecomeActive()
        model.refreshRoute(force: true)
        await model.waitForRoute()
        var count = await routes.requestCount()
        XCTAssertEqual(count, 1, "Not supported by this server: no automatic retry")

        // Another server may support routes.
        await routes.setResponder { _, _ in TestBackend.route() }
        XCTAssertNil(model.applyBackendAddress("https://newer.example"))
        XCTAssertEqual(model.routeState, .loading)
        await model.waitForRoute()
        count = await routes.requestCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.routeState, .route(TestBackend.route()))
    }

    // MARK: Places

    func testALateAnswerForOldPlacesIsDropped() async throws {
        let routes = LateAnsweringRouteProvider()
        let model = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        let asked = await waitUntil { await routes.requestCount() == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.routeState, .loading, "The schematic line stays while the route loads")
        XCTAssertNil(model.routeState.geometry)

        // The user moves home while the first route is still in flight.
        let newHome = try place("New home", 38.45, -121.39)
        model.setPlace(newHome, for: .home)
        let askedAgain = await waitUntil { await routes.requestCount() == 2 }
        XCTAssertTrue(askedAgain)
        let second = await routes.request(at: 1)
        XCTAssertEqual(second, RoutePair(origin: newHome.coordinate, destination: campus))
        XCTAssertEqual(model.routeState, .loading)

        // The route for the old home arrives late and must never be drawn.
        await routes.answer(0, with: TestBackend.route(label: "TomTom", miles: 12.4))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.routeState, .loading, "The answer for the old places is dropped")

        let fresh = RouteGeometry(points: [newHome.coordinate, campus], distanceMiles: 9.1, sourceLabel: "TomTom", isFallback: false, isFixture: false)
        await routes.answer(1, with: fresh)
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(fresh))
    }

    func testChangedPlacesStartFromTheSchematicLine() async throws {
        let routes = ScriptedRouteProvider { origin, destination in
            RouteGeometry(points: [origin, destination], distanceMiles: 10, sourceLabel: "TomTom", isFallback: false, isFixture: false)
        }
        let model = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState.geometry?.points, [home, campus])

        let newCampus = try place("Other campus", 38.60, -121.45)
        model.setPlace(newCampus, for: .campus)
        XCTAssertEqual(model.routeState, .loading, "The old route is not shown between the new pins")
        await model.waitForRoute()
        XCTAssertEqual(model.routeState.geometry?.points, [home, newCampus.coordinate])

        model.resetPlacesToSample()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState.geometry?.points, [home, campus])
        let count = await routes.requestCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: Age and source

    func testAnOldRouteIsAskedAgainInTheForegroundAndStaysVisibleMeanwhile() async throws {
        let time = clock()
        let routes = LateAnsweringRouteProvider()
        let model = TestBackend.makeLiveModel(clock: time, liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        _ = await waitUntil { await routes.requestCount() == 1 }
        let first = TestBackend.route(miles: 12.4)
        await routes.answer(0, with: first)
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(first))

        // Twenty-nine minutes later the route is still fresh.
        time.advance(by: 29 * 60)
        model.appDidBecomeActive()
        var count = await routes.requestCount()
        XCTAssertEqual(count, 1)

        // Thirty minutes: asked again, and the route on screen stays while the same pair is asked.
        time.advance(by: 60)
        model.appDidBecomeActive()
        let asked = await waitUntil { await routes.requestCount() == 2 }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.routeState, .route(first), "The previous route stays visible while the same pair is asked again")

        // The refresh fails: the route already shown is still a route.
        await routes.fail(1, with: CommuteProviderFailure(.offline))
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(first))

        // The next return to the foreground tries again and takes the new geometry.
        model.appDidBecomeActive()
        _ = await waitUntil { await routes.requestCount() == 3 }
        let second = TestBackend.route(miles: 13.0, bend: 38.52)
        await routes.answer(2, with: second)
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(second))
        count = await routes.requestCount()
        XCTAssertEqual(count, 3)
    }

    func testSwitchingToDemoDropsTheRouteAndLiveAsksAgain() async throws {
        let routes = ScriptedRouteProvider { _, _ in TestBackend.route() }
        let model = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(TestBackend.route()))

        model.setDataMode(.demo)
        XCTAssertEqual(model.routeState, .schematic, "The demo never shows a backend route")
        await model.waitForRoute()
        var count = await routes.requestCount()
        XCTAssertEqual(count, 1)

        model.setDataMode(.live)
        XCTAssertEqual(model.routeState, .loading)
        await model.waitForRoute()
        XCTAssertEqual(model.routeState, .route(TestBackend.route()))
        count = await routes.requestCount()
        XCTAssertEqual(count, 2)
    }

    func testARouteArrivingAfterTheSwitchToDemoIsDropped() async throws {
        let routes = LateAnsweringRouteProvider()
        let model = TestBackend.makeLiveModel(clock: clock(), liveEstimator: idleBackend(), routeProvider: routes)
        await model.loadPreferences()
        _ = await waitUntil { await routes.requestCount() == 1 }
        model.setDataMode(.demo)
        await routes.answer(0, with: TestBackend.route())
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.routeState, .schematic)
    }
}
