import Foundation

/// Storage boundary for activities.
///
/// Implementations may do file I/O, so every operation is asynchronous and must never be
/// assumed to run on the main actor. Repositories store what they are given;
/// `WaitItOutModel` validates through `ActivityValidator` before it writes.
public protocol ActivityRepository: Sendable {
    /// One sentence, shown in Settings, saying where activities are kept.
    var persistenceDescription: String { get }
    /// Every stored activity, in no particular order.
    func fetchAll() async throws -> [Activity]
    /// Inserts each activity, or replaces the stored activity that has the same id.
    func upsert(_ activities: [Activity]) async throws
    /// Removes the activities with these ids. Unknown ids are ignored.
    func delete(ids: Set<UUID>) async throws
    /// Explicit recovery after a failed read (step 0007): moves the unreadable data aside under
    /// a new name, never deleting it, and continues with an empty schedule. Returns the backup's
    /// file name, or `nil` when the data is readable and nothing was moved.
    func setAsideUnreadableData() async throws -> String?
}

public extension ActivityRepository {
    /// Stores that cannot become unreadable, such as the in-memory one, have nothing to set aside.
    func setAsideUnreadableData() async throws -> String? {
        nil
    }

    func upsert(_ activity: Activity) async throws {
        try await upsert([activity])
    }

    func delete(id: UUID) async throws {
        try await delete(ids: [id])
    }
}

/// Reported by `WaitItOutModel` when the repository fails. The message is safe to show.
public struct ActivityStorageError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Session-only store. Activities live as long as the process; nothing is written to disk.
public actor InMemoryActivityRepository: ActivityRepository {
    private var storage: [UUID: Activity]

    public init(initial: [Activity] = []) {
        storage = Dictionary(initial.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public nonisolated var persistenceDescription: String {
        "Activities are kept in memory for this app session only. Nothing is written to disk."
    }

    public func fetchAll() async throws -> [Activity] {
        Array(storage.values)
    }

    public func upsert(_ activities: [Activity]) async throws {
        for activity in activities {
            storage[activity.id] = activity
        }
    }

    public func delete(ids: Set<UUID>) async throws {
        for id in ids {
            storage.removeValue(forKey: id)
        }
    }
}
