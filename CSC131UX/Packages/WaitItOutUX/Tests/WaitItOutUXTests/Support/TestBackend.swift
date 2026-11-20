import Foundation
import XCTest
@testable import WaitItOutUX

// Doubles and fixtures for the live backend: a scripted `HTTPTransport` that records every
// request and never opens a connection, response bodies shaped exactly like the real
// backend's (dates as `Date.toISOString()` writes them, capitalised confidence, snake_case
// actions), route provider doubles, and a model wired to a `LiveBackend`.

/// One request the scripted transport saw.
struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval

    var path: String {
        url.path
    }

    /// The JSON body as text, or "" without one.
    var bodyText: String {
        body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The body's top-level JSON object, or an empty dictionary.
    func jsonObject() -> [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }

    /// A string at a top-level key of the JSON body.
    func string(_ key: String) -> String? {
        jsonObject()[key] as? String
    }

    /// A number at `outer.inner` of the JSON body, such as `origin.lat`.
    func number(_ outer: String, _ inner: String) -> Double? {
        ((jsonObject()[outer] as? [String: Any])?[inner] as? NSNumber)?.doubleValue
    }
}

/// How the scripted transport answers one request.
enum ScriptedReply: Sendable {
    /// An HTTP answer with this status and body text.
    case http(status: Int, body: String)
    /// No HTTP answer: the transport throws this URL error.
    case urlError(URLError.Code)
    /// No HTTP answer: the transport throws an error that is not a URL error.
    case otherError
}

/// `HTTPTransport` that answers from a closure and records what was asked. No network.
actor ScriptedHTTPTransport: HTTPTransport {
    typealias Responder = @Sendable (RecordedRequest) -> ScriptedReply

    private var responder: Responder
    private(set) var requests: [RecordedRequest] = []

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    /// Always gives the same answer.
    init(_ reply: ScriptedReply) {
        responder = { _ in reply }
    }

    func setResponder(_ responder: @escaping Responder) {
        self.responder = responder
    }

    func setReply(_ reply: ScriptedReply) {
        responder = { _ in reply }
    }

    func requestCount() -> Int {
        requests.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeout: request.timeoutInterval
        )
        requests.append(recorded)
        switch responder(recorded) {
        case .http(let status, let body):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        case .urlError(let code):
            throw URLError(code)
        case .otherError:
            throw TestStoreError()
        }
    }
}

/// Holds every request until the test answers it and ignores cancellation, so a test can
/// deliver a genuinely late answer for a superseded request. Unlike `GatedCommuteEstimator`,
/// a cancelled call still returns what the test gives it.
actor LateAnsweringEstimator: CommuteEstimating {
    private(set) var requests: [CommuteRequest] = []
    private var waiting: [Int: CheckedContinuation<CommuteEstimateResponse, Error>] = [:]

    func callCount() -> Int {
        requests.count
    }

    func request(at index: Int) -> CommuteRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    @discardableResult
    func answer(_ index: Int, with response: CommuteEstimateResponse) -> Bool {
        guard let continuation = waiting.removeValue(forKey: index) else { return false }
        continuation.resume(returning: response)
        return true
    }

    @discardableResult
    func fail(_ index: Int, with failure: CommuteProviderFailure) -> Bool {
        guard let continuation = waiting.removeValue(forKey: index) else { return false }
        continuation.resume(throwing: failure)
        return true
    }

    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[index] = continuation
        }
    }
}

/// Route provider that answers from a closure and records what was asked.
actor ScriptedRouteProvider: RouteProviding {
    typealias Responder = @Sendable (GeoCoordinate, GeoCoordinate) throws -> RouteGeometry

    private var responder: Responder
    private(set) var requests: [RoutePair] = []

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func setResponder(_ responder: @escaping Responder) {
        self.responder = responder
    }

    func requestCount() -> Int {
        requests.count
    }

    func route(from origin: GeoCoordinate, to destination: GeoCoordinate) async throws -> RouteGeometry {
        requests.append(RoutePair(origin: origin, destination: destination))
        return try responder(origin, destination)
    }
}

