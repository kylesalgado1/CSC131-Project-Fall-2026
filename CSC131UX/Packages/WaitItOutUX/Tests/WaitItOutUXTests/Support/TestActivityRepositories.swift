import Foundation
import WaitItOutUX

/// In-memory activity store whose reads and writes can be made to fail on demand, and which
/// counts successful writes so tests can prove nothing was stored on a failure path.
actor ScriptedActivityRepository: ActivityRepository {
    private var storage: [UUID: Activity]
    private var failReads = false
    private var failWrites = false
    private(set) var writeCount = 0

    init(initial: [Activity] = []) {
        storage = Dictionary(initial.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    nonisolated var persistenceDescription: String { "Scripted test store" }

    func setFailReads(_ value: Bool) {
        failReads = value
    }

    func setFailWrites(_ value: Bool) {
        failWrites = value
    }

    func fetchAll() async throws -> [Activity] {
        if failReads { throw TestStoreError() }
        return Array(storage.values)
    }

    func upsert(_ activities: [Activity]) async throws {
        if failWrites { throw TestStoreError() }
        writeCount += 1
        for activity in activities {
            storage[activity.id] = activity
        }
    }

    func delete(ids: Set<UUID>) async throws {
        if failWrites { throw TestStoreError() }
        writeCount += 1
        for id in ids {
            storage.removeValue(forKey: id)
        }
    }
}
