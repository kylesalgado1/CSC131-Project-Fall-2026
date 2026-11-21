import XCTest
@testable import WaitItOutUX

/// Stage S2: the device and trip shapes on the wire, decoded from bodies shaped exactly like
/// the real backend's and mapped explicitly to the app's own types; and the trips the app
/// sends, which are valid by construction.
final class TripWireTests: XCTestCase {
    private let now = TestFixtures.date(2026, 10, 26, 6)
    private let arrival = TestFixtures.date(2026, 10, 26, 8, 15)
    private let departure = TestFixtures.date(2026, 10, 26, 7, 5)
    private let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-10-26"

    private func decodeTrip(_ body: String) throws -> MonitoredTripState? {
        let wire = try BackendJSON.makeDecoder().decode(WireTripState.self, from: Data(body.utf8))
        return try BackendSession.tripState(from: wire)
    }

    // MARK: Trip states

    func testAMonitoredTripDecodesWithEveryField() throws {
        let body = TestBackend.tripStateBody(
            id: id,
            arriveBy: arrival,
            phase: "monitoring",
            recommendation: TestBackend.recommendationBody(
                departAt: departure,
                arriveAt: TestFixtures.date(2026, 10, 26, 7, 50),
                evaluatedAt: now,
                source: #"{"baseline":"pems","fallback":true,"live":false}"#
            ),
            startsAt: TestFixtures.date(2026, 10, 26, 5, 5),
            startedAt: TestFixtures.date(2026, 10, 26, 5, 6),
            headsUpAt: TestFixtures.date(2026, 10, 26, 5, 35),
            headsUpSentAt: TestFixtures.date(2026, 10, 26, 5, 36),
            nextCheckAt: TestFixtures.date(2026, 10, 26, 6, 5),
            lastAlert: #"{"kind":"heads_up","status":"sent","at":"2026-10-26T12:36:00.000Z"}"#,
            lastError: #"{"code":"budget_exhausted","at":"2026-10-26T12:50:00.000Z"}"#
        )
        let trip = try XCTUnwrap(try decodeTrip(body))

        XCTAssertEqual(trip.id.rawValue, id)
        XCTAssertEqual(trip.arriveBy, arrival)
        XCTAssertEqual(trip.phase, .monitoring)
        XCTAssertEqual(trip.monitoringStartsAt, TestFixtures.date(2026, 10, 26, 5, 5))
        XCTAssertEqual(trip.monitoringStartedAt, TestFixtures.date(2026, 10, 26, 5, 6))
        XCTAssertEqual(trip.headsUpAt, TestFixtures.date(2026, 10, 26, 5, 35))
        XCTAssertEqual(trip.headsUpSentAt, TestFixtures.date(2026, 10, 26, 5, 36))
        XCTAssertNil(trip.leaveAlertSentAt)
        XCTAssertEqual(trip.endsAt, arrival)
        XCTAssertEqual(trip.nextCheckAt, TestFixtures.date(2026, 10, 26, 6, 5))
        XCTAssertEqual(trip.lastAlert, TripAlert(kind: .headsUp, status: .sent, at: TestFixtures.date(2026, 10, 26, 5, 36), reason: nil))
        XCTAssertEqual(trip.lastErrorCode, "budget_exhausted")
        XCTAssertEqual(trip.lastErrorAt, TestFixtures.date(2026, 10, 26, 5, 50))
        XCTAssertNil(trip.noPlanReason)
        XCTAssertNil(trip.planAvailableAt)

        let plan = try XCTUnwrap(trip.plan)
        XCTAssertEqual(plan.advice, .leaveLater)
        XCTAssertEqual(plan.departAt, departure)
        XCTAssertEqual(plan.arriveAt, TestFixtures.date(2026, 10, 26, 7, 50))
        XCTAssertEqual(plan.driveMinutes, 45)
        XCTAssertEqual(plan.reason, "Leaving at 7:05 AM gets you there with 25 minutes to spare.")
        XCTAssertEqual(plan.confidence, .high)
        XCTAssertEqual(plan.confidenceReason, "Based on plenty of historical data and live traffic.")
        XCTAssertEqual(plan.notes, [])
        XCTAssertNil(plan.lateBy)
        XCTAssertEqual(plan.margin, 25 * 60)
        XCTAssertEqual(plan.evaluatedAt, now)
        XCTAssertEqual(plan.source, RecommendationSource(baseline: .pems, usedFallback: true, hasLiveTraffic: false))
        XCTAssertFalse(plan.isStale)
    }

