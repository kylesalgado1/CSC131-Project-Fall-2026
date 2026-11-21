import XCTest
@testable import WaitItOutUX

/// Stage S1: `BackendCommuteProvider` against a scripted transport. The request carries the
/// origin, the destination, and the ideal arrival only; every verdict action maps explicitly;
/// coverage gaps, "no rush", and far-off trips are answers, not failures; every failure has
/// its kind; and a trip beyond the planning horizon costs no request at all.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT (13:00Z). The trip arrives by 8:15 AM PDT (15:15Z).
final class BackendCommuteProviderTests: XCTestCase {
    private let sixAM = TestFixtures.date(2026, 10, 26, 6, 0)
    private let sevenFifteen = TestFixtures.date(2026, 10, 26, 7, 15)
    private let eight = TestFixtures.date(2026, 10, 26, 8, 0)
    private let eightFifteen = TestFixtures.date(2026, 10, 26, 8, 15)

    private func request(arriveBy: Date? = nil) -> CommuteRequest {
        CommuteRequest(
            occurrenceID: OccurrenceID(activityID: UUID(), date: LocalDate.of(arriveBy ?? eightFifteen, in: TestFixtures.pacific)),
            origin: CommutePlaces.sample.home,
            destination: TestFixtures.demoDestination,
            arriveBy: arriveBy ?? eightFifteen
        )
    }

    private func provider(
        _ transport: ScriptedHTTPTransport,
        clock: any WallClock,
        baseURL: URL? = TestBackend.baseURL,
        monitoredTrips: (any MonitoredTripSource)? = nil,
        planningHorizon: TimeInterval = BackendCommuteProvider.defaultPlanningHorizon
    ) -> BackendCommuteProvider {
        BackendCommuteProvider(
            client: TestBackend.client(transport: transport, clock: clock, baseURL: baseURL),
            clock: clock,
            monitoredTrips: monitoredTrips,
            planningHorizon: planningHorizon,
            describe: { "<\(TestBackend.iso($0))>" }
        )
    }

    /// Asks once at the fixture clock with a transport that always gives `reply`.
    private func answer(to reply: ScriptedReply) async throws -> CommuteEstimateResponse {
        let clock = FixedWallClock(sixAM)
        return try await provider(ScriptedHTTPTransport(reply), clock: clock).estimateCommute(for: request())
    }

    /// The failure kind thrown for `reply`, or `nil` when nothing or something else was thrown.
    private func failureKind(for reply: ScriptedReply) async -> CommuteProviderFailure.Kind? {
        do {
            _ = try await answer(to: reply)
            return nil
        } catch let failure as CommuteProviderFailure {
            return failure.kind
        } catch {
            return nil
        }
    }

    private func recommendation(_ response: CommuteEstimateResponse, file: StaticString = #filePath, line: UInt = #line) throws -> DepartureRecommendation {
        guard case .recommendation(let recommendation) = response else {
            XCTFail("Expected a recommendation, got \(response)", file: file, line: line)
            throw TestStoreError()
        }
        return recommendation
    }

    private func leaveLaterBody(source: String? = #"{"baseline":"tomtom","fallback":false,"live":true}"#, confidence: String = "High") -> String {
        TestBackend.verdictBody(
            action: "leave_later",
            leaveNow: (sixAM, sixAM.addingTimeInterval(42 * 60)),
            recommended: (sevenFifteen, eight),
            marginMinutes: 15,
            confidence: confidence,
            notes: ["Light rain is expected, so drive times include extra delay."],
            generatedAt: sixAM,
            source: source
        )
    }

    // MARK: Request

