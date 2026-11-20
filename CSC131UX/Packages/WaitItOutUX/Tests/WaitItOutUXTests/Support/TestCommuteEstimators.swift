import Foundation
@testable import WaitItOutUX

/// An estimate of `minutes` of travel, labeled as unit-test data and stamped `at`.
func testEstimate(minutes: Double, at date: Date = TestFixtures.fridayNoon, label: String = "Unit test estimate") -> CommuteEstimate {
    CommuteEstimate(travelTime: minutes * 60, sourceLabel: label, estimatedAt: date, isSimulated: true)
}

/// Polls `condition` every few milliseconds until it holds or `timeout` passes. Returns
/// whether it held. Awaiting here frees the main actor, so the model's tasks keep running.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Answers every request at once from a closure and records what was asked.
actor ScriptedCommuteEstimator: CommuteEstimating {
    typealias Responder = @Sendable (CommuteRequest) throws -> CommuteEstimateResponse

    private var responder: Responder
    private(set) var requests: [CommuteRequest] = []

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    /// Always answers `minutes` of travel.
    init(minutes: Double) {
        responder = { _ in .estimate(testEstimate(minutes: minutes)) }
    }

    func setResponder(_ responder: @escaping Responder) {
        self.responder = responder
    }

    func requestCount() -> Int {
        requests.count
    }

    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        requests.append(request)
        return try responder(request)
    }
}

/// How the test answers one held request.
enum GatedAnswer: Sendable {
    case response(CommuteEstimateResponse)
    /// Throws `TestStoreError`, like a provider outage.
    case failure
}

/// Holds every request until the test answers it, in any order, so tests can deliver answers
/// out of order or after an edit. Records which calls were cancelled.
actor GatedCommuteEstimator: CommuteEstimating {
    private(set) var requests: [CommuteRequest] = []
    private(set) var cancelledCalls: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<CommuteEstimateResponse, Error>] = [:]

    func callCount() -> Int {
        requests.count
    }

    /// Request of call `index` (0-based, in arrival order), or `nil` before it arrives.
    func request(at index: Int) -> CommuteRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func isWaiting(_ index: Int) -> Bool {
        waiting[index] != nil
    }

    func wasCancelled(_ index: Int) -> Bool {
        cancelledCalls.contains(index)
    }

    /// Answers call `index`. Returns `false` when that call is not waiting (unknown,
    /// already answered, or cancelled).
    @discardableResult
    func answer(_ index: Int, with answer: GatedAnswer) -> Bool {
        guard let continuation = waiting.removeValue(forKey: index) else { return false }
        switch answer {
        case .response(let response):
            continuation.resume(returning: response)
        case .failure:
            continuation.resume(throwing: TestStoreError())
        }
        return true
    }

    /// Answers call `index` with `minutes` of travel.
    @discardableResult
    func answer(_ index: Int, minutes: Double) -> Bool {
        answer(index, with: .response(.estimate(testEstimate(minutes: minutes))))
    }

    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        let index = requests.count
        requests.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommuteEstimateResponse, Error>) in
                if cancelledCalls.contains(index) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[index] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCall(index) }
        }
    }

    private func cancelCall(_ index: Int) {
        cancelledCalls.insert(index)
        waiting.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}
