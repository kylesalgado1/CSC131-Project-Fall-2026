import CryptoKit
import Foundation

/// The three values the server is told about push: where alerts go, in which push
/// environment, and whether the user allows them.
struct PushReport: Equatable, Sendable {
    let token: String?
    let environment: String
    let authorized: Bool
}

/// The team backend's device and trip endpoints behind the `TripMonitoring` boundary, and the
/// source of monitored answers for `BackendCommuteProvider`.
///
/// - **Credentials.** There are no accounts: the installation registers once per server
///   origin and keeps the bearer credential in the injected `CredentialStoring` (the Keychain
///   in the host). A device is registered only when trips are synchronized, never just to
///   read, end, or remove something.
/// - **Snapshots.** `synchronize` sends the complete set of trips under a revision. A revision
///   is used again only to resend exactly the body last sent under it; any other body gets a
///   higher one, stored before it is sent. A snapshot counts as acknowledged only when the
///   server answers with the revision that was sent and exactly the trips that were sent.
/// - **One snapshot.** The session answers `answer(for:)` only from the last snapshot it
///   returned to its caller, and only for a plan the server still keeps current
///   (`MonitoredTripState.currentPlan`). It never refreshes by itself; the model owns
///   refreshing.
/// - **Order.** Every network operation runs in a queue of its own tasks, one after the other,
///   so interleaved calls cannot reorder revisions and a caller's cancellation never fails
///   another caller. A newer `synchronize` replaces an older one that has not started.
/// - **Addresses.** State belongs to one server origin. When the address changes, a new
///   generation starts with empty state, and an answer from the old address is dropped.
///   Every request is pinned to the address its operation started with, so a credential is
///   never sent to another server.
/// Bodies, coordinates, and credentials are never logged.
public actor BackendSession: TripMonitoring, MonitoredTripSource {
    private struct Target: Sendable {
        let baseURL: URL
        let origin: String
        /// The generation the target belongs to, or `nil` for a server that is not in use.
        let generation: UInt64?
    }

    private enum PushOutcome {
        case unchanged
        case reported(PushDeliveryStatus)
        case failed
        case unauthorized
    }

    /// What became of one snapshot sent with PUT /trips.
    private enum SnapshotOutcome {
        /// The server holds exactly the trips that were sent, under the credential `token`.
        case acknowledged(WireSyncResponse, token: String)
        /// The server no longer knows the device, and it was not registered again.
        case deviceUnknown
    }

    private let client: BackendClient
    private let credentials: any CredentialStoring
    private let push: (any PushRegistering)?
    private let clock: any WallClock

    // State of the server address in use; reset when the address changes.
    private var generation: UInt64 = 0
    private var origin: String?
    private var credential: StoredCredential?
    private var credentialIsLoaded = false
    private var snapshot: MonitoringSnapshot?
    private var acknowledgedTrips: [OccurrenceID: MonitoredTrip] = [:]
    private var limits: MonitoringLimits?
    private var reportedPush: PushReport?
    private var hasRepairedPush = false

    // This device's push registration, whatever the server. The failure is the system's own
    // reason, without a sentence around it.
    private var deviceToken: String?
    private var registrationFailure: String?

    // Serialization.
    private var queueTail: Task<Void, Never>?
    private var newestSynchronize: UInt64 = 0

    /// - Parameter push: the host's notification and registration adapter. Without one (unit
    ///   tests, previews) permission is "not determined" and nothing is registered or reported.
    public init(client: BackendClient, credentials: any CredentialStoring, push: (any PushRegistering)?, clock: any WallClock) {
        self.client = client
        self.credentials = credentials
        self.push = push
        self.clock = clock
    }

    // MARK: TripMonitoring

    public func synchronize(_ trips: [MonitoredTrip]) async throws -> MonitoringSnapshot {
        newestSynchronize &+= 1
        let ticket = newestSynchronize
        return try await serialized { [self] in
            try await self.runSynchronize(trips, ticket: ticket)
        }
    }

    public func refresh() async throws -> MonitoringSnapshot {
        try await serialized { [self] in
            try await self.runRefresh()
        }
    }

    public func refreshTrip(_ id: OccurrenceID) async throws -> MonitoredTripState? {
        try await serialized { [self] in
            try await self.runRefreshTrip(id)
        }
    }

    public func markDeparted(_ id: OccurrenceID, arriveBy: Date) async -> Result<MonitoredTripState, TripMonitoringFailure> {
        do {
            let state = try await serialized { [self] in
                try await self.runMarkDeparted(id, arriveBy: arriveBy)
            }
            return .success(state)
        } catch let failure as TripMonitoringFailure {
            return .failure(failure)
        } catch {
            // The address changed while the request was under way: nothing is known.
            return .failure(.invalidResponse)
        }
    }

    public func unregister(from address: URL?) async throws {
        try await serialized { [self] in
            try await self.runUnregister(from: address)
        }
    }

    public func withdrawTrips() async throws {
        // A snapshot that is still waiting its turn would only be withdrawn again.
        newestSynchronize &+= 1
        try await serialized { [self] in
            try await self.runWithdrawTrips()
        }
    }

    public func serversLeftBehind() async -> [URL] {
        guard let stored = try? await credentials.origins() else { return [] }
        let inUse = client.configuration.baseURL.flatMap(Self.origin(of:))
        return stored.filter { $0 != inUse }.compactMap { URL(string: $0) }
    }

    public func notificationPermission() async -> NotificationPermission {
        guard let push else { return .notDetermined }
        return await push.authorizationStatus()
    }

    public func requestNotificationPermission() async -> NotificationPermission {
        guard let push else { return .notDetermined }
        let permission = await push.requestPermission()
        if permission == .authorized {
            await push.registerForRemoteNotifications()
        }
        return permission
    }

    public func refreshPushRegistration() async {
        // A new foreground may repair a token the server lost, once.
        hasRepairedPush = false
        guard let push else { return }
        if await push.authorizationStatus() == .authorized {
            await push.registerForRemoteNotifications()
        }
    }

    // MARK: Push registration (called by the host)

    /// The host's device token from the push service, or `nil` when there is none any more.
    /// It is reported to the server with the next synchronize or refresh. Returns whether
    /// anything changed; when it did, the host calls
    /// `WaitItOutModel.pushRegistrationDidChange()` so the report goes out at once. The push
    /// service hands over the same token at every launch, which is not a change.
    @discardableResult
    public func updateDeviceToken(_ token: Data?) -> Bool {
        let text = token.map(Self.hex)
        let isChanged = text != deviceToken || (text != nil && registrationFailure != nil)
        deviceToken = text
        if text != nil {
            registrationFailure = nil
        }
        return isChanged
    }

    /// The host could not register with the push service. The system's reason is shown as a
    /// failure of this device (`PushDeliveryStatus.registrationFailure`) while the server has
    /// no token for it. Returns whether that is news.
    @discardableResult
    public func registrationFailed(_ description: String) -> Bool {
        let reason = BackendClient.sentence(description) ?? "unknown reason"
        let isChanged = reason != registrationFailure
        registrationFailure = reason
        return isChanged
    }

    // MARK: MonitoredTripSource

    /// The server's own recommendation for `request`, only while the server still keeps that
    /// plan current (`MonitoredTripState.currentPlan`: it is actively monitoring the trip, its
    /// monitoring worker runs, the plan is not stale, its departure is still ahead, and no
    /// time-to-leave or late alert was sent or queued), the trip it was sent matches the
    /// request exactly, and the snapshot is still within `MonitoringSnapshot.lifetime`. `nil`
    /// in every other case: the provider then asks the backend directly, so a screen never
    /// shows a plan nobody refreshes as the current recommendation.
    public func answer(for request: CommuteRequest) async throws -> CommuteEstimateResponse? {
        let now = clock.now()
        guard let snapshot, isAddressCurrent,
              now.timeIntervalSince(snapshot.acknowledgedAt) < MonitoringSnapshot.lifetime,
              let trip = snapshot.trips[request.occurrenceID],
              let plan = trip.currentPlan(monitorEnabled: snapshot.monitor.enabled, at: now),
              let sent = acknowledgedTrips[request.occurrenceID],
              sent.arriveBy == request.arriveBy,
              sent.origin == request.origin.coordinate,
              sent.destination == request.destination.coordinate,
              BackendDate.string(from: trip.arriveBy) == BackendDate.string(from: request.arriveBy) else {
            return nil
        }
        return .recommendation(Self.recommendation(from: plan, acknowledgedAt: snapshot.acknowledgedAt, serverTime: snapshot.serverTime))
    }

    public func planningHorizon() async -> TimeInterval? {
        isAddressCurrent ? limits?.planningHorizon : nil
    }

    // MARK: Operations

    private func runSynchronize(_ trips: [MonitoredTrip], ticket: UInt64) async throws -> MonitoringSnapshot {
        // A newer snapshot was asked for while this one waited its turn: only the newest is sent.
        guard ticket == newestSynchronize else { throw CancellationError() }
        let target = try currentTarget()
        let sent = Self.normalized(trips)

        var current: StoredCredential
        var hasReregistered = false
        if let stored = try await loadCredential(target) {
            current = stored
        } else {
            current = try await register(target)
        }
        if case .unauthorized = await reportPushIfChanged(target, token: current.token) {
            await forgetCredential(target)
            hasReregistered = true
            current = try await register(target)
            _ = await reportPushIfChanged(target, token: current.token)
        }

        let answer = try await putSnapshot(sent, credential: current, target: target, registersAgain: !hasReregistered)
        guard case .acknowledged(let response, let token) = answer else {
            // The server keeps refusing a device it has only just registered.
            throw TripMonitoringFailure.server(status: 401)
        }
        guard isCurrent(target) else { throw CancellationError() }
        let acknowledged = try makeSnapshot(from: response)
        snapshot = acknowledged
        limits = acknowledged.limits
        acknowledgedTrips = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return await repairingPush(in: acknowledged, target: target, token: token)
    }

    /// The empty snapshot of a withdrawal, under the credential this installation already has.
    /// Unlike `runSynchronize` it never registers and reports no push token: the user is
    /// opting out, so nothing new about this device may reach the server.
    private func runWithdrawTrips() async throws {
        let target = try currentTarget()
        // No credential: this installation is not on that server, and none is made.
        guard let current = try await loadCredential(target) else { return }
        let answer = try await putSnapshot([], credential: current, target: target, registersAgain: false)
        guard case .acknowledged = answer, isCurrent(target) else { return }
        snapshot = nil
        acknowledgedTrips = [:]
    }

    /// PUT /trips for `sent` under the revision rules, until the server acknowledges exactly
    /// that set. When the server no longer knows the device, `registersAgain` registers it
    /// anew once and sends everything again; without it the credential is dropped and the
    /// outcome is `.deviceUnknown`: nothing of this installation is left there.
    private func putSnapshot(
        _ sent: [MonitoredTrip],
        credential: StoredCredential,
        target: Target,
        registersAgain: Bool
    ) async throws -> SnapshotOutcome {
        let wireTrips = sent.map(Self.wireTrip)
        let digest = Self.sha256Hex(try encode(wireTrips))
        var current = credential
        var mayRegister = registersAgain
        var hasBumped = false
        while true {
            let revision: Int
            if current.sentDigest == digest, current.revision >= 1 {
                // Exactly the body last sent under this revision: a safe resend.
                revision = current.revision
            } else {
                revision = max(current.revision, current.serverRevision) + 1
                current.revision = revision
                current.sentDigest = digest
                // Stored before sending, so a lost answer can never lead to a reused revision.
                try await store(current, target)
            }
            let body = try encode(WireSyncRequest(revision: revision, trips: wireTrips))
            let reply = try await send(target, method: "PUT", path: ["trips"], body: body, token: current.token)
            if reply.status == 401 {
                // The server lost this device: register again once and send everything again.
                await forgetCredential(target)
                guard mayRegister else { return .deviceUnknown }
                mayRegister = false
                current = try await register(target)
                _ = await reportPushIfChanged(target, token: current.token)
                continue
            }
            if reply.status == 409, reply.errorCode == "revision_conflict" {
                // Another body already used this revision: move past what the server holds.
                guard !hasBumped else { throw TripMonitoringFailure.server(status: 409) }
                hasBumped = true
                let held = (try? decode(WireRevisionConflict.self, from: reply))?.revision ?? revision
                current.serverRevision = max(current.serverRevision, held)
                current.sentDigest = nil
                continue
            }
            guard reply.isSuccess else { throw Self.failure(for: reply) }
            let response = try decode(WireSyncResponse.self, from: reply)
            if response.revision > current.serverRevision {
                current.serverRevision = response.revision
                try? await store(current, target)
            }
            if response.revision == revision, Self.isSameSet(sent, response.trips) {
                return .acknowledged(response, token: current.token)
            }
            // The local counter fell behind, or the server no longer holds what was sent
            // (its trips were cancelled from elsewhere): send once more under a new revision.
            guard !hasBumped else { throw TripMonitoringFailure.invalidResponse }
            hasBumped = true
            current.sentDigest = nil
        }
    }

    private func runRefresh() async throws -> MonitoringSnapshot {
        let target = try currentTarget()
        guard var current = try await loadCredential(target) else { throw TripMonitoringFailure.notRegistered }
        if case .unauthorized = await reportPushIfChanged(target, token: current.token) {
            await forgetCredential(target)
            throw TripMonitoringFailure.reregistered
        }
        let reply = try await send(target, method: "GET", path: ["trips"], token: current.token)
        if reply.status == 401 {
            await forgetCredential(target)
            throw TripMonitoringFailure.reregistered
        }
        guard reply.isSuccess else { throw Self.failure(for: reply) }
        let response = try decode(WireSyncResponse.self, from: reply)
        if response.revision > current.serverRevision {
            current.serverRevision = response.revision
            try? await store(current, target)
        }
        guard isCurrent(target) else { throw CancellationError() }
        let refreshed = try makeSnapshot(from: response)
        snapshot = refreshed
        limits = refreshed.limits
        return await repairingPush(in: refreshed, target: target, token: current.token)
    }

    private func runRefreshTrip(_ id: OccurrenceID) async throws -> MonitoredTripState? {
        let target = try currentTarget()
        guard let current = try await loadCredential(target) else { throw TripMonitoringFailure.notRegistered }
        let reply = try await send(target, method: "GET", path: ["trips", id.rawValue], token: current.token)
        if reply.status == 401 {
            await forgetCredential(target)
            throw TripMonitoringFailure.reregistered
        }
        if reply.status == 404, reply.errorCode == "not_found" {
            if isCurrent(target) {
                replaceTrip(id, with: nil)
            }
            return nil
        }
        guard reply.isSuccess else { throw Self.failure(for: reply) }
        let detail = try decode(WireTripDetail.self, from: reply)
        guard let state = try Self.tripState(from: detail.trip), state.id == id else {
            throw TripMonitoringFailure.invalidResponse
        }
        guard isCurrent(target) else { throw CancellationError() }
        replaceTrip(id, with: state)
        return state
    }

    private func runMarkDeparted(_ id: OccurrenceID, arriveBy: Date) async throws -> MonitoredTripState {
        let target = try currentTarget()
        guard let current = try await loadCredential(target) else { throw TripMonitoringFailure.notRegistered }
        let body = try encode(WireDepartedRequest(arriveBy: arriveBy))
        let reply = try await send(target, method: "POST", path: ["trips", id.rawValue, "departed"], body: body, token: current.token)
        if reply.status == 401 {
            await forgetCredential(target)
            throw TripMonitoringFailure.reregistered
        }
        if reply.errorCode == "superseded" { throw TripMonitoringFailure.superseded }
        if reply.status == 404, reply.errorCode == "not_found" { throw TripMonitoringFailure.notMonitored }
        guard reply.isSuccess else { throw Self.failure(for: reply) }
        let response = try decode(WireDepartedResponse.self, from: reply)
        guard let state = try Self.tripState(from: response.trip), state.id == id else {
            throw TripMonitoringFailure.invalidResponse
        }
        guard isCurrent(target) else { throw CancellationError() }
        replaceTrip(id, with: state)
        return state
    }

    private func runUnregister(from address: URL?) async throws {
        // No address or no credential: this installation is not on that server.
        guard let baseURL = address ?? client.configuration.baseURL, let origin = Self.origin(of: baseURL) else { return }
        let target = Target(baseURL: baseURL, origin: origin, generation: origin == self.origin ? generation : nil)
        guard let current = try await loadCredential(target) else { return }
        let reply = try await send(target, method: "DELETE", path: ["devices", "me"], token: current.token)
        // Removed now (204), already unknown to the server (401), or a server that predates
        // these endpoints (a 404 that is not the API's own), where there is nothing to remove.
        // Every other answer, including 503 "monitoring_unavailable" and
        // "temporarily_unavailable", says nothing about what the server still holds for a
        // device that was registered there: the credential is kept, so the removal can be
        // tried again, and the failure is reported.
        let predatesEndpoints = reply.status == 404 && reply.errorCode != "not_found"
        guard reply.status == 204 || reply.status == 401 || predatesEndpoints else {
            // Another success status is not the API's answer (a sign-in page, a proxy).
            throw reply.isSuccess ? TripMonitoringFailure.invalidResponse : Self.failure(for: reply)
        }
        await forgetCredential(target)
    }

    // MARK: Address and credential

    /// The address in use now. A changed address starts a new generation with empty state.
    private func currentTarget() throws -> Target {
        guard let baseURL = client.configuration.baseURL, let origin = Self.origin(of: baseURL) else {
            throw TripMonitoringFailure.notConfigured
        }
        if origin != self.origin {
            generation &+= 1
            self.origin = origin
            credential = nil
            credentialIsLoaded = false
            snapshot = nil
            acknowledgedTrips = [:]
            limits = nil
            reportedPush = nil
            hasRepairedPush = false
        }
        return Target(baseURL: baseURL, origin: origin, generation: generation)
    }

    /// True while the state still belongs to the address the client uses.
    private var isAddressCurrent: Bool {
        guard let origin else { return false }
        return client.configuration.baseURL.flatMap(Self.origin(of:)) == origin
    }

    /// True while `target` is the generation in use and the address has not moved on.
    private func isCurrent(_ target: Target) -> Bool {
        target.generation == generation && target.origin == origin && isAddressCurrent
    }

    private func loadCredential(_ target: Target) async throws -> StoredCredential? {
        if isCurrent(target), credentialIsLoaded { return credential }
        let stored: StoredCredential?
        do {
            stored = try await credentials.load(origin: target.origin)
        } catch {
            throw TripMonitoringFailure.credentialStorage
        }
        if isCurrent(target) {
            credential = stored
            credentialIsLoaded = true
        }
        return stored
    }

    private func store(_ value: StoredCredential, _ target: Target) async throws {
        do {
            try await credentials.save(value, origin: target.origin)
        } catch {
            throw TripMonitoringFailure.credentialStorage
        }
        if isCurrent(target) {
            credential = value
            credentialIsLoaded = true
        }
    }

    /// Drops the credential for the target's server, and everything known about that server
    /// when it is the one in use.
    private func forgetCredential(_ target: Target) async {
        try? await credentials.clear(origin: target.origin)
        guard target.origin == origin else { return }
        credential = nil
        credentialIsLoaded = true
        snapshot = nil
        acknowledgedTrips = [:]
        reportedPush = nil
    }

    /// POST /devices: a new device for this installation on the target's server.
    private func register(_ target: Target) async throws -> StoredCredential {
        let body = try encode(WireRegisterRequest(platform: "ios"))
        let reply = try await send(target, method: "POST", path: ["devices"], body: body, token: nil)
        guard reply.isSuccess else { throw Self.failure(for: reply) }
        let registration = try decode(WireRegistration.self, from: reply)
        guard Self.isUsableToken(registration.token), !registration.deviceId.isEmpty else {
            throw TripMonitoringFailure.invalidResponse
        }
        let registered = StoredCredential(deviceID: registration.deviceId, token: registration.token)
        try await store(registered, target)
        if isCurrent(target) {
            limits = Self.limits(from: registration.limits)
            reportedPush = nil
        }
        return registered
    }

    // MARK: Push reporting

    /// Tells the server where alerts go and whether they are allowed, when any of the three
    /// values changed since the last report that succeeded. A failed report is simply tried
    /// again with the next synchronize or refresh. While notifications are allowed but the
    /// push service has not handed over a token yet, nothing is reported, so a token the
    /// server already holds is not cleared at every launch. `force` sends the report whatever
    /// was reported before; `repairingPush` uses it when the server's view is known to be wrong.
    private func reportPushIfChanged(_ target: Target, token: String, force: Bool = false) async -> PushOutcome {
        guard let push, isCurrent(target) else { return .unchanged }
        let isAuthorized = await push.authorizationStatus() == .authorized
        let report = PushReport(token: deviceToken, environment: push.apnsEnvironment, authorized: isAuthorized)
        if !force {
            guard report != reportedPush else { return .unchanged }
            if report.token == nil {
                // Nothing to tell a server that was never told anything, and nothing to clear
                // while the token may still be on its way.
                if report.authorized || reportedPush == nil { return .unchanged }
            }
        }
        let request = WirePushRequest(apnsToken: report.token, environment: report.environment, authorized: report.authorized)
        guard let body = try? encode(request),
              let reply = try? await send(target, method: "PUT", path: ["devices", "me", "push"], body: body, token: token) else {
            return .failed
        }
        if reply.status == 401 { return .unauthorized }
        guard reply.isSuccess, let response = try? decode(WirePushResponse.self, from: reply) else { return .failed }
        if isCurrent(target) {
            reportedPush = report
        }
        return .reported(pushStatus(from: response.push))
    }

    /// Brings the server's view of push in line with the device when the two disagree, at most
    /// once per foreground. The server says it has no token although the device holds one and
    /// notifications are allowed (the push service rejected it, or another installation took it
    /// over): the token is sent again. Or the server still believes notifications are allowed
    /// although they no longer are (they were turned off while the app was not running): it is
    /// told, so it stops sending alerts nobody would see.
    private func repairingPush(in current: MonitoringSnapshot, target: Target, token: String) async -> MonitoringSnapshot {
        guard let push, !hasRepairedPush else { return current }
        let isAuthorized = await push.authorizationStatus() == .authorized
        let lostToken = !current.push.deviceRegistered && deviceToken != nil && isAuthorized
        let staleConsent = current.push.authorized && !isAuthorized
        guard lostToken || staleConsent else { return current }
        hasRepairedPush = true
        guard case .reported(let status) = await reportPushIfChanged(target, token: token, force: true), isCurrent(target) else {
            return current
        }
        let repaired = MonitoringSnapshot(
            trips: current.trips,
            push: status,
            limits: current.limits,
            acknowledgedAt: current.acknowledgedAt,
            serverTime: current.serverTime,
            monitor: current.monitor
        )
        snapshot = repaired
        return repaired
    }

    // MARK: Snapshot

    private func makeSnapshot(from response: WireSyncResponse) throws -> MonitoringSnapshot {
        var trips: [OccurrenceID: MonitoredTripState] = [:]
        for wire in response.trips {
            // An id that is not one of the app's occurrence ids is not the app's trip.
            if let state = try Self.tripState(from: wire) {
                trips[state.id] = state
            }
        }
        return MonitoringSnapshot(
            trips: trips,
            push: pushStatus(from: response.push),
            limits: Self.limits(from: response.limits),
            acknowledgedAt: clock.now(),
            serverTime: response.serverTime,
            monitor: MonitorHealth(
                enabled: response.monitor?.enabled ?? false,
                dependable: (response.monitor?.enabled ?? false) && (response.monitor?.dependable ?? false),
                lastTickAt: response.monitor?.lastTickAt
            )
        )
    }

    private func pushStatus(from wire: WirePushStatus?) -> PushDeliveryStatus {
        let isRegistered = wire?.registered ?? false
        return PushDeliveryStatus(
            serverConfigured: wire?.configured ?? false,
            deviceRegistered: isRegistered,
            authorized: wire?.authorized ?? false,
            lastFailure: BackendClient.sentence(wire?.lastFailure?.reason),
            // This device's own failure matters only while the server has no token for it.
            registrationFailure: isRegistered ? nil : registrationFailure
        )
    }

    /// Puts one trip's newer state into the snapshot (or removes the trip), keeping the
    /// snapshot's own stamps so the other trips do not look fresher than they are.
    private func replaceTrip(_ id: OccurrenceID, with state: MonitoredTripState?) {
        guard let current = snapshot else { return }
        var trips = current.trips
        trips[id] = state
        snapshot = MonitoringSnapshot(
            trips: trips,
            push: current.push,
            limits: current.limits,
            acknowledgedAt: current.acknowledgedAt,
            serverTime: current.serverTime,
            monitor: current.monitor
        )
    }

    // MARK: Plumbing

    /// Runs `work` after everything queued before it, in a task of the session's own, so the
    /// operations never interleave and a cancelled caller does not cancel the request others
    /// may be waiting for.
    private func serialized<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let previous = queueTail
        let task = Task<Value, Error> {
            await previous?.value
            return try await work()
        }
        queueTail = Task {
            _ = await task.result
        }
        return try await task.value
    }

    private func send(_ target: Target, method: String, path: [String], body: Data? = nil, token: String?) async throws -> BackendReply {
        do {
            return try await client.send(method: method, path: path, body: body, bearerToken: token, baseURL: target.baseURL)
        } catch let failure as CommuteProviderFailure {
            throw Self.failure(for: failure.kind)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = BackendJSON.makeEncoder()
        // Sorted keys make the same trips the same bytes, which is what a resend relies on.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw TripMonitoringFailure.rejected(message: "A trip's details could not be written.")
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from reply: BackendReply) throws -> Value {
        do {
            return try BackendJSON.makeDecoder().decode(type, from: reply.data)
        } catch {
            throw TripMonitoringFailure.invalidResponse
        }
    }

    // MARK: Pure helpers

    /// The origin a credential belongs to: lowercased scheme and host, with the port unless it
    /// is the scheme's default. `nil` for an address without a scheme or a host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Lowercase hexadecimal, as the server expects a push token.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A bearer credential that can be written into a header: visible ASCII without spaces.
    static func isUsableToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    /// One trip per id, in id order, so the same set is always the same body.
    static func normalized(_ trips: [MonitoredTrip]) -> [MonitoredTrip] {
        var seen: Set<OccurrenceID> = []
        return trips
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    static func wireTrip(_ trip: MonitoredTrip) -> WireTripInput {
        WireTripInput(
            id: trip.id.rawValue,
            title: trip.title,
            origin: WirePoint(trip.origin),
            destination: WirePoint(trip.destination),
            arriveBy: trip.arriveBy,
            timeZone: trip.timeZoneIdentifier
        )
    }

    /// True when the server's answer lists exactly the trips that were sent: the same ids
    /// with the same arrival times, compared as they are written on the wire.
    static func isSameSet(_ sent: [MonitoredTrip], _ returned: [WireTripState]) -> Bool {
        let wanted = Set(sent.map { "\($0.id.rawValue) \(BackendDate.string(from: $0.arriveBy))" })
        let held = Set(returned.map { "\($0.id) \(BackendDate.string(from: $0.arriveBy))" })
        return wanted == held
    }

    /// The failure for an error answer no operation handles itself, discriminated by the
    /// body's code first. `temporarily_unavailable` (HTTP 503) is the server's word for "try
    /// again shortly" and always maps to a transient failure. `monitoring_unavailable` (HTTP
    /// 503) means its trip tables are not set up yet, and a 404 that is not the API's own
    /// `not_found` means the server predates these endpoints: both are "not supported by this
    /// server", which is not retried on the minute ticks.
    static func failure(for reply: BackendReply) -> TripMonitoringFailure {
        if reply.errorCode == "temporarily_unavailable" {
            return .server(status: reply.status >= 500 ? reply.status : 503)
        }
        if reply.errorCode == "monitoring_unavailable" { return .unavailableOnServer }
        if reply.status == 404, reply.errorCode != "not_found" { return .unavailableOnServer }
        if reply.status == 400 || reply.errorCode == "bad_request" {
            return .rejected(message: reply.errorMessage ?? "The request was not acceptable.")
        }
        return .server(status: reply.status)
    }

    static func failure(for kind: CommuteProviderFailure.Kind) -> TripMonitoringFailure {
        switch kind {
        case .notConfigured:
            return .notConfigured
        case .offline:
            return .offline
        case .timedOut:
            return .timedOut
        case .routingUnavailable:
            return .server(status: 502)
        case .server(let status):
            return .server(status: status)
        case .invalidResponse:
            return .invalidResponse
        case .unauthorized:
            return .server(status: 401)
        }
    }

    /// The server's numbers, with the fallback for any that are missing or unusable.
    static func limits(from wire: WireLimits?) -> MonitoringLimits {
        let fallback = MonitoringLimits.fallback
        func seconds(_ minutes: Double?, _ otherwise: TimeInterval) -> TimeInterval {
            guard let minutes, minutes.isFinite, minutes > 0 else { return otherwise }
            return minutes * 60
        }
        var maxTrips = fallback.maxTrips
        if let reported = wire?.maxTrips, reported > 0 {
            maxTrips = reported
        }
        return MonitoringLimits(
            planningHorizon: seconds(wire?.planningHorizonMinutes, fallback.planningHorizon),
            monitorLead: seconds(wire?.monitorLeadMinutes, fallback.monitorLead),
            headsUpLead: seconds(wire?.headsUpLeadMinutes, fallback.headsUpLead),
            meaningfulShift: seconds(wire?.meaningfulShiftMinutes, fallback.meaningfulShift),
            maxTrips: maxTrips
        )
    }

    /// One trip as the app's own type. `nil` when the id is not an occurrence id. Wire
    /// spellings are mapped explicitly: an unknown phase or action is an unreadable answer,
    /// while an unknown alert kind or status simply leaves the last alert out.
    static func tripState(from wire: WireTripState) throws -> MonitoredTripState? {
        guard let id = OccurrenceID(rawValue: wire.id) else { return nil }
        let phase: TripPhase
        switch wire.phase {
        case "scheduled":
            phase = .scheduled
        case "planning":
            phase = .planning
        case "planned":
            phase = .planned
        case "monitoring":
            phase = .monitoring
        case "departed":
            phase = .departed
        case "ended":
            phase = .ended
        default:
            throw TripMonitoringFailure.invalidResponse
        }
        let monitoring = wire.monitoring
        return MonitoredTripState(
            id: id,
            arriveBy: wire.arriveBy,
            phase: phase,
            plan: try wire.recommendation.map(plan(from:)),
            noPlanReason: BackendClient.sentence(wire.noPlanReason),
            planAvailableAt: wire.planAvailableAt,
            monitoringStartsAt: monitoring?.startsAt,
            monitoringStartedAt: monitoring?.startedAt,
            headsUpAt: monitoring?.headsUpAt,
            headsUpSentAt: monitoring?.headsUpSentAt,
            leaveAlertSentAt: monitoring?.leaveAlertSentAt,
            lastAlert: alert(from: monitoring?.lastAlert),
            endsAt: monitoring?.endsAt ?? wire.arriveBy,
            nextCheckAt: monitoring?.nextCheckAt,
            lastErrorCode: wire.lastError?.code,
            lastErrorAt: wire.lastError?.at
        )
    }

    static func plan(from wire: WireRecommendation) throws -> MonitoredPlan {
        let advice: DepartureAdvice
        switch wire.action {
        case "leave_now":
            advice = .leaveNow
        case "wait":
            advice = .wait
        case "leave_later":
            advice = .leaveLater
        default:
            throw TripMonitoringFailure.invalidResponse
        }
        guard let confidence = BackendCommuteProvider.confidence(for: wire.confidence) else {
            throw TripMonitoringFailure.invalidResponse
        }
        var lateBy: TimeInterval?
        if let minutes = wire.lateByMinutes, minutes.isFinite, minutes > 0 {
            lateBy = minutes * 60
        }
        var margin: TimeInterval?
        if let minutes = wire.marginMinutes, minutes.isFinite, minutes >= 0 {
            margin = minutes * 60
        }
        return MonitoredPlan(
            advice: advice,
            departAt: wire.departAt,
            arriveAt: wire.arriveAt,
            driveMinutes: wire.driveMinutes ?? max(0, wire.arriveAt.timeIntervalSince(wire.departAt) / 60),
            reason: wire.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            confidence: confidence,
            confidenceReason: wire.confidenceReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            notes: (wire.notes ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            lateBy: lateBy,
            margin: margin,
            evaluatedAt: wire.evaluatedAt,
            source: BackendCommuteProvider.source(for: wire.source),
            isStale: wire.stale ?? false
        )
    }

    static func alert(from wire: WireLastAlert?) -> TripAlert? {
        guard let wire, let at = wire.at else { return nil }
        let kind: TripAlert.Kind
        switch wire.kind {
        case "heads_up":
            kind = .headsUp
        case "update":
            kind = .update
        case "leave_now":
            kind = .leaveNow
        case "late":
            kind = .late
        default:
            return nil
        }
        let status: TripAlert.Status
        switch wire.status {
        case "queued":
            status = .queued
        case "sent":
            status = .sent
        case "dropped":
            status = .dropped
        case "failed":
            status = .failed
        default:
            return nil
        }
        return TripAlert(kind: kind, status: status, at: at, reason: BackendClient.sentence(wire.reason))
    }

    /// The monitored plan as the recommendation the screens show. `receivedAt` is the device
    /// clock's equivalent of the server's evaluation time: the moment the snapshot arrived
    /// minus the plan's age on the server's own clock, so a skewed clock on either side cannot
    /// make the plan look newer or older than it is.
    static func recommendation(from plan: MonitoredPlan, acknowledgedAt: Date, serverTime: Date) -> DepartureRecommendation {
        let age = max(0, serverTime.timeIntervalSince(plan.evaluatedAt))
        return DepartureRecommendation(
            advice: plan.advice,
            recommendedDeparture: plan.departAt,
            predictedArrival: plan.arriveAt,
            reason: plan.reason,
            confidence: plan.confidence,
            confidenceReason: plan.confidenceReason,
            notes: plan.notes,
            lateBy: plan.lateBy,
            margin: plan.margin,
            generatedAt: plan.evaluatedAt,
            receivedAt: acknowledgedAt.addingTimeInterval(-age),
            source: plan.source,
            isStale: plan.isStale,
            isMonitored: true
        )
    }
}
