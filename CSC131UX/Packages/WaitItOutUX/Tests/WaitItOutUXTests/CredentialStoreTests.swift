import Security
import XCTest
@testable import WaitItOutUX

/// Stage S2: where the device credential is kept. One item per server origin, never shared
/// between servers; the counters travel with the token; an unreadable item counts as none.
final class CredentialStoreTests: XCTestCase {
    private let first = StoredCredential(deviceID: "0a0a0a0a-0000-4000-8000-000000000001", token: "0a0a0a0a-0000-4000-8000-000000000001.secret-one", revision: 4, sentDigest: "abc", serverRevision: 5)
    private let second = StoredCredential(deviceID: "0b0b0b0b-0000-4000-8000-000000000002", token: "0b0b0b0b-0000-4000-8000-000000000002.secret-two")

    func testTheInMemoryStoreKeepsOneCredentialPerOrigin() async throws {
        let store = InMemoryCredentialStore()
        let nothing = try await store.load(origin: "https://backend.example")
        XCTAssertNil(nothing)

        try await store.save(first, origin: "https://backend.example")
        try await store.save(second, origin: "http://localhost:3000")
        let loadedFirst = try await store.load(origin: "https://backend.example")
        let loadedSecond = try await store.load(origin: "http://localhost:3000")
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(loadedSecond, second)

        try await store.clear(origin: "https://backend.example")
        let cleared = try await store.load(origin: "https://backend.example")
        let kept = try await store.load(origin: "http://localhost:3000")
        XCTAssertNil(cleared)
        XCTAssertEqual(kept, second, "Clearing one server leaves the other alone")
        let origins = await store.origins()
        XCTAssertEqual(origins, ["http://localhost:3000"])
    }

    func testTheKeychainStoreKeepsOneItemPerOriginUnderItsService() async throws {
        let items = FakeKeychain()
        let store = KeychainCredentialStore(service: KeychainCredentialStore.service, items: items)
        XCTAssertEqual(KeychainCredentialStore.service, "com.waititout.backend")

        try await store.save(first, origin: "https://backend.example")
        try await store.save(second, origin: "http://localhost:3000")
        XCTAssertEqual(try items.accounts(service: "com.waititout.backend"), ["http://localhost:3000", "https://backend.example"], "The account is the origin, so two servers never share a credential")
        let loaded = try await store.load(origin: "https://backend.example")
        XCTAssertEqual(loaded, first, "The revision counters are kept with the token")
        let other = try await store.load(origin: "http://localhost:3000")
        XCTAssertEqual(other, second)
        let unknown = try await store.load(origin: "https://elsewhere.example")
        XCTAssertNil(unknown)

        var updated = first
        updated.revision = 5
        updated.sentDigest = "def"
        try await store.save(updated, origin: "https://backend.example")
        let reloaded = try await store.load(origin: "https://backend.example")
        XCTAssertEqual(reloaded, updated, "Saving again replaces the item")
        XCTAssertEqual(try items.accounts(service: "com.waititout.backend").count, 2)

        try await store.clear(origin: "https://backend.example")
        let cleared = try await store.load(origin: "https://backend.example")
        XCTAssertNil(cleared)
        XCTAssertEqual(try items.accounts(service: "com.waititout.backend"), ["http://localhost:3000"])
        try await store.clear(origin: "https://backend.example")
    }

    func testAnUnreadableItemCountsAsNoCredential() async throws {
        let items = FakeKeychain()
        try items.write(Data("not a credential".utf8), service: "com.waititout.backend", account: "https://backend.example")
        let store = KeychainCredentialStore(service: "com.waititout.backend", items: items)
        let loaded = try await store.load(origin: "https://backend.example")
        XCTAssertNil(loaded, "The device simply registers again")
        let origins = try await store.origins()
        XCTAssertEqual(origins, [], "And no server is named for an item that is not a credential")
    }

