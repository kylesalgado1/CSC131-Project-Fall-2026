import XCTest
@testable import WaitItOutUX

/// Stage S1: the server address (`BackendConfiguration`), its validation, and the two stored
/// backend settings (`dataMode`, `backendAddress`), which are written only when they differ
/// from their defaults so an existing settings file keeps exactly its keys.
final class BackendConfigurationTests: XCTestCase {
    private func parsed(_ text: String) -> String? {
        switch BackendConfiguration.parse(text) {
        case .success(let url):
            return url?.absoluteString ?? "default"
        case .failure:
            return nil
        }
    }

    private func issue(_ text: String) -> BackendAddressIssue? {
        switch BackendConfiguration.parse(text) {
        case .success:
            return nil
        case .failure(let issue):
            return issue
        }
    }

    // MARK: Parsing

    func testEmptyTextMeansTheDefaultAddress() {
        XCTAssertEqual(parsed(""), "default")
        XCTAssertEqual(parsed("   \n"), "default")
        XCTAssertNil(issue(""))
    }

    func testHTTPSAddressesAreNormalized() {
        XCTAssertEqual(parsed("https://example.org"), "https://example.org")
        XCTAssertEqual(parsed("  https://example.org/  "), "https://example.org", "Surrounding spaces and the trailing slash are trimmed")
        XCTAssertEqual(parsed("https://example.org///"), "https://example.org")
        XCTAssertEqual(parsed("HTTPS://Example.ORG"), "https://example.org", "Scheme and host are lowercased")
        XCTAssertEqual(parsed("https://api.example.org:8443/"), "https://api.example.org:8443", "A port is kept")
        XCTAssertEqual(parsed("https://wait-it-out.onrender.com"), "https://wait-it-out.onrender.com")
    }

