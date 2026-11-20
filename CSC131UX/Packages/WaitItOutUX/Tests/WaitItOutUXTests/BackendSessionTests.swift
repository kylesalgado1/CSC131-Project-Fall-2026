import XCTest
@testable import WaitItOutUX

/// Stage S2: the backend session. It registers this installation once per server and keeps
/// the credential; sends the complete set of trips under a revision that is reused only for
/// the very same body; counts a snapshot as acknowledged only when the server answers with
/// that revision and exactly those trips; heals a counter that fell behind and a device the
/// server lost; runs its requests one after the other; reports the push token and permission
/// when they change; answers for a trip only while the server actively monitors it; and keeps
/// every server's credential and state apart.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The class's ideal arrival is 8:15 AM.
final class BackendSessionTests: XCTestCase {
    // MARK: Helpers

    private let now = TestFixtures.date(2026, 10, 26, 6)
    private let arrival = TestFixtures.date(2026, 10, 26, 8, 15)
    private let classID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF") ?? UUID()
    private let labID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

    private struct Fixture {
        let clock: ManualWallClock
        let server: FakeTripServer
        let transport: ScriptedHTTPTransport
        let configuration: BackendConfiguration
        let credentials: InMemoryCredentialStore
        let push: FakePushRegistrar?
        let session: BackendSession
    }

    private func makeFixture(push: FakePushRegistrar? = nil, credentials: InMemoryCredentialStore = InMemoryCredentialStore()) -> Fixture {
        let clock = ManualWallClock(now)
        let server = FakeTripServer(clock: clock)
        let transport = ScriptedHTTPTransport(responder: server.responder)
        let configuration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let client = BackendClient(configuration: configuration, transport: transport, clock: clock)
        let session = BackendSession(client: client, credentials: credentials, push: push, clock: clock)
        return Fixture(clock: clock, server: server, transport: transport, configuration: configuration, credentials: credentials, push: push, session: session)
    }

    private func occurrenceID(_ activityID: UUID, _ year: Int = 2026, _ month: Int = 10, _ day: Int = 26) -> OccurrenceID {
        OccurrenceID(activityID: activityID, date: LocalDate(year: year, month: month, day: day) ?? LocalDate(dayNumber: 0))
    }

    private func trip(_ activityID: UUID? = nil, title: String = "One-time class", arriveBy: Date? = nil) -> MonitoredTrip {
        MonitoredTrip(
            id: occurrenceID(activityID ?? classID),
            title: title,
            origin: CommutePlaces.sample.home.coordinate,
            destination: CommutePlaces.sample.campus.coordinate,
            arriveBy: arriveBy ?? arrival,
            timeZoneIdentifier: "America/Los_Angeles"
        )
    }

    private func request(for trip: MonitoredTrip) -> CommuteRequest {
        CommuteRequest(
            occurrenceID: trip.id,
            origin: CommutePlaces.sample.home,
            destination: Destination(id: SampleLocation.demoCampus.destinationID, name: CommutePlaces.sample.campus.name, coordinate: trip.destination),
            arriveBy: trip.arriveBy
        )
    }

    private func requests(_ fixture: Fixture, _ method: String, _ path: String) async -> [RecordedRequest] {
        await fixture.transport.requests.filter { $0.method == method && $0.path == path }
    }

    private func credential(_ store: InMemoryCredentialStore, _ origin: String = "https://backend.example") async throws -> StoredCredential {
        let stored = try await store.load(origin: origin)
        return try XCTUnwrap(stored, "No credential is stored for \(origin)")
    }

    private func firstRequest(_ fixture: Fixture, _ method: String, _ path: String) async throws -> RecordedRequest {
        let matching = await requests(fixture, method, path)
        return try XCTUnwrap(matching.first, "No \(method) \(path) was sent")
    }

    private func lastRequest(_ fixture: Fixture, _ method: String, _ path: String) async throws -> RecordedRequest {
        let matching = await requests(fixture, method, path)
        return try XCTUnwrap(matching.last, "No \(method) \(path) was sent")
    }

    private func lastRequest(_ fixture: Fixture) async throws -> RecordedRequest {
        let all = await fixture.transport.requests
        return try XCTUnwrap(all.last, "Nothing was sent")
    }

    private func failure(_ work: () async throws -> Void) async -> TripMonitoringFailure? {
        do {
            try await work()
            return nil
        } catch {
            return error as? TripMonitoringFailure
        }
    }

    /// Sets the class trip to be reported as actively monitored with a plan leaving at 7:05.
    private func monitorClass(_ fixture: Fixture, stale: Bool = false, evaluatedAt: Date? = nil) {
        fixture.server.setPhase(
            occurrenceID(classID).rawValue,
            "monitoring",
            recommendation: TestBackend.recommendationBody(
                departAt: TestFixtures.date(2026, 10, 26, 7, 5),
                arriveAt: TestFixtures.date(2026, 10, 26, 7, 50),
                evaluatedAt: evaluatedAt ?? now,
                stale: stale
            )
        )
    }

    // MARK: Registration and credentials