    func testTheKeychainStoreNamesEveryOriginThatStillHasACredential() async throws {
        let items = FakeKeychain()
        let store = KeychainCredentialStore(service: "com.waititout.backend", items: items)
        let none = try await store.origins()
        XCTAssertEqual(none, [])

        try await store.save(second, origin: "https://old.example")
        try await store.save(first, origin: "https://backend.example")
        try await store.save(second, origin: "http://localhost:3000")
        try items.write(Data("{}".utf8), service: "com.waititout.backend", account: "https://broken.example")
        try items.write(Data("other".utf8), service: "com.example.other", account: "https://elsewhere.example")
        var origins = try await store.origins()
        XCTAssertEqual(origins, ["http://localhost:3000", "https://backend.example", "https://old.example"], "Sorted, only this service, only items that read as a credential")

        // A credential leaves the list only when it is cleared, which the session does only
        // after the server confirmed the removal: this is how a server left behind is remembered
        // across restarts.
        try await store.clear(origin: "https://old.example")
        origins = try await store.origins()
        XCTAssertEqual(origins, ["http://localhost:3000", "https://backend.example"])

        items.failure = CredentialStoreError(status: errSecInteractionNotAllowed)
        do {
            _ = try await store.origins()
            XCTFail("A Keychain that cannot be read is not the same as no credentials")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, CredentialStoreError(status: errSecInteractionNotAllowed))
        }
    }

    func testAKeychainFailureIsReported() async throws {
        let items = FakeKeychain()
        items.failure = CredentialStoreError(status: errSecInteractionNotAllowed)
        let store = KeychainCredentialStore(service: "com.waititout.backend", items: items)
        do {
            _ = try await store.load(origin: "https://backend.example")
            XCTFail("A Keychain that cannot be read is not the same as no credential")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, CredentialStoreError(status: errSecInteractionNotAllowed))
        }
        do {
            try await store.save(first, origin: "https://backend.example")
            XCTFail("Expected the save to fail")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, CredentialStoreError(status: errSecInteractionNotAllowed))
        }
    }

    func testACredentialFromAnEarlierBuildStillDecodes() throws {
        let stored = Data(#"{"deviceID":"0a0a0a0a-0000-4000-8000-000000000001","token":"0a0a0a0a-0000-4000-8000-000000000001.secret"}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredCredential.self, from: stored)
        XCTAssertEqual(decoded.revision, 0)
        XCTAssertNil(decoded.sentDigest)
        XCTAssertEqual(decoded.serverRevision, 0)

        let roundTrip = try JSONDecoder().decode(StoredCredential.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(roundTrip, first)
        XCTAssertThrowsError(try JSONDecoder().decode(StoredCredential.self, from: Data(#"{"deviceID":"x"}"#.utf8)), "Without a token there is no credential")
    }

    /// The real Keychain, when the test host may use it. A simulator test bundle without an
    /// application host is sometimes refused; that is reported as a skip, never as a pass.
    func testTheSystemKeychainStoresReplacesAndDeletes() async throws {
        let service = "com.waititout.backend.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service, items: SystemKeychain())
        do {
            try await store.save(first, origin: "https://backend.example")
        } catch let error as CredentialStoreError {
            throw XCTSkip("The system Keychain is not available to this test host (status \(error.status)).")
        }
        let loaded = try await store.load(origin: "https://backend.example")
        XCTAssertEqual(loaded, first)
        try await store.save(second, origin: "https://backend.example")
        let replaced = try await store.load(origin: "https://backend.example")
        XCTAssertEqual(replaced, second)
        let other = try await store.load(origin: "http://localhost:3000")
        XCTAssertNil(other)
        // The real Keychain lists the accounts of this service, which is how a server left
        // behind by an address change is found again after a restart.
        try await store.save(first, origin: "http://localhost:3000")
        let origins = try await store.origins()
        XCTAssertEqual(origins, ["http://localhost:3000", "https://backend.example"])
        try await store.clear(origin: "http://localhost:3000")
        try await store.clear(origin: "https://backend.example")
        let cleared = try await store.load(origin: "https://backend.example")
        XCTAssertNil(cleared)
        let none = try await store.origins()
        XCTAssertEqual(none, [])
        try await store.clear(origin: "https://backend.example")
    }
}

/// The four Keychain operations over a dictionary.
private final class FakeKeychain: KeychainItemAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Data]] = [:]
    var failure: CredentialStoreError?

    func accounts(service: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return (items[service] ?? [:]).keys.sorted()
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return items[service]?[account]
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        items[service, default: [:]][account] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        items[service]?[account] = nil
    }
}