    func testAScheduledTripAndATripWithoutAPlanDecode() throws {
        let scheduled = try XCTUnwrap(try decodeTrip(TestBackend.tripStateBody(
            id: id,
            arriveBy: arrival.addingTimeInterval(86_400),
            phase: "scheduled",
            planAvailableAt: arrival.addingTimeInterval(86_400 - 690 * 60)
        )))
        XCTAssertEqual(scheduled.phase, .scheduled)
        XCTAssertNil(scheduled.plan)
        XCTAssertEqual(scheduled.planAvailableAt, arrival.addingTimeInterval(86_400 - 690 * 60))
        XCTAssertNil(scheduled.lastAlert)
        XCTAssertNil(scheduled.lastErrorCode)

        let waiting = try XCTUnwrap(try decodeTrip(TestBackend.tripStateBody(
            id: id,
            arriveBy: arrival,
            phase: "planning",
            noPlanReason: "Your deadline is far away, so there is no rush."
        )))
        XCTAssertEqual(waiting.phase, .planning)
        XCTAssertEqual(waiting.noPlanReason, "Your deadline is far away, so there is no rush.")
    }

    func testEveryPhaseActionAndAlertSpellingIsMappedExplicitly() throws {
        let phases: [(String, TripPhase)] = [
            ("scheduled", .scheduled), ("planning", .planning), ("planned", .planned),
            ("monitoring", .monitoring), ("departed", .departed), ("ended", .ended)
        ]
        for (text, phase) in phases {
            let trip = try decodeTrip(TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: text))
            XCTAssertEqual(trip?.phase, phase, text)
        }
        XCTAssertThrowsError(try decodeTrip(TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "Monitoring")), "Phases are matched exactly as the backend spells them") {
            XCTAssertEqual($0 as? TripMonitoringFailure, .invalidResponse)
        }

        let actions: [(String, DepartureAdvice)] = [("leave_now", .leaveNow), ("wait", .wait), ("leave_later", .leaveLater)]
        for (text, advice) in actions {
            let body = TestBackend.tripStateBody(
                id: id,
                arriveBy: arrival,
                phase: "monitoring",
                recommendation: TestBackend.recommendationBody(action: text, departAt: departure, arriveAt: arrival, confidence: "low", lateByMinutes: text == "leave_now" ? 12 : nil, evaluatedAt: now, stale: true)
            )
            let plan = try XCTUnwrap(try decodeTrip(body)?.plan)
            XCTAssertEqual(plan.advice, advice, text)
            XCTAssertEqual(plan.confidence, .low, "Confidence is matched in any letter case")
            XCTAssertEqual(plan.lateBy, text == "leave_now" ? 12 * 60 : nil)
            XCTAssertTrue(plan.isStale)
        }
        let noRush = TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "planned", recommendation: TestBackend.recommendationBody(action: "no_rush", departAt: departure, arriveAt: arrival, evaluatedAt: now))
        XCTAssertThrowsError(try decodeTrip(noRush), "A recommendation always carries a departure, so no other action is one") {
            XCTAssertEqual($0 as? TripMonitoringFailure, .invalidResponse)
        }

        let alerts: [(String, String, TripAlert.Kind, TripAlert.Status)] = [
            ("heads_up", "queued", .headsUp, .queued), ("update", "sent", .update, .sent),
            ("leave_now", "dropped", .leaveNow, .dropped), ("late", "failed", .late, .failed)
        ]
        for (kind, status, expectedKind, expectedStatus) in alerts {
            let alert = #"{"kind":"\#(kind)","status":"\#(status)","at":"2026-10-26T12:36:00.000Z","reason":"BadDeviceToken"}"#
            let trip = try decodeTrip(TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "monitoring", lastAlert: alert))
            XCTAssertEqual(trip?.lastAlert, TripAlert(kind: expectedKind, status: expectedStatus, at: TestFixtures.date(2026, 10, 26, 5, 36), reason: "BadDeviceToken"))
        }
        let unknownAlert = #"{"kind":"digest","status":"sent","at":"2026-10-26T12:36:00.000Z"}"#
        let tolerant = try decodeTrip(TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "monitoring", lastAlert: unknownAlert))
        XCTAssertNotNil(tolerant, "An alert kind the app does not know is not a failure")
        XCTAssertNil(tolerant?.lastAlert)
    }

    func testAnIdThatIsNotAnOccurrenceIsNotTheAppsTrip() throws {
        let foreign = try decodeTrip(TestBackend.tripStateBody(id: "something-else", arriveBy: arrival, phase: "planning"))
        XCTAssertNil(foreign)
    }

    // MARK: Whole answers

    func testASyncAnswerDecodesWithAndWithoutTheNewerFields() throws {
        let full = TestBackend.syncBody(
            revision: 7,
            applied: true,
            serverTime: now,
            trips: [TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "planning")],
            push: #"{"configured":true,"registered":false,"authorized":true,"lastFailure":{"reason":"BadDeviceToken","at":"2026-10-26T12:00:00.000Z"}}"#,
            monitor: #"{"enabled":true,"dependable":false,"lastTickAt":"2026-10-26T12:58:00Z"}"#,
            limits: #"{"planningHorizonMinutes":690,"monitorLeadMinutes":60,"headsUpLeadMinutes":45,"meaningfulShiftMinutes":10,"maxTrips":25}"#
        )
        let response = try BackendJSON.makeDecoder().decode(WireSyncResponse.self, from: Data(full.utf8))
        XCTAssertEqual(response.revision, 7)
        XCTAssertEqual(response.applied, true)
        XCTAssertEqual(response.serverTime, now)
        XCTAssertEqual(response.trips.map(\.id), [id])
        XCTAssertEqual(response.push?.lastFailure?.reason, "BadDeviceToken")
        XCTAssertEqual(response.monitor?.lastTickAt, TestFixtures.date(2026, 10, 26, 5, 58), "Dates are read with or without fractional seconds")
        XCTAssertEqual(
            BackendSession.limits(from: response.limits),
            MonitoringLimits(planningHorizon: 690 * 60, monitorLead: 60 * 60, headsUpLead: 45 * 60, meaningfulShift: 10 * 60, maxTrips: 25)
        )

        // An answer without the optional parts still decodes; the mapper fills in the fallback.
        let bare = #"{"revision":1,"serverTime":"2026-10-26T13:00:00.000Z","trips":[]}"#
        let minimal = try BackendJSON.makeDecoder().decode(WireSyncResponse.self, from: Data(bare.utf8))
        XCTAssertNil(minimal.applied)
        XCTAssertNil(minimal.push)
        XCTAssertNil(minimal.monitor)
        XCTAssertEqual(BackendSession.limits(from: minimal.limits), .fallback)
        XCTAssertEqual(
            BackendSession.limits(from: WireLimits(planningHorizonMinutes: -5, monitorLeadMinutes: .nan, headsUpLeadMinutes: 0, meaningfulShiftMinutes: nil, maxTrips: 0)),
            .fallback,
            "Unusable numbers are not adopted"
        )
        XCTAssertThrowsError(try BackendJSON.makeDecoder().decode(WireSyncResponse.self, from: Data(#"{"revision":1,"trips":[]}"#.utf8)), "Without the server's time a snapshot cannot be dated")
    }

    func testRegistrationDetailAndDepartedAnswersDecode() throws {
        let registration = TestBackend.object([
            #""deviceId":"0a0a0a0a-0000-4000-8000-000000000001""#,
            #""token":"0a0a0a0a-0000-4000-8000-000000000001.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ""#,
            #""limits":\#(TestBackend.limitsBody)"#
        ])
        let registered = try BackendJSON.makeDecoder().decode(WireRegistration.self, from: Data(registration.utf8))
        XCTAssertEqual(registered.deviceId, "0a0a0a0a-0000-4000-8000-000000000001")
        XCTAssertTrue(BackendSession.isUsableToken(registered.token))
        XCTAssertFalse(BackendSession.isUsableToken(""))
        XCTAssertFalse(BackendSession.isUsableToken("has space"))
        XCTAssertFalse(BackendSession.isUsableToken("line\nbreak"))

        let trip = TestBackend.tripStateBody(id: id, arriveBy: arrival, phase: "departed")
        let detail = TestBackend.object([#""trip":\#(trip)"#, #""serverTime":"2026-10-26T13:00:00.000Z""#, #""limits":\#(TestBackend.limitsBody)"#])
        let decodedDetail = try BackendJSON.makeDecoder().decode(WireTripDetail.self, from: Data(detail.utf8))
        XCTAssertEqual(decodedDetail.trip.phase, "departed")
        let departed = try BackendJSON.makeDecoder().decode(WireDepartedResponse.self, from: Data(TestBackend.object([#""trip":\#(trip)"#]).utf8))
        XCTAssertEqual(departed.trip.id, id)

        let conflict = #"{"error":"revision_conflict","message":"A different set of trips already used this revision. Send it again with a higher one.","revision":9}"#
        XCTAssertEqual(try BackendJSON.makeDecoder().decode(WireRevisionConflict.self, from: Data(conflict.utf8)).revision, 9)
        XCTAssertEqual(try BackendJSON.makeDecoder().decode(WireErrorBody.self, from: Data(conflict.utf8)).error, "revision_conflict")
    }

    // MARK: What the app sends

    func testThePushRequestAlwaysWritesTheToken() throws {
        let encoder = BackendJSON.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let without = try encoder.encode(WirePushRequest(apnsToken: nil, environment: "production", authorized: false))
        XCTAssertEqual(String(data: without, encoding: .utf8), #"{"apnsToken":null,"authorized":false,"environment":"production"}"#, "The server requires the field, so no token is an explicit null")
        let with = try encoder.encode(WirePushRequest(apnsToken: "0aff", environment: "sandbox", authorized: true))
        XCTAssertEqual(String(data: with, encoding: .utf8), #"{"apnsToken":"0aff","authorized":true,"environment":"sandbox"}"#)
    }

    func testMonitoredTripsAreValidByConstruction() throws {
        let id = try XCTUnwrap(OccurrenceID(rawValue: self.id))
        func trip(title: String, zone: String = "America/Los_Angeles") -> MonitoredTrip {
            MonitoredTrip(
                id: id,
                title: title,
                origin: CommutePlaces.sample.home.coordinate,
                destination: CommutePlaces.sample.campus.coordinate,
                arriveBy: arrival,
                timeZoneIdentifier: zone
            )
        }
        XCTAssertEqual(trip(title: "  Lecture \n").title, "Lecture")
        XCTAssertEqual(trip(title: "").title, "Activity")
        XCTAssertEqual(trip(title: " \t ").title, "Activity", "The server uses the title in its notification text, so it is never empty")

        let long = String(repeating: "a", count: 119) + " " + String(repeating: "b", count: 50)
        let cut = trip(title: long)
        XCTAssertEqual(cut.title, String(repeating: "a", count: 119), "Cut to 120 scalars, and never ending in white space")
        XCTAssertEqual(trip(title: String(repeating: "c", count: 300)).title.unicodeScalars.count, 120)
        // Counted in Unicode scalars, as the server counts: a flag is two of them.
        let flags = String(repeating: "\u{1F1FA}\u{1F1F8}", count: 80)
        XCTAssertEqual(trip(title: flags).title.unicodeScalars.count, 120)

        XCTAssertEqual(trip(title: "Lecture").timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(trip(title: "Lecture", zone: "").timeZoneIdentifier, "UTC")
        XCTAssertEqual(trip(title: "Lecture", zone: String(repeating: "z", count: 65)).timeZoneIdentifier, "UTC")

        let wire = BackendSession.wireTrip(trip(title: " Lecture "))
        XCTAssertEqual(wire.id, self.id)
        XCTAssertEqual(wire.title, "Lecture")
        XCTAssertEqual(wire.timeZone, "America/Los_Angeles")
        let encoder = BackendJSON.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(data: try encoder.encode(wire), encoding: .utf8)
        // Exactly the fields the server uses: no start time and no destination name.
        XCTAssertEqual(text, #"{"arriveBy":"2026-10-26T15:15:00.000Z","destination":{"lat":38.561,"lng":-121.4237},"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-10-26","origin":{"lat":38.4088,"lng":-121.3716},"timeZone":"America\/Los_Angeles","title":"Lecture"}"#)
    }

    func testTheSameSetIsRecognizedByIdAndArrival() throws {
        let occurrence = try XCTUnwrap(OccurrenceID(rawValue: id))
        let sent = MonitoredTrip(
            id: occurrence,
            title: "Lecture",
            origin: CommutePlaces.sample.home.coordinate,
            destination: CommutePlaces.sample.campus.coordinate,
            arriveBy: arrival,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        func returned(_ id: String, _ arriveBy: Date) throws -> WireTripState {
            try BackendJSON.makeDecoder().decode(WireTripState.self, from: Data(TestBackend.tripStateBody(id: id, arriveBy: arriveBy, phase: "ended").utf8))
        }
        XCTAssertTrue(BackendSession.isSameSet([sent], [try returned(id, arrival)]), "Whatever its phase")
        XCTAssertFalse(BackendSession.isSameSet([sent], []))
        XCTAssertFalse(BackendSession.isSameSet([sent], [try returned(id, arrival.addingTimeInterval(60))]), "Another arrival time is another trip")
        XCTAssertFalse(BackendSession.isSameSet([sent], [try returned(id, arrival), try returned("11111111-2222-3333-4444-555555555555@2026-10-26", arrival)]))
        XCTAssertTrue(BackendSession.isSameSet([], []))
    }

    func testTheNotificationPayloadIsReadWithoutSystemTypes() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Time to leave for Lecture", "body": "Leave at 7:05 AM to arrive around 7:50 AM. Your target is 8:15 AM."], "category": "WAIT_IT_OUT_TRIP"],
            "tripId": id,
            "kind": "leave_now",
            "departAt": "2026-10-26T14:05:00.000Z",
            "arriveBy": "2026-10-26T15:15:00.000Z"
        ]
        XCTAssertEqual(TripNotificationPayload.tripID(from: userInfo), id)
        XCTAssertEqual(TripNotificationPayload.arriveBy(from: userInfo), arrival)
        XCTAssertNil(TripNotificationPayload.tripID(from: ["tripId": ""]))
        XCTAssertNil(TripNotificationPayload.tripID(from: ["tripId": 7]))
        XCTAssertNil(TripNotificationPayload.arriveBy(from: ["arriveBy": "soon"]))
        XCTAssertNil(TripNotificationPayload.arriveBy(from: [:]))
        XCTAssertEqual(TripNotificationPayload.categoryIdentifier, "WAIT_IT_OUT_TRIP")
        XCTAssertEqual(TripNotificationPayload.leftActionIdentifier, "WAIT_IT_OUT_LEFT")
        XCTAssertEqual(TripNotificationPayload.leftActionTitle, "I've left")
        XCTAssertEqual(TripNotificationPayload.action(forIdentifier: "WAIT_IT_OUT_LEFT"), .left)
        XCTAssertEqual(TripNotificationPayload.action(forIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"), .open)
    }
}
