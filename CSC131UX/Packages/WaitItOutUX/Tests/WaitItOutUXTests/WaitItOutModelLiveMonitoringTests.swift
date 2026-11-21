import XCTest
@testable import WaitItOutUX

/// Stage S2, end to end without a network: the model, the live commute provider, and the
/// backend session together, against an in-memory stand-in for the backend's device and trip
/// endpoints. The screens show the server's own plan while it monitors a trip, the app never
/// claims what the server did not acknowledge, and turning monitoring off, losing an answer,
/// or changing the server always ends with the server and the app agreeing.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The one-time class runs 9:00 to 9:50 AM with an
/// ideal arrival of 8:15 AM. Asked directly, the backend recommends leaving at 7:10 AM; the
/// monitored plan, when there is one, says 7:05 AM.
@MainActor
final class WaitItOutModelLiveMonitoringTests: XCTestCase {
    // MARK: Helpers

    private struct Stack {
        let clock: ManualWallClock
        let server: FakeTripServer
        let transport: ScriptedHTTPTransport
        let credentials: InMemoryCredentialStore
        let session: BackendSession
        let model: WaitItOutModel
    }

    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private func oneTimeClass(start: Date? = nil) -> Activity {
        let begins = start ?? pacific(2026, 10, 26, 9)
        return TestFixtures.activity(
            title: "One-time class",
            start: begins,
            end: begins.addingTimeInterval(50 * 60),
            arrival: begins.addingTimeInterval(-45 * 60)
        )
    }

    private func occurrenceID(_ activity: Activity) -> OccurrenceID {
        OccurrenceID(activityID: activity.id, date: LocalDate.of(activity.start, in: TestFixtures.pacific))
    }