    func testPlainHTTPIsAcceptedOnlyForLocalHosts() {
        XCTAssertEqual(parsed("http://localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(parsed("http://LOCALHOST:3000/"), "http://localhost:3000")
        XCTAssertEqual(parsed("http://my-mac.local:3000"), "http://my-mac.local:3000")
        XCTAssertEqual(parsed("http://192.168.1.20:3000"), "http://192.168.1.20:3000")
        XCTAssertEqual(parsed("http://127.0.0.1"), "http://127.0.0.1")
        XCTAssertEqual(parsed("http://[::1]:3000"), "http://[::1]:3000", "An IPv6 literal keeps its brackets")

        XCTAssertEqual(issue("http://example.org"), .needsHTTPS)
        XCTAssertEqual(issue("http://example.org:3000"), .needsHTTPS)
        XCTAssertEqual(issue("http://999.1.1.1"), .needsHTTPS, "Not an IP literal")
        XCTAssertEqual(issue("http://1.2.3"), .needsHTTPS, "Three parts are a name, not an address")
        XCTAssertEqual(issue("http://local"), .needsHTTPS)
        XCTAssertEqual(issue("http://notlocal.example"), .needsHTTPS)
        XCTAssertEqual(BackendAddressIssue.needsHTTPS.message, "Use https for this address.")
        // The same hosts are fine over https.
        XCTAssertEqual(parsed("https://192.168.1.20"), "https://192.168.1.20")
    }

    func testUnusableAddressesSayWhy() {
        XCTAssertEqual(issue("example.org"), .unsupportedScheme, "No scheme")
        XCTAssertEqual(issue("ftp://example.org"), .unsupportedScheme)
        XCTAssertEqual(issue("localhost:3000"), .unsupportedScheme)
        XCTAssertEqual(issue("https://"), .missingHost)
        XCTAssertEqual(issue("https:example.org"), .missingHost)
        XCTAssertEqual(issue("https://example.org/api"), .extraParts)
        XCTAssertEqual(issue("https://example.org/verdict/"), .extraParts)
        XCTAssertEqual(issue("https://example.org?debug=1"), .extraParts)
        XCTAssertEqual(issue("https://example.org#top"), .extraParts)
        XCTAssertEqual(issue("https://user:secret@example.org"), .extraParts, "Sign-in details never belong in the address")
        XCTAssertEqual(issue("https://exa mple.org"), .notAnAddress)
        let all: [BackendAddressIssue] = [.notAnAddress, .unsupportedScheme, .missingHost, .extraParts, .needsHTTPS]
        for one in all {
            XCTAssertFalse(one.message.isEmpty)
            XCTAssertTrue(one.message.hasSuffix("."), one.message)
        }
        XCTAssertEqual(Set(all.map(\.message)).count, all.count, "Every issue has its own sentence")
    }

    func testCleartextHostRule() {
        for host in ["localhost", "printer.local", "10.0.0.5", "255.255.255.255", "::1", "[fe80::1]"] {
            XCTAssertTrue(BackendConfiguration.allowsCleartext(host: host), host)
        }
        for host in ["example.org", "256.0.0.1", "1.2.3.4.5", "1..2.3", "localhost.example.org", "local", "+1.2.3.4"] {
            XCTAssertFalse(BackendConfiguration.allowsCleartext(host: host), host)
        }
    }

    // MARK: Configuration

    func testTheOverrideWinsOverTheDefault() throws {
        let fallback = try XCTUnwrap(URL(string: "http://localhost:3000"))
        let typed = try XCTUnwrap(URL(string: "https://example.org"))
        let configuration = BackendConfiguration(defaultBaseURL: fallback)
        XCTAssertEqual(configuration.baseURL, fallback)
        XCTAssertEqual(configuration.defaultBaseURL, fallback)
        XCTAssertNil(configuration.overrideBaseURL)

        configuration.setOverride(typed)
        XCTAssertEqual(configuration.baseURL, typed)
        XCTAssertEqual(configuration.overrideBaseURL, typed)

        configuration.setOverride(nil)
        XCTAssertEqual(configuration.baseURL, fallback, "Clearing the override returns to the default")

        let unconfigured = BackendConfiguration(defaultBaseURL: nil)
        XCTAssertNil(unconfigured.baseURL, "No default and no override: not configured")
        unconfigured.setOverride(typed)
        XCTAssertEqual(unconfigured.baseURL, typed)
    }

    // MARK: Stored settings

    private func keys(of preferences: UserPreferences) throws -> Set<String> {
        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    private func decoded(_ json: String) throws -> UserPreferences {
        try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
    }

    func testDefaultSettingsKeepExactlyTheirOldKeys() throws {
        let defaults = UserPreferences()
        XCTAssertEqual(defaults.dataMode, .live)
        XCTAssertNil(defaults.backendAddress)
        XCTAssertEqual(
            try keys(of: defaults),
            ["appearance", "testCommuteDuration", "testCommuteScenario", "places", "leaveHomeRemindersEnabled", "simulatesReminderFailure"],
            "Neither backend field is written at its default"
        )
        XCTAssertEqual(DataMode.allCases, [.live, .demo])
    }

    func testNonDefaultBackendSettingsRoundTrip() throws {
        let demo = UserPreferences(dataMode: .demo)
        XCTAssertTrue(try keys(of: demo).contains("dataMode"))
        XCTAssertFalse(try keys(of: demo).contains("backendAddress"))
        XCTAssertEqual(try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(demo)), demo)

        let addressed = UserPreferences(backendAddress: "https://example.org")
        XCTAssertTrue(try keys(of: addressed).contains("backendAddress"))
        XCTAssertFalse(try keys(of: addressed).contains("dataMode"), "Live is the default and is not written")
        XCTAssertEqual(try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(addressed)), addressed)

        let both = UserPreferences(appearance: .dark, leaveHomeRemindersEnabled: true, dataMode: .demo, backendAddress: "http://localhost:3000")
        let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(both))
        XCTAssertEqual(restored, both)
        XCTAssertEqual(restored.dataMode, .demo)
        XCTAssertEqual(restored.backendAddress, "http://localhost:3000")
    }

    func testUnreadableBackendSettingsFallBackPerField() throws {
        XCTAssertEqual(try decoded("{}").dataMode, .live)
        XCTAssertNil(try decoded("{}").backendAddress)
        let odd = try decoded(#"{"dataMode":"staging","backendAddress":42,"appearance":"dark"}"#)
        XCTAssertEqual(odd.dataMode, .live, "An unknown mode falls back to live")
        XCTAssertNil(odd.backendAddress, "An unreadable address falls back to none")
        XCTAssertEqual(odd.appearance, .dark, "The other fields still load")
        let demo = try decoded(#"{"dataMode":"demo","backendAddress":"https://example.org"}"#)
        XCTAssertEqual(demo.dataMode, .demo)
        XCTAssertEqual(demo.backendAddress, "https://example.org")
    }
}
