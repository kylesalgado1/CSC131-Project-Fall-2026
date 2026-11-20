import XCTest
@testable import WaitItOutUX

/// Stage S3: the Settings "Data source" status row. "Connected" is claimed only for a server
/// that actually answered, the newest event decides, and nothing is requested just to find out.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The one-time class runs 9:00 to 9:50 AM with an
/// ideal arrival of 8:15 AM.
@MainActor
final class BackendConnectionTests: XCTestCase {
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
    private let six = TestFixtures.date(2026, 10, 26, 6)

    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    private func oneTimeClass() -> Activity {
        TestFixtures.activity(
            title: "One-time class",
            start: TestFixtures.date(2026, 10, 26, 9),
            end: TestFixtures.date(2026, 10, 26, 9, 50),
            arrival: TestFixtures.date(2026, 10, 26, 8, 15)
        )
    }

    /// A live estimator that recommends leaving 70 minutes before the ideal arrival.
    private func steadyBackend(_ clock: ManualWallClock) -> ScriptedCommuteEstimator {
        ScriptedCommuteEstimator { request in
            .recommendation(TestBackend.recommendation(
                departure: request.arriveBy.addingTimeInterval(-70 * 60),
                arrival: request.arriveBy.addingTimeInterval(-25 * 60),
                margin: 25 * 60,
                generatedAt: clock.now()
            ))
        }
    }

