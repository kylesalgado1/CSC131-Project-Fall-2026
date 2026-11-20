import Foundation

/// Facts shown in the Settings tab's "Prototype information" area.
public struct PrototypeInfo: Equatable, Sendable {
    public let appName: String
    public let version: String
    public let build: String
    public let packageName: String
    public let stepDescription: String
    public let dataDisclosure: String

    public init(appName: String, version: String, build: String) {
        self.appName = appName
        self.version = version
        self.build = build
        packageName = "WaitItOutUX"
        stepDescription = "Prototype step 8 of 8: the complete standalone demo, reviewed for team handoff. Activities and settings are saved on this device; leave-home times are calculated from the ideal arrival and a simulated test commute; reminders appear as in-app previews only, and no system notification is sent."
        dataDisclosure = "Everything shown is demo content. Commute times are simulated test values, not measured traffic, and the line between home and campus is schematic, not a driving route. Reminders are previews inside the app; no notification permission is requested and no system notification is sent. No live traffic, routing, device location, accounts, or network services are used."
    }

    /// The step description for the data mode in use. The demo text is the prototype's own;
    /// with the live backend it says what comes from the team backend instead of claiming a
    /// simulated commute and in-app previews.
    public func stepDescription(usesLiveBackend: Bool) -> String {
        guard usesLiveBackend else { return stepDescription }
        return "Live data mode: activities and settings are saved on this device; each leave-home time is the team backend's traffic-based recommendation for your ideal arrival; with leave-home reminders on, the server monitors your upcoming trips and tries to alert you. The Demo data mode under Data source brings back the standalone demo."
    }

    /// The data disclosure for the data mode in use. The demo text is the prototype's own;
    /// with the live backend nothing claims "no network", "no live traffic", or "no
    /// notification permission".
    public func dataDisclosure(usesLiveBackend: Bool) -> String {
        guard usesLiveBackend else { return dataDisclosure }
        return "Leave-home times, and the Map's driving route when the server provides one, come from the team backend over the network. Each recommendation names the traffic source the backend reported, and live traffic is claimed only when the backend had it. Home and campus are the coordinates set in Settings; no device location, address lookup, or account is used. Notification permission is asked for only when you turn leave-home reminders on or choose Allow Notifications. Sample activities and sample locations stay labeled SAMPLE."
    }

    /// Reads the display name and version from an app bundle's Info dictionary, with safe
    /// fallbacks for missing keys (for example when running inside a test host).
    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        let name = [displayName, bundleName].compactMap { $0 }.first { !$0.isEmpty } ?? "WAIT IT OUT UX Prototype"
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let build = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        self.init(appName: name, version: version, build: build)
    }
}
