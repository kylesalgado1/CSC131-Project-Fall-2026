import Foundation

/// Everything the host supplies to run the app on the team backend. Passing one to
/// `WaitItOutModel.init` makes live data the normal flow; the simulated test provider and the
/// in-app reminder previews then remain only as the explicit Demo data mode. Without one the
/// model behaves exactly as the standalone prototype.
public struct LiveBackend: Sendable {
    /// Asks the backend for departure recommendations.
    public let commuteEstimator: any CommuteEstimating
    /// Supplies the Map's driving route; `nil` keeps the schematic line.
    public let routeProvider: (any RouteProviding)?
    /// Synchronizes trips for server-side monitoring; `nil` when monitoring is not composed.
    public let tripMonitor: (any TripMonitoring)?
    /// The server address in use, shared with the backend client.
    public let configuration: BackendConfiguration

    public init(
        commuteEstimator: any CommuteEstimating,
        routeProvider: (any RouteProviding)? = nil,
        tripMonitor: (any TripMonitoring)? = nil,
        configuration: BackendConfiguration
    ) {
        self.commuteEstimator = commuteEstimator
        self.routeProvider = routeProvider
        self.tripMonitor = tripMonitor
        self.configuration = configuration
    }
}
