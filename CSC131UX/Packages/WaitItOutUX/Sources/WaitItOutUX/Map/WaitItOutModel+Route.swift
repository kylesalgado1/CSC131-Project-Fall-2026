import Foundation

/// The two points a route is asked for.
struct RoutePair: Equatable, Sendable {
    let origin: GeoCoordinate
    let destination: GeoCoordinate
}

/// Bookkeeping for the Map's route request. Not observed and never stored.
struct RouteTracking {
    /// The pair the current `routeState` answers or is being asked for.
    var pair: RoutePair?
    /// Unique per request, so a late answer for an earlier pair or source is dropped.
    var token: UInt64 = 0
    /// When the route on screen arrived.
    var loadedAt: Date?
    /// When the last request started.
    var attemptedAt: Date?
    /// Consecutive failed attempts for `pair`.
    var failedAttempts = 0
    /// True when the last failure can clear on its own, so the minute ticks retry it.
    var lastFailureIsTransient = false
    /// True when the server has no route feature: not asked again until the server address or
    /// the data mode changes.
    var isUnsupported = false
}

/// The Map's driving route (live backend only). The model asks the injected `RouteProviding`
/// for home to campus and publishes the answer as `routeState`; the Map draws a route only
/// when one arrived, and the dashed schematic line with its schematic labels in every other
/// state. Requests are token-guarded like leave-home requests: a late answer for old places
/// or another source is dropped. Triggers: the first settings load, a home or campus change, a
/// data-mode or server-address change, the return to the foreground when the route is older
/// than `routeLifetime` or missing, and the minute ticks after a transient failure.
extension WaitItOutModel {
    /// How long a loaded route is kept before the foreground asks for it again: 30 minutes.
    static let routeLifetime: TimeInterval = 30 * 60

    /// Brings `routeState` in line with the data mode and the places. Asks only when there is
    /// something new to ask: a different pair, or `force`. While the same pair is asked again,
    /// the route already on screen stays visible. Without the live backend or a route provider
    /// the state is `.schematic` and nothing is asked.
    func refreshRoute(force: Bool = false) {
        guard usesLiveBackend, let provider = liveBackend?.routeProvider else {
            clearRoute()
            return
        }
        let pair = RoutePair(origin: places.home.coordinate, destination: places.campus.coordinate)
        let samePair = routeTracking.pair == pair
        if samePair {
            // Already loading, unsupported by this server, or nothing new to ask.
            if routeTask != nil || routeTracking.isUnsupported || !force { return }
        }
        routeTask?.cancel()
        routeTracking.token &+= 1
        let token = routeTracking.token
        if !samePair {
            routeTracking.failedAttempts = 0
            routeTracking.lastFailureIsTransient = false
            routeTracking.isUnsupported = false
            routeTracking.loadedAt = nil
        }
        routeTracking.pair = pair
        routeTracking.attemptedAt = currentDate()
        let keepsRoute = samePair && routeState.geometry != nil
        if !keepsRoute, routeState != .loading {
            routeState = .loading
        }
        routeTask = Task { [weak self] in
            let outcome = await WaitItOutModel.resolveRoute(pair, using: provider)
            guard !Task.isCancelled else { return }
            self?.applyRoute(outcome, token: token)
        }
    }

    /// The source changed: forget the route and everything known about the old server, then ask.
    func restartRoute() {
        clearRoute()
        refreshRoute()
    }

    /// The app returned to the foreground: ask again when the route on screen is older than
    /// `routeLifetime`, or when the last request failed.
    func refreshRouteOnForeground() {
        let isDue: Bool
        switch routeState {
        case .route:
            let loadedAt = routeTracking.loadedAt ?? .distantPast
            isDue = currentDate().timeIntervalSince(loadedAt) >= Self.routeLifetime
        case .unavailable:
            isDue = true
        case .schematic, .loading:
            isDue = false
        }
        refreshRoute(force: isDue)
    }

    /// Minute ticks: after a transient failure the route is asked again with the same backoff
    /// as leave-home requests (`DepartureRetry`). Other failures wait for a trigger.
    func retryRouteIfDue(at now: Date) {
        guard usesLiveBackend, routeState == .unavailable, routeTask == nil,
              routeTracking.lastFailureIsTransient, !routeTracking.isUnsupported,
              let attemptedAt = routeTracking.attemptedAt,
              now.timeIntervalSince(attemptedAt) >= DepartureRetry.delay(afterAttempt: routeTracking.failedAttempts) else {
            return
        }
        refreshRoute(force: true)
    }

    /// Waits for the running route request. Tests use this; the UI never needs to.
    func waitForRoute() async {
        while let task = routeTask {
            await task.value
            if routeTask == task {
                routeTask = nil
            }
        }
    }

    private func clearRoute() {
        routeTask?.cancel()
        routeTask = nil
        let token = routeTracking.token &+ 1
        routeTracking = RouteTracking()
        routeTracking.token = token
        if routeState != .schematic {
            routeState = .schematic
        }
    }

    private func applyRoute(_ outcome: RouteOutcome, token: UInt64) {
        guard token == routeTracking.token else { return }
        routeTask = nil
        switch outcome {
        case .route(let geometry):
            routeTracking.loadedAt = currentDate()
            routeTracking.failedAttempts = 0
            routeTracking.lastFailureIsTransient = false
            // Identical geometry is not published again, so the Map does not redraw for nothing.
            if routeState != .route(geometry) {
                routeState = .route(geometry)
            }
        case .failed(let isTransient, let isUnsupported):
            routeTracking.failedAttempts += 1
            routeTracking.lastFailureIsTransient = isTransient
            routeTracking.isUnsupported = isUnsupported
            // A route already on screen for this pair is still a route; only a missing one
            // falls back to the schematic line.
            if routeState.geometry == nil, routeState != .unavailable {
                routeState = .unavailable
            }
        }
    }

    private enum RouteOutcome: Sendable {
        case route(RouteGeometry)
        case failed(isTransient: Bool, isUnsupported: Bool)
    }

    /// Asks the provider off the main actor and classifies a failure.
    private nonisolated static func resolveRoute(_ pair: RoutePair, using provider: any RouteProviding) async -> RouteOutcome {
        do {
            return .route(try await provider.route(from: pair.origin, to: pair.destination))
        } catch RouteProviderFailure.notSupported {
            return .failed(isTransient: false, isUnsupported: true)
        } catch let failure as CommuteProviderFailure {
            return .failed(isTransient: failure.kind.isTransient, isUnsupported: false)
        } catch {
            return .failed(isTransient: false, isUnsupported: false)
        }
    }
}
