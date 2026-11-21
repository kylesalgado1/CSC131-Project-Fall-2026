import Foundation
@testable import WaitItOutUX

/// Reminder adapter that records every call, for step 0007's reconciliation tests.
///
/// Pre-populated pending reminders stand in for a persistent system adapter after a relaunch.
/// Pending reminders are kept in an array, so `initial` may hold duplicate copies of one id,
/// which the model must reconcile away. Scheduling replaces every copy with the same id, as a
/// system notification center does for a request with the same identifier. While `failing`
/// is on, every call throws `TestStoreError` after being counted and changes nothing.
actor RecordingReminderScheduler: ReminderScheduling {
    /// Everything the adapter holds now, in the order it was added, duplicates included.
    private(set) var pending: [ScheduledReminder]
    private(set) var failing = false
    private(set) var scheduleCalls = 0
    private(set) var cancelCalls = 0
    private(set) var readCalls = 0

    init(initial: [ScheduledReminder] = []) {
        pending = initial
    }

    nonisolated var delivery: ReminderDelivery { .inAppPreview }

    func setFailing(_ value: Bool) {
        failing = value
    }

    /// Adds a reminder behind the model's back, as another process or the system might.
    func inject(_ reminder: ScheduledReminder) {
        pending.append(reminder)
    }

    /// Removes every copy with this id behind the model's back.
    func remove(id: OccurrenceID) {
        pending.removeAll { $0.id == id }
    }

    func pendingReminders() async throws -> [ScheduledReminder] {
        readCalls += 1
        if failing { throw TestStoreError() }
        return pending
    }

    func schedule(_ reminders: [ScheduledReminder]) async throws {
        scheduleCalls += 1
        if failing { throw TestStoreError() }
        for reminder in reminders {
            pending.removeAll { $0.id == reminder.id }
            pending.append(reminder)
        }
    }

    func cancelReminders(withIDs ids: Set<OccurrenceID>) async throws {
        cancelCalls += 1
        if failing { throw TestStoreError() }
        pending.removeAll { ids.contains($0.id) }
    }
}
