import Foundation
import Security

/// What this installation needs to talk to one server about its trips: the device credential
/// the server issued, and where the trip snapshots stand. There are no user accounts; the
/// credential identifies the installation only.
public struct StoredCredential: Codable, Equatable, Sendable {
    /// The server's id for this installation.
    public let deviceID: String
    /// The bearer credential, shown once at registration. Never logged, never written to
    /// preferences or files.
    public let token: String
    /// The revision of the last trip snapshot sent. Kept with the token because the Keychain
    /// outlives a reinstall and the server remembers the revision.
    public var revision: Int
    /// SHA-256 of the trips last sent under `revision`. The same revision is used again only
    /// for exactly that body; any other body gets a new one.
    public var sentDigest: String?
    /// The highest revision the server has reported.
    public var serverRevision: Int

    public init(deviceID: String, token: String, revision: Int = 0, sentDigest: String? = nil, serverRevision: Int = 0) {
        self.deviceID = deviceID
        self.token = token
        self.revision = revision
        self.sentDigest = sentDigest
        self.serverRevision = serverRevision
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case token
        case revision
        case sentDigest
        case serverRevision
    }

    /// The counters decode tolerantly, so a credential stored by an earlier build stays usable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        token = try container.decode(String.self, forKey: .token)
        revision = (try? container.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
        sentDigest = (try? container.decodeIfPresent(String.self, forKey: .sentDigest)) ?? nil
        serverRevision = (try? container.decodeIfPresent(Int.self, forKey: .serverRevision)) ?? 0
    }
}

/// Where device credentials are kept, one per server origin (scheme, host, and port), so two
/// servers never share a credential. Implementations may do I/O; every method is called off
/// the main actor.
public protocol CredentialStoring: Sendable {
    func load(origin: String) async throws -> StoredCredential?
    func save(_ credential: StoredCredential, origin: String) async throws
    func clear(origin: String) async throws
    /// Every origin that has a credential now, sorted. A credential is cleared only after its
    /// server confirmed the removal, so the origins other than the one in use are the servers
    /// that may still hold this installation.
    func origins() async throws -> [String]
}

/// Session-only store for tests and previews. Nothing outlives the process.
public actor InMemoryCredentialStore: CredentialStoring {
    private var stored: [String: StoredCredential]

    public init(initial: [String: StoredCredential] = [:]) {
        stored = initial
    }

    public func load(origin: String) async throws -> StoredCredential? {
        stored[origin]
    }

    public func save(_ credential: StoredCredential, origin: String) async throws {
        stored[origin] = credential
    }

    public func clear(origin: String) async throws {
        stored[origin] = nil
    }

    public func origins() -> [String] {
        stored.keys.sorted()
    }
}

/// A Keychain call failed with this status.
public struct CredentialStoreError: Error, Equatable, Sendable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

/// The four Keychain operations the credential store needs, so the store's own logic is
/// testable without the system Keychain.
protocol KeychainItemAccessing: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
    /// The account of every item stored under `service`.
    func accounts(service: String) throws -> [String]
}

/// The system Keychain: generic passwords that stay on this device and are readable after the
/// first unlock, so a notification action can use the credential while the phone is locked
/// again.
struct SystemKeychain: KeychainItemAccessing {
    func read(service: String, account: String) throws -> Data? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        return result as? Data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = Self.query(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CredentialStoreError(status: updated) }
        var item = query
        for (key, value) in attributes {
            item[key] = value
        }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialStoreError(status: added) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }

    func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// The host's credential store: one Keychain item per server origin under the service
/// `com.waititout.backend`, kept on this device only. The bearer credential never goes to
/// preferences, files, or logs. An item that can no longer be read as a credential counts as
/// none, so the device simply registers again.
public struct KeychainCredentialStore: CredentialStoring {
    public static let service = "com.waititout.backend"

    private let service: String
    private let items: any KeychainItemAccessing

    public init() {
        self.init(service: Self.service, items: SystemKeychain())
    }

    init(service: String, items: any KeychainItemAccessing) {
        self.service = service
        self.items = items
    }

    public func load(origin: String) async throws -> StoredCredential? {
        guard let data = try items.read(service: service, account: origin) else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    public func save(_ credential: StoredCredential, origin: String) async throws {
        let data = try JSONEncoder().encode(credential)
        try items.write(data, service: service, account: origin)
    }

    public func clear(origin: String) async throws {
        try items.delete(service: service, account: origin)
    }

    /// Only items that still read as a credential count, as in `load`.
    public func origins() async throws -> [String] {
        try items.accounts(service: service)
            .filter { account in
                guard let data = try items.read(service: service, account: account) else { return false }
                return (try? JSONDecoder().decode(StoredCredential.self, from: data)) != nil
            }
            .sorted()
    }
}