    func testTheRequestCarriesOnlyOriginDestinationAndArrival() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        _ = try await provider(transport, clock: FixedWallClock(sixAM)).estimateCommute(for: request())

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/verdict")
        XCTAssertEqual(sent.url.absoluteString, "https://backend.example/verdict")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.headers["Accept"], "application/json")
        XCTAssertNil(sent.headers["Authorization"], "The verdict endpoint is unauthenticated")
        XCTAssertEqual(Set(sent.jsonObject().keys), ["origin", "destination", "arriveBy"], "No preferences: the server applies its defaults")
        XCTAssertEqual(sent.string("arriveBy"), "2026-10-26T15:15:00.000Z", "The ideal arrival as an absolute UTC instant with Z")
        XCTAssertEqual(sent.number("origin", "lat"), 38.4088)
        XCTAssertEqual(sent.number("origin", "lng"), -121.3716)
        XCTAssertEqual(sent.number("destination", "lat"), 38.561)
        XCTAssertEqual(sent.number("destination", "lng"), -121.4237)
        XCTAssertEqual((sent.jsonObject()["origin"] as? [String: Any])?.keys.sorted(), ["lat", "lng"], "No names or ids leave the device")
        XCTAssertFalse(sent.bodyText.contains("preferences"))
        XCTAssertFalse(sent.bodyText.contains("Sample"), "Place names are not sent")
    }

    // MARK: Actions

    func testLeaveLaterBecomesARecommendationWithTheBackendsOwnTimes() async throws {
        let clock = ManualWallClock(sixAM)
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: clock)
        // The answer arrives two seconds after the backend stamped it.
        clock.advance(by: 2)
        let advised = try recommendation(try await backend.estimateCommute(for: request()))

        XCTAssertEqual(advised.advice, .leaveLater)
        XCTAssertEqual(advised.recommendedDeparture, sevenFifteen, "recommended.departAt, verbatim")
        XCTAssertEqual(advised.predictedArrival, eight, "recommended.arriveAt, verbatim")
        XCTAssertEqual(advised.reason, "Your deadline is 2 hr 15 min away, so there is no rush. Leaving at 7:15 AM still gets you there with 15 minutes to spare.")
        XCTAssertEqual(advised.confidence, .high)
        XCTAssertEqual(advised.confidenceReason, "Based on plenty of historical data and live traffic.")
        XCTAssertEqual(advised.notes, ["Light rain is expected, so drive times include extra delay."])
        XCTAssertEqual(advised.margin, 15 * 60)
        XCTAssertNil(advised.lateBy)
        XCTAssertEqual(advised.generatedAt, sixAM, "The backend's stamp")
        XCTAssertEqual(advised.receivedAt, sixAM.addingTimeInterval(2), "The device clock when it arrived")
        XCTAssertEqual(advised.source, TestBackend.liveSource)
        XCTAssertFalse(advised.isStale)
        XCTAssertFalse(advised.isMonitored)
    }

    func testWaitUsesTheRecommendedSlot() async throws {
        let body = TestBackend.verdictBody(
            action: "wait",
            reason: "Wait 30 minutes: you'll save 12 minutes in traffic and you arrive at the same time.",
            leaveNow: (sixAM, sixAM.addingTimeInterval(57 * 60)),
            recommended: (sixAM.addingTimeInterval(30 * 60), sixAM.addingTimeInterval(75 * 60)),
            marginMinutes: 60,
            confidence: "Medium",
            confidenceReason: "Live traffic is unavailable, so this uses typical conditions.",
            generatedAt: sixAM
        )
        let advised = try recommendation(try await answer(to: .http(status: 200, body: body)))
        XCTAssertEqual(advised.advice, .wait)
        XCTAssertEqual(advised.recommendedDeparture, sixAM.addingTimeInterval(30 * 60))
        XCTAssertEqual(advised.predictedArrival, sixAM.addingTimeInterval(75 * 60))
        XCTAssertEqual(advised.confidence, .medium)
        XCTAssertEqual(advised.margin, 3_600)
        XCTAssertTrue(advised.notes.isEmpty)
    }

    func testLeaveNowOnTimeUsesTheLeaveNowSlot() async throws {
        // The two slots differ here so the test proves which one is read.
        let body = TestBackend.verdictBody(
            action: "leave_now",
            reason: "Traffic won't improve much in the next 3 hours.",
            leaveNow: (sixAM, sixAM.addingTimeInterval(50 * 60)),
            recommended: (sixAM.addingTimeInterval(15 * 60), sixAM.addingTimeInterval(70 * 60)),
            marginMinutes: 85,
            generatedAt: sixAM
        )
        let advised = try recommendation(try await answer(to: .http(status: 200, body: body)))
        XCTAssertEqual(advised.advice, .leaveNow)
        XCTAssertEqual(advised.recommendedDeparture, sixAM, "leaveNow.departAt")
        XCTAssertEqual(advised.predictedArrival, sixAM.addingTimeInterval(50 * 60), "leaveNow.arriveAt")
        XCTAssertNil(advised.lateBy, "On time: nothing alarming")
        XCTAssertEqual(advised.margin, 85 * 60)
    }

    func testLeaveNowLateCarriesHowLate() async throws {
        let body = TestBackend.verdictBody(
            action: "leave_now",
            reason: "Leave now, you may be late by about 40 minutes.",
            leaveNow: (sixAM, eightFifteen.addingTimeInterval(40 * 60)),
            recommended: (sixAM, eightFifteen.addingTimeInterval(40 * 60)),
            lateByMinutes: 40,
            confidence: "Low",
            confidenceReason: "An incident on your route could change this estimate.",
            generatedAt: sixAM
        )
        let advised = try recommendation(try await answer(to: .http(status: 200, body: body)))
        XCTAssertEqual(advised.advice, .leaveNow)
        XCTAssertEqual(advised.lateBy, 40 * 60)
        XCTAssertNil(advised.margin, "A late verdict has no deadline margin")
        XCTAssertEqual(advised.confidence, .low)
        XCTAssertEqual(advised.reason, "Leave now, you may be late by about 40 minutes.")
    }

    func testNoRushIsNotYetInTheBackendsOwnWordsAndIsAskedAgainInTenMinutes() async throws {
        let reason = "Your deadline is 12 hr 10 min away, too far ahead to plan a departure. There is no need to leave yet. A plan will appear once the deadline is within 12 hours, in about 10 minutes."
        let body = TestBackend.verdictBody(
            action: "no_rush",
            reason: reason,
            leaveNow: (sixAM, sixAM.addingTimeInterval(42 * 60)),
            recommended: (sixAM, sixAM.addingTimeInterval(42 * 60)),
            generatedAt: sixAM
        )
        let response = try await answer(to: .http(status: 200, body: body))
        XCTAssertEqual(
            response,
            .notYet(message: "\(reason) Checked <2026-10-26T13:00:00.000Z>.", askAgainAt: sixAM.addingTimeInterval(600)),
            "The sentence is relative to when it was written, so it carries its time"
        )
    }

    // MARK: Coverage

    func testNoCoverageIsUnavailableWithTheBackendsSentence() async throws {
        let covered = try await answer(to: .http(status: 422, body: TestBackend.errorBody("no_coverage", "We have no traffic history for this route yet.")))
        XCTAssertEqual(covered, .unavailable(message: "We have no traffic history for this route yet."))

        let bare = try await answer(to: .http(status: 422, body: ""))
        XCTAssertEqual(bare, .unavailable(message: "There is not enough traffic data for this route yet."))
        XCTAssertEqual(BackendCommuteProvider.noCoverageMessage, "There is not enough traffic data for this route yet.")

        // The code decides even under another status.
        let coded = try await answer(to: .http(status: 400, body: #"{"error":"no_coverage"}"#))
        XCTAssertEqual(coded, .unavailable(message: "There is not enough traffic data for this route yet."))

        // A 422 that names another problem is not a coverage gap.
        let other = await failureKind(for: .http(status: 422, body: TestBackend.errorBody("bad_request", "Nope.")))
        XCTAssertEqual(other, .server(status: 422))
    }

    // MARK: Failures

    func testEveryFailureHasItsKind() async {
        let routing = await failureKind(for: .http(status: 502, body: TestBackend.errorBody("routing_unavailable", "The routing service is unavailable.")))
        XCTAssertEqual(routing, .routingUnavailable)
        let gateway = await failureKind(for: .http(status: 502, body: "<html>Bad Gateway</html>"))
        XCTAssertEqual(gateway, .server(status: 502), "A gateway's 502 is not the routing service")
        let sleeping = await failureKind(for: .http(status: 503, body: ""))
        XCTAssertEqual(sleeping, .server(status: 503))
        let internalError = await failureKind(for: .http(status: 500, body: TestBackend.errorBody("internal", "Something went wrong.")))
        XCTAssertEqual(internalError, .server(status: 500))
        let badRequest = await failureKind(for: .http(status: 400, body: TestBackend.errorBody("bad_request", "arriveBy must be a date-time.")))
        XCTAssertEqual(badRequest, .server(status: 400))
        let unauthorized = await failureKind(for: .http(status: 401, body: TestBackend.errorBody("unauthorized", "This device is not registered.")))
        XCTAssertEqual(unauthorized, .unauthorized)
        let notFound = await failureKind(for: .http(status: 404, body: "Not Found"))
        XCTAssertEqual(notFound, .server(status: 404), "A wrong address")

        let timedOut = await failureKind(for: .urlError(.timedOut))
        XCTAssertEqual(timedOut, .timedOut)
        let offline = await failureKind(for: .urlError(.notConnectedToInternet))
        XCTAssertEqual(offline, .offline)
        let lost = await failureKind(for: .urlError(.networkConnectionLost))
        XCTAssertEqual(lost, .offline)
        let noHost = await failureKind(for: .urlError(.cannotFindHost))
        XCTAssertEqual(noHost, .offline)
        let tls = await failureKind(for: .urlError(.secureConnectionFailed))
        XCTAssertEqual(tls, .invalidResponse)
    }

    func testUnreadableAnswersAreInvalidResponses() async {
        let notJSON = await failureKind(for: .http(status: 200, body: "<html>Welcome to the captive portal</html>"))
        XCTAssertEqual(notJSON, .invalidResponse)
        let empty = await failureKind(for: .http(status: 200, body: ""))
        XCTAssertEqual(empty, .invalidResponse)
        let noVerdict = await failureKind(for: .http(status: 200, body: #"{"slots":[]}"#))
        XCTAssertEqual(noVerdict, .invalidResponse)

        let unknownAction = TestBackend.verdictBody(action: "teleport", leaveNow: (sixAM, eight), recommended: (sevenFifteen, eight), generatedAt: sixAM)
        let action = await failureKind(for: .http(status: 200, body: unknownAction))
        XCTAssertEqual(action, .invalidResponse, "An unknown action is never guessed at")

        let unknownConfidence = await failureKind(for: .http(status: 200, body: leaveLaterBody(confidence: "Certain")))
        XCTAssertEqual(unknownConfidence, .invalidResponse)

        let missingSlot = #"{"verdict":{"action":"leave_later","reason":"Leave later.","leaveNow":{"departAt":"2026-10-26T13:00:00.000Z","arriveAt":"2026-10-26T13:42:00.000Z","driveMinutes":42},"confidence":"High","confidenceReason":"","notes":[],"generatedAt":"2026-10-26T13:00:00.000Z"}}"#
        let slot = await failureKind(for: .http(status: 200, body: missingSlot))
        XCTAssertEqual(slot, .invalidResponse, "leave_later without its recommended slot")

        let missingStamp = #"{"verdict":{"action":"leave_now","reason":"Leave now.","leaveNow":{"departAt":"2026-10-26T13:00:00.000Z","arriveAt":"2026-10-26T13:42:00.000Z","driveMinutes":42},"confidence":"High","confidenceReason":"","notes":[]}}"#
        let stamp = await failureKind(for: .http(status: 200, body: missingStamp))
        XCTAssertEqual(stamp, .invalidResponse)

        let badDate = #"{"verdict":{"action":"leave_now","reason":"Leave now.","leaveNow":{"departAt":"13:00","arriveAt":"13:42","driveMinutes":42},"confidence":"High","confidenceReason":"","notes":[],"generatedAt":"2026-10-26T13:00:00.000Z"}}"#
        let date = await failureKind(for: .http(status: 200, body: badDate))
        XCTAssertEqual(date, .invalidResponse)
    }

    func testAMissingAddressIsNotConfiguredAndSendsNothing() async {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: FixedWallClock(sixAM), baseURL: nil)
        do {
            _ = try await backend.estimateCommute(for: request())
            XCTFail("Expected a failure")
        } catch let failure as CommuteProviderFailure {
            XCTAssertEqual(failure.kind, .notConfigured)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let sent = await transport.requestCount()
        XCTAssertEqual(sent, 0)
    }

    func testCancellationPropagates() async {
        // The transport reports a cancelled load, as the system session does.
        let cancelledLoad = ScriptedHTTPTransport(.urlError(.cancelled))
        do {
            _ = try await provider(cancelledLoad, clock: FixedWallClock(sixAM)).estimateCommute(for: request())
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        // A task that is already cancelled never reaches the transport.
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: FixedWallClock(sixAM))
        let trip = request()
        let task = Task { () async throws -> CommuteEstimateResponse in
            try? await Task.sleep(for: .seconds(10))
            return try await backend.estimateCommute(for: trip)
        }
        task.cancel()
        switch await task.result {
        case .success(let response):
            XCTFail("Expected CancellationError, got \(response)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let sent = await transport.requestCount()
        XCTAssertEqual(sent, 0)
    }

    // MARK: Without a request

    func testATripBeyondThePlanningHorizonMakesNoRequest() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: FixedWallClock(sixAM))
        // 13 hours ahead; the backend plans 11 hours 30 minutes ahead.
        let arriveBy = sixAM.addingTimeInterval(13 * 3_600)
        let response = try await backend.estimateCommute(for: request(arriveBy: arriveBy))
        let askAgainAt = arriveBy.addingTimeInterval(-690 * 60)
        XCTAssertEqual(askAgainAt, sixAM.addingTimeInterval(90 * 60))
        XCTAssertEqual(
            response,
            .notYet(
                message: "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after <\(TestBackend.iso(askAgainAt))>.",
                askAgainAt: askAgainAt
            )
        )
        var sent = await transport.requestCount()
        XCTAssertEqual(sent, 0, "Far-off occurrences cost no request")

        // One second inside the horizon is asked; exactly at it too.
        _ = try await backend.estimateCommute(for: request(arriveBy: sixAM.addingTimeInterval(690 * 60)))
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
        let justBeyond = try await backend.estimateCommute(for: request(arriveBy: sixAM.addingTimeInterval(690 * 60 + 1)))
        guard case .notYet = justBeyond else {
            return XCTFail("Expected not yet, got \(justBeyond)")
        }
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
    }

    func testThePlanningHorizonCanBeUpdatedFromTheServersLimits() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: FixedWallClock(sixAM))
        XCTAssertEqual(backend.planningHorizon, 690 * 60)
        XCTAssertEqual(BackendCommuteProvider.defaultPlanningHorizon, 690 * 60)

        backend.setPlanningHorizon(12 * 3_600)
        XCTAssertEqual(backend.planningHorizon, 12 * 3_600)
        let arriveBy = sixAM.addingTimeInterval(13 * 3_600)
        let response = try await backend.estimateCommute(for: request(arriveBy: arriveBy))
        XCTAssertEqual(
            response,
            .notYet(
                message: "The traffic forecast reaches about 12 hours ahead. A leave-home time will appear after <\(TestBackend.iso(sixAM.addingTimeInterval(3_600)))>.",
                askAgainAt: sixAM.addingTimeInterval(3_600)
            ),
            "The words follow the value"
        )

        backend.setPlanningHorizon(0)
        backend.setPlanningHorizon(-.infinity)
        backend.setPlanningHorizon(.nan)
        XCTAssertEqual(backend.planningHorizon, 12 * 3_600, "Unusable values are ignored")
        XCTAssertEqual(provider(transport, clock: FixedWallClock(sixAM), planningHorizon: -5).planningHorizon, 690 * 60)

        XCTAssertEqual(BackendCommuteProvider.hoursText(690 * 60), "11.5 hours")
        XCTAssertEqual(BackendCommuteProvider.hoursText(720 * 60), "12 hours")
        XCTAssertEqual(BackendCommuteProvider.hoursText(3_600), "1 hour")
        XCTAssertEqual(BackendCommuteProvider.hoursText(90 * 60), "1.5 hours")
        XCTAssertFalse(BackendCommuteProvider.deviceTimeDescription(sixAM).isEmpty)
    }

    func testAPassedArrivalIsAnsweredLocally() async throws {
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let backend = provider(transport, clock: FixedWallClock(eightFifteen))
        let atArrival = try await backend.estimateCommute(for: request())
        XCTAssertEqual(atArrival, .unavailable(message: "The ideal arrival time has passed."))
        let earlier = try await backend.estimateCommute(for: request(arriveBy: sixAM))
        XCTAssertEqual(earlier, .unavailable(message: "The ideal arrival time has passed."))
        let sent = await transport.requestCount()
        XCTAssertEqual(sent, 0)
    }

    // MARK: Source and confidence

    func testTheSourceIsMappedExplicitly() async throws {
        func source(_ json: String?) async throws -> RecommendationSource {
            try recommendation(try await answer(to: .http(status: 200, body: leaveLaterBody(source: json)))).source
        }
        let live = try await source(#"{"baseline":"tomtom","fallback":false,"live":true}"#)
        XCTAssertEqual(live, RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true))
        XCTAssertEqual(live.label, "Live traffic (TomTom) via the team backend")

        let typical = try await source(#"{"baseline":"tomtom","fallback":false,"live":false}"#)
        XCTAssertEqual(typical.label, "Typical traffic (TomTom); live traffic unavailable")

        let fallback = try await source(#"{"baseline":"pems","fallback":true,"live":false}"#)
        XCTAssertEqual(fallback, RecommendationSource(baseline: .pems, usedFallback: true, hasLiveTraffic: false))
        XCTAssertEqual(fallback.label, "Historical traffic (PeMS fallback); TomTom unavailable")

        let fixture = try await source(#"{"baseline":"fixture","fallback":false,"live":false}"#)
        XCTAssertEqual(fixture.baseline, .fixture)
        XCTAssertEqual(fixture.label, "Test fixture traffic, not live")

        let absent = try await source(nil)
        XCTAssertEqual(absent, .unknown, "An older server reports no source")
        XCTAssertEqual(absent.label, "Team backend")
        XCTAssertFalse(absent.hasLiveTraffic, "Live traffic is not assumed")

        let unknown = try await source(#"{"baseline":"here","fallback":false,"live":true}"#)
        XCTAssertEqual(unknown.baseline, .unknown, "An unknown baseline is not a failure")
        XCTAssertTrue(unknown.hasLiveTraffic)

        let explicitUnknown = try await source(#"{"baseline":"unknown","fallback":false,"live":false}"#)
        XCTAssertEqual(explicitUnknown, .unknown)

        let partial = try await source(#"{"baseline":"TomTom"}"#)
        XCTAssertEqual(partial, RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: false), "Missing flags count as false")
    }

    func testConfidenceIsReadInAnyLetterCase() {
        XCTAssertEqual(BackendCommuteProvider.confidence(for: "High"), .high)
        XCTAssertEqual(BackendCommuteProvider.confidence(for: "HIGH"), .high)
        XCTAssertEqual(BackendCommuteProvider.confidence(for: "medium"), .medium)
        XCTAssertEqual(BackendCommuteProvider.confidence(for: "Low"), .low)
        XCTAssertNil(BackendCommuteProvider.confidence(for: "Certain"))
        XCTAssertNil(BackendCommuteProvider.confidence(for: nil))
    }

    // MARK: Monitored trips

    func testAMonitoredTripAnswersBeforeTheBackendIsAsked() async throws {
        let monitoredAnswer = CommuteEstimateResponse.recommendation(TestBackend.recommendation(
            departure: sevenFifteen,
            arrival: eight,
            generatedAt: sixAM,
            isMonitored: true
        ))
        let transport = ScriptedHTTPTransport(.http(status: 200, body: leaveLaterBody()))
        let monitored = ScriptedMonitoredTripSource { _ in monitoredAnswer }
        let withAnswer = provider(transport, clock: FixedWallClock(sixAM), monitoredTrips: monitored)
        let response = try await withAnswer.estimateCommute(for: request())
        XCTAssertEqual(response, monitoredAnswer, "The server's monitored recommendation is used as is")
        var sent = await transport.requestCount()
        XCTAssertEqual(sent, 0)

        // Not monitored: the backend is asked directly.
        let unmonitored = ScriptedMonitoredTripSource { _ in nil }
        let direct = try recommendation(try await provider(transport, clock: FixedWallClock(sixAM), monitoredTrips: unmonitored).estimateCommute(for: request()))
        XCTAssertFalse(direct.isMonitored)
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
        let asked = await unmonitored.calls
        XCTAssertEqual(asked, 1)

        // A passed arrival never reaches the monitored source either.
        let late = provider(transport, clock: FixedWallClock(eightFifteen), monitoredTrips: monitored)
        _ = try await late.estimateCommute(for: request())
        let monitoredCalls = await monitored.calls
        XCTAssertEqual(monitoredCalls, 1)

        // Its failure is the provider's failure.
        let failing = ScriptedMonitoredTripSource { _ in throw CommuteProviderFailure(.offline) }
        do {
            _ = try await provider(transport, clock: FixedWallClock(sixAM), monitoredTrips: failing).estimateCommute(for: request())
            XCTFail("Expected a failure")
        } catch let failure as CommuteProviderFailure {
            XCTAssertEqual(failure.kind, .offline)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
    }
}
