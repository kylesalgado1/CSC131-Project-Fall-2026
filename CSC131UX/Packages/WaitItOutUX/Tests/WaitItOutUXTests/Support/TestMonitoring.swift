import Foundation
import XCTest
@testable import WaitItOutUX

// Doubles for trip monitoring (stage S2): a push registrar that never touches the system, a
// recording `TripMonitoring` service for the model's tests, and an in-memory stand-in for the
// backend's device and trip endpoints that answers a scripted transport with bodies shaped
// exactly like the real backend's. Nothing here opens a connection.

/// `HTTPTransport` that holds every request until the test releases them, then answers from a
/// responder like the scripted transport. After `releaseAll` later requests are answered at
/// once, so a test can stop a call in mid-flight, change something, and let everything go on.
actor HeldTransport: HTTPTransport {
    private let responder: ScriptedHTTPTransport.Responder
    private(set) var requests: [RecordedRequest] = []
    private var isHolding = true
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(responder: @escaping ScriptedHTTPTransport.Responder) {
        self.responder = responder
    }

    /// Waits until at least `count` requests are being held. Returns whether that happened.
    func waitForHeldRequests(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if waiting.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return waiting.count >= count
    }

    func releaseAll() {
        isHolding = false
        let held = waiting
        waiting = []
        for continuation in held {
            continuation.resume()
        }
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
        if isHolding {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
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

/// `PushRegistering` without the system: the permission is whatever the test says.
final class FakePushRegistrar: PushRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var status: NotificationPermission
    private var answerToRequest: NotificationPermission
    private var requests = 0
    private var registrations = 0
    let apnsEnvironment: String

    init(status: NotificationPermission = .notDetermined, answerToRequest: NotificationPermission = .authorized, environment: String = "sandbox") {
        self.status = status
        self.answerToRequest = answerToRequest
        apnsEnvironment = environment
    }

    func setStatus(_ value: NotificationPermission) {
        lock.lock()
        status = value
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var registrationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    func authorizationStatus() async -> NotificationPermission {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func requestPermission() async -> NotificationPermission {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        if status == .notDetermined {
            status = answerToRequest
        }
        return status
    }

    @MainActor
    func registerForRemoteNotifications() {
        lock.lock()
        registrations += 1
        lock.unlock()
    }
}

/// `TripMonitoring` that records every call and answers from what the test set up. The
/// snapshot it returns lists exactly the trips it was last given, each in the phase the test
/// chose for it (planning without a plan unless told otherwise).
actor RecordingTripMonitor: TripMonitoring {
    /// How one trip is reported.
    struct Report: Sendable {
        var phase: TripPhase
        var plan: MonitoredPlan?
        var monitoringStartsAt: Date?
        var nextCheckAt: Date?
        var planAvailableAt: Date?
        var headsUpSentAt: Date?
        var leaveAlertSentAt: Date?
        var lastAlert: TripAlert?
        var lastErrorCode: String?
        var noPlanReason: String?
    }

    private let clock: any WallClock
    private(set) var synchronized: [[MonitoredTrip]] = []
    private(set) var held: [MonitoredTrip] = []
    private(set) var refreshCalls = 0
    private(set) var tripRefreshes: [OccurrenceID] = []
    private(set) var departedCalls: [OccurrenceID] = []
    private(set) var departedArrivals: [Date] = []
    private(set) var unregistered: [URL?] = []
    private(set) var withdrawals = 0
    private(set) var permissionRequests = 0
    private(set) var pushRefreshes = 0
    /// Every call in order, such as "synchronize 2", "refresh", "unregister https://old.example".
    private(set) var events: [String] = []

    private var synchronizeFailure: TripMonitoringFailure?
    private var refreshFailure: TripMonitoringFailure?
    private var unregisterFailure: TripMonitoringFailure?
    private var unregisterFailures: [String: TripMonitoringFailure] = [:]
    private var withdrawFailure: TripMonitoringFailure?
    private var leftBehind: [URL] = []
    private var departedFailure: TripMonitoringFailure?
    private var permission: NotificationPermission = .notDetermined
    private var permissionAfterRequest: NotificationPermission?
    private var reports: [OccurrenceID: Report] = [:]
    private var push = PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil)
    private var monitor = MonitorHealth(enabled: true, dependable: true, lastTickAt: nil)
    private var limits = MonitoringLimits.fallback
    private var isGated = false
    private var gate: [CheckedContinuation<Void, Never>] = []

    init(clock: any WallClock) {
        self.clock = clock
    }

    // MARK: Setup

    func failSynchronize(with failure: TripMonitoringFailure?) {
        synchronizeFailure = failure
    }

    func failRefresh(with failure: TripMonitoringFailure?) {
        refreshFailure = failure
    }

    func failUnregister(with failure: TripMonitoringFailure?) {
        unregisterFailure = failure
    }

    /// Makes removing this installation from one server fail, whatever the others do.
    func failUnregister(from address: URL, with failure: TripMonitoringFailure?) {
        unregisterFailures[address.absoluteString] = failure
    }

    /// Makes the empty snapshot of a withdrawal fail.
    func failWithdrawTrips(with failure: TripMonitoringFailure?) {
        withdrawFailure = failure
    }

    /// The servers the credential store would still name after an address change. A server
    /// leaves the list when its removal succeeds, as its credential would.
    func setServersLeftBehind(_ servers: [URL]) {
        leftBehind = servers
    }

    func failDeparted(with failure: TripMonitoringFailure?) {
        departedFailure = failure
    }

    func setPermission(_ value: NotificationPermission, afterRequest: NotificationPermission? = nil) {
        permission = value
        permissionAfterRequest = afterRequest
    }

    func report(_ id: OccurrenceID, as report: Report) {
        reports[id] = report
    }

    func setPush(_ value: PushDeliveryStatus) {
        push = value
    }

    func setMonitor(_ value: MonitorHealth) {
        monitor = value
    }

    func setLimits(_ value: MonitoringLimits) {
        limits = value
    }

    /// Makes every synchronize wait until `release`.
    func holdSynchronize() {
        isGated = true
    }

    /// Lets the waiting synchronize calls go on; later ones are not held.
    func release() {
        isGated = false
        let waiting = gate
        gate = []
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Lets only the synchronize call that has waited longest go on; later ones stay held.
    func releaseOne() {
        guard !gate.isEmpty else { return }
        gate.removeFirst().resume()
    }

    func waitingCount() -> Int {
        gate.count
    }

    func synchronizeCount() -> Int {
        synchronized.count
    }

    func lastSynchronized() -> [MonitoredTrip]? {
        synchronized.last
    }

    // MARK: TripMonitoring

    func synchronize(_ trips: [MonitoredTrip]) async throws -> MonitoringSnapshot {
        synchronized.append(trips)
        events.append("synchronize \(trips.count)")
        if isGated {
            await withCheckedContinuation { continuation in
                gate.append(continuation)
            }
        }
        if let synchronizeFailure { throw synchronizeFailure }
        held = trips
        return snapshot()
    }

    func refresh() async throws -> MonitoringSnapshot {
        refreshCalls += 1
        events.append("refresh")
        if let refreshFailure { throw refreshFailure }
        return snapshot()
    }

    func refreshTrip(_ id: OccurrenceID) async throws -> MonitoredTripState? {
        tripRefreshes.append(id)
        events.append("refreshTrip")
        if let refreshFailure { throw refreshFailure }
        guard let trip = held.first(where: { $0.id == id }) else { return nil }
        return state(trip)
    }

    func markDeparted(_ id: OccurrenceID, arriveBy: Date) async -> Result<MonitoredTripState, TripMonitoringFailure> {
        departedCalls.append(id)
        departedArrivals.append(arriveBy)
        events.append("markDeparted")
        if let departedFailure { return .failure(departedFailure) }
        guard let trip = held.first(where: { $0.id == id }) else { return .failure(.notMonitored) }
        guard trip.arriveBy == arriveBy else { return .failure(.superseded) }
        reports[id] = Report(phase: .departed, plan: nil)
        return .success(state(trip))
    }

    func unregister(from address: URL?) async throws {
        unregistered.append(address)
        events.append("unregister \(address?.absoluteString ?? "current")")
        if let address, let failure = unregisterFailures[address.absoluteString] { throw failure }
        if let unregisterFailure { throw unregisterFailure }
        if let address {
            leftBehind.removeAll { $0 == address }
        }
        held = []
    }

    func withdrawTrips() async throws {
        withdrawals += 1
        events.append("withdrawTrips")
        if let withdrawFailure { throw withdrawFailure }
        held = []
    }

    func serversLeftBehind() async -> [URL] {
        leftBehind
    }

    func notificationPermission() async -> NotificationPermission {
        permission
    }

    func requestNotificationPermission() async -> NotificationPermission {
        permissionRequests += 1
        if let permissionAfterRequest {
            permission = permissionAfterRequest
        }
        return permission
    }

    func refreshPushRegistration() async {
        pushRefreshes += 1
    }

    // MARK: Answers

    private func snapshot() -> MonitoringSnapshot {
        let now = clock.now()
        return MonitoringSnapshot(
            trips: Dictionary(held.map { ($0.id, state($0)) }, uniquingKeysWith: { first, _ in first }),
            push: push,
            limits: limits,
            acknowledgedAt: now,
            serverTime: now,
            monitor: monitor
        )
    }

    private func state(_ trip: MonitoredTrip) -> MonitoredTripState {
        let report = reports[trip.id] ?? Report(phase: .planning, plan: nil)
        return MonitoredTripState(
            id: trip.id,
            arriveBy: trip.arriveBy,
            phase: report.phase,
            plan: report.plan,
            noPlanReason: report.noPlanReason,
            planAvailableAt: report.planAvailableAt,
            monitoringStartsAt: report.monitoringStartsAt ?? report.plan.map { $0.departAt.addingTimeInterval(-limits.monitorLead) },
            monitoringStartedAt: report.phase == .monitoring ? report.plan.map { $0.departAt.addingTimeInterval(-limits.monitorLead) } : nil,
            headsUpAt: report.plan.map { $0.departAt.addingTimeInterval(-limits.headsUpLead) },
            headsUpSentAt: report.headsUpSentAt,
            leaveAlertSentAt: report.leaveAlertSentAt,
            lastAlert: report.lastAlert,
            endsAt: trip.arriveBy,
            nextCheckAt: report.nextCheckAt,
            lastErrorCode: report.lastErrorCode,
            lastErrorAt: report.lastErrorCode == nil ? nil : clock.now()
        )
    }
}

extension TestBackend {
    /// A monitored plan as the server would report it: leave at `departure`, arrive at `arrival`.
    static func plan(
        advice: DepartureAdvice = .leaveLater,
        departure: Date,
        arrival: Date,
        reason: String = "Leaving at 7:05 AM gets you there with 25 minutes to spare.",
        lateBy: TimeInterval? = nil,
        margin: TimeInterval? = 25 * 60,
        evaluatedAt: Date,
        isStale: Bool = false
    ) -> MonitoredPlan {
        MonitoredPlan(
            advice: advice,
            departAt: departure,
            arriveAt: arrival,
            driveMinutes: arrival.timeIntervalSince(departure) / 60,
            reason: reason,
            confidence: .high,
            confidenceReason: "Based on plenty of historical data and live traffic.",
            notes: [],
            lateBy: lateBy,
            margin: margin,
            evaluatedAt: evaluatedAt,
            source: TestBackend.liveSource,
            isStale: isStale
        )
    }

    /// The `limits` object every device and trip answer carries.
    static let limitsBody = #"{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50}"#

    /// A recommendation inside a trip state, in the backend's own shape.
    static func recommendationBody(
        action: String = "leave_later",
        departAt: Date,
        arriveAt: Date,
        reason: String = "Leaving at 7:05 AM gets you there with 25 minutes to spare.",
        confidence: String = "High",
        lateByMinutes: Int? = nil,
        marginMinutes: Int? = 25,
        evaluatedAt: Date,
        source: String = #"{"baseline":"tomtom","fallback":false,"live":true}"#,
        stale: Bool = false
    ) -> String {
        let minutes = Int((arriveAt.timeIntervalSince(departAt) / 60).rounded())
        var fields = [
            #""action":"\#(action)""#,
            #""departAt":"\#(iso(departAt))""#,
            #""arriveAt":"\#(iso(arriveAt))""#,
            #""driveMinutes":\#(minutes)"#,
            #""reason":"\#(reason)""#,
            #""confidence":"\#(confidence)""#,
            #""confidenceReason":"Based on plenty of historical data and live traffic.""#,
            #""notes":[]"#
        ]
        if let lateByMinutes {
            fields.append(#""lateByMinutes":\#(lateByMinutes)"#)
        }
        if let marginMinutes {
            fields.append(#""marginMinutes":\#(marginMinutes)"#)
        }
        fields.append(#""evaluatedAt":"\#(iso(evaluatedAt))""#)
        fields.append(#""source":\#(source)"#)
        fields.append(#""stale":\#(stale)"#)
        return object(fields)
    }

    /// One trip state in the backend's own shape, with `lastAlert` inside `monitoring`.
    static func tripStateBody(
        id: String,
        arriveBy: Date,
        phase: String,
        recommendation: String? = nil,
        noPlanReason: String? = nil,
        planAvailableAt: Date? = nil,
        startsAt: Date? = nil,
        startedAt: Date? = nil,
        headsUpAt: Date? = nil,
        headsUpSentAt: Date? = nil,
        leaveAlertSentAt: Date? = nil,
        nextCheckAt: Date? = nil,
        lastAlert: String? = nil,
        lastError: String? = nil
    ) -> String {
        func date(_ value: Date?) -> String {
            value.map { "\"\(iso($0))\"" } ?? "null"
        }
        let monitoring = object([
            #""startsAt":\#(date(startsAt))"#,
            #""startedAt":\#(date(startedAt))"#,
            #""headsUpAt":\#(date(headsUpAt))"#,
            #""headsUpSentAt":\#(date(headsUpSentAt))"#,
            #""leaveAlertSentAt":\#(date(leaveAlertSentAt))"#,
            #""endsAt":"\#(iso(arriveBy))""#,
            #""nextCheckAt":\#(date(nextCheckAt))"#,
            #""lastAlert":\#(lastAlert ?? "null")"#
        ])
        return object([
            #""id":"\#(id)""#,
            #""arriveBy":"\#(iso(arriveBy))""#,
            #""phase":"\#(phase)""#,
            #""recommendation":\#(recommendation ?? "null")"#,
            #""noPlanReason":\#(noPlanReason.map { "\"\($0)\"" } ?? "null")"#,
            #""planAvailableAt":\#(date(planAvailableAt))"#,
            #""monitoring":\#(monitoring)"#,
            #""lastError":\#(lastError ?? "null")"#
        ])
    }

    /// The answer to PUT /trips and GET /trips, in the backend's own shape.
    static func syncBody(
        revision: Int,
        applied: Bool,
        serverTime: Date,
        trips: [String],
        push: String = #"{"configured":true,"registered":true,"authorized":true}"#,
        monitor: String = #"{"enabled":true,"dependable":true,"lastTickAt":null}"#,
        limits: String = TestBackend.limitsBody
    ) -> String {
        object([
            #""revision":\#(revision)"#,
            #""applied":\#(applied)"#,
            #""digest":"0000000000000000000000000000000000000000000000000000000000000000""#,
            #""serverTime":"\#(iso(serverTime))""#,
            #""limits":\#(limits)"#,
            #""push":\#(push)"#,
            #""monitor":\#(monitor)"#,
            #""trips":[\#(trips.joined(separator: ","))]"#
        ])
    }

    /// A JSON object from its "key":value fields.
    static func object(_ fields: [String]) -> String {
        "{" + fields.joined(separator: ",") + "}"
    }
}

/// An in-memory stand-in for the backend's device and trip endpoints, following SPEC-API:
/// registration, bearer credentials, snapshot revisions (a lower revision changes nothing, the
/// stored revision with other trips is a conflict, a higher one is applied), "I've left" with
/// its arrival time, push status, and removal. Tests choose each trip's phase and plan, and
/// can make one request fail before or after the server applied it.
final class FakeTripServer: @unchecked Sendable {
    struct Trip {
        var id: String
        var arriveBy: Date
        var body: [String: Any]
        var phase: String?
        var recommendation: String?
        var isCancelled = false
        var isDeparted = false
    }

    struct Device {
        var token: String
        var revision = 0
        var canonical = "[]"
        var trips: [Trip] = []
        var apnsToken: String?
        var authorized = false
        var environment: String?
    }

    /// What else the server reports about one trip: its alerts and its own problems.
    struct TripDetails {
        var headsUpSentAt: Date?
        var leaveAlertSentAt: Date?
        /// The `lastAlert` object, as JSON.
        var lastAlert: String?
        /// The `lastError` object, as JSON.
        var lastError: String?
        var noPlanReason: String?
    }

    /// When a scripted failure strikes: before the server looks at the request, or after it
    /// applied it (the answer is lost on its way back).
    enum Moment {
        case before
        case afterApplying
    }

    private struct Fault {
        let method: String
        let path: String
        let moment: Moment
        let reply: ScriptedReply
    }

    private let lock = NSLock()
    private let clock: any WallClock
    private var devices: [String: Device] = [:]
    private var registrations = 0
    private var faults: [Fault] = []
    private var phases: [String: String] = [:]
    private var recommendations: [String: String] = [:]
    private var details: [String: TripDetails] = [:]
    private var verdict: ScriptedReply = .http(status: 502, body: TestBackend.errorBody("routing_unavailable", "The routing service is unavailable."))

    var pushConfigured = true
    var monitor = #"{"enabled":true,"dependable":true,"lastTickAt":null}"#
    var limits = TestBackend.limitsBody

    init(clock: any WallClock) {
        self.clock = clock
    }

    var responder: ScriptedHTTPTransport.Responder {
        { [self] request in self.respond(to: request) }
    }

    // MARK: Setup and inspection

    /// The next request with this method and path fails with `reply`.
    func failNext(_ method: String, _ path: String, _ moment: Moment = .before, with reply: ScriptedReply) {
        lock.lock()
        faults.append(Fault(method: method, path: path, moment: moment, reply: reply))
        lock.unlock()
    }

    /// How the trip with this id is reported from now on, on every device.
    func setPhase(_ id: String, _ phase: String, recommendation: String? = nil) {
        lock.lock()
        phases[id] = phase
        recommendations[id] = recommendation
        lock.unlock()
    }

    /// What the trip with this id reports beside its phase and plan, from now on.
    func setDetails(_ id: String, _ value: TripDetails?) {
        lock.lock()
        details[id] = value
        lock.unlock()
    }

    func setVerdict(_ reply: ScriptedReply) {
        lock.lock()
        verdict = reply
        lock.unlock()
    }

    /// Forgets every device, as a server that lost its data would.
    func loseDevices() {
        lock.lock()
        devices = [:]
        lock.unlock()
    }

    /// Cancels every trip of every device behind the app's back, without touching revisions.
    func cancelTrips() {
        lock.lock()
        for key in devices.keys {
            devices[key]?.trips = []
        }
        lock.unlock()
    }

    /// Clears the push token of every device, as a rejected token would.
    func dropPushTokens() {
        lock.lock()
        for key in devices.keys {
            devices[key]?.apnsToken = nil
        }
        lock.unlock()
    }

    var registrationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    var deviceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return devices.count
    }

    /// The ids of the trips the only device holds, sorted; empty without a device.
    var heldTripIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.flatMap(\.trips).filter { !$0.isCancelled }.map(\.id).sorted()
    }

    var storedRevision: Int? {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first?.revision
    }

    var storedPushToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first?.apnsToken
    }

    var storedAuthorized: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first?.authorized
    }

    // MARK: Answering

    func respond(to request: RecordedRequest) -> ScriptedReply {
        lock.lock()
        defer { lock.unlock() }
        var late: ScriptedReply?
        if let index = faults.firstIndex(where: { $0.method == request.method && $0.path == request.path }) {
            let fault = faults.remove(at: index)
            if fault.moment == .before { return fault.reply }
            late = fault.reply
        }
        let answer = handle(request)
        return late ?? answer
    }

    private func handle(_ request: RecordedRequest) -> ScriptedReply {
        let parts = request.path.split(separator: "/").map(String.init)
        if request.method == "POST", parts == ["verdict"] { return verdict }
        if request.method == "POST", parts == ["devices"] { return register() }
        guard let key = deviceKey(for: request) else {
            return .http(status: 401, body: TestBackend.errorBody("unauthorized", "This device is not registered."))
        }
        switch (request.method, parts.count) {
        case ("PUT", 3) where parts == ["devices", "me", "push"]:
            return setPush(key, request)
        case ("DELETE", 2) where parts == ["devices", "me"]:
            devices[key] = nil
            return .http(status: 204, body: "")
        case ("PUT", 1) where parts == ["trips"]:
            return synchronize(key, request)
        case ("GET", 1) where parts == ["trips"]:
            return .http(status: 200, body: snapshot(key, applied: false))
        case ("GET", 2) where parts[0] == "trips":
            guard let trip = activeTrip(key, parts[1]) else { return notFound() }
            return .http(status: 200, body: TestBackend.object([
                #""trip":\#(state(trip))"#,
                #""serverTime":"\#(TestBackend.iso(clock.now()))""#,
                #""push":\#(pushBody(key))"#,
                #""limits":\#(limits)"#,
                #""monitor":\#(monitor)"#
            ]))
        case ("POST", 3) where parts[0] == "trips" && parts[2] == "departed":
            return departed(key, parts[1], request)
        default:
            return .http(status: 404, body: #"{"message":"Route not found","error":"Not Found","statusCode":404}"#)
        }
    }

    private func register() -> ScriptedReply {
        registrations += 1
        let deviceID = UUID().uuidString.lowercased()
        let secret = String(repeating: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", count: 1).prefix(42) + String(registrations % 10)
        let token = "\(deviceID).\(secret)"
        devices[token] = Device(token: token)
        return .http(status: 201, body: TestBackend.object([
            #""deviceId":"\#(deviceID)""#,
            #""token":"\#(token)""#,
            #""limits":\#(limits)"#
        ]))
    }

    private func deviceKey(for request: RecordedRequest) -> String? {
        guard let header = request.headers["Authorization"], header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return devices[token] == nil ? nil : token
    }

    private func setPush(_ key: String, _ request: RecordedRequest) -> ScriptedReply {
        let body = request.jsonObject()
        guard body.keys.sorted() == ["apnsToken", "authorized", "environment"],
              let environment = body["environment"] as? String, ["sandbox", "production"].contains(environment),
              let authorized = body["authorized"] as? Bool else {
            return .http(status: 400, body: TestBackend.errorBody("bad_request", "The push details are not acceptable."))
        }
        let token = body["apnsToken"] as? String
        if let token, token.count < 32 {
            return .http(status: 400, body: TestBackend.errorBody("bad_request", "The push token is not acceptable."))
        }
        if let token {
            // One token belongs to one device: every other device loses it and its trips.
            for other in devices.keys where other != key && devices[other]?.apnsToken == token.lowercased() {
                devices[other]?.apnsToken = nil
                devices[other]?.trips = []
            }
        }
        devices[key]?.apnsToken = token?.lowercased()
        devices[key]?.environment = environment
        devices[key]?.authorized = authorized
        return .http(status: 200, body: TestBackend.object([#""push":\#(pushBody(key))"#]))
    }

    private func synchronize(_ key: String, _ request: RecordedRequest) -> ScriptedReply {
        let body = request.jsonObject()
        guard let revision = body["revision"] as? Int, revision >= 1, let list = body["trips"] as? [[String: Any]] else {
            return .http(status: 400, body: TestBackend.errorBody("bad_request", "The snapshot is not acceptable."))
        }
        var incoming: [Trip] = []
        let now = clock.now()
        for item in list {
            guard let id = item["id"] as? String, let title = item["title"] as? String, !title.isEmpty, title.unicodeScalars.count <= 120,
                  let text = item["arriveBy"] as? String, let arriveBy = BackendDate.parse(text),
                  item["timeZone"] is String, item["origin"] is [String: Any], item["destination"] is [String: Any] else {
                return .http(status: 400, body: TestBackend.errorBody("bad_request", "A trip is not acceptable."))
            }
            if arriveBy.timeIntervalSince(now) >= 8 * 86_400 {
                return .http(status: 400, body: TestBackend.errorBody("bad_request", "A trip's arrival time is more than 8 days away."))
            }
            incoming.append(Trip(id: id, arriveBy: arriveBy, body: item))
        }
        let canonical = incoming.sorted { $0.id < $1.id }.map { "\($0.id) \(TestBackend.iso($0.arriveBy)) \($0.body["title"] as? String ?? "")" }.joined(separator: ";")
        guard var device = devices[key] else { return notFound() }
        if revision < device.revision {
            return .http(status: 200, body: snapshot(key, applied: false))
        }
        if revision == device.revision {
            if canonical != device.canonical {
                let conflict = TestBackend.object([
                    #""error":"revision_conflict""#,
                    #""message":"A different set of trips already used this revision. Send it again with a higher one.""#,
                    #""revision":\#(device.revision)"#
                ])
                return .http(status: 409, body: conflict)
            }
            return .http(status: 200, body: snapshot(key, applied: false))
        }
        // A trip the user left stays left unless its arrival time changed.
        let left = Set(device.trips.filter(\.isDeparted).map { "\($0.id) \(TestBackend.iso($0.arriveBy))" })
        device.trips = incoming.map { trip in
            var kept = trip
            kept.isDeparted = left.contains("\(trip.id) \(TestBackend.iso(trip.arriveBy))")
            return kept
        }
        device.revision = revision
        device.canonical = canonical
        devices[key] = device
        return .http(status: 200, body: snapshot(key, applied: true))
    }

    private func departed(_ key: String, _ id: String, _ request: RecordedRequest) -> ScriptedReply {
        guard let text = request.string("arriveBy"), let arriveBy = BackendDate.parse(text) else {
            return .http(status: 400, body: TestBackend.errorBody("bad_request", "arriveBy is not a date and time."))
        }
        guard let index = devices[key]?.trips.firstIndex(where: { $0.id == id && !$0.isCancelled }) else { return notFound() }
        guard let trip = devices[key]?.trips[index], trip.arriveBy == arriveBy else {
            return .http(status: 409, body: TestBackend.errorBody("superseded", "This trip was rescheduled."))
        }
        devices[key]?.trips[index].isDeparted = true
        guard let updated = devices[key]?.trips[index] else { return notFound() }
        return .http(status: 200, body: TestBackend.object([#""trip":\#(state(updated))"#]))
    }

    private func activeTrip(_ key: String, _ id: String) -> Trip? {
        devices[key]?.trips.first { $0.id == id && !$0.isCancelled }
    }

    private func notFound() -> ScriptedReply {
        .http(status: 404, body: TestBackend.errorBody("not_found", "No such trip."))
    }

    private func pushBody(_ key: String) -> String {
        let device = devices[key]
        return TestBackend.object([
            #""configured":\#(pushConfigured)"#,
            #""registered":\#(device?.apnsToken != nil)"#,
            #""authorized":\#(device?.authorized ?? false)"#
        ])
    }

    private func snapshot(_ key: String, applied: Bool) -> String {
        let device = devices[key]
        let trips = (device?.trips ?? []).filter { !$0.isCancelled }.sorted { $0.arriveBy < $1.arriveBy }.map(state)
        return TestBackend.syncBody(
            revision: device?.revision ?? 0,
            applied: applied,
            serverTime: clock.now(),
            trips: trips,
            push: pushBody(key),
            monitor: monitor,
            limits: limits
        )
    }

    /// One trip as the backend reports it: its phase follows the clock unless the test set one.
    private func state(_ trip: Trip) -> String {
        let now = clock.now()
        let horizon: TimeInterval = 690 * 60
        var phase = phases[trip.id] ?? (trip.arriveBy.timeIntervalSince(now) > horizon ? "scheduled" : "planning")
        if trip.isDeparted {
            phase = "departed"
        } else if trip.arriveBy <= now {
            phase = "ended"
        }
        let isLive = phase != "departed" && phase != "ended"
        let extra = isLive ? details[trip.id] : nil
        return TestBackend.tripStateBody(
            id: trip.id,
            arriveBy: trip.arriveBy,
            phase: phase,
            recommendation: isLive ? recommendations[trip.id] : nil,
            noPlanReason: extra?.noPlanReason,
            planAvailableAt: phase == "scheduled" ? trip.arriveBy.addingTimeInterval(-horizon) : nil,
            startedAt: phase == "monitoring" ? now.addingTimeInterval(-600) : nil,
            headsUpSentAt: extra?.headsUpSentAt,
            leaveAlertSentAt: extra?.leaveAlertSentAt,
            nextCheckAt: isLive ? now.addingTimeInterval(300) : nil,
            lastAlert: extra?.lastAlert,
            lastError: extra?.lastError
        )
    }
}
