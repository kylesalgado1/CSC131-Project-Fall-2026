import XCTest
@testable import WaitItOutUX

/// Stage S3: what the host reads at launch (`BackendLaunchOptions`) and how it reads a
/// notification response (`TripNotificationPayload.response`). Both are pure so the host's
/// decisions are tested here; the host itself only forwards.
final class BackendLaunchOptionsTests: XCTestCase {
    private let plist: [String: Any] = ["WaitItOutBackendURL": "http://localhost:3000"]

    private func options(_ environment: [String: String], info: [String: Any]? = nil) -> BackendLaunchOptions {
        BackendLaunchOptions(environment: environment, infoDictionary: info ?? plist)
    }

    // MARK: Composition

    func testTheNamesTheHostAndTheUITestsRepeat() {
        XCTAssertEqual(BackendLaunchOptions.dataModeEnvironmentKey, "WAIT_IT_OUT_DATA_MODE")
        XCTAssertEqual(BackendLaunchOptions.demoDataModeValue, "demo")
        XCTAssertEqual(BackendLaunchOptions.backendURLEnvironmentKey, "WAIT_IT_OUT_BACKEND_URL")
        XCTAssertEqual(BackendLaunchOptions.backendURLInfoKey, "WaitItOutBackendURL")
    }

    func testTheLiveBackendIsComposedUnlessTheEnvironmentAsksForTheDemo() {
        XCTAssertTrue(options([:]).composesLiveBackend, "No value: the normal flow is live")
        XCTAssertTrue(options(["WAIT_IT_OUT_DATA_MODE": "live"]).composesLiveBackend)
        XCTAssertTrue(options(["WAIT_IT_OUT_DATA_MODE": ""]).composesLiveBackend)
        XCTAssertTrue(options(["WAIT_IT_OUT_DATA_MODE": "demonstration"]).composesLiveBackend, "Only the exact word asks for the demo")

        XCTAssertFalse(options(["WAIT_IT_OUT_DATA_MODE": "demo"]).composesLiveBackend)
        XCTAssertFalse(options(["WAIT_IT_OUT_DATA_MODE": " Demo\n"]).composesLiveBackend, "Case and surrounding space do not matter")
    }

    func testTheStandaloneDemoHasNoServerAddress() {
        let demo = options(["WAIT_IT_OUT_DATA_MODE": "demo", "WAIT_IT_OUT_BACKEND_URL": "https://example.org"])
        XCTAssertFalse(demo.composesLiveBackend)
        XCTAssertNil(demo.defaultBaseURL, "The demo composition never holds an address")
        XCTAssertNil(BackendLaunchOptions(composesLiveBackend: false, defaultBaseURL: URL(string: "https://example.org")).defaultBaseURL)
    }

    // MARK: Server address