    private func makeModel(
        _ clock: ManualWallClock,
        activities: [Activity] = [],
        estimator: ScriptedCommuteEstimator,
        monitor: RecordingTripMonitor? = nil,
        remindersOn: Bool = false,
        dataMode: DataMode = .live,
        defaultAddress: URL? = TestBackend.baseURL
    ) -> WaitItOutModel {
        TestBackend.makeLiveModel(
            clock: clock,
            activities: activities,
            liveEstimator: estimator,
            demoEstimator: ScriptedCommuteEstimator(minutes: 60),
            tripMonitor: monitor,
            configuration: BackendConfiguration(defaultBaseURL: defaultAddress),
            store: InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn, dataMode: dataMode))
        )
    }

    private func settle(_ model: WaitItOutModel) async {
        for _ in 0..<4 {
            await model.waitForDepartures()
            await model.waitForMonitoring()
            await model.waitForReminders()
        }
        await model.flushPendingSaves()
    }

    private func launch(_ model: WaitItOutModel) async {
        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)
    }

    private func tick(_ model: WaitItOutModel, _ clock: ManualWallClock, after seconds: TimeInterval) async {
        clock.advance(by: seconds)
        model.refreshDepartures()
        await settle(model)
    }

    // MARK: The rule

    func testTheNewestEventDecides() throws {
        let address = try url("https://backend.example")
        let later = six.addingTimeInterval(60)
        let failure = BackendConnection.Failure(at: later, problem: "The backend could not be reached. Check the connection.")

        XCTAssertEqual(BackendConnection.resolve(isLive: false, address: address, lastAnswerAt: six, lastFailure: failure), .demo)
        XCTAssertEqual(BackendConnection.resolve(isLive: true, address: nil, lastAnswerAt: six, lastFailure: failure), .notConfigured)
        XCTAssertEqual(BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: nil, lastFailure: nil), .unanswered(host: "backend.example"))
        XCTAssertEqual(BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: six, lastFailure: nil), .connected(host: "backend.example", at: six))
        XCTAssertEqual(
            BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: six, lastFailure: failure),
            .failing(host: "backend.example", at: later, problem: failure.problem),
            "A failure after the last answer is what stands"
        )
        XCTAssertEqual(
            BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: later.addingTimeInterval(60), lastFailure: failure),
            .connected(host: "backend.example", at: later.addingTimeInterval(60)),
            "An answer after the failure clears it"
        )
        XCTAssertEqual(
            BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: later, lastFailure: failure),
            .failing(host: "backend.example", at: later, problem: failure.problem),
            "A tie is never called connected"
        )
        XCTAssertEqual(
            BackendConnection.resolve(isLive: true, address: address, lastAnswerAt: nil, lastFailure: failure),
            .failing(host: "backend.example", at: later, problem: failure.problem)
        )
    }

    func testTheHostNamesItsPort() throws {
        XCTAssertEqual(BackendConnection.hostText(of: try url("https://backend.example")), "backend.example")
        XCTAssertEqual(BackendConnection.hostText(of: try url("http://localhost:3000")), "localhost:3000")
        XCTAssertEqual(BackendConnection.hostText(of: try url("http://192.168.1.20:8080")), "192.168.1.20:8080")
    }

    func testEveryStateHasItsSentence() {
        let yesterday = TestFixtures.date(2026, 10, 25, 21, 30)
        XCTAssertEqual(formatter.backendStatusText(for: .demo, at: six), "Not in use: the Demo data mode is on.")
        XCTAssertEqual(formatter.backendStatusText(for: .notConfigured, at: six), "Not configured. Enter a server address to use live data.")
        XCTAssertEqual(formatter.backendStatusText(for: .unanswered(host: "localhost:3000"), at: six), "Using localhost:3000. No answer has arrived yet.")
        XCTAssertEqual(
            formatter.backendStatusText(for: .connected(host: "backend.example", at: six), at: six),
            "Connected to backend.example. Last answer \(formatter.clockTime(six))."
        )
        XCTAssertEqual(
            formatter.backendStatusText(for: .connected(host: "backend.example", at: yesterday), at: six),
            "Connected to backend.example. Last answer \(formatter.reminderTimestamp(yesterday)).",
            "An answer from another day names the day"
        )
        XCTAssertEqual(
            formatter.backendStatusText(for: .failing(host: "backend.example", at: six, problem: "The backend could not be reached. Check the connection."), at: six),
            "The last request to backend.example failed (\(formatter.clockTime(six))). The backend could not be reached. Check the connection."
        )
    }

    // MARK: What the model reads it from

    func testWithoutALiveBackendOrInDemoModeTheBackendIsNotInUse() async {
        let standalone = TestFixtures.makeModel()
        XCTAssertEqual(standalone.backendConnection, .demo)
        XCTAssertNil(standalone.defaultBackendURL)

        let clock = ManualWallClock(six)
        let estimator = steadyBackend(clock)
        let model = makeModel(clock, activities: [oneTimeClass()], estimator: estimator, dataMode: .demo)
        await launch(model)
        XCTAssertEqual(model.backendConnection, .demo)
        XCTAssertEqual(model.defaultBackendURL, TestBackend.baseURL)
        let asked = await estimator.requestCount()
        XCTAssertEqual(asked, 0, "The Demo data mode never asks the backend")
    }

    func testWithoutAnAddressTheBackendIsNotConfigured() async {
        let clock = ManualWallClock(six)
        let model = makeModel(clock, activities: [oneTimeClass()], estimator: steadyBackend(clock), defaultAddress: nil)
        XCTAssertEqual(model.backendConnection, .notConfigured)
        XCTAssertNil(model.defaultBackendURL)
        XCTAssertNil(model.applyBackendAddress("http://localhost:3000"))
        XCTAssertEqual(model.backendConnection, .unanswered(host: "localhost:3000"))
    }

    func testAnAnswerMeansConnectedAndNothingIsAskedJustToFindOut() async {
        let clock = ManualWallClock(six)
        let estimator = steadyBackend(clock)
        let model = makeModel(clock, activities: [oneTimeClass()], estimator: estimator)
        XCTAssertEqual(model.backendConnection, .unanswered(host: "backend.example"), "Nothing was asked yet")

        await launch(model)
        XCTAssertEqual(model.backendConnection, .connected(host: "backend.example", at: six))
        let asked = await estimator.requestCount()
        for _ in 0..<5 {
            _ = model.backendConnection
        }
        await settle(model)
        let askedAfter = await estimator.requestCount()
        XCTAssertEqual(askedAfter, asked, "Reading the status asks nothing")
    }

    func testAFailedRequestIsNamedAndALaterAnswerClearsIt() async {
        let clock = ManualWallClock(six)
        let estimator = ScriptedCommuteEstimator { _ in throw CommuteProviderFailure(.offline) }
        let model = makeModel(clock, activities: [oneTimeClass()], estimator: estimator)
        await launch(model)
        XCTAssertEqual(
            model.backendConnection,
            .failing(host: "backend.example", at: six, problem: "The backend could not be reached. Check the connection.")
        )

        await estimator.setResponder { request in
            .recommendation(TestBackend.recommendation(
                departure: request.arriveBy.addingTimeInterval(-70 * 60),
                arrival: request.arriveBy.addingTimeInterval(-25 * 60),
                generatedAt: clock.now()
            ))
        }
        await tick(model, clock, after: 60)
        XCTAssertEqual(model.backendConnection, .connected(host: "backend.example", at: six.addingTimeInterval(60)))
    }

    func testAnAnswerTheProviderGaveWithoutARequestIsNotAConnection() async throws {
        // Mon 8:30 AM: the class's ideal arrival, 8:15, has passed, and the class has not begun.
        let clock = ManualWallClock(TestFixtures.date(2026, 10, 26, 8, 30))
        let transport = ScriptedHTTPTransport(.http(status: 422, body: TestBackend.errorBody("no_coverage", "There is not enough traffic data for this route yet.")))
        let provider = BackendCommuteProvider(client: TestBackend.client(transport: transport, clock: clock), clock: clock)
        let passed = oneTimeClass()
        let model = TestBackend.makeLiveModel(clock: clock, activities: [passed], liveEstimator: provider)
        await launch(model)

        let id = OccurrenceID(activityID: passed.id, date: LocalDate.of(passed.start, in: TestFixtures.pacific))
        XCTAssertEqual(model.departures[id]?.state, .unavailable(.noEstimate(message: BackendCommuteProvider.arrivalPassedMessage)))
        var sent = await transport.requestCount()
        XCTAssertEqual(sent, 0, "The provider said that by itself: nothing was asked")
        XCTAssertEqual(
            model.backendConnection,
            .unanswered(host: "backend.example"),
            "A server that was never asked is not called connected"
        )
        let status = formatter.backendStatusText(for: model.backendConnection, at: clock.now())
        XCTAssertEqual(status, "Using backend.example. No answer has arrived yet.")
        XCTAssertFalse(status.contains("Connected"))

        // An answer the server did give, even "no coverage", is a contact.
        let lab = TestFixtures.activity(
            title: "Lab",
            start: TestFixtures.date(2026, 10, 26, 11),
            end: TestFixtures.date(2026, 10, 26, 11, 50),
            arrival: TestFixtures.date(2026, 10, 26, 10, 15)
        )
        try await model.saveActivity(lab)
        await settle(model)
        sent = await transport.requestCount()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(model.backendConnection, .connected(host: "backend.example", at: clock.now()))
    }

    func testAKeptRecommendationDoesNotHideTheFailureAfterIt() async {
        let clock = ManualWallClock(six)
        let estimator = steadyBackend(clock)
        let model = makeModel(clock, activities: [oneTimeClass()], estimator: estimator)
        await launch(model)
        XCTAssertEqual(model.backendConnection, .connected(host: "backend.example", at: six))

        await estimator.setResponder { _ in throw CommuteProviderFailure(.timedOut) }
        // One backend slot after it was asked, so the tick asks again and fails.
        await tick(model, clock, after: 15 * 60)
        let later = six.addingTimeInterval(15 * 60)
        XCTAssertEqual(
            model.backendConnection,
            .failing(host: "backend.example", at: later, problem: "The backend did not answer in time. It may be waking up; this is retried automatically."),
            "The recommendation on screen is out of date; the newest thing known is the failure"
        )
    }

    func testTheTripSynchronizationCountsAsAnAnswerOrAFailure() async {
        let clock = ManualWallClock(six)
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.setPermission(.authorized)
        // No activities: the only request is the synchronization of an empty set.
        let model = makeModel(clock, estimator: steadyBackend(clock), monitor: monitor, remindersOn: true)
        await launch(model)
        XCTAssertTrue(model.monitoringStatus.isActive)
        XCTAssertEqual(model.backendConnection, .connected(host: "backend.example", at: six))

        await monitor.failSynchronize(with: .offline)
        clock.advance(by: 120)
        model.retryMonitoring()
        await settle(model)
        XCTAssertEqual(model.monitoringStatus.failure, .offline)
        XCTAssertEqual(
            model.backendConnection,
            .failing(host: "backend.example", at: six.addingTimeInterval(120), problem: "Trips could not be synchronized: the backend could not be reached.")
        )
    }

    func testAServerWithoutMonitoringDidAnswerSoItIsNotAConnectionFailure() async {
        let clock = ManualWallClock(six)
        let monitor = RecordingTripMonitor(clock: clock)
        await monitor.failSynchronize(with: .unavailableOnServer)
        let model = makeModel(clock, estimator: steadyBackend(clock), monitor: monitor, remindersOn: true)
        await launch(model)
        XCTAssertEqual(model.monitoringStatus.failure, .unavailableOnServer)
        XCTAssertEqual(model.backendConnection, .unanswered(host: "backend.example"))
        XCTAssertTrue(WaitItOutModel.isConnectionFailure(.timedOut))
        XCTAssertTrue(WaitItOutModel.isConnectionFailure(.server(status: 502)))
        XCTAssertTrue(WaitItOutModel.isConnectionFailure(.invalidResponse))
        XCTAssertFalse(WaitItOutModel.isConnectionFailure(.rejected(message: "Too many trips.")))
        XCTAssertFalse(WaitItOutModel.isConnectionFailure(.credentialStorage))
    }
}