/// Route provider that holds every request until the test answers it and ignores
/// cancellation, so an answer for old places can arrive late.
actor LateAnsweringRouteProvider: RouteProviding {
    private(set) var requests: [RoutePair] = []
    private var waiting: [Int: CheckedContinuation<RouteGeometry, Error>] = [:]

    func requestCount() -> Int {
        requests.count
    }

    func request(at index: Int) -> RoutePair? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    @discardableResult
    func answer(_ index: Int, with geometry: RouteGeometry) -> Bool {
        guard let continuation = waiting.removeValue(forKey: index) else { return false }
        continuation.resume(returning: geometry)
        return true
    }

    @discardableResult
    func fail(_ index: Int, with error: Error) -> Bool {
        guard let continuation = waiting.removeValue(forKey: index) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    func route(from origin: GeoCoordinate, to destination: GeoCoordinate) async throws -> RouteGeometry {
        let index = requests.count
        requests.append(RoutePair(origin: origin, destination: destination))
        return try await withCheckedThrowingContinuation { continuation in
            waiting[index] = continuation
        }
    }
}

/// Monitored-trip source that answers from a closure and counts its calls.
actor ScriptedMonitoredTripSource: MonitoredTripSource {
    typealias Responder = @Sendable (CommuteRequest) throws -> CommuteEstimateResponse?

    private let responder: Responder
    private(set) var calls = 0

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func answer(for request: CommuteRequest) async throws -> CommuteEstimateResponse? {
        calls += 1
        return try responder(request)
    }
}

enum TestBackend {
    static let baseURL: URL = {
        guard let url = URL(string: "https://backend.example") else {
            preconditionFailure("The fixture address must be a URL")
        }
        return url
    }()

    /// TomTom with live traffic: the best the backend reports.
    static let liveSource = RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true)

    /// A date as JavaScript's `Date.toISOString()` writes it: UTC, milliseconds, "Z". Built
    /// with a formatter of its own, independent of the code under test.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// A recommendation as `BackendCommuteProvider` would build it.
    static func recommendation(
        advice: DepartureAdvice = .leaveLater,
        departure: Date,
        arrival: Date,
        reason: String = "Leaving at 7:15 AM still gets you there with 15 minutes to spare.",
        confidence: RecommendationConfidence = .high,
        confidenceReason: String = "Based on plenty of historical data and live traffic.",
        notes: [String] = [],
        lateBy: TimeInterval? = nil,
        margin: TimeInterval? = nil,
        generatedAt: Date,
        receivedAt: Date? = nil,
        source: RecommendationSource = TestBackend.liveSource,
        isStale: Bool = false,
        isMonitored: Bool = false
    ) -> DepartureRecommendation {
        DepartureRecommendation(
            advice: advice,
            recommendedDeparture: departure,
            predictedArrival: arrival,
            reason: reason,
            confidence: confidence,
            confidenceReason: confidenceReason,
            notes: notes,
            lateBy: lateBy,
            margin: margin,
            generatedAt: generatedAt,
            receivedAt: receivedAt ?? generatedAt,
            source: source,
            isStale: isStale,
            isMonitored: isMonitored
        )
    }

    /// A POST /verdict 200 body in the backend's own shape, including the `slots` the app
    /// does not read. `recommended` and `leaveNow` are (departAt, arriveAt) pairs.
    static func verdictBody(
        action: String,
        reason: String = "Your deadline is 2 hr 15 min away, so there is no rush. Leaving at 7:15 AM still gets you there with 15 minutes to spare.",
        leaveNow: (Date, Date),
        recommended: (Date, Date),
        lateByMinutes: Int? = nil,
        marginMinutes: Int? = nil,
        confidence: String = "High",
        confidenceReason: String = "Based on plenty of historical data and live traffic.",
        notes: [String] = [],
        generatedAt: Date,
        source: String? = #"{"baseline":"tomtom","fallback":false,"live":true}"#
    ) -> String {
        func slot(_ pair: (Date, Date), extras: String = "") -> String {
            let minutes = Int((pair.1.timeIntervalSince(pair.0) / 60).rounded())
            return #"{"departAt":"\#(iso(pair.0))","arriveAt":"\#(iso(pair.1))","driveMinutes":\#(minutes)\#(extras)}"#
        }
        let noteList = notes.map { "\"\($0)\"" }.joined(separator: ",")
        var verdict = #""action":"\#(action)","waitMinutes":0,"reason":"\#(reason)","leaveNow":\#(slot(leaveNow)),"recommended":\#(slot(recommended)),"minutesSaved":0,"arrivalDelayMinutes":0"#
        if let lateByMinutes {
            verdict += #","lateByMinutes":\#(lateByMinutes)"#
        }
        if let marginMinutes {
            verdict += #","deadline":{"arriveBy":"\#(iso(recommended.1.addingTimeInterval(TimeInterval(marginMinutes) * 60)))","marginMinutes":\#(marginMinutes)}"#
        }
        verdict += #","confidence":"\#(confidence)","confidenceReason":"\#(confidenceReason)","notes":[\#(noteList)],"generatedAt":"\#(iso(generatedAt))""#
        let slotExtras = #","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.""#
        let slots = "[" + slot(leaveNow, extras: slotExtras) + "]"
        var body = #"{"slots":\#(slots),"verdict":{\#(verdict)}"#
        if let source {
            body += #","source":\#(source)"#
        }
        return body + "}"
    }

    /// An error body in the backend's shape.
    static func errorBody(_ code: String, _ message: String) -> String {
        #"{"error":"\#(code)","message":"\#(message)"}"#
    }

    /// A POST /route 200 body.
    static func routeBody(points: [(Double, Double)], distanceMiles: Double, source: String? = "tomtom", fallback: Bool = false) -> String {
        let list = points.map { #"{"lat":\#($0.0),"lng":\#($0.1)}"# }.joined(separator: ",")
        var body = #"{"points":[\#(list)],"distanceMiles":\#(distanceMiles)"#
        if let source {
            body += #","source":"\#(source)""#
        }
        return body + #","fallback":\#(fallback)}"#
    }

    /// A route between the sample home and the sample campus with one bend.
    static func route(label: String = "TomTom", miles: Double = 12.4, bend: Double = 38.5) -> RouteGeometry {
        RouteGeometry(
            points: [
                CommutePlaces.sample.home.coordinate,
                GeoCoordinate(latitude: bend, longitude: -121.40),
                CommutePlaces.sample.campus.coordinate
            ],
            distanceMiles: miles,
            sourceLabel: label,
            isFallback: false,
            isFixture: false
        )
    }

    /// A client on `transport` with the fixture address (or none).
    static func client(transport: any HTTPTransport, clock: any WallClock, baseURL: URL? = TestBackend.baseURL) -> BackendClient {
        BackendClient(configuration: BackendConfiguration(defaultBaseURL: baseURL), transport: transport, clock: clock)
    }

    /// A model wired to a live backend. `demoEstimator` is the injected provider of the
    /// explicit Demo mode; without one the model creates its own `TestCommuteProvider`.
    /// `tripMonitor` is the monitoring service; without one nothing is synchronized.
    /// `repository` replaces the store made from `activities`.
    @MainActor
    static func makeLiveModel(
        clock: any WallClock,
        activities: [Activity] = [],
        liveEstimator: any CommuteEstimating,
        demoEstimator: (any CommuteEstimating)? = nil,
        routeProvider: (any RouteProviding)? = nil,
        tripMonitor: (any TripMonitoring)? = nil,
        configuration: BackendConfiguration = BackendConfiguration(defaultBaseURL: TestBackend.baseURL),
        store: any PreferencesStoring = InMemoryPreferencesStore(),
        reminderScheduler: (any ReminderScheduling)? = nil,
        repository: (any ActivityRepository)? = nil
    ) -> WaitItOutModel {
        WaitItOutModel(
            clock: clock,
            preferencesStore: store,
            activityRepository: repository ?? ScriptedActivityRepository(initial: activities),
            commuteEstimator: demoEstimator,
            reminderScheduler: reminderScheduler,
            weekCalculator: WeekCalculator(timeZone: TestFixtures.pacific, locale: TestFixtures.enUS),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "Test", version: "1", build: "1"),
            liveBackend: LiveBackend(
                commuteEstimator: liveEstimator,
                routeProvider: routeProvider,
                tripMonitor: tripMonitor,
                configuration: configuration
            )
        )
    }
}
