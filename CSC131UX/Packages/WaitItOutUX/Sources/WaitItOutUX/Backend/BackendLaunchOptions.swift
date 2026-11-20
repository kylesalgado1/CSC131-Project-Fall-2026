import Foundation

/// What the host reads from its launch environment and its Info.plist before it composes the
/// app: whether the team backend is composed at all, and the server address used until
/// Settings names another. Pure, so the host's two compositions are decided in one tested place.
public struct BackendLaunchOptions: Equatable, Sendable {
    /// Environment variable that selects the composition. Every UI test sets it.
    public static let dataModeEnvironmentKey = "WAIT_IT_OUT_DATA_MODE"
    /// The value that composes the standalone demo: no backend, no network, no notifications.
    public static let demoDataModeValue = "demo"
    /// Environment variable that replaces the Info.plist server address for one launch.
    public static let backendURLEnvironmentKey = "WAIT_IT_OUT_BACKEND_URL"
    /// Info.plist key holding the host's default server address.
    public static let backendURLInfoKey = "WaitItOutBackendURL"

    /// False only when the environment asks for the standalone demo. Any other value, and no
    /// value at all, composes the live backend, which is the app's normal flow.
    public let composesLiveBackend: Bool
    /// The server address used while Settings has none, or `nil` when the host has no usable
    /// one. Always `nil` for the standalone demo.
    public let defaultBaseURL: URL?

    public init(composesLiveBackend: Bool, defaultBaseURL: URL?) {
        self.composesLiveBackend = composesLiveBackend
        self.defaultBaseURL = composesLiveBackend ? defaultBaseURL : nil
    }

    /// Reads the options for one launch.
    ///
    /// The address comes from the environment when it names one, else from the Info.plist.
    /// Both go through `BackendConfiguration.parse`, the same rules as the Settings field. An
    /// environment address that is not usable leaves the app without a server ("not
    /// configured") instead of quietly falling back to the Info.plist address, so a launch
    /// never talks to a server other than the one it was pointed at.
    public init(environment: [String: String], infoDictionary: [String: Any]?) {
        let mode = environment[Self.dataModeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isLive = mode != Self.demoDataModeValue
        self.init(
            composesLiveBackend: isLive,
            defaultBaseURL: isLive ? Self.defaultBaseURL(environment: environment, infoDictionary: infoDictionary) : nil
        )
    }

    /// The host's server address: the environment's when it has one, else the Info.plist's.
    static func defaultBaseURL(environment: [String: String], infoDictionary: [String: Any]?) -> URL? {
        if let text = nonEmpty(environment[backendURLEnvironmentKey]) {
            return address(from: text)
        }
        guard let text = nonEmpty(infoDictionary?[backendURLInfoKey] as? String) else { return nil }
        return address(from: text)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func address(from text: String) -> URL? {
        switch BackendConfiguration.parse(text) {
        case .success(let url):
            return url
        case .failure:
            return nil
        }
    }
}
