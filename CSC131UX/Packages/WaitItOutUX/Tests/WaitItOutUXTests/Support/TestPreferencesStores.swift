import Foundation
import WaitItOutUX

struct TestStoreError: Error {}

/// Store whose load and save both fail. Simulates unreadable or unwritable storage.
struct FailingPreferencesStore: PreferencesStoring {
    var persistenceDescription: String { "Failing test store" }

    func loadPreferences() async throws -> UserPreferences? {
        throw TestStoreError()
    }

    func savePreferences(_ preferences: UserPreferences) async throws {
        throw TestStoreError()
    }
}

/// Store that records every save so tests can assert what was persisted.
actor RecordingPreferencesStore: PreferencesStoring {
    private(set) var saved: [UserPreferences] = []
    private let initial: UserPreferences?

    init(initial: UserPreferences? = nil) {
        self.initial = initial
    }

    nonisolated var persistenceDescription: String { "Recording test store" }

    func loadPreferences() async throws -> UserPreferences? {
        initial
    }

    func savePreferences(_ preferences: UserPreferences) async throws {
        saved.append(preferences)
    }
}
