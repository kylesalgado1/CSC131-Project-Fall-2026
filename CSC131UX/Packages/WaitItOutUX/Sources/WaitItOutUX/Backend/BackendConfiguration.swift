import Foundation

/// Why typed text is not a usable server address. Messages are user-facing.
public enum BackendAddressIssue: Error, Equatable, Sendable {
    /// The text is not an address at all.
    case notAnAddress
    /// The address does not start with http or https.
    case unsupportedScheme
    /// The address has no host name.
    case missingHost
    /// The address carries a path, a query, a fragment, or sign-in details.
    case extraParts
    /// Plain http for a host that is not local: App Transport Security would block it.
    case needsHTTPS

    public var message: String {
        switch self {
        case .notAnAddress:
            return "Enter a server address, such as https://example.org."
        case .unsupportedScheme:
            return "Start the address with https:// (plain http:// works only for a server on this network)."
        case .missingHost:
            return "The address needs a host name, such as https://example.org."
        case .extraParts:
            return "Enter only the server address, without a path, a question mark, or sign-in details."
        case .needsHTTPS:
            return "Use https for this address."
        }
    }
}

/// Where the team backend lives. The host supplies a default address (from its Info.plist or
/// environment); the address typed in Settings overrides it. Thread-safe, so the backend
/// client can read the current address from any task while the model changes it on the main
/// actor.
public final class BackendConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var overrideURL: URL?

    /// The host's own address, used while Settings has none. `nil` when the host has none either.
    public let defaultBaseURL: URL?

    public init(defaultBaseURL: URL?) {
        self.defaultBaseURL = defaultBaseURL
    }

    /// The address requests go to: the Settings override, else the host's default, else `nil`
    /// (not configured).
    public var baseURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return overrideURL ?? defaultBaseURL
    }

    /// The Settings override on its own, or `nil` while the default applies.
    public var overrideBaseURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return overrideURL
    }

    /// Replaces the Settings override; `nil` returns to the host's default.
    public func setOverride(_ url: URL?) {
        lock.lock()
        overrideURL = url
        lock.unlock()
    }

    /// Parses a typed server address. Empty text means "use the default" and succeeds with
    /// `nil`. Otherwise the address must be http or https with a host and nothing after it but
    /// slashes, which are trimmed. Plain http is accepted only for localhost, names ending in
    /// ".local", and IP-literal hosts, because App Transport Security blocks other cleartext
    /// hosts; everything else must be https. The result is normalized: lowercased scheme and
    /// host, optional port, no path.
    public static func parse(_ text: String) -> Result<URL?, BackendAddressIssue> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: trimmed) else {
            return .failure(.notAnAddress)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .failure(.missingHost)
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            return .failure(.extraParts)
        }
        if scheme == "http", !allowsCleartext(host: host) {
            return .failure(.needsHTTPS)
        }
        components.scheme = scheme
        // An IPv6 literal keeps its brackets and spelling; names are lowercased.
        if !host.contains(":") {
            components.host = host
        }
        components.path = ""
        guard let url = components.url else { return .failure(.notAnAddress) }
        return .success(url)
    }

    /// True for the hosts App Transport Security lets an app reach over plain http when local
    /// networking is allowed: localhost, ".local" names, and IPv4 or IPv6 literals.
    static func allowsCleartext(host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if name.contains(":") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}