    private func makeStack(activities: [Activity], remindersOn: Bool = true, push: FakePushRegistrar? = nil) -> Stack {
        let clock = ManualWallClock(pacific(2026, 10, 26, 6))
        let server = FakeTripServer(clock: clock)
        // Asked directly, the backend recommends leaving at 7:10 and arriving at 7:55.
        server.setVerdict(.http(status: 200, body: TestBackend.verdictBody(
            action: "leave_later",
            leaveNow: (pacific(2026, 10, 26, 6), pacific(2026, 10, 26, 6, 45)),
            recommended: (pacific(2026, 10, 26, 7, 10), pacific(2026, 10, 26, 7, 55)),
            marginMinutes: 20,
            generatedAt: pacific(2026, 10, 26, 6)
        )))
        let transport = ScriptedHTTPTransport(responder: server.responder)
        let configuration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL)
        let client = BackendClient(configuration: configuration, transport: transport, clock: clock)
        let credentials = InMemoryCredentialStore()
        let session = BackendSession(client: client, credentials: credentials, push: push, clock: clock)
        let provider = BackendCommuteProvider(client: client, clock: clock, monitoredTrips: session)
        let model = TestBackend.makeLiveModel(
            clock: clock,
            activities: activities,
            liveEstimator: provider,
            demoEstimator: ScriptedCommuteEstimator(minutes: 60),
            tripMonitor: session,
            configuration: configuration,
            store: InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn))
        )
        return Stack(clock: clock, server: server, transport: transport, credentials: credentials, session: session, model: model)
    }

    private func settle(_ model: WaitItOutModel) async {
        for _ in 0..<4 {
            await model.waitForDepartures()
            await model.waitForMonitoring()
            await model.waitForReminders()
        }
        await model.flushPendingSaves()
    }

    private func launch(_ stack: Stack) async {
        await stack.model.loadPreferences()
        await stack.model.loadActivities()
        await settle(stack.model)
    }

    private func tick(_ stack: Stack, after seconds: TimeInterval) async {
        stack.clock.advance(by: seconds)
        stack.model.refreshDepartures()
        await settle(stack.model)
    }

    private func sent(_ stack: Stack, _ method: String, _ path: String) async -> [RecordedRequest] {
        await stack.transport.requests.filter { $0.method == method && $0.path == path }
    }

    /// Minute ticks up to `time`, as the Map's clock makes them while the app stays open, so
    /// the server's state is read every minute on the way.
    private func runClock(_ stack: Stack, until time: Date) async {
        while stack.clock.now() < time {
            await tick(stack, after: min(60, time.timeIntervalSince(stack.clock.now())))
        }
    }

    /// The server reports the class as actively monitored, leaving at `departure`.
    private func monitor(_ stack: Stack, _ activity: Activity, departure: Date, stale: Bool = false) {
        stack.server.setPhase(
            occurrenceID(activity).rawValue,
            "monitoring",
            recommendation: TestBackend.recommendationBody(
                departAt: departure,
                arriveAt: departure.addingTimeInterval(45 * 60),
                evaluatedAt: stack.clock.now(),
                stale: stale
            )
        )
    }

    // MARK: One answer on every screen

    func testTheScreensShowTheServersPlanWhileItMonitorsTheTrip() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 5))
        await launch(stack)

        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
        let calculation = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 7, 5), "The server's own plan, not the 7:10 a direct question would get")
        XCTAssertEqual(calculation.recommendation?.isMonitored, true)
        let occurrence = try XCTUnwrap(model.occurrence(for: id))
        XCTAssertEqual(model.departureState(for: occurrence), model.departures[id]?.state)
        XCTAssertEqual(model.nextTrip(at: stack.clock.now())?.state, model.departures[id]?.state, "Map and Calendar read the same state")
        XCTAssertEqual(model.monitoringSummary(for: occurrence)?.recommendedDeparture, calculation.leaveHome, "What the alerts will say is what the screens say")
        var verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1, "Asked directly once at launch, before the server's state was known")

        // Minute ticks read the server's state and never ask a second opinion.
        await tick(stack, after: 60)
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1)
        let reads = await sent(stack, "GET", "/trips")
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))

        // The server moves the departure: the screens follow with the next read.
        monitor(stack, activity, departure: pacific(2026, 10, 26, 6, 55))
        await tick(stack, after: 60)
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, pacific(2026, 10, 26, 6, 55))
        XCTAssertEqual(model.monitoringSummary(for: id)?.recommendedDeparture, pacific(2026, 10, 26, 6, 55))

        // The server could not re-check on schedule: its plan is nobody's current plan, so the
        // screens go back to asking the backend directly instead of pinning to it.
        monitor(stack, activity, departure: pacific(2026, 10, 26, 6, 55), stale: true)
        await tick(stack, after: 60)
        let direct = try XCTUnwrap(model.departures[id]?.state.calculation, "A current answer, not a kept one: \(String(describing: model.departures[id]?.state))")
        XCTAssertEqual(direct.leaveHome, pacific(2026, 10, 26, 7, 10), "The backend's own answer to a direct question")
        XCTAssertEqual(direct.recommendation?.isMonitored, false)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2, "Asked directly once when the server's plan stopped being current")
        XCTAssertEqual(model.monitoringSummary(for: id)?.showsPlanTimes, false, "And the stale plan's times are not printed beside that answer")

        // Later reads of the same stale plan do not ask again and again.
        await tick(stack, after: 60)
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2)

        // Once the server refreshed its plan, the screens take it again.
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 0))
        await tick(stack, after: 60)
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 0))
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)
    }

    // MARK: A plan the server no longer keeps current

    /// A direct answer of the backend: leave now, arriving 45 minutes later, optionally late.
    private func leaveNowVerdict(at now: Date, lateByMinutes: Int? = nil) -> ScriptedReply {
        .http(status: 200, body: TestBackend.verdictBody(
            action: "leave_now",
            reason: lateByMinutes.map { "Leave now, you may be late by about \($0) minutes." } ?? "Traffic won't improve much in the next 3 hours.",
            leaveNow: (now, now.addingTimeInterval(45 * 60)),
            recommended: (now, now.addingTimeInterval(45 * 60)),
            lateByMinutes: lateByMinutes,
            marginMinutes: lateByMinutes == nil ? 10 : nil,
            generatedAt: now
        ))
    }

    func testAfterTheTimeToLeaveAlertTheScreensAskTheBackendDirectly() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: TestFixtures.enUS)
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 5))
        await launch(stack)
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)
        var verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1)

        // The app stays open; the server's plan is read every minute and nothing else is asked.
        await runClock(stack, until: pacific(2026, 10, 26, 7, 3))
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)

        // 7:04 on this device: the server queues its time-to-leave alert for the plan it has,
        // and from then on re-checks nothing. The plan itself is unchanged.
        stack.server.setDetails(id.rawValue, FakeTripServer.TripDetails(
            lastAlert: #"{"kind":"leave_now","status":"queued","at":"\#(TestBackend.iso(pacific(2026, 10, 26, 7, 4)))"}"#
        ))
        stack.server.setVerdict(leaveNowVerdict(at: pacific(2026, 10, 26, 7, 4)))
        await runClock(stack, until: pacific(2026, 10, 26, 7, 4))

        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2, "One direct request, although the plan did not change")
        var shown = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(shown.recommendation?.isMonitored, false, "The frozen plan is no longer the answer on screen")
        XCTAssertEqual(shown.recommendation?.advice, .leaveNow)
        XCTAssertEqual(model.monitoringSummary(for: id)?.canMarkDeparted, true, "I've Left is still offered")
        XCTAssertEqual(
            model.monitoringSummary(for: id).map { formatter.monitoringLines(for: $0, at: stack.clock.now()) },
            ["Monitoring started \(formatter.clockTime(pacific(2026, 10, 26, 6, 54))).", "Time-to-leave alert queued; not sent yet."],
            "The queued alert is said; no alert at a coming time is promised"
        )

        // The same frozen plan read again and again asks nothing more for five minutes.
        await tick(stack, after: 60)
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2)

        // Twenty minutes on the user is still at home and traffic got worse. The direct answer
        // is asked again after its five minutes and says so; the frozen plan never could.
        stack.server.setVerdict(leaveNowVerdict(at: pacific(2026, 10, 26, 7, 24), lateByMinutes: 15))
        stack.clock.set(pacific(2026, 10, 26, 7, 24))
        stack.model.refreshDepartures()
        await settle(model)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 3)
        shown = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(shown.recommendation?.lateBy, 15 * 60)
        XCTAssertEqual(
            formatter.departureTimingText(for: shown, at: stack.clock.now()),
            "Your ideal arrival is no longer reachable: leaving now you would arrive about 15 minutes late."
        )
        XCTAssertNil(formatter.recommendationReasonText(for: shown, at: stack.clock.now().addingTimeInterval(180)), "No \"to spare\" sentence for an arrival that cannot be met")
    }

    func testAPlanWhoseDepartureHasPassedIsHandedBackToTheBackend() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 5))
        await launch(stack)

        // 7:05 sharp: leaving exactly on time is still the plan.
        await runClock(stack, until: pacific(2026, 10, 26, 7, 5))
        var verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)

        // 7:06: the departure has passed and the server said nothing new (its own check is
        // late). The plan is not left on screen as the current recommendation.
        stack.server.setVerdict(leaveNowVerdict(at: pacific(2026, 10, 26, 7, 6)))
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2)
        let shown = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(shown.recommendation?.isMonitored, false)
        XCTAssertEqual(shown.recommendation?.advice, .leaveNow)
        XCTAssertEqual(shown.leaveHome, pacific(2026, 10, 26, 7, 6))

        // The server's alert arrives a minute later with the same plan: nothing is asked again.
        stack.server.setDetails(id.rawValue, FakeTripServer.TripDetails(
            leaveAlertSentAt: pacific(2026, 10, 26, 7, 7),
            lastAlert: #"{"kind":"leave_now","status":"sent","at":"\#(TestBackend.iso(pacific(2026, 10, 26, 7, 7)))"}"#
        ))
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2)
        XCTAssertEqual(model.monitoredTrips[id]?.leaveAlertSentAt, pacific(2026, 10, 26, 7, 7))
    }

    func testAServerWhoseWorkerIsOffNeverPinsTheScreensToItsPlan() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        // The server evaluated the trip once when it was sent and calls it "monitoring", but
        // nothing runs that would ever look at it again.
        stack.server.monitor = #"{"enabled":false,"dependable":false,"lastTickAt":null}"#
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 5))
        await launch(stack)

        XCTAssertEqual(model.monitorHealth?.enabled, false)
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .monitoring)
        let direct = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(direct.leaveHome, pacific(2026, 10, 26, 7, 10), "The backend's fresh answer to a direct question, not the plan nobody refreshes")
        XCTAssertEqual(direct.recommendation?.isMonitored, false)

        // It follows the ordinary refresh rhythm of a direct answer.
        for _ in 0..<14 {
            await tick(stack, after: 60)
        }
        var verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 1)
        await tick(stack, after: 60)
        verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertEqual(verdicts.count, 2, "Asked again one backend slot later")
        XCTAssertNotNil(model.departures[id]?.state.calculation, "Never the kept, out-of-date plan with a Try Again that cannot help")

        // Once the worker runs, the screens take the server's plan.
        stack.server.monitor = #"{"enabled":true,"dependable":true,"lastTickAt":null}"#
        await tick(stack, after: 60)
        XCTAssertEqual(model.departures[id]?.state.calculation?.leaveHome, pacific(2026, 10, 26, 7, 5))
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)
    }

    func testBeforeMonitoringStartsTheBackendIsAskedDirectly() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        // Planned, with a plan of its own, but nothing has been announced yet.
        stack.server.setPhase(id.rawValue, "planned", recommendation: TestBackend.recommendationBody(
            departAt: pacific(2026, 10, 26, 7, 5),
            arriveAt: pacific(2026, 10, 26, 7, 50),
            evaluatedAt: stack.clock.now()
        ))
        await launch(stack)

        let calculation = try XCTUnwrap(stack.model.departures[id]?.state.calculation)
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 7, 10), "The direct, fresh answer")
        XCTAssertEqual(calculation.recommendation?.isMonitored, false)
        XCTAssertEqual(stack.model.monitoredTrips[id]?.phase, .planned)
        XCTAssertEqual(stack.model.monitoringSummary(for: id)?.recommendedDeparture, pacific(2026, 10, 26, 7, 5))

        // The server's stored plan says 7:05 while the screens show the direct answer, 7:10.
        // The monitoring lines therefore name no clock time of the plan: two different
        // departures are never shown one above the other.
        let formatter = OccurrenceFormatter(calculator: stack.model.weekCalculator, locale: TestFixtures.enUS)
        let summary = try XCTUnwrap(stack.model.monitoringSummary(for: id))
        XCTAssertFalse(summary.showsPlanTimes)
        let lines = formatter.monitoringLines(for: summary, at: stack.clock.now())
        XCTAssertEqual(lines, [
            "Monitoring starts about 2 hours before the recommended departure.",
            "Heads-up about 90 minutes before the recommended departure.",
            "Time-to-leave alert at the recommended departure."
        ])
        XCTAssertFalse(lines.joined().contains(formatter.clockTime(pacific(2026, 10, 26, 7, 5))), "\(lines)")
    }

    func testATripBeyondTheHorizonIsScheduledWithoutSpendingARequest() async throws {
        // Wednesday's class: two days ahead, far beyond the 11.5 hours the backend plans.
        let activity = oneTimeClass(start: pacific(2026, 10, 28, 9))
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        await launch(stack)

        guard case .unavailable(.notYetPlannable(_, let askAgainAt)) = stack.model.departures[id]?.state else {
            return XCTFail("Expected a not-yet answer, got \(String(describing: stack.model.departures[id]?.state))")
        }
        XCTAssertEqual(askAgainAt, activity.idealArrival.addingTimeInterval(-690 * 60))
        let verdicts = await sent(stack, "POST", "/verdict")
        XCTAssertTrue(verdicts.isEmpty, "No traffic request for a trip the backend cannot plan yet")
        let summary = try XCTUnwrap(stack.model.monitoringSummary(for: id))
        XCTAssertEqual(summary.phase, .scheduled, "But the server already knows about it")
        XCTAssertEqual(summary.planAvailableAt, activity.idealArrival.addingTimeInterval(-690 * 60))
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue])
        await tick(stack, after: 60)
        let reads = await sent(stack, "GET", "/trips")
        XCTAssertTrue(reads.isEmpty, "Nothing is due on the server, so its state is not polled")
    }

    // MARK: Lost answers

    func testATimedOutSynchronizationIsNotClaimedAndTurningOffLeavesNothingBehind() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity], remindersOn: false)
        let model = stack.model
        await launch(stack)
        let before = await stack.transport.requests.filter { $0.path != "/verdict" }
        XCTAssertTrue(before.isEmpty, "Off, and never registered: nothing about trips is sent")

        // Turned on; the server applies the trips but its answer is lost.
        stack.server.failNext("PUT", "/trips", .afterApplying, with: .urlError(.timedOut))
        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue], "The server is monitoring the trip")
        XCTAssertEqual(model.monitoringStatus, .failed(.timedOut, lastAcknowledgedAt: nil), "And the app does not claim it")
        XCTAssertTrue(model.monitoredTrips.isEmpty)
        XCTAssertNil(model.monitoringSummary(for: id))
        XCTAssertEqual(model.monitoringDeliverySentence, "Trips could not be synchronized: the backend did not answer in time.")

        // Turned off again before any retry: the server must end up with nothing.
        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(stack.server.heldTripIDs, [])
        XCTAssertEqual(stack.server.deviceCount, 0, "The installation's data is deleted from the server")
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.monitoringWithdrawal, .none)
        let origins = await stack.credentials.origins()
        XCTAssertTrue(origins.isEmpty)
    }

    func testATimedOutSynchronizationRecoversOnTheNextTick() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        stack.server.failNext("PUT", "/trips", .afterApplying, with: .urlError(.timedOut))
        await launch(stack)
        XCTAssertEqual(stack.model.monitoringStatus, .failed(.timedOut, lastAcknowledgedAt: nil))

        await tick(stack, after: 60)
        XCTAssertEqual(stack.model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
        let puts = await sent(stack, "PUT", "/trips")
        XCTAssertEqual(puts.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1], "The retry is the same snapshot, so it cannot disturb what the server already applied")
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue])
        XCTAssertEqual(stack.server.registrationCount, 1)
    }

    func testALostRemovalStillEndsWithNothingMonitoredAndTurningOnAgainWorks() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        await launch(stack)
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue])

        // Turned off; the server deletes the device but its answer is lost.
        stack.server.failNext("DELETE", "/devices/me", .afterApplying, with: .urlError(.timedOut))
        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(stack.server.heldTripIDs, [], "Whatever happened to the answer, no trip is monitored")
        XCTAssertEqual(model.monitoringStatus, .off)
        XCTAssertEqual(model.monitoringWithdrawal, .none, "The server no longer knew the device, so the app knows no alert can come")
        // The user opted out: nothing new about this device may reach the server on the way.
        XCTAssertEqual(stack.server.registrationCount, 1, "No device is registered just to withdraw")
        XCTAssertEqual(stack.server.deviceCount, 0, "And none is left on the server")
        let afterRemoval = await stack.transport.requests.filter { $0.path != "/verdict" }.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(Array(afterRemoval.suffix(2)), ["DELETE /devices/me", "PUT /trips"], "The removal, then one empty snapshot under the old credential: no POST /devices and no push report")
        let withdrawn = await stack.credentials.origins()
        XCTAssertTrue(withdrawn.isEmpty, "The credential the server no longer knows is dropped")

        // Turned on again: the trips are back, under a credential the server knows.
        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue])
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
        XCTAssertEqual(model.monitoredTrips.keys.map(\.rawValue), [id.rawValue])
    }

    func testARemovalTheServerCouldNotConfirmKeepsTheCredentialAndIsToldAgain() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        await launch(stack)
        let notSetUp = ScriptedReply.http(status: 503, body: TestBackend.errorBody("monitoring_unavailable", "Trip monitoring is not set up on this server."))

        // The server answers "monitoring_unavailable" to everything about devices and trips,
        // although it still holds this device and its trip.
        stack.server.failNext("DELETE", "/devices/me", with: notSetUp)
        stack.server.failNext("PUT", "/trips", with: notSetUp)
        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(model.monitoringStatus, .off, "Off for the user at once")
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.unavailableOnServer), "Not reported as removed")
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue], "The server still holds the trip and would still alert")
        var origins = await stack.credentials.origins()
        XCTAssertEqual(origins, ["https://backend.example"], "The credential is kept: it is the only way to stop those alerts later")
        XCTAssertEqual(
            model.monitoringPresentation(formatter: OccurrenceFormatter(calculator: model.weekCalculator, locale: TestFixtures.enUS), at: stack.clock.now()).details,
            ["The server could not be told to stop (this server does not support trip monitoring yet), so it may still send alerts for a while. It is tried again when you tap Try Again or open the app again."]
        )

        // Not on the ticks; when the app is opened again the server answers properly.
        await tick(stack, after: 120)
        XCTAssertEqual(stack.server.deviceCount, 1)
        model.appDidBecomeActive()
        await settle(model)
        XCTAssertEqual(stack.server.deviceCount, 0, "Removed, device and trips")
        XCTAssertEqual(model.monitoringWithdrawal, .none)
        origins = await stack.credentials.origins()
        XCTAssertTrue(origins.isEmpty)
    }

    func testABusyServerIsToldToStopAgainOnTheNextTick() async throws {
        let activity = oneTimeClass()
        let stack = makeStack(activities: [activity])
        let model = stack.model
        await launch(stack)
        let busy = ScriptedReply.http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "The server cannot reach its database right now. Try again shortly."))
        stack.server.failNext("DELETE", "/devices/me", with: busy)
        stack.server.failNext("PUT", "/trips", with: busy)

        model.setRemindersEnabled(false)
        await settle(model)
        XCTAssertEqual(model.monitoringWithdrawal, .failed(.server(status: 503)), "A DELETE answered with it is not done")
        XCTAssertEqual(stack.server.deviceCount, 1)
        XCTAssertTrue(MonitoringText.withdrawalSentence(model.monitoringWithdrawal)?.hasSuffix("This is tried again automatically.") ?? false)

        await tick(stack, after: 60)
        XCTAssertEqual(stack.server.deviceCount, 0, "Tried again automatically, a minute later")
        XCTAssertEqual(model.monitoringWithdrawal, .none)
    }

    func testAServerWhoseTablesAreNotSetUpIsAskedAgainWhenTheAppIsOpened() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        let notSetUp = ScriptedReply.http(status: 503, body: TestBackend.errorBody("monitoring_unavailable", "Trip monitoring is not set up on this server."))
        stack.server.failNext("POST", "/devices", with: notSetUp)
        await launch(stack)
        XCTAssertEqual(model.monitoringStatus, .failed(.unavailableOnServer, lastAcknowledgedAt: nil))
        XCTAssertEqual(model.monitoringDeliverySentence, "This server does not support trip monitoring yet.")
        XCTAssertNotNil(model.departures[id]?.state.calculation, "Recommendations do not depend on monitoring")

        await tick(stack, after: 61)
        await tick(stack, after: 300)
        XCTAssertEqual(stack.server.registrationCount, 0, "Never retried on the minute ticks")

        // The migration was applied meanwhile; opening the app again finds out.
        model.appDidBecomeActive()
        await settle(model)
        XCTAssertEqual(stack.server.registrationCount, 1)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
    }

    func testATemporarilyUnavailableServerIsRetriedOnTheTicks() async throws {
        let activity = oneTimeClass()
        let stack = makeStack(activities: [activity])
        let model = stack.model
        let busy = ScriptedReply.http(status: 503, body: TestBackend.errorBody("temporarily_unavailable", "The server cannot reach its database right now. Try again shortly."))
        stack.server.failNext("POST", "/devices", with: busy)
        await launch(stack)
        XCTAssertEqual(model.monitoringStatus, .failed(.server(status: 503), lastAcknowledgedAt: nil), "A passing problem, never \"this server does not support trip monitoring\"")
        XCTAssertEqual(model.monitoringDeliverySentence, "Trips could not be synchronized: the backend had a problem (HTTP 503).")

        await tick(stack, after: 60)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1), "Retried with the normal backoff")

        // The same answer to a read of the server's state leaves the status alone.
        stack.server.setPhase(occurrenceID(activity).rawValue, "planning")
        stack.server.failNext("GET", "/trips", with: busy)
        await tick(stack, after: 60)
        XCTAssertTrue(model.monitoringStatus.isActive)
    }

    func testAServerThatForgotTheDeviceIsRepairedByTheNextRead() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        await launch(stack)
        stack.server.loseDevices()
        XCTAssertEqual(stack.server.heldTripIDs, [])

        await tick(stack, after: 60)
        XCTAssertEqual(stack.server.registrationCount, 2, "Registered again, once")
        XCTAssertEqual(stack.server.heldTripIDs, [id.rawValue], "And every trip was sent again")
        XCTAssertEqual(stack.model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
    }

    // MARK: "I've left", addresses, push

    func testIveLeftEndsMonitoringOnTheServerAndTheScreenAsksDirectlyAgain() async throws {
        let activity = oneTimeClass()
        let id = occurrenceID(activity)
        let stack = makeStack(activities: [activity])
        let model = stack.model
        monitor(stack, activity, departure: pacific(2026, 10, 26, 7, 5))
        await launch(stack)
        XCTAssertEqual(model.departures[id]?.state.calculation?.recommendation?.isMonitored, true)
        XCTAssertEqual(model.monitoringSummary(for: id)?.canMarkDeparted, true)

        await model.markDeparted(id)
        await settle(model)
        XCTAssertEqual(model.departedState(for: id), .done)
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .departed)
        let departures = await sent(stack, "POST", "/trips/\(id.rawValue)/departed")
        let request = try XCTUnwrap(departures.first)
        XCTAssertEqual(request.string("arriveBy"), "2026-10-26T15:15:00.000Z")
        let calculation = try XCTUnwrap(model.departures[id]?.state.calculation)
        XCTAssertEqual(calculation.recommendation?.isMonitored, false, "No longer the monitored plan")
        XCTAssertEqual(calculation.leaveHome, pacific(2026, 10, 26, 7, 10))

        // A later synchronization does not bring the trip back to life.
        model.appDidBecomeActive()
        await settle(model)
        XCTAssertEqual(model.monitoredTrips[id]?.phase, .departed)
        XCTAssertEqual(model.monitoringSummary(for: id)?.departedSentence, "Marked as left. Monitoring ended for this trip.")
    }

    func testChangingTheServerAddressMovesTheInstallation() async throws {
        let activity = oneTimeClass()
        let stack = makeStack(activities: [activity])
        let model = stack.model
        await launch(stack)
        let oldCredential = try await stack.credentials.load(origin: "https://backend.example")
        let oldToken = try XCTUnwrap(oldCredential?.token)

        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        await settle(model)

        let all = await stack.transport.requests.filter { $0.path != "/verdict" && $0.path != "/route" }
        let afterSwitch = Array(all.drop { !($0.method == "DELETE") })
        XCTAssertEqual(afterSwitch.map { "\($0.method) \($0.url.absoluteString)" }, [
            "DELETE https://backend.example/devices/me",
            "POST http://localhost:3000/devices",
            "PUT http://localhost:3000/trips"
        ], "The old server forgets the installation first; then the new one gets a device and the trips")
        XCTAssertEqual(afterSwitch.first?.headers["Authorization"], "Bearer \(oldToken)")
        XCTAssertNotEqual(afterSwitch.last?.headers["Authorization"], "Bearer \(oldToken)", "The old credential never goes to the new server")
        let origins = await stack.credentials.origins()
        XCTAssertEqual(origins, ["http://localhost:3000"])
        XCTAssertFalse(model.previousServerMayStillAlert)
        XCTAssertEqual(model.monitoringStatus, .active(acknowledgedAt: stack.clock.now(), tripCount: 1))
        XCTAssertEqual(stack.server.deviceCount, 1)
    }

    func testAnUnreachableOldServerIsRememberedHonestly() async throws {
        let stack = makeStack(activities: [oneTimeClass()])
        let model = stack.model
        await launch(stack)
        stack.server.failNext("DELETE", "/devices/me", with: .urlError(.cannotConnectToHost))

        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        await settle(model)
        XCTAssertTrue(model.previousServerMayStillAlert, "The old server still holds the trips and could not be told")
        XCTAssertTrue(model.monitoringStatus.isActive)
        let origins = await stack.credentials.origins()
        XCTAssertEqual(origins, ["http://localhost:3000", "https://backend.example"], "Its credential is kept, so it can still be told later")

        model.appDidBecomeActive()
        await settle(model)
        XCTAssertFalse(model.previousServerMayStillAlert)
        let remaining = await stack.credentials.origins()
        XCTAssertEqual(remaining, ["http://localhost:3000"])
    }

    func testAPushTokenReachesTheServerAndTheStatusOnScreen() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let stack = makeStack(activities: [oneTimeClass()], push: push)
        let model = stack.model
        await launch(stack)
        XCTAssertEqual(model.notificationPermission, .authorized)
        XCTAssertEqual(push.registrationCount, 1, "Allowed already: the launch registers with the push service")
        XCTAssertEqual(model.monitoringObstacle, .deviceNotRegistered, "No token yet, so alerts are not described as active")
        XCTAssertEqual(model.monitoringDeliverySentence, "This device is not registered for push notifications yet.")

        // The host hands over the device token.
        let isNew = await stack.session.updateDeviceToken(Data(repeating: 0x5C, count: 32))
        XCTAssertTrue(isNew)
        model.pushRegistrationDidChange()
        await settle(model)
        XCTAssertEqual(stack.server.storedPushToken, String(repeating: "5c", count: 32))
        XCTAssertEqual(stack.server.storedAuthorized, true)
        XCTAssertEqual(model.pushDelivery, PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil))
        XCTAssertNil(model.monitoringObstacle)
        XCTAssertEqual(model.monitoringDeliverySentence, MonitoringText.activeDelivery)

        // A server that only wakes up for requests is named as such.
        stack.server.monitor = #"{"enabled":true,"dependable":false,"lastTickAt":null}"#
        model.appDidBecomeActive()
        await settle(model)
        XCTAssertEqual(model.monitoringObstacle, .monitorNotDependable)
        XCTAssertEqual(model.monitorHealth, MonitorHealth(enabled: true, dependable: false, lastTickAt: nil))
    }

    func testTurningRemindersOnPromptsThroughTheRegistrar() async throws {
        let push = FakePushRegistrar(status: .notDetermined, answerToRequest: .denied)
        let stack = makeStack(activities: [oneTimeClass()], remindersOn: false, push: push)
        let model = stack.model
        await launch(stack)
        XCTAssertEqual(push.requestCount, 0)

        model.setRemindersEnabled(true)
        await settle(model)
        XCTAssertEqual(push.requestCount, 1)
        XCTAssertEqual(push.registrationCount, 0, "Denied: nothing registers with the push service")
        XCTAssertEqual(model.notificationPermission, .denied)
        XCTAssertTrue(model.monitoringStatus.isActive, "The trips are synchronized all the same")
        XCTAssertEqual(model.monitoringObstacle, .permissionDenied)
        XCTAssertEqual(model.monitoringDeliverySentence, "Notifications are off for this app in iOS Settings.")
    }
}
