import XCTest
@testable import WaitItOutUX

/// Stage S1: the wire layer. Dates are read with and without fractional seconds and written
/// the way the backend writes them; bodies shaped exactly like the real backend's decode;
/// request URLs, headers, and every transport error map to something defined.
final class BackendWireTests: XCTestCase {
    private let clock = FixedWallClock(TestFixtures.fridayNoon)

    // MARK: Dates

    func testDatesParseWithAndWithoutFractionalSeconds() throws {
        // 2026-11-20T15:30:00Z.
        let expected = TestFixtures.date(2026, 11, 20, 15, 30, in: TestFixtures.utc)
        XCTAssertEqual(BackendDate.parse("2026-11-20T15:30:00.000Z"), expected, "As Date.toISOString writes it")
        XCTAssertEqual(BackendDate.parse("2026-11-20T15:30:00Z"), expected, "Without fractional seconds")
        XCTAssertEqual(BackendDate.parse("2026-11-20T15:30:00.250Z"), expected.addingTimeInterval(0.25))
        XCTAssertEqual(BackendDate.parse("2026-11-20T07:30:00-08:00"), expected, "A numeric zone designator names the same instant")
        XCTAssertEqual(BackendDate.parse("2026-11-20T07:30:00.000-08:00"), expected)
        XCTAssertNil(BackendDate.parse("yesterday"))
        XCTAssertNil(BackendDate.parse(""))
        XCTAssertNil(BackendDate.parse("2026-11-20"))
    }

    func testDatesAreWrittenWithMillisecondsAndZ() {
        let instant = TestFixtures.date(2026, 11, 20, 15, 30, in: TestFixtures.utc)
        XCTAssertEqual(BackendDate.string(from: instant), "2026-11-20T15:30:00.000Z")
        XCTAssertEqual(BackendDate.string(from: instant.addingTimeInterval(0.25)), "2026-11-20T15:30:00.250Z")
        XCTAssertEqual(BackendDate.string(from: instant), TestBackend.iso(instant), "Agrees with an independent formatter")
        // Pacific wall times become absolute UTC instants: 8:15 AM PDT is 15:15Z, 8:15 AM PST is 16:15Z.
        XCTAssertEqual(BackendDate.string(from: TestFixtures.date(2026, 10, 26, 8, 15)), "2026-10-26T15:15:00.000Z")
        XCTAssertEqual(BackendDate.string(from: TestFixtures.date(2026, 11, 2, 8, 15)), "2026-11-02T16:15:00.000Z")
        XCTAssertEqual(BackendDate.parse(BackendDate.string(from: instant)), instant, "Round trip")
    }

    // MARK: Bodies shaped like the backend's

