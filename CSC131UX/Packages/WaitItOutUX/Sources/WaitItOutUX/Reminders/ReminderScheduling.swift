import Foundation
import os

/// How reminders reach the user. Every reminder text in the app is worded from this value, so
/// an in-app preview is never described as a notification.
public enum ReminderDelivery: Equatable, Sendable {
    /// Shown inside the app only. Nothing is handed to the system's notification service.
    case inAppPreview
    /// Delivered as a system notification by an adapter the team provides.
    case systemNotification

    /// One sentence for every place a reminder is shown.
    public var disclosure: String {
        switch self {
        case .inAppPreview:
            return "Preview only - no system notification will be sent."
        case .systemNotification:
            return "Delivered as a notification by the team's notification service."
        }
    }
}

/// One leave-home reminder, due at the calculated leave-home time of one saved occurrence.
public struct ScheduledReminder: Identifiable, Hashable, Sendable {
    /// One reminder per occurrence, so the stable occurrence id is the reminder id.
    public let id: OccurrenceID
    /// When the reminder is due: the occurrence's calculated leave-home time.
    public let fireDate: Date
    public let title: String
    public let message: String

    public init(id: OccurrenceID, fireDate: Date, title: String, message: String) {
        self.id = id
        self.fireDate = fireDate
        self.title = title
        self.message = message
    }

    /// Identifier a system adapter can use for its notification request, such as
    /// `leave-home.6F9619FF-8B86-D011-B42D-00C04FC964FF@2026-11-02`.
    public var identifier: String {
        "leave-home." + id.rawValue
    }

    /// Fire date, then occurrence id.
    public static func isOrderedBefore(_ lhs: ScheduledReminder, _ rhs: ScheduledReminder) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// The reminders boundary (step 0007). `WaitItOutModel` decides which reminders should exist
/// (`ReminderPlan`) and reconciles the adapter against that list (`ReminderChanges`); adapters
/// only store, replace, and remove what they are given, keyed by occurrence id.
///
/// The prototype injects `PreviewReminderScheduler`, an in-app preview. The team replaces it with
/// an adapter over its notification service; see `docs/REMINDERS.md`. Every method may do I/O and
/// is called off the main actor.
public protocol ReminderScheduling: Sendable {
    /// How this adapter delivers reminders.
    var delivery: ReminderDelivery { get }
    /// Every reminder the adapter currently holds.
    func pendingReminders() async throws -> [ScheduledReminder]
    /// Adds each reminder, or replaces the one with the same id.
    func schedule(_ reminders: [ScheduledReminder]) async throws
    /// Removes the reminders with these ids. Unknown ids are ignored.
    func cancelReminders(withIDs ids: Set<OccurrenceID>) async throws
}

/// Thrown by `PreviewReminderScheduler` while its failure simulation is on.
public struct PreviewReminderSchedulerError: Error, Equatable, Sendable {
    public init() {}
}

/// The prototype's reminder adapter: an in-app preview (step 0007).
///
/// It keeps reminders in memory so the app can show them, and does nothing else: no
/// notification permission, no system notification, no background delivery. Pending previews
/// last as long as the process; after a relaunch the model reconciles again and recreates them.
///
/// Deterministic failure simulation for Settings > Prototype testing: while `simulatesFailure`
/// is on, every call throws `PreviewReminderSchedulerError` and changes nothing, so the failure
/// message and Try Again can be tried. Turning it off makes the next call succeed.
public final class PreviewReminderScheduler: ReminderScheduling {
    private struct State {
        var pending: [OccurrenceID: ScheduledReminder] = [:]
        var simulatesFailure = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(simulatesFailure: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(simulatesFailure: simulatesFailure))
    }

    public var delivery: ReminderDelivery {
        .inAppPreview
    }

    public var simulatesFailure: Bool {
        state.withLock { $0.simulatesFailure }
    }

    public func setSimulatesFailure(_ value: Bool) {
        state.withLock { $0.simulatesFailure = value }
    }

    public func pendingReminders() async throws -> [ScheduledReminder] {
        try state.withLock { current in
            if current.simulatesFailure { throw PreviewReminderSchedulerError() }
            return current.pending.values.sorted(by: ScheduledReminder.isOrderedBefore)
        }
    }

    public func schedule(_ reminders: [ScheduledReminder]) async throws {
        try state.withLock { current in
            if current.simulatesFailure { throw PreviewReminderSchedulerError() }
            for reminder in reminders {
                current.pending[reminder.id] = reminder
            }
        }
    }

    public func cancelReminders(withIDs ids: Set<OccurrenceID>) async throws {
        try state.withLock { current in
            if current.simulatesFailure { throw PreviewReminderSchedulerError() }
            for id in ids {
                current.pending.removeValue(forKey: id)
            }
        }
    }
}