    func testRegistersOnceAndReusesTheCredential() async throws {
        let fixture = makeFixture()
        let first = try await fixture.session.synchronize([trip()])
        let second = try await fixture.session.synchronize([trip(), trip(labID, title: "Lab")])

        XCTAssertEqual(fixture.server.registrationCount, 1, "One installation, one device")
        let registration = try await firstRequest(fixture, "POST", "/devices")
        XCTAssertEqual(registration.jsonObject()["platform"] as? String, "ios")
        XCTAssertNil(registration.headers["Authorization"], "Registration carries no credential")

        let stored = try await credential(fixture.credentials)
        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.count, 2)
        for request in sent {
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(stored.token)")
        }
        XCTAssertEqual(first.trips.count, 1)
        XCTAssertEqual(second.trips.count, 2)
        XCTAssertEqual(second.limits, .fallback, "The server's limits equal the fallback in this fixture")
        XCTAssertEqual(second.acknowledgedAt, now)
        XCTAssertEqual(second.serverTime, now)
        XCTAssertTrue(second.monitor.enabled)
        XCTAssertTrue(second.monitor.dependable)
    }

    func testACredentialFromAnEarlierLaunchIsUsedWithoutRegistering() async throws {
        let first = makeFixture()
        _ = try await first.session.synchronize([trip()])
        let stored = try await credential(first.credentials)
        XCTAssertEqual(stored.revision, 1)
        XCTAssertNotNil(stored.sentDigest)

        // A new session on the same store and the same server, as after a relaunch.
        let client = BackendClient(configuration: first.configuration, transport: first.transport, clock: first.clock)
        let relaunched = BackendSession(client: client, credentials: first.credentials, push: nil, clock: first.clock)
        _ = try await relaunched.synchronize([trip()])

        XCTAssertEqual(first.server.registrationCount, 1)
        let sent = await requests(first, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1], "The same body keeps its revision across a relaunch")
        XCTAssertEqual(sent.first?.body, sent.last?.body, "A resend is byte for byte the body sent before")
    }

    func testNothingIsRegisteredJustToReadEndOrRemove() async throws {
        let fixture = makeFixture()
        let id = occurrenceID(classID)

        let refreshFailure = await failure { _ = try await fixture.session.refresh() }
        XCTAssertEqual(refreshFailure, .notRegistered)
        let tripFailure = await failure { _ = try await fixture.session.refreshTrip(id) }
        XCTAssertEqual(tripFailure, .notRegistered)
        let departed = await fixture.session.markDeparted(id, arriveBy: arrival)
        XCTAssertEqual(departed, .failure(.notRegistered))
        try await fixture.session.unregister(from: nil)

        let count = await fixture.transport.requestCount()
        XCTAssertEqual(count, 0, "Without a credential there is nothing to do, and nothing is sent")
        XCTAssertEqual(fixture.server.registrationCount, 0)
    }

    func testWithoutAnAddressNothingIsSent() async throws {
        let clock = ManualWallClock(now)
        let transport = ScriptedHTTPTransport(.http(status: 200, body: "{}"))
        let client = BackendClient(configuration: BackendConfiguration(defaultBaseURL: nil), transport: transport, clock: clock)
        let session = BackendSession(client: client, credentials: InMemoryCredentialStore(), push: nil, clock: clock)

        let syncFailure = await failure { _ = try await session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .notConfigured)
        try await session.unregister(from: nil)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: Snapshot shape

    func testTheSnapshotBodyHasExactlyTheContractsShape() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])

        let sent = try await firstRequest(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.url.absoluteString, "https://backend.example/trips")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        let body = sent.jsonObject()
        XCTAssertEqual(body.keys.sorted(), ["revision", "trips"])
        XCTAssertEqual(body["revision"] as? Int, 1)
        let trips = try XCTUnwrap(body["trips"] as? [[String: Any]])
        XCTAssertEqual(trips.count, 1)
        let first = try XCTUnwrap(trips.first)
        XCTAssertEqual(first.keys.sorted(), ["arriveBy", "destination", "id", "origin", "timeZone", "title"], "Only what the server uses: no start time and no destination name")
        XCTAssertEqual(first["id"] as? String, "6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-10-26", "The stable occurrence id: activity id, an at sign, the local day")
        XCTAssertEqual(first["title"] as? String, "One-time class")
        XCTAssertEqual(first["arriveBy"] as? String, "2026-10-26T15:15:00.000Z", "8:15 AM PDT as an absolute instant with a zone designator")
        XCTAssertNil(first["startsAt"], "The activity's start time is not sent")
        XCTAssertNil(first["destinationName"], "The destination's name is not sent")
        XCTAssertFalse(sent.bodyText.contains(CommutePlaces.sample.campus.name), "The campus name appears nowhere in the body")
        XCTAssertEqual(first["timeZone"] as? String, "America/Los_Angeles")
        let origin = try XCTUnwrap(first["origin"] as? [String: Any])
        XCTAssertEqual(origin.keys.sorted(), ["lat", "lng"])
        XCTAssertEqual((origin["lat"] as? NSNumber)?.doubleValue, CommutePlaces.sample.home.coordinate.latitude)
        XCTAssertEqual((origin["lng"] as? NSNumber)?.doubleValue, CommutePlaces.sample.home.coordinate.longitude)
        let destination = try XCTUnwrap(first["destination"] as? [String: Any])
        XCTAssertEqual((destination["lat"] as? NSNumber)?.doubleValue, CommutePlaces.sample.campus.coordinate.latitude)
    }

    func testTripsAreSentInIdOrderOncePerId() async throws {
        let fixture = makeFixture()
        let lab = trip(labID, title: "Lab")
        _ = try await fixture.session.synchronize([trip(), lab, trip()])

        let sent = try await firstRequest(fixture, "PUT", "/trips")
        let ids = (sent.jsonObject()["trips"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, [lab.id.rawValue, trip().id.rawValue], "Sorted by id, so the same set is always the same body")
    }

    func testATripWithoutATitleIsSentAsActivity() async throws {
        let fixture = makeFixture()
        let unnamed = MonitoredTrip(
            id: occurrenceID(classID),
            title: "  ",
            origin: CommutePlaces.sample.home.coordinate,
            destination: CommutePlaces.sample.campus.coordinate,
            arriveBy: arrival,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        _ = try await fixture.session.synchronize([unnamed])

        let sent = try await firstRequest(fixture, "PUT", "/trips")
        let first = try XCTUnwrap((sent.jsonObject()["trips"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["title"] as? String, "Activity", "An empty title is never sent")
    }

    // MARK: Revisions

    func testTheRevisionRisesOnlyWhenTheSetChanges() async throws {
        let fixture = makeFixture()
        let lab = trip(labID, title: "Lab")
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.synchronize([trip(), lab])
        _ = try await fixture.session.synchronize([lab, trip()])
        _ = try await fixture.session.synchronize([])
        _ = try await fixture.session.synchronize([trip()])

        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1, 2, 2, 3, 4])
        XCTAssertEqual(sent[0].body, sent[1].body, "An identical retry is byte for byte the same request")
        XCTAssertEqual(sent[2].body, sent[3].body, "The order the caller lists trips in does not matter")
        XCTAssertNotEqual(sent[0].body, sent[5].body, "The same trips after another set are a new snapshot")
        XCTAssertEqual(fixture.server.storedRevision, 4)
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])
    }

    func testARenamedTripIsANewSnapshot() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.synchronize([trip(title: "Renamed class")])

        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2])
    }

    func testTheRevisionIsStoredBeforeTheRequestIsSent() async throws {
        let fixture = makeFixture()
        fixture.server.failNext("PUT", "/trips", with: .urlError(.timedOut))

        let syncFailure = await failure { _ = try await fixture.session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .timedOut)
        let stored = try await credential(fixture.credentials)
        XCTAssertEqual(stored.revision, 1, "A lost answer can never lead to a reused revision for another body")
        XCTAssertNotNil(stored.sentDigest)
    }

    func testACounterThatFellBehindHealsItself() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.synchronize([trip(), trip(labID, title: "Lab")])
        _ = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(fixture.server.storedRevision, 3)

        // The device keeps its credential but loses its counters, as after restored storage.
        let stored = try await credential(fixture.credentials)
        let forgetful = InMemoryCredentialStore(initial: ["https://backend.example": StoredCredential(deviceID: stored.deviceID, token: stored.token)])
        let client = BackendClient(configuration: fixture.configuration, transport: fixture.transport, clock: fixture.clock)
        let session = BackendSession(client: client, credentials: forgetful, push: nil, clock: fixture.clock)
        let lab = trip(labID, title: "Lab")
        let snapshot = try await session.synchronize([lab])

        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2, 3, 1, 4], "Revision 1 was not applied, so the session moved past the server's 3 and sent once more")
        XCTAssertEqual(fixture.server.heldTripIDs, [lab.id.rawValue])
        XCTAssertEqual(Array(snapshot.trips.keys), [lab.id])
        let healed = try await credential(forgetful)
        XCTAssertEqual(healed.revision, 4)
        XCTAssertEqual(healed.serverRevision, 4)
    }

    func testARevisionConflictMovesPastTheServersRevision() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])

        // The stored counter says 0 sent, the server holds revision 1 with another body.
        let stored = try await credential(fixture.credentials)
        let forgetful = InMemoryCredentialStore(initial: ["https://backend.example": StoredCredential(deviceID: stored.deviceID, token: stored.token)])
        let client = BackendClient(configuration: fixture.configuration, transport: fixture.transport, clock: fixture.clock)
        let session = BackendSession(client: client, credentials: forgetful, push: nil, clock: fixture.clock)
        let lab = trip(labID, title: "Lab")
        _ = try await session.synchronize([lab])

        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1, 2], "409, then one resend under a higher revision")
        XCTAssertEqual(fixture.server.heldTripIDs, [lab.id.rawValue])
    }

    func testTripsCancelledBehindTheAppsBackAreSentAgain() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.cancelTrips()

        let snapshot = try await fixture.session.synchronize([trip()])

        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1, 2], "The resend was answered without the trip, so it was not acknowledged and went out once more")
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])
        XCTAssertEqual(snapshot.trips.count, 1)
    }

    func testAnAnswerThatNeverListsTheSentTripsIsNotAcknowledged() async throws {
        let clock = ManualWallClock(now)
        let registration = TestBackend.object([#""deviceId":"0a0a0a0a-0000-4000-8000-000000000001""#, #""token":"0a0a0a0a-0000-4000-8000-000000000001.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ""#])
        let serverTime = now
        let transport = ScriptedHTTPTransport { request in
            if request.path == "/devices" { return .http(status: 201, body: registration) }
            let revision = request.jsonObject()["revision"] as? Int ?? 0
            return .http(status: 200, body: TestBackend.syncBody(revision: revision, applied: true, serverTime: serverTime, trips: []))
        }
        let client = TestBackend.client(transport: transport, clock: clock)
        let session = BackendSession(client: client, credentials: InMemoryCredentialStore(), push: nil, clock: clock)

        let syncFailure = await failure { _ = try await session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .invalidResponse)
        let puts = await transport.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.count, 2, "One resend, then it gives up instead of claiming monitoring")
        let answer = try await session.answer(for: request(for: trip()))
        XCTAssertNil(answer)
    }

    // MARK: A device the server lost

    func testAnUnknownDeviceIsRegisteredAgainOnceAndEverythingIsResent() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.synchronize([trip(), trip(labID, title: "Lab")])
        let before = try await credential(fixture.credentials)
        fixture.server.loseDevices()

        let snapshot = try await fixture.session.synchronize([trip()])

        XCTAssertEqual(fixture.server.registrationCount, 2)
        let after = try await credential(fixture.credentials)
        XCTAssertNotEqual(after.token, before.token)
        XCTAssertEqual(after.revision, 1, "The new device starts counting again")
        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2, 3, 1])
        XCTAssertEqual(sent.last?.headers["Authorization"], "Bearer \(after.token)")
        XCTAssertEqual(snapshot.trips.count, 1)
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])
    }

    func testADeviceThatStaysUnknownIsAFailureNotALoop() async throws {
        let clock = ManualWallClock(now)
        let registration = TestBackend.object([#""deviceId":"0a0a0a0a-0000-4000-8000-000000000001""#, #""token":"0a0a0a0a-0000-4000-8000-000000000001.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ""#])
        let transport = ScriptedHTTPTransport { request in
            request.path == "/devices"
                ? .http(status: 201, body: registration)
                : .http(status: 401, body: TestBackend.errorBody("unauthorized", "This device is not registered."))
        }
        let session = BackendSession(client: TestBackend.client(transport: transport, clock: clock), credentials: InMemoryCredentialStore(), push: nil, clock: clock)

        let syncFailure = await failure { _ = try await session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .server(status: 401))
        let registrations = await transport.requests.filter { $0.path == "/devices" }
        XCTAssertEqual(registrations.count, 2, "Registered again exactly once")
    }

    func testReadingWithAnUnknownDeviceDropsTheCredentialAndSaysSo() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.loseDevices()

        let refreshFailure = await failure { _ = try await fixture.session.refresh() }
        XCTAssertEqual(refreshFailure, .reregistered, "The caller must synchronize again")
        let stored = try await fixture.credentials.load(origin: "https://backend.example")
        XCTAssertNil(stored, "The stale credential is gone")
        XCTAssertEqual(fixture.server.registrationCount, 1, "Reading never registers a device")
        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(answer, "Nothing is answered from a server that no longer knows the device")

        _ = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(fixture.server.registrationCount, 2)
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])
    }

    // MARK: One request after the other

    func testANewerSnapshotReplacesOneThatHasNotStarted() async throws {
        let clock = ManualWallClock(now)
        let server = FakeTripServer(clock: clock)
        let gate = HeldTransport(responder: server.responder)
        let client = BackendClient(configuration: BackendConfiguration(defaultBaseURL: TestBackend.baseURL), transport: gate, clock: clock)
        let session = BackendSession(client: client, credentials: InMemoryCredentialStore(), push: nil, clock: clock)
        let lab = trip(labID, title: "Lab")
        let both = [trip(), lab]

        let first = Task { try await session.synchronize([self.trip()]) }
        let registrationArrived = await gate.waitForHeldRequests(1)
        XCTAssertTrue(registrationArrived)
        // The two later calls line up behind the first, in this order.
        let second = Task { try await session.synchronize([lab]) }
        try await Task.sleep(for: .milliseconds(60))
        let third = Task { try await session.synchronize(both) }
        try await Task.sleep(for: .milliseconds(60))
        await gate.releaseAll()

        let firstSnapshot = try await first.value
        XCTAssertEqual(firstSnapshot.trips.count, 1)
        do {
            _ = try await second.value
            XCTFail("The snapshot in the middle was replaced before it started")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let thirdSnapshot = try await third.value
        XCTAssertEqual(thirdSnapshot.trips.count, 2)

        let sent = await gate.requests.filter { $0.method == "PUT" && $0.path == "/trips" }
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2], "The requests went out one after the other, and the replaced one never did")
        XCTAssertEqual(server.heldTripIDs, both.map(\.id.rawValue).sorted())
        XCTAssertEqual(server.registrationCount, 1, "Queued calls did not each register a device")
    }

    func testACancelledCallerDoesNotCancelTheRequest() async throws {
        let clock = ManualWallClock(now)
        let server = FakeTripServer(clock: clock)
        let gate = HeldTransport(responder: server.responder)
        let client = BackendClient(configuration: BackendConfiguration(defaultBaseURL: TestBackend.baseURL), transport: gate, clock: clock)
        let session = BackendSession(client: client, credentials: InMemoryCredentialStore(), push: nil, clock: clock)

        let caller = Task { try await session.synchronize([self.trip()]) }
        let arrived = await gate.waitForHeldRequests(1)
        XCTAssertTrue(arrived)
        caller.cancel()
        await gate.releaseAll()
        _ = try? await caller.value

        // The request ran to its end in the session's own task: the server holds the trip and
        // the session can answer for it.
        let snapshot = try await session.refresh()
        XCTAssertEqual(snapshot.trips.count, 1)
        XCTAssertEqual(server.heldTripIDs, [trip().id.rawValue])
    }

    // MARK: Lost answers (the server applied the request)

    func testOnThenOffEndsWithNothingOnTheServerWhenTheFirstAnswerWasLost() async throws {
        let fixture = makeFixture()
        fixture.server.failNext("PUT", "/trips", .afterApplying, with: .urlError(.timedOut))

        let lost = await failure { _ = try await fixture.session.synchronize([self.trip()]) }
        XCTAssertEqual(lost, .timedOut)
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue], "The server applied the snapshot the app heard nothing about")
        let unacknowledged = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(unacknowledged, "Nothing is claimed for a snapshot that was not acknowledged")

        // Turned off again: the empty set is a different body, so it gets a higher revision.
        let empty = try await fixture.session.synchronize([])
        XCTAssertTrue(empty.trips.isEmpty)
        XCTAssertEqual(fixture.server.heldTripIDs, [], "The server holds the empty set")
        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2])
    }

    func testOffThenOnEndsWithTheTripsOnTheServerWhenTheFirstAnswerWasLost() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.failNext("PUT", "/trips", .afterApplying, with: .urlError(.timedOut))

        let lost = await failure { _ = try await fixture.session.synchronize([]) }
        XCTAssertEqual(lost, .timedOut)
        XCTAssertEqual(fixture.server.heldTripIDs, [], "The server applied the withdrawal")

        let snapshot = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(snapshot.trips.count, 1)
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue], "A revision reused here would have been ignored and left the server empty")
        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2, 3])
    }

    func testAResendAfterALostAnswerIsHarmless() async throws {
        let fixture = makeFixture()
        fixture.server.failNext("PUT", "/trips", .afterApplying, with: .urlError(.networkConnectionLost))

        let lost = await failure { _ = try await fixture.session.synchronize([self.trip()]) }
        XCTAssertEqual(lost, .offline)
        let snapshot = try await fixture.session.synchronize([trip()])

        XCTAssertEqual(snapshot.trips.count, 1)
        let sent = await requests(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1], "The very same body keeps its revision, which the server treats as a retry")
        XCTAssertEqual(fixture.server.storedRevision, 1)
    }

    // MARK: Push

    func testThePushTokenAndPermissionAreReportedWhenTheyChange() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)

        // Allowed, but the push service has not handed over a token yet: nothing to report.
        _ = try await fixture.session.synchronize([trip()])
        var reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertTrue(reports.isEmpty)

        let changed = await fixture.session.updateDeviceToken(Data([0x0A, 0xFF] + Array(repeating: UInt8(0x1B), count: 30)))
        XCTAssertTrue(changed)
        let first = try await fixture.session.synchronize([trip()])
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 1)
        let body = try XCTUnwrap(reports.first?.jsonObject())
        XCTAssertEqual(body.keys.sorted(), ["apnsToken", "authorized", "environment"])
        XCTAssertEqual(body["apnsToken"] as? String, "0aff" + String(repeating: "1b", count: 30), "Lowercase hexadecimal")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(body["authorized"] as? Bool, true)
        XCTAssertTrue(first.push.deviceRegistered, "The report went out before the snapshot, so its answer already shows it")
        XCTAssertTrue(first.push.authorized)
        XCTAssertTrue(first.push.serverConfigured)

        // Nothing changed: nothing is reported again.
        _ = try await fixture.session.synchronize([trip()])
        _ = try await fixture.session.refresh()
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 1)
        let unchanged = await fixture.session.updateDeviceToken(Data([0x0A, 0xFF] + Array(repeating: UInt8(0x1B), count: 30)))
        XCTAssertFalse(unchanged, "The same token again is not a change")

        // The user turns notifications off in iOS Settings.
        push.setStatus(.denied)
        let denied = try await fixture.session.refresh()
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last?.jsonObject()["authorized"] as? Bool, false)
        XCTAssertFalse(denied.push.authorized)
        XCTAssertEqual(fixture.server.storedAuthorized, false)
    }

    func testAFailedPushReportIsTriedAgainWithTheNextCall() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)
        await fixture.session.updateDeviceToken(Data(repeating: 0xAB, count: 32))
        // The report fails, and so does the one repeat the session makes when the snapshot
        // says the server has no token.
        let outage = ScriptedReply.http(status: 500, body: TestBackend.errorBody("internal", "Something went wrong."))
        fixture.server.failNext("PUT", "/devices/me/push", with: outage)
        fixture.server.failNext("PUT", "/devices/me/push", with: outage)

        let first = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(first.trips.count, 1, "The reports failed, and the synchronization went on")
        XCTAssertFalse(first.push.deviceRegistered)
        XCTAssertNil(fixture.server.storedPushToken)
        var reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)

        let second = try await fixture.session.synchronize([trip()])
        XCTAssertTrue(second.push.deviceRegistered)
        XCTAssertEqual(fixture.server.storedPushToken, String(repeating: "ab", count: 32))
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 3)
    }

    func testAFailedPushReportIsRepeatedOnceRightAway() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)
        await fixture.session.updateDeviceToken(Data(repeating: 0xAB, count: 32))
        fixture.server.failNext("PUT", "/devices/me/push", with: .urlError(.timedOut))

        let snapshot = try await fixture.session.synchronize([trip()])
        XCTAssertTrue(snapshot.push.deviceRegistered, "The snapshot said the server has no token, so the report was repeated")
        let reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)
    }

    func testATokenTheServerLostIsSentAgainOncePerForeground() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)
        await fixture.session.updateDeviceToken(Data(repeating: 0xCD, count: 32))
        _ = try await fixture.session.synchronize([trip()])

        fixture.server.dropPushTokens()
        let repaired = try await fixture.session.refresh()
        XCTAssertTrue(repaired.push.deviceRegistered, "The snapshot said the token was gone, so it was sent again")
        var reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)

        fixture.server.dropPushTokens()
        let second = try await fixture.session.refresh()
        XCTAssertFalse(second.push.deviceRegistered, "Only once per foreground: a token the push service rejects is not sent in a loop")
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)

        await fixture.session.refreshPushRegistration()
        XCTAssertEqual(push.registrationCount, 1, "A new foreground registers with the push service again")
        let third = try await fixture.session.refresh()
        XCTAssertTrue(third.push.deviceRegistered)
        reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 3)
    }

    func testAPermissionRevokedWhileTheAppWasClosedIsReported() async throws {
        // An earlier launch: notifications allowed, token reported.
        let allowed = FakePushRegistrar(status: .authorized)
        let first = makeFixture(push: allowed)
        await first.session.updateDeviceToken(Data(repeating: 0xEE, count: 32))
        _ = try await first.session.synchronize([trip()])
        XCTAssertEqual(first.server.storedAuthorized, true)

        // This launch: the user turned notifications off in iOS Settings meanwhile, so the
        // push service hands over no token and this session has reported nothing yet.
        let denied = FakePushRegistrar(status: .denied)
        let client = BackendClient(configuration: first.configuration, transport: first.transport, clock: first.clock)
        let relaunched = BackendSession(client: client, credentials: first.credentials, push: denied, clock: first.clock)
        let snapshot = try await relaunched.synchronize([trip()])

        XCTAssertEqual(first.server.storedAuthorized, false, "The server stops believing alerts are allowed")
        XCTAssertFalse(snapshot.push.authorized)
        let reports = await requests(first, "PUT", "/devices/me/push")
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last?.jsonObject()["authorized"] as? Bool, false)
        XCTAssertTrue(reports.last?.jsonObject()["apnsToken"] is NSNull, "No token this launch: an explicit null")

        // Once is enough: the next read sends nothing more.
        _ = try await relaunched.refresh()
        let later = await requests(first, "PUT", "/devices/me/push")
        XCTAssertEqual(later.count, 2)
    }

    func testPermissionGoesThroughTheRegistrar() async throws {
        let push = FakePushRegistrar(status: .notDetermined, answerToRequest: .authorized)
        let fixture = makeFixture(push: push)

        let before = await fixture.session.notificationPermission()
        XCTAssertEqual(before, .notDetermined)
        await fixture.session.refreshPushRegistration()
        XCTAssertEqual(push.requestCount, 0, "Refreshing never prompts")
        XCTAssertEqual(push.registrationCount, 0, "And registers only when allowed")

        let granted = await fixture.session.requestNotificationPermission()
        XCTAssertEqual(granted, .authorized)
        XCTAssertEqual(push.requestCount, 1)
        XCTAssertEqual(push.registrationCount, 1, "Allowed: the device registers with the push service")

        let denying = FakePushRegistrar(status: .notDetermined, answerToRequest: .denied)
        let other = makeFixture(push: denying)
        let denied = await other.session.requestNotificationPermission()
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(denying.registrationCount, 0)
    }

    func testWithoutARegistrarNothingIsAskedOrReported() async throws {
        let fixture = makeFixture(push: nil)
        let permission = await fixture.session.requestNotificationPermission()
        XCTAssertEqual(permission, .notDetermined)
        await fixture.session.refreshPushRegistration()
        await fixture.session.updateDeviceToken(Data(repeating: 0xAB, count: 32))
        let snapshot = try await fixture.session.synchronize([trip()])

        let reports = await requests(fixture, "PUT", "/devices/me/push")
        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(snapshot.push.deviceRegistered)
    }

    func testALocalRegistrationFailureIsShownWhileTheServerHasNoToken() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)
        let changed = await fixture.session.registrationFailed("no valid aps-environment entitlement string found for application")
        XCTAssertTrue(changed)

        let snapshot = try await fixture.session.synchronize([trip()])
        XCTAssertFalse(snapshot.push.deviceRegistered)
        XCTAssertEqual(snapshot.push.registrationFailure, "no valid aps-environment entitlement string found for application", "The system's own reason, kept as a failure of this device")
        XCTAssertNil(snapshot.push.lastFailure, "The server attempted nothing, so no failed send of its own is reported")
        let unchanged = await fixture.session.registrationFailed("no valid aps-environment entitlement string found for application")
        XCTAssertFalse(unchanged, "The same failure again is not news")

        // Once the device has a token and the server holds it, the earlier failure is over.
        _ = await fixture.session.updateDeviceToken(Data(repeating: 0xAB, count: 32))
        let registered = try await fixture.session.synchronize([trip()])
        XCTAssertTrue(registered.push.deviceRegistered)
        XCTAssertNil(registered.push.registrationFailure)
    }

    // MARK: Answers for monitored trips

    func testItAnswersOnlyForATripTheServerIsActivelyMonitoring() async throws {
        let fixture = makeFixture()
        let monitored = trip()
        let lab = trip(labID, title: "Lab", arriveBy: TestFixtures.date(2026, 10, 26, 9, 15))
        fixture.server.setPhase(lab.id.rawValue, "planned", recommendation: TestBackend.recommendationBody(
            departAt: TestFixtures.date(2026, 10, 26, 8, 5),
            arriveAt: TestFixtures.date(2026, 10, 26, 8, 50),
            evaluatedAt: now
        ))

        let nothingYet = try await fixture.session.answer(for: request(for: monitored))
        XCTAssertNil(nothingYet, "No snapshot yet")

        _ = try await fixture.session.synchronize([monitored, lab])
        let planning = try await fixture.session.answer(for: request(for: monitored))
        XCTAssertNil(planning, "Planning: the provider asks the backend directly")
        let planned = try await fixture.session.answer(for: request(for: lab))
        XCTAssertNil(planned, "Planned but not yet monitored: nothing has been announced, so the provider asks directly")

        monitorClass(fixture)
        _ = try await fixture.session.refresh()
        let answer = try await fixture.session.answer(for: request(for: monitored))
        guard case .recommendation(let recommendation) = answer else {
            return XCTFail("Expected the server's plan, got \(String(describing: answer))")
        }
        XCTAssertTrue(recommendation.isMonitored)
        XCTAssertFalse(recommendation.isStale)
        XCTAssertEqual(recommendation.advice, .leaveLater)
        XCTAssertEqual(recommendation.recommendedDeparture, TestFixtures.date(2026, 10, 26, 7, 5))
        XCTAssertEqual(recommendation.predictedArrival, TestFixtures.date(2026, 10, 26, 7, 50))
        XCTAssertEqual(recommendation.margin, 25 * 60)
        XCTAssertEqual(recommendation.confidence, .high)
        XCTAssertEqual(recommendation.source, TestBackend.liveSource)
        XCTAssertEqual(recommendation.generatedAt, now)

        let count = await fixture.transport.requestCount()
        _ = try await fixture.session.answer(for: request(for: monitored))
        let after = await fixture.transport.requestCount()
        XCTAssertEqual(after, count, "Answering never sends a request: the model owns refreshing")
    }

    func testItAnswersOnlyWhileTheServerKeepsThePlanCurrent() async throws {
        let fixture = makeFixture()
        let id = trip().id.rawValue
        let running = #"{"enabled":true,"dependable":true,"lastTickAt":null}"#
        func answered() async throws -> Bool {
            _ = try await fixture.session.refresh()
            return try await fixture.session.answer(for: request(for: trip())) != nil
        }
        func alert(_ kind: String, _ status: String) -> FakeTripServer.TripDetails {
            FakeTripServer.TripDetails(lastAlert: #"{"kind":"\#(kind)","status":"\#(status)","at":"\#(TestBackend.iso(now))"}"#)
        }
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])
        var isAnswered = try await answered()
        XCTAssertTrue(isAnswered, "Monitoring, the worker runs, the plan is fresh, its departure is ahead, nothing was announced")

        // The server does not run its monitoring worker: nobody re-checks the plan.
        fixture.server.monitor = #"{"enabled":false,"dependable":false,"lastTickAt":null}"#
        isAnswered = try await answered()
        XCTAssertFalse(isAnswered, "A plan nobody refreshes is not the current recommendation")
        fixture.server.monitor = #"{"enabled":true,"dependable":false,"lastTickAt":null}"#
        isAnswered = try await answered()
        XCTAssertTrue(isAnswered, "A worker that only runs while the server is awake still refreshes the plan")
        fixture.server.monitor = running

        // A time-to-leave or late alert was queued or sent: the server stops re-checking, so the
        // plan is a record of what was announced.
        for (kind, status) in [("leave_now", "queued"), ("leave_now", "sent"), ("leave_now", "failed"), ("late", "queued"), ("late", "sent")] {
            fixture.server.setDetails(id, alert(kind, status))
            isAnswered = try await answered()
            XCTAssertFalse(isAnswered, "\(kind) \(status)")
        }
        // The earlier alerts leave the plan current.
        for kind in ["heads_up", "update"] {
            fixture.server.setDetails(id, alert(kind, "sent"))
            isAnswered = try await answered()
            XCTAssertTrue(isAnswered, kind)
        }
        fixture.server.setDetails(id, FakeTripServer.TripDetails(leaveAlertSentAt: now))
        isAnswered = try await answered()
        XCTAssertFalse(isAnswered, "The server's own stamp for the time-to-leave alert")
        fixture.server.setDetails(id, nil)

        // The plan the server could not refresh on schedule.
        monitorClass(fixture, stale: true)
        isAnswered = try await answered()
        XCTAssertFalse(isAnswered)
        monitorClass(fixture)

        // The plan's departure, 7:05, is still ahead one second before, and has come at 7:05.
        fixture.clock.set(TestFixtures.date(2026, 10, 26, 7, 4, 59))
        isAnswered = try await answered()
        XCTAssertTrue(isAnswered)
        fixture.clock.set(TestFixtures.date(2026, 10, 26, 7, 5))
        isAnswered = try await answered()
        XCTAssertFalse(isAnswered, "From its departure on, the backend is asked directly, so it can say leave now or no longer reachable")
    }

    func testAnEditedTripNeverGetsTheOldServerAnswer() async throws {
        let fixture = makeFixture()
        let monitored = trip()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([monitored])
        let matching = try await fixture.session.answer(for: request(for: monitored))
        XCTAssertNotNil(matching)

        let laterArrival = CommuteRequest(
            occurrenceID: monitored.id,
            origin: CommutePlaces.sample.home,
            destination: request(for: monitored).destination,
            arriveBy: arrival.addingTimeInterval(15 * 60)
        )
        let moved = try await fixture.session.answer(for: laterArrival)
        XCTAssertNil(moved, "Another arrival time is another trip")

        let otherHome = try CommutePlace(name: "New home", coordinate: GeoCoordinate(latitude: 38.60, longitude: -121.50))
        let fromElsewhere = CommuteRequest(
            occurrenceID: monitored.id,
            origin: otherHome,
            destination: request(for: monitored).destination,
            arriveBy: arrival
        )
        let relocated = try await fixture.session.answer(for: fromElsewhere)
        XCTAssertNil(relocated, "Another origin is another trip")

        let otherCampus = CommuteRequest(
            occurrenceID: monitored.id,
            origin: CommutePlaces.sample.home,
            destination: Destination(id: SampleLocation.demoCampus.destinationID, name: "Elsewhere", coordinate: GeoCoordinate(latitude: 38.0, longitude: -121.0)),
            arriveBy: arrival
        )
        let redirected = try await fixture.session.answer(for: otherCampus)
        XCTAssertNil(redirected, "Another destination is another trip")
    }

    func testAPlanTheServerCouldNotRefreshIsNotAnswered() async throws {
        let fixture = makeFixture()
        monitorClass(fixture, stale: true, evaluatedAt: now.addingTimeInterval(-40 * 60))
        let snapshot = try await fixture.session.synchronize([trip()])
        let plan = try XCTUnwrap(snapshot.trips[trip().id]?.plan)
        XCTAssertTrue(plan.isStale, "The server's flag is read")

        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(answer, "A plan the server could not refresh is nobody's current plan: the provider asks the backend directly")

        // The mapping itself still marks such a plan, for any source that hands one over.
        let recommendation = BackendSession.recommendation(from: plan, acknowledgedAt: snapshot.acknowledgedAt, serverTime: snapshot.serverTime)
        XCTAssertTrue(recommendation.isStale)
        XCTAssertTrue(recommendation.isMonitored)
        XCTAssertEqual(recommendation.generatedAt, now.addingTimeInterval(-40 * 60))
        XCTAssertEqual(recommendation.receivedAt, now.addingTimeInterval(-40 * 60), "The device clock's equivalent of the server's evaluation time")
        let state = DepartureState.resolving(.recommendation(recommendation), for: request(for: trip()))
        guard case .stale(_, .staleServerData) = state else {
            return XCTFail("A stale server plan is never current, got \(state)")
        }

        // Once the server refreshed it, the plan is answered again.
        monitorClass(fixture)
        _ = try await fixture.session.refresh()
        let refreshed = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(refreshed)
    }

    func testTheAgeOfAPlanIsImmuneToClockSkew() {
        let plan = TestBackend.plan(departure: TestFixtures.date(2026, 10, 26, 7, 5), arrival: TestFixtures.date(2026, 10, 26, 7, 50), evaluatedAt: now)
        // The server's clock runs an hour ahead of the device's; the plan is 4 minutes old there.
        let serverTime = now.addingTimeInterval(4 * 60)
        let deviceNow = now.addingTimeInterval(-3_600 + 4 * 60)
        let recommendation = BackendSession.recommendation(from: plan, acknowledgedAt: deviceNow, serverTime: serverTime)
        XCTAssertEqual(recommendation.receivedAt, deviceNow.addingTimeInterval(-4 * 60))
        XCTAssertFalse(recommendation.isReasonCurrent(at: deviceNow), "Four minutes old: the relative sentence is no longer shown")

        // A server stamp from the future never makes a plan newer than the moment it arrived.
        let ahead = BackendSession.recommendation(from: plan, acknowledgedAt: deviceNow, serverTime: now.addingTimeInterval(-60))
        XCTAssertEqual(ahead.receivedAt, deviceNow)
    }

    func testAnOldSnapshotNoLongerAnswers() async throws {
        let fixture = makeFixture()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])

        fixture.clock.advance(by: MonitoringSnapshot.lifetime - 1)
        let fresh = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(fresh)

        fixture.clock.advance(by: 1)
        let expired = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(expired, "Three minutes without news from the server: its plan is not presented as current")

        _ = try await fixture.session.refresh()
        let renewed = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(renewed)
    }

    func testTheProviderShowsTheServersPlanAndItsHorizon() async throws {
        let fixture = makeFixture()
        fixture.server.limits = #"{"planningHorizonMinutes":600,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50}"#
        let client = BackendClient(configuration: fixture.configuration, transport: fixture.transport, clock: fixture.clock)
        let provider = BackendCommuteProvider(client: client, clock: fixture.clock, monitoredTrips: fixture.session, describe: { _ in "LATER" })
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])

        let answer = try await provider.estimateCommute(for: request(for: trip()))
        guard case .recommendation(let recommendation) = answer else {
            return XCTFail("Expected the monitored plan")
        }
        XCTAssertTrue(recommendation.isMonitored)
        let verdicts = await requests(fixture, "POST", "/verdict")
        XCTAssertTrue(verdicts.isEmpty, "The server's own plan needs no second opinion")

        // 10 hours 30 minutes ahead: inside the default reach, beyond the server's 10 hours.
        let far = trip(labID, title: "Lab", arriveBy: now.addingTimeInterval(630 * 60))
        let farAnswer = try await provider.estimateCommute(for: request(for: far))
        XCTAssertEqual(farAnswer, .notYet(message: "The traffic forecast reaches about 10 hours ahead. A leave-home time will appear after LATER.", askAgainAt: now.addingTimeInterval(30 * 60)))
        let horizon = await fixture.session.planningHorizon()
        XCTAssertEqual(horizon, 600 * 60)
    }

    // MARK: One trip

    func testRefreshingOneTripUsesOneEncodedPathSegment() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        monitorClass(fixture)

        let state = try await fixture.session.refreshTrip(trip().id)
        XCTAssertEqual(state?.phase, .monitoring)
        XCTAssertEqual(state?.plan?.departAt, TestFixtures.date(2026, 10, 26, 7, 5))
        let sent = try await lastRequest(fixture)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.url.absoluteString, "https://backend.example/trips/6F9619FF-8B86-D011-B42D-00C04FC964FF%402026-10-26", "The at sign is percent-encoded, so the id is exactly one segment")

        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(answer, "The newer state of that one trip is what the session answers from")

        let unknown = try await fixture.session.refreshTrip(occurrenceID(labID))
        XCTAssertNil(unknown, "A trip the server does not hold is simply not there")
    }

    func testIveLeftSendsTheArrivalTimeAndEndsMonitoring() async throws {
        let fixture = makeFixture()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])

        let result = await fixture.session.markDeparted(trip().id, arriveBy: arrival)
        guard case .success(let state) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(state.phase, .departed)
        XCTAssertNil(state.plan)
        let sent = try await lastRequest(fixture)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://backend.example/trips/6F9619FF-8B86-D011-B42D-00C04FC964FF%402026-10-26/departed")
        XCTAssertEqual(sent.jsonObject().keys.sorted(), ["arriveBy"])
        XCTAssertEqual(sent.string("arriveBy"), "2026-10-26T15:15:00.000Z")

        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(answer, "A trip the user left is no longer answered from the server's plan")

        // Saying it twice is harmless.
        let again = await fixture.session.markDeparted(trip().id, arriveBy: arrival)
        guard case .success = again else {
            return XCTFail("Expected success again, got \(again)")
        }
    }

    func testIveLeftForARescheduledTripChangesNothing() async throws {
        let fixture = makeFixture()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])

        let stale = await fixture.session.markDeparted(trip().id, arriveBy: arrival.addingTimeInterval(-30 * 60))
        XCTAssertEqual(stale, .failure(.superseded), "An old notification cannot end the monitoring of the new time")
        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(answer, "Monitoring continues")

        let unknown = await fixture.session.markDeparted(occurrenceID(labID), arriveBy: arrival)
        XCTAssertEqual(unknown, .failure(.notMonitored))

        fixture.server.failNext("POST", "/trips/\(trip().id.rawValue)/departed", with: .urlError(.notConnectedToInternet))
        let offline = await fixture.session.markDeparted(trip().id, arriveBy: arrival)
        XCTAssertEqual(offline, .failure(.offline))
    }

    // MARK: Failures

    func testFailuresAreToldApartByTheBodysCodeFirst() async throws {
        let cases: [(ScriptedReply, TripMonitoringFailure)] = [
            (.http(status: 503, body: TestBackend.errorBody("monitoring_unavailable", "Trip monitoring is not set up on this server.")), .unavailableOnServer),
            (.http(status: 404, body: #"{"message":"Route PUT:/trips not found","error":"Not Found","statusCode":404}"#), .unavailableOnServer),
            (.http(status: 404, body: "Not Found"), .unavailableOnServer),
            (.http(status: 400, body: TestBackend.errorBody("bad_request", "A trip's arrival time is more than 8 days away.")), .rejected(message: "A trip's arrival time is more than 8 days away.")),
            (.http(status: 400, body: "nonsense"), .rejected(message: "The request was not acceptable.")),
            (.http(status: 429, body: TestBackend.errorBody("rate_limited", "Too many new devices from this network. Try again later.")), .server(status: 429)),
            (.http(status: 503, body: TestBackend.errorBody("registrations_closed", "This server is not taking new devices right now. Try again later.")), .server(status: 503)),
            (.http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "The server cannot reach its database right now. Try again shortly.")), .server(status: 503)),
            (.http(status: 502, body: "Bad Gateway"), .server(status: 502)),
            (.http(status: 200, body: "not json"), .invalidResponse),
            (.urlError(.timedOut), .timedOut),
            (.urlError(.notConnectedToInternet), .offline),
            (.urlError(.cannotFindHost), .offline),
            (.urlError(.secureConnectionFailed), .invalidResponse),
            (.otherError, .offline)
        ]
        for (reply, expected) in cases {
            let fixture = makeFixture()
            _ = try await fixture.session.synchronize([trip()])
            fixture.server.failNext("PUT", "/trips", with: reply)
            let syncFailure = await failure { _ = try await fixture.session.synchronize([self.trip(self.labID, title: "Lab")]) }
            XCTAssertEqual(syncFailure, expected, "\(reply)")
        }
    }

    func testTheTwo503CodesMeanDifferentThings() async throws {
        // "temporarily_unavailable": try again shortly. Always transient, whatever the status.
        let busy = BackendReply(status: 503, data: Data(), errorCode: "temporarily_unavailable", errorMessage: nil)
        XCTAssertEqual(BackendSession.failure(for: busy), .server(status: 503))
        XCTAssertTrue(BackendSession.failure(for: busy).isTransient, "Retried with the normal backoff")
        let oddStatus = BackendReply(status: 404, data: Data(), errorCode: "temporarily_unavailable", errorMessage: nil)
        XCTAssertTrue(BackendSession.failure(for: oddStatus).isTransient, "Never mistaken for a server without the feature")
        XCTAssertNotEqual(BackendSession.failure(for: oddStatus), .unavailableOnServer)

        // "monitoring_unavailable": the server's trip tables are not set up yet. Not retried on
        // the ticks, and worded as "does not support".
        let notSetUp = BackendReply(status: 503, data: Data(), errorCode: "monitoring_unavailable", errorMessage: nil)
        XCTAssertEqual(BackendSession.failure(for: notSetUp), .unavailableOnServer)
        XCTAssertFalse(TripMonitoringFailure.unavailableOnServer.isTransient)
        XCTAssertEqual(MonitoringText.failureSentence(.unavailableOnServer), "This server does not support trip monitoring yet.")

        // A bare gateway 503 without a JSON body is a server problem like any other.
        let gateway = BackendReply(status: 503, data: Data(), errorCode: nil, errorMessage: nil)
        XCTAssertEqual(BackendSession.failure(for: gateway), .server(status: 503))
    }

    func testAServerWithoutTheFeatureIsNotRegisteredWith() async throws {
        let clock = ManualWallClock(now)
        let transport = ScriptedHTTPTransport(.http(status: 404, body: #"{"message":"Route POST:/devices not found","error":"Not Found","statusCode":404}"#))
        let credentials = InMemoryCredentialStore()
        let session = BackendSession(client: TestBackend.client(transport: transport, clock: clock), credentials: credentials, push: nil, clock: clock)

        let syncFailure = await failure { _ = try await session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .unavailableOnServer)
        XCTAssertFalse(TripMonitoringFailure.unavailableOnServer.isTransient, "Not retried by itself")
        let origins = await credentials.origins()
        XCTAssertTrue(origins.isEmpty)
    }

    func testAnUnknownPhaseOrActionIsAnUnreadableAnswer() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])

        fixture.server.setPhase(trip().id.rawValue, "hibernating")
        let phaseFailure = await failure { _ = try await fixture.session.refresh() }
        XCTAssertEqual(phaseFailure, .invalidResponse)

        fixture.server.setPhase(trip().id.rawValue, "monitoring", recommendation: TestBackend.recommendationBody(
            action: "teleport",
            departAt: TestFixtures.date(2026, 10, 26, 7, 5),
            arriveAt: TestFixtures.date(2026, 10, 26, 7, 50),
            evaluatedAt: now
        ))
        let actionFailure = await failure { _ = try await fixture.session.refresh() }
        XCTAssertEqual(actionFailure, .invalidResponse)
    }

    func testWhichFailuresAreRetriedAutomatically() {
        let transient: [TripMonitoringFailure] = [.offline, .timedOut, .server(status: 500), .server(status: 503), .server(status: 429)]
        let lasting: [TripMonitoringFailure] = [
            .notConfigured, .invalidResponse, .unavailableOnServer, .rejected(message: "No."), .reregistered,
            .notRegistered, .superseded, .notMonitored, .credentialStorage, .server(status: 401), .server(status: 409)
        ]
        for failure in transient {
            XCTAssertTrue(failure.isTransient, "\(failure)")
        }
        for failure in lasting {
            XCTAssertFalse(failure.isTransient, "\(failure)")
        }
    }

    // MARK: Removal and addresses

    func testUnregisteringDeletesTheDeviceAndForgetsTheCredential() async throws {
        let fixture = makeFixture()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])
        let stored = try await credential(fixture.credentials)

        try await fixture.session.unregister(from: nil)

        let sent = try await lastRequest(fixture)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.url.absoluteString, "https://backend.example/devices/me")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(stored.token)")
        XCTAssertNil(sent.body, "Nothing is sent with the removal")
        XCTAssertEqual(fixture.server.deviceCount, 0)
        let origins = await fixture.credentials.origins()
        XCTAssertTrue(origins.isEmpty)
        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(answer, "Nothing is answered for a server that was told to forget the trips")

        // Removing again has nothing to do.
        let count = await fixture.transport.requestCount()
        try await fixture.session.unregister(from: nil)
        let after = await fixture.transport.requestCount()
        XCTAssertEqual(after, count)
    }

    func testADeviceTheServerAlreadyLostCountsAsRemoved() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.loseDevices()

        try await fixture.session.unregister(from: nil)
        let origins = await fixture.credentials.origins()
        XCTAssertTrue(origins.isEmpty)
        XCTAssertEqual(fixture.server.registrationCount, 1, "Never registered just to be removed")
    }

    func testAFailedRemovalKeepsTheCredentialForLater() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.failNext("DELETE", "/devices/me", with: .urlError(.notConnectedToInternet))

        let removal = await failure { try await fixture.session.unregister(from: nil) }
        XCTAssertEqual(removal, .offline)
        let origins = await fixture.credentials.origins()
        XCTAssertEqual(origins, ["https://backend.example"])

        try await fixture.session.unregister(from: nil)
        XCTAssertEqual(fixture.server.deviceCount, 0)
    }

    func testOnlyAConfirmedRemovalForgetsTheCredential() async throws {
        // None of these answers says that the device and its trips are gone, so each keeps the
        // credential and reports the removal as failed.
        let unconfirmed: [(ScriptedReply, TripMonitoringFailure)] = [
            (.http(status: 503, body: TestBackend.errorBody("monitoring_unavailable", "Trip monitoring is not set up on this server.")), .unavailableOnServer),
            (.http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "The server cannot reach its database right now. Try again shortly.")), .server(status: 503)),
            (.http(status: 500, body: TestBackend.errorBody("internal", "Something went wrong.")), .server(status: 500)),
            (.http(status: 404, body: TestBackend.errorBody("not_found", "No such device.")), .server(status: 404)),
            (.http(status: 502, body: "Bad Gateway"), .server(status: 502)),
            (.http(status: 200, body: "<html>Sign in to this network</html>"), .invalidResponse),
            (.urlError(.timedOut), .timedOut)
        ]
        for (reply, expected) in unconfirmed {
            let fixture = makeFixture()
            _ = try await fixture.session.synchronize([trip()])
            fixture.server.failNext("DELETE", "/devices/me", with: reply)

            let removal = await failure { try await fixture.session.unregister(from: nil) }
            XCTAssertEqual(removal, expected, "\(reply)")
            let origins = await fixture.credentials.origins()
            XCTAssertEqual(origins, ["https://backend.example"], "\(reply): the credential is kept, so the removal can be tried again")
            XCTAssertEqual(fixture.server.deviceCount, 1, "The server still holds the device and its trips")
            XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])

            // The next attempt, answered properly, removes it.
            try await fixture.session.unregister(from: nil)
            XCTAssertEqual(fixture.server.deviceCount, 0, "\(reply)")
            let remaining = await fixture.credentials.origins()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testAServerThatPredatesTheEndpointsHasNothingToRemove() async throws {
        // A 404 that is not the API's own: this server has no device endpoints at all, so it
        // holds nothing of this installation and the credential is of no use.
        let bodies = [#"{"message":"Route DELETE:/devices/me not found","error":"Not Found","statusCode":404}"#, "Not Found"]
        for body in bodies {
            let fixture = makeFixture()
            _ = try await fixture.session.synchronize([trip()])
            fixture.server.failNext("DELETE", "/devices/me", with: .http(status: 404, body: body))

            try await fixture.session.unregister(from: nil)
            let origins = await fixture.credentials.origins()
            XCTAssertTrue(origins.isEmpty, body)
        }
    }

    // MARK: Withdrawing trips without removing the device

    func testWithdrawingTripsSendsAnEmptySnapshotAndNothingElse() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)

        // Without a credential there is nothing to withdraw, and no device is made for it.
        try await fixture.session.withdrawTrips()
        var count = await fixture.transport.requestCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(fixture.server.registrationCount, 0)

        _ = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue])
        // A push token arrives; a synchronization would report it now.
        _ = await fixture.session.updateDeviceToken(Data(repeating: 0xCD, count: 32))
        count = await fixture.transport.requestCount()

        try await fixture.session.withdrawTrips()
        let sent = await fixture.transport.requests.dropFirst(count).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(sent, ["PUT /trips"], "Only the empty snapshot: no registration, and no push token for a user who is opting out")
        let body = try await lastRequest(fixture, "PUT", "/trips").jsonObject()
        XCTAssertEqual((body["trips"] as? [Any])?.count, 0)
        XCTAssertEqual(body["revision"] as? Int, 2, "A new body, so a new revision")
        XCTAssertTrue(fixture.server.heldTripIDs.isEmpty, "The server monitors nothing any more")
        XCTAssertEqual(fixture.server.deviceCount, 1, "The device entry stays until it is removed")
        XCTAssertNil(fixture.server.storedPushToken)
        XCTAssertEqual(fixture.server.registrationCount, 1)
        let answer = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(answer, "Nothing is answered from a server that was told to stop")

        // Withdrawing again resends the same body under the same revision.
        try await fixture.session.withdrawTrips()
        let again = try await lastRequest(fixture, "PUT", "/trips").jsonObject()
        XCTAssertEqual(again["revision"] as? Int, 2)
    }

    func testWithdrawingFromAServerThatLostTheDeviceRegistersNothing() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let fixture = makeFixture(push: push)
        _ = await fixture.session.updateDeviceToken(Data(repeating: 0xCD, count: 32))
        _ = try await fixture.session.synchronize([trip()])
        // The removal reached the server but its answer was lost: the device is gone there.
        fixture.server.loseDevices()
        let count = await fixture.transport.requestCount()

        try await fixture.session.withdrawTrips()
        let sent = await fixture.transport.requests.dropFirst(count).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(sent, ["PUT /trips"], "The 401 is the answer: nothing is left there")
        XCTAssertEqual(fixture.server.registrationCount, 1, "No new device is registered just to withdraw")
        XCTAssertEqual(fixture.server.deviceCount, 0)
        let origins = await fixture.credentials.origins()
        XCTAssertTrue(origins.isEmpty, "The credential the server no longer knows is dropped")
    }

    func testAFailedWithdrawalOfTripsIsReportedAndKeepsTheCredential() async throws {
        let fixture = makeFixture()
        _ = try await fixture.session.synchronize([trip()])
        fixture.server.failNext("PUT", "/trips", with: .http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "Try again shortly.")))

        let withdrawal = await failure { try await fixture.session.withdrawTrips() }
        XCTAssertEqual(withdrawal, .server(status: 503))
        XCTAssertEqual(fixture.server.heldTripIDs, [trip().id.rawValue], "The server still monitors the trip, and the app was told so")
        let origins = await fixture.credentials.origins()
        XCTAssertEqual(origins, ["https://backend.example"])

        try await fixture.session.withdrawTrips()
        XCTAssertTrue(fixture.server.heldTripIDs.isEmpty)
    }

    func testAServerLeftBehindIsNamedUntilItConfirmedTheRemoval() async throws {
        let fixture = makeFixture()
        var left = await fixture.session.serversLeftBehind()
        XCTAssertEqual(left, [], "Nothing is registered anywhere yet")
        _ = try await fixture.session.synchronize([trip()])
        left = await fixture.session.serversLeftBehind()
        XCTAssertEqual(left, [], "The server in use is not left behind")

        // The address changes: the old server still has a device of this installation.
        fixture.configuration.setOverride(try XCTUnwrap(URL(string: "http://localhost:3000")))
        left = await fixture.session.serversLeftBehind()
        XCTAssertEqual(left, [TestBackend.baseURL])

        // A restart: a new session over the same credential store names it again.
        let restarted = BackendSession(
            client: BackendClient(configuration: fixture.configuration, transport: fixture.transport, clock: fixture.clock),
            credentials: fixture.credentials,
            push: nil,
            clock: fixture.clock
        )
        left = await restarted.serversLeftBehind()
        XCTAssertEqual(left, [TestBackend.baseURL], "Remembered by the credential that is still stored for it")

        // A removal that fails keeps it on the list; one that succeeds takes it off.
        fixture.server.failNext("DELETE", "/devices/me", with: .urlError(.notConnectedToInternet))
        let failed = await failure { try await restarted.unregister(from: TestBackend.baseURL) }
        XCTAssertEqual(failed, .offline)
        left = await restarted.serversLeftBehind()
        XCTAssertEqual(left, [TestBackend.baseURL])
        try await restarted.unregister(from: TestBackend.baseURL)
        left = await restarted.serversLeftBehind()
        XCTAssertEqual(left, [])

        // A store that cannot be read names nothing rather than guessing.
        let unreadable = BackendSession(client: TestBackend.client(transport: fixture.transport, clock: fixture.clock), credentials: FailingCredentialStore(), push: nil, clock: fixture.clock)
        let none = await unreadable.serversLeftBehind()
        XCTAssertEqual(none, [])
    }

    func testEveryServerHasItsOwnCredentialAndState() async throws {
        let fixture = makeFixture()
        monitorClass(fixture)
        _ = try await fixture.session.synchronize([trip()])
        let first = try await credential(fixture.credentials)

        let other = try XCTUnwrap(URL(string: "http://localhost:3000"))
        fixture.configuration.setOverride(other)
        let afterSwitch = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNil(afterSwitch, "Nothing from the old server is shown under the new address")
        let horizon = await fixture.session.planningHorizon()
        XCTAssertNil(horizon)

        _ = try await fixture.session.synchronize([trip()])
        XCTAssertEqual(fixture.server.registrationCount, 2, "The new server gets a device of its own")
        let second = try await credential(fixture.credentials, "http://localhost:3000")
        XCTAssertNotEqual(second.token, first.token)
        XCTAssertEqual(second.revision, 1, "Revisions are per server")
        let origins = await fixture.credentials.origins()
        XCTAssertEqual(origins, ["http://localhost:3000", "https://backend.example"])
        let sent = try await lastRequest(fixture, "PUT", "/trips")
        XCTAssertEqual(sent.url.absoluteString, "http://localhost:3000/trips")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(second.token)", "A credential is never sent to another server")

        // The server left behind is told to forget this installation, at its own address.
        try await fixture.session.unregister(from: TestBackend.baseURL)
        let removal = try await lastRequest(fixture)
        XCTAssertEqual(removal.url.absoluteString, "https://backend.example/devices/me")
        XCTAssertEqual(removal.headers["Authorization"], "Bearer \(first.token)")
        let remaining = await fixture.credentials.origins()
        XCTAssertEqual(remaining, ["http://localhost:3000"])
        let stillAnswers = try await fixture.session.answer(for: request(for: trip()))
        XCTAssertNotNil(stillAnswers, "Removing the old server's device leaves the one in use alone")
    }

    func testAnAnswerFromTheOldAddressIsDropped() async throws {
        let clock = ManualWallClock(now)
        let server = FakeTripServer(clock: clock)
        let gate = HeldTransport(responder: server.responder)
        let configuration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let client = BackendClient(configuration: configuration, transport: gate, clock: clock)
        let credentials = InMemoryCredentialStore()
        let session = BackendSession(client: client, credentials: credentials, push: nil, clock: clock)
        server.setPhase(trip().id.rawValue, "monitoring", recommendation: TestBackend.recommendationBody(
            departAt: TestFixtures.date(2026, 10, 26, 7, 5),
            arriveAt: TestFixtures.date(2026, 10, 26, 7, 50),
            evaluatedAt: now
        ))

        let call = Task { try await session.synchronize([self.trip()]) }
        let arrived = await gate.waitForHeldRequests(1)
        XCTAssertTrue(arrived)
        // The address changes while the request to the old server is under way.
        configuration.setOverride(try XCTUnwrap(URL(string: "http://localhost:3000")))
        await gate.releaseAll()

        do {
            _ = try await call.value
            XCTFail("An answer from the old address must not be returned as the current state")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let urls = await gate.requests.map(\.url.absoluteString)
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("https://backend.example/") }, "Every request of that call stayed with the server it started for: \(urls)")
        let answer = try await session.answer(for: request(for: trip()))
        XCTAssertNil(answer)
    }

    func testOriginsTellServersApart() throws {
        func origin(_ text: String) throws -> String? {
            BackendSession.origin(of: try XCTUnwrap(URL(string: text)))
        }
        XCTAssertEqual(try origin("https://Backend.Example"), "https://backend.example")
        XCTAssertEqual(try origin("https://backend.example:443"), "https://backend.example", "The default port is not part of the name")
        XCTAssertEqual(try origin("https://backend.example:8443"), "https://backend.example:8443")
        XCTAssertEqual(try origin("http://backend.example"), "http://backend.example", "Another scheme is another origin")
        XCTAssertEqual(try origin("http://localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(try origin("http://192.168.1.20:3000/"), "http://192.168.1.20:3000")
        XCTAssertEqual(try origin("http://[::1]:3000"), "http://[::1]:3000")
        XCTAssertNil(try origin("mailto:someone"))
    }

    func testACredentialThatCannotBeStoredStopsBeforeAnythingIsSent() async throws {
        let clock = ManualWallClock(now)
        let server = FakeTripServer(clock: clock)
        let transport = ScriptedHTTPTransport(responder: server.responder)
        let session = BackendSession(client: TestBackend.client(transport: transport, clock: clock), credentials: FailingCredentialStore(), push: nil, clock: clock)

        let syncFailure = await failure { _ = try await session.synchronize([self.trip()]) }
        XCTAssertEqual(syncFailure, .credentialStorage)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0, "Without the stored credential state, nothing is registered or sent")
    }
}

/// Credential store whose every call fails, like a Keychain that cannot be read.
private struct FailingCredentialStore: CredentialStoring {
    func load(origin: String) async throws -> StoredCredential? {
        throw TestStoreError()
    }

    func save(_ credential: StoredCredential, origin: String) async throws {
        throw TestStoreError()
    }

    func clear(origin: String) async throws {
        throw TestStoreError()
    }

    func origins() async throws -> [String] {
        throw TestStoreError()
    }
}