    func testTheInfoPlistAddressIsTheDefault() {
        XCTAssertEqual(options([:]).defaultBaseURL?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(options([:], info: ["WaitItOutBackendURL": " HTTPS://Example.org/ "]).defaultBaseURL?.absoluteString, "https://example.org")
    }

    func testTheEnvironmentAddressReplacesTheInfoPlistAddress() {
        let live = options(["WAIT_IT_OUT_BACKEND_URL": "http://localhost:3100"])
        XCTAssertEqual(live.defaultBaseURL?.absoluteString, "http://localhost:3100")
        XCTAssertEqual(options(["WAIT_IT_OUT_BACKEND_URL": "https://api.example.org:8443/"]).defaultBaseURL?.absoluteString, "https://api.example.org:8443")
    }

    func testAnEmptyEnvironmentAddressLeavesTheInfoPlistAddress() {
        XCTAssertEqual(options(["WAIT_IT_OUT_BACKEND_URL": ""]).defaultBaseURL?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(options(["WAIT_IT_OUT_BACKEND_URL": "  \n"]).defaultBaseURL?.absoluteString, "http://localhost:3000")
    }

    func testAnUnusableEnvironmentAddressNeverFallsBackToAnotherServer() {
        XCTAssertNil(options(["WAIT_IT_OUT_BACKEND_URL": "http://example.org"]).defaultBaseURL, "Cleartext to a public host is refused")
        XCTAssertNil(options(["WAIT_IT_OUT_BACKEND_URL": "not an address"]).defaultBaseURL)
        XCTAssertNil(options(["WAIT_IT_OUT_BACKEND_URL": "https://example.org/api"]).defaultBaseURL, "A path is refused")
        XCTAssertTrue(options(["WAIT_IT_OUT_BACKEND_URL": "not an address"]).composesLiveBackend, "Still live: the app says no server is configured")
    }

    func testAMissingOrUnusableInfoPlistAddressMeansNotConfigured() {
        XCTAssertNil(BackendLaunchOptions(environment: [:], infoDictionary: nil).defaultBaseURL)
        XCTAssertNil(options([:], info: [:]).defaultBaseURL)
        XCTAssertNil(options([:], info: ["WaitItOutBackendURL": ""]).defaultBaseURL)
        XCTAssertNil(options([:], info: ["WaitItOutBackendURL": 3000]).defaultBaseURL, "Not text")
        XCTAssertNil(options([:], info: ["WaitItOutBackendURL": "ftp://example.org"]).defaultBaseURL)
    }

    func testTheAddressFeedsTheBackendConfiguration() {
        let live = options(["WAIT_IT_OUT_BACKEND_URL": "http://127.0.0.1:3100"])
        let configuration = BackendConfiguration(defaultBaseURL: live.defaultBaseURL)
        XCTAssertEqual(configuration.baseURL?.absoluteString, "http://127.0.0.1:3100")
        XCTAssertNil(configuration.overrideBaseURL, "Settings has not named another server")
    }

    // MARK: Notification responses

    private let openIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
    private let dismissIdentifier = "com.apple.UNNotificationDismissActionIdentifier"
    private let tripID = "0B6F4A52-3C1D-4E8A-9F27-5D1E2C3B4A59@2026-11-20"

    private func response(_ userInfo: [AnyHashable: Any], _ actionIdentifier: String) -> TripNotificationResponse? {
        TripNotificationPayload.response(userInfo: userInfo, actionIdentifier: actionIdentifier, openActionIdentifier: openIdentifier)
    }

    func testTappingATripNotificationOpensItsTrip() throws {
        let userInfo: [AnyHashable: Any] = ["tripId": tripID, "kind": "heads_up", "arriveBy": "2026-11-20T16:15:00.000Z"]
        let opened = try XCTUnwrap(response(userInfo, openIdentifier))
        XCTAssertEqual(opened.tripID, tripID)
        XCTAssertEqual(opened.action, .open)
        XCTAssertEqual(opened.arriveBy, BackendDate.parse("2026-11-20T16:15:00.000Z"))
    }

    func testTheLeftActionCarriesTheArrivalTimeOfItsNotification() throws {
        let userInfo: [AnyHashable: Any] = ["tripId": tripID, "arriveBy": "2026-11-20T16:15:00Z"]
        let left = try XCTUnwrap(response(userInfo, "WAIT_IT_OUT_LEFT"))
        XCTAssertEqual(left, TripNotificationResponse(tripID: tripID, action: .left, arriveBy: BackendDate.parse("2026-11-20T16:15:00Z")))
    }

    func testAnUnreadableArrivalTimeStillNamesTheTrip() throws {
        let left = try XCTUnwrap(response(["tripId": tripID, "arriveBy": "soon"], "WAIT_IT_OUT_LEFT"))
        XCTAssertEqual(left.action, .left)
        XCTAssertNil(left.arriveBy, "The model then uses the trip's current arrival time")
    }

    func testADismissedOrUnknownResponseDoesNothing() {
        let userInfo: [AnyHashable: Any] = ["tripId": tripID, "arriveBy": "2026-11-20T16:15:00.000Z"]
        XCTAssertNil(response(userInfo, dismissIdentifier), "A dismissal never opens the trip or ends its monitoring")
        XCTAssertNil(response(userInfo, "SOMETHING_ELSE"))
        XCTAssertNil(response(userInfo, ""))
    }

    func testANotificationWithoutATripIsIgnored() {
        XCTAssertNil(response([:], openIdentifier))
        XCTAssertNil(response(["tripId": ""], openIdentifier))
        XCTAssertNil(response(["tripId": 7], "WAIT_IT_OUT_LEFT"))
        XCTAssertNil(response(["aps": ["alert": "Hello"]], openIdentifier), "Another sender's notification")
    }
}
