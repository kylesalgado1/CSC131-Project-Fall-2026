import Foundation

/// Committed activities in `activities.json` (step 0007), behind `ActivityRepository`.
///
/// - The file is read once, on the first call, and again after a failed read, so the model's
///   Try Again re-reads it. A missing file is an empty schedule.
/// - Every write encodes the whole schedule and replaces the file atomically. The in-memory
///   copy changes only after the write succeeds, so a failure keeps the previous valid data
///   both on disk and in memory.
/// - While the file cannot be read (damaged, newer format, read error), every write is refused
///   with `.unreadableDataProtected`: the unreadable schedule is never replaced by an empty one.
///   Only the explicit `setAsideUnreadableData()` moves it aside, under a new name.
/// - Drafts, departures, estimates, and reminders are never stored here.
public actor FileActivityRepository: ActivityRepository {
    private enum State {
        case unread
        case ready([UUID: Activity])
        case unreadable(PersistenceError)
    }

    public static let documentKind = "activities"

    private let file: VersionedJSONFile<[Activity]>
    private let clock: any WallClock
    private var state: State = .unread

    public init(fileURL: URL, files: any FileAccessing = LocalFileAccess(), clock: any WallClock = SystemWallClock()) {
        file = VersionedJSONFile(url: fileURL, kind: Self.documentKind, files: files)
        self.clock = clock
    }

    public nonisolated var persistenceDescription: String {
        "Activities are saved on this device in a JSON file in Application Support, so they survive relaunching the app."
    }

    public func fetchAll() async throws -> [Activity] {
        try Array(storedActivities().values)
    }

    public func upsert(_ activities: [Activity]) async throws {
        var next = try writableActivities()
        for activity in activities {
            next[activity.id] = activity
        }
        try commit(next)
    }

    public func delete(ids: Set<UUID>) async throws {
        var next = try writableActivities()
        for id in ids {
            next.removeValue(forKey: id)
        }
        try commit(next)
    }

    public func setAsideUnreadableData() async throws -> String? {
        if (try? storedActivities()) != nil { return nil }
        let backup = try file.setAside(at: clock.now())
        state = .ready([:])
        return backup.lastPathComponent
    }

    /// The stored schedule, read from disk on first use and after a failed read.
    private func storedActivities() throws -> [UUID: Activity] {
        if case .ready(let stored) = state { return stored }
        do {
            let activities = try file.read() ?? []
            let stored = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            state = .ready(stored)
            return stored
        } catch {
            let failure = error as? PersistenceError ?? .readFailed
            state = .unreadable(failure)
            throw failure
        }
    }

    private func writableActivities() throws -> [UUID: Activity] {
        do {
            return try storedActivities()
        } catch {
            throw PersistenceError.unreadableDataProtected
        }
    }

    private func commit(_ next: [UUID: Activity]) throws {
        try file.write(next.values.sorted(by: Self.isStoredBefore))
        state = .ready(next)
    }

    /// Stable file order: start, then id.
    private static func isStoredBefore(_ lhs: Activity, _ rhs: Activity) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// `UserPreferences` in `preferences.json` (step 0007), behind `PreferencesStoring`: appearance,
/// the Settings test commute and scenario, home and campus, the reminder preference, and the
/// reminder failure simulation. Decoding inside a valid envelope is tolerant per field (see
/// `UserPreferences.init(from:)`); a damaged or newer file is reported and never overwritten
/// until `setAsideUnreadableData()` is chosen explicitly. Departure results are never stored.
public actor FilePreferencesStore: PreferencesStoring {
    private enum State {
        case unread
        case ready
        case unreadable(PersistenceError)
    }

    public static let documentKind = "preferences"

    private let file: VersionedJSONFile<UserPreferences>
    private let clock: any WallClock
    private var state: State = .unread

    public init(fileURL: URL, files: any FileAccessing = LocalFileAccess(), clock: any WallClock = SystemWallClock()) {
        file = VersionedJSONFile(url: fileURL, kind: Self.documentKind, files: files)
        self.clock = clock
    }

    public nonisolated var persistenceDescription: String {
        "Settings are saved on this device in a JSON file in Application Support, so they survive relaunching the app."
    }

    public func loadPreferences() async throws -> UserPreferences? {
        do {
            let stored = try file.read()
            state = .ready
            return stored
        } catch {
            let failure = error as? PersistenceError ?? .readFailed
            state = .unreadable(failure)
            throw failure
        }
    }

    public func savePreferences(_ preferences: UserPreferences) async throws {
        switch state {
        case .ready:
            break
        case .unreadable:
            // The settings in effect were not read from this file (defaults apply), so writing
            // them would replace the stored ones even if the file reads again now. Only a
            // successful `loadPreferences()` (Try Again) or the explicit set-aside lifts this.
            throw PersistenceError.unreadableDataProtected
        case .unread:
            // Never replace a file this store has not read successfully.
            do {
                _ = try file.read()
                state = .ready
            } catch {
                state = .unreadable(error as? PersistenceError ?? .readFailed)
                throw PersistenceError.unreadableDataProtected
            }
        }
        try file.write(preferences)
    }

    public func setAsideUnreadableData() async throws -> String? {
        do {
            // Readable again, or no file at all: there is nothing to set aside.
            _ = try file.read()
            state = .ready
            return nil
        } catch {
            // Stays protected if the move fails too.
            state = .unreadable(error as? PersistenceError ?? .readFailed)
            let backup = try file.setAside(at: clock.now())
            state = .ready
            return backup.lastPathComponent
        }
    }
}