    /// A POST /verdict answer in the backend's own shape: slots, the verdict with every field
    /// the backend writes (`deadline.latestDeparture` is a departure object, and the reason is
    /// relative to when it was written), and the additive source. Bodies captured verbatim
    /// from the real backend are in `RealBackendShapesTests`.
    private let verdictBody = #"""
    {
      "slots": [
        {"departAt":"2026-10-26T13:00:00.000Z","arriveAt":"2026-10-26T13:42:00.000Z","driveMinutes":42,"confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic."},
        {"departAt":"2026-10-26T14:15:00.000Z","arriveAt":"2026-10-26T15:00:00.000Z","driveMinutes":45,"confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic."}
      ],
      "verdict": {
        "action": "leave_later",
        "waitMinutes": 75,
        "reason": "Your deadline is 2 hr 15 min away, so there is no rush. Leaving in 1 hr 15 min still gets you there with 15 minutes to spare.",
        "leaveNow": {"departAt":"2026-10-26T13:00:00.000Z","arriveAt":"2026-10-26T13:42:00.000Z","driveMinutes":42},
        "recommended": {"departAt":"2026-10-26T14:15:00.000Z","arriveAt":"2026-10-26T15:00:00.000Z","driveMinutes":45},
        "minutesSaved": -3,
        "arrivalDelayMinutes": 78,
        "deadline": {"arriveBy":"2026-10-26T15:15:00.000Z","marginMinutes":15,"latestDeparture":{"departAt":"2026-10-26T14:30:00.000Z","arriveAt":"2026-10-26T15:15:00.000Z","driveMinutes":45}},
        "confidence": "High",
        "confidenceReason": "Based on plenty of historical data and live traffic.",
        "notes": ["Light rain is expected, so drive times include extra delay."],
        "generatedAt": "2026-10-26T13:00:00.000Z"
      },
      "source": {"baseline":"tomtom","fallback":false,"live":true}
    }
    """#

    func testARealVerdictBodyDecodes() throws {
        let response = try BackendJSON.makeDecoder().decode(WireVerdictResponse.self, from: Data(verdictBody.utf8))
        let verdict = response.verdict
        XCTAssertEqual(verdict.action, "leave_later")
        XCTAssertEqual(verdict.confidence, "High")
        XCTAssertEqual(verdict.recommended?.departAt, TestFixtures.date(2026, 10, 26, 7, 15))
        XCTAssertEqual(verdict.recommended?.arriveAt, TestFixtures.date(2026, 10, 26, 8, 0))
        XCTAssertEqual(verdict.recommended?.driveMinutes, 45)
        XCTAssertEqual(verdict.leaveNow?.departAt, TestFixtures.date(2026, 10, 26, 6, 0))
        XCTAssertEqual(verdict.deadline?.marginMinutes, 15, "Read beside latestDeparture, which is an object the app does not use")
        XCTAssertEqual(verdict.reason, "Your deadline is 2 hr 15 min away, so there is no rush. Leaving in 1 hr 15 min still gets you there with 15 minutes to spare.")
        XCTAssertNil(verdict.lateByMinutes)
        XCTAssertEqual(verdict.notes, ["Light rain is expected, so drive times include extra delay."])
        XCTAssertEqual(verdict.generatedAt, TestFixtures.date(2026, 10, 26, 6, 0))
        XCTAssertEqual(response.source?.baseline, "tomtom")
        XCTAssertEqual(response.source?.fallback, false)
        XCTAssertEqual(response.source?.live, true)
    }

    func testAnOlderServersBodyWithoutSourceAndWithoutFractionsDecodes() throws {
        let body = #"{"slots":[],"verdict":{"action":"leave_now","waitMinutes":0,"reason":"Leave now, you may be late by about 40 minutes.","leaveNow":{"departAt":"2026-10-26T15:00:00Z","arriveAt":"2026-10-26T15:55:00Z","driveMinutes":55},"recommended":{"departAt":"2026-10-26T15:00:00Z","arriveAt":"2026-10-26T15:55:00Z","driveMinutes":55},"minutesSaved":0,"arrivalDelayMinutes":0,"lateByMinutes":40,"confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"generatedAt":"2026-10-26T15:00:00Z"}}"#
        let response = try BackendJSON.makeDecoder().decode(WireVerdictResponse.self, from: Data(body.utf8))
        XCTAssertNil(response.source, "The source field is additive")
        XCTAssertEqual(response.verdict.lateByMinutes, 40)
        XCTAssertNil(response.verdict.deadline)
        XCTAssertEqual(response.verdict.leaveNow?.arriveAt, TestFixtures.date(2026, 10, 26, 8, 55))
    }

    func testABodyWithAnUnreadableDateDoesNotDecode() {
        let body = #"{"verdict":{"action":"leave_now","leaveNow":{"departAt":"soon","arriveAt":"2026-10-26T15:55:00Z"}}}"#
        XCTAssertThrowsError(try BackendJSON.makeDecoder().decode(WireVerdictResponse.self, from: Data(body.utf8)))
    }

    func testRequestsEncodeDatesAsISOStrings() throws {
        let request = WireVerdictRequest(
            origin: WirePoint(GeoCoordinate(latitude: 38.4088, longitude: -121.3716)),
            destination: WirePoint(GeoCoordinate(latitude: 38.561, longitude: -121.4237)),
            arriveBy: TestFixtures.date(2026, 10, 26, 8, 15)
        )
        let data = try BackendJSON.makeEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["origin", "destination", "arriveBy"])
        XCTAssertEqual(object["arriveBy"] as? String, "2026-10-26T15:15:00.000Z")
        XCTAssertEqual((object["origin"] as? [String: Any])?.keys.sorted(), ["lat", "lng"])
        XCTAssertEqual(WirePoint(GeoCoordinate(latitude: 1.5, longitude: -2.5)).coordinate, GeoCoordinate(latitude: 1.5, longitude: -2.5))
    }

    func testErrorBodiesDecode() throws {
        let body = try BackendJSON.makeDecoder().decode(WireErrorBody.self, from: Data(TestBackend.errorBody("no_coverage", "No traffic data for this route.").utf8))
        XCTAssertEqual(body.error, "no_coverage")
        XCTAssertEqual(body.message, "No traffic data for this route.")
    }

    // MARK: Request helper

    func testURLsAreBuiltFromTheBaseAndEncodedSegments() throws {
        let base = try XCTUnwrap(URL(string: "https://backend.example"))
        XCTAssertEqual(BackendClient.url(base: base, path: ["verdict"])?.absoluteString, "https://backend.example/verdict")
        let withSlash = try XCTUnwrap(URL(string: "http://localhost:3000/"))
        XCTAssertEqual(BackendClient.url(base: withSlash, path: ["route"])?.absoluteString, "http://localhost:3000/route")
        XCTAssertEqual(
            BackendClient.url(base: base, path: ["trips", "0F3A@2026-11-02", "departed"])?.absoluteString,
            "https://backend.example/trips/0F3A%402026-11-02/departed",
            "An id is one percent-encoded segment"
        )
        XCTAssertEqual(
            BackendClient.url(base: base, path: ["trips", "a/b c"])?.absoluteString,
            "https://backend.example/trips/a%2Fb%20c",
            "A slash inside an id can never add a path level"
        )
        XCTAssertNil(BackendClient.url(base: nil, path: ["verdict"]), "No address configured")
        XCTAssertNil(BackendClient.url(base: base, path: ["trips", ""]), "An empty segment is refused")
    }

    func testTheRequestHelperSetsMethodHeadersBodyAndTimeout() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: "{}"))
        let client = TestBackend.client(transport: transport, clock: clock)
        let reply = try await client.send(method: "PUT", path: ["trips"], body: Data("{}".utf8), bearerToken: "device.secret")
        XCTAssertTrue(reply.isSuccess)
        XCTAssertEqual(reply.status, 200)
        XCTAssertNil(reply.errorCode)

        let withoutBody = try await client.send(method: "GET", path: ["trips"])
        XCTAssertTrue(withoutBody.isSuccess)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, "PUT")
        XCTAssertEqual(requests[0].url.absoluteString, "https://backend.example/trips")
        XCTAssertEqual(requests[0].headers["Accept"], "application/json")
        XCTAssertEqual(requests[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer device.secret")
        XCTAssertEqual(requests[0].bodyText, "{}")
        XCTAssertEqual(requests[0].timeout, 25)
        XCTAssertEqual(requests[1].method, "GET")
        XCTAssertNil(requests[1].headers["Content-Type"], "No body, no content type")
        XCTAssertNil(requests[1].headers["Authorization"], "No credential unless one is given")
        XCTAssertNil(requests[1].body)
    }

    func testErrorAnswersCarryTheBodysCodeAndSentence() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 422, body: TestBackend.errorBody("no_coverage", "  No traffic data for this route.  ")))
        let client = TestBackend.client(transport: transport, clock: clock)
        let reply = try await client.send(method: "POST", path: ["verdict"], body: Data("{}".utf8))
        XCTAssertFalse(reply.isSuccess)
        XCTAssertEqual(reply.status, 422)
        XCTAssertEqual(reply.errorCode, "no_coverage")
        XCTAssertEqual(reply.errorMessage, "No traffic data for this route.", "Trimmed")

        await transport.setReply(.http(status: 502, body: "<html>Bad Gateway</html>"))
        let gateway = try await client.send(method: "POST", path: ["verdict"], body: Data("{}".utf8))
        XCTAssertEqual(gateway.status, 502)
        XCTAssertNil(gateway.errorCode, "A gateway page is not an error body")
        XCTAssertNil(gateway.errorMessage)
        XCTAssertEqual(BackendClient.sentence(String(repeating: "x", count: 900))?.count, 300, "A runaway message is bounded")
        XCTAssertNil(BackendClient.sentence("   "))
    }

    func testFailuresAreDiscriminatedByTheBodysCodeFirst() {
        let client = TestBackend.client(transport: ScriptedHTTPTransport(.otherError), clock: clock)
        func kind(_ status: Int, _ code: String?) -> CommuteProviderFailure.Kind {
            client.failure(for: BackendReply(status: status, data: Data(), errorCode: code, errorMessage: nil)).kind
        }
        XCTAssertEqual(kind(502, "routing_unavailable"), .routingUnavailable)
        XCTAssertEqual(kind(503, "routing_unavailable"), .routingUnavailable, "The code decides, not the status")
        XCTAssertEqual(kind(502, nil), .server(status: 502), "A gateway's 502 without a JSON body")
        XCTAssertEqual(kind(503, nil), .server(status: 503))
        XCTAssertEqual(kind(401, "unauthorized"), .unauthorized)
        XCTAssertEqual(kind(401, nil), .unauthorized)
        XCTAssertEqual(kind(500, "internal"), .server(status: 500))
        XCTAssertEqual(kind(400, "bad_request"), .server(status: 400))
        XCTAssertEqual(kind(404, nil), .server(status: 404))
    }

    func testTemporarilyUnavailableIsAlwaysATransientServerFailure() async {
        let clock = FixedWallClock(TestFixtures.fridayNoon)
        let transport = ScriptedHTTPTransport(.http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "The server cannot reach its database right now. Try again shortly.")))
        let client = TestBackend.client(transport: transport, clock: clock)
        do {
            _ = try await client.verdict(origin: CommutePlaces.sample.home.coordinate, destination: CommutePlaces.sample.campus.coordinate, arriveBy: TestFixtures.fridayNoon.addingTimeInterval(3_600))
            XCTFail("Expected a failure")
        } catch let failure as CommuteProviderFailure {
            XCTAssertEqual(failure.kind, .server(status: 503))
            XCTAssertTrue(failure.kind.isTransient, "Retried on the minute ticks with the usual backoff")
        } catch {
            XCTFail("Expected a provider failure, got \(error)")
        }
        // Whatever status carries the code, it is never read as a lasting failure.
        let odd = BackendReply(status: 409, data: Data(), errorCode: "temporarily_unavailable", errorMessage: nil)
        XCTAssertEqual(client.failure(for: odd).kind, .server(status: 503))
        XCTAssertTrue(client.failure(for: odd).kind.isTransient)
    }

    func testEveryTransportErrorMapsToADefinedKind() {
        let offline: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .resourceUnavailable, .unknown
        ]
        for code in offline {
            XCTAssertEqual(BackendClient.kind(for: code), .offline, "\(code.rawValue)")
        }
        let unreadable: [URLError.Code] = [
            .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .zeroByteResource,
            .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL, .httpTooManyRedirects
        ]
        for code in unreadable {
            XCTAssertEqual(BackendClient.kind(for: code), .invalidResponse, "\(code.rawValue)")
        }
        XCTAssertEqual(BackendClient.kind(for: .timedOut), .timedOut)
    }

    func testTransportFailuresBecomeProviderFailures() async {
        func failure(_ reply: ScriptedReply) async -> CommuteProviderFailure.Kind? {
            let client = TestBackend.client(transport: ScriptedHTTPTransport(reply), clock: clock)
            do {
                _ = try await client.send(method: "GET", path: ["health"])
                return nil
            } catch let failure as CommuteProviderFailure {
                return failure.kind
            } catch {
                return nil
            }
        }
        let timedOut = await failure(.urlError(.timedOut))
        XCTAssertEqual(timedOut, .timedOut)
        let offline = await failure(.urlError(.notConnectedToInternet))
        XCTAssertEqual(offline, .offline)
        let refused = await failure(.urlError(.cannotConnectToHost))
        XCTAssertEqual(refused, .offline)
        let insecure = await failure(.urlError(.appTransportSecurityRequiresSecureConnection))
        XCTAssertEqual(insecure, .invalidResponse)
        let other = await failure(.otherError)
        XCTAssertEqual(other, .offline, "A transport that fails without a URL error did not reach the backend")
    }

    func testTheSessionIsEphemeralWithShortTimeouts() {
        let configuration = URLSessionTransport.makeConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 25)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.httpCookieStorage, "No cookies")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache, "No cache")
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(URLSessionTransport.requestTimeout, BackendClient.requestTimeout)
    }
}
