import Foundation

/// Why the next trip gets no reminder (step 0007). Shown so the user knows why no preview exists.
public enum ReminderGap: Equatable, Sendable {
    /// Nothing saved starts within the planning horizon (`DepartureHorizon`, 7 days).
    case noUpcomingTrips
    /// The trip's commute estimate has not arrived yet.
    case waitingForEstimate
    /// The trip has no leave-home time, for this reason.
    case estimateUnavailable(DepartureUnavailableReason)
    /// The trip's commute estimate failed; Try Again on the trip asks again.
    case estimateFailed(DepartureFailure)
    /// The trip's leave-home time has already passed, so a reminder would be in the past.
    case leaveHomePassed(Date)
}

/// Which leave-home reminders should exist at one instant. Pure: built from the saved upcoming
/// occurrences and their departure states; the model rebuilds it whenever either changes.
///
/// - One reminder per occurrence, keyed by its stable `OccurrenceID`, due at the calculated
///   leave-home time. Only current (`.success`) calculations produce reminders; loading,
///   failed, out-of-date (`.stale`), and unavailable estimates never do, and nothing is ever
///   due in the past.
/// - Bounded: occurrences inside `DepartureHorizon` that have not started, at most
///   `maximumCount` reminders.
/// - A trip whose same request is being re-estimated (`.refreshing`) is `held`: a reminder
///   already pending for it stays until the new estimate arrives, instead of flickering away.
public struct ReminderPlan: Equatable, Sendable {
    /// Upper bound on reminders at once, well under the 64 pending requests iOS allows an app.
    public static let maximumCount = 20

    /// Wanted reminders, ordered by fire date, all due after the plan's instant.
    public let reminders: [ScheduledReminder]
    /// Occurrences being re-estimated for the same trip.
    public let held: Set<OccurrenceID>
    /// The next trip: the first saved occurrence within the horizon that has not started.
    public let nextTrip: ActivityOccurrence?
    /// Why the next trip gets no reminder; `nil` when it gets one or is held.
    public let nextTripGap: ReminderGap?

    public init(reminders: [ScheduledReminder], held: Set<OccurrenceID>, nextTrip: ActivityOccurrence?, nextTripGap: ReminderGap?) {
        self.reminders = reminders
        self.held = held
        self.nextTrip = nextTrip
        self.nextTripGap = nextTripGap
    }

    /// No reminders wanted: reminders are off. Reconciling against it removes every pending one.
    public static let none = ReminderPlan(reminders: [], held: [], nextTrip: nil, nextTripGap: nil)

    /// The plan at `now`.
    /// - Parameters:
    ///   - upcoming: saved occurrences from `DepartureHorizon.upcomingOccurrences(of:at:)`.
    ///   - state: the departure state of each occurrence.
    ///   - makeReminder: the reminder's title and message for a current calculation.
    public static func make(
        upcoming: [ActivityOccurrence],
        at now: Date,
        state: (ActivityOccurrence) -> DepartureState,
        makeReminder: (ActivityOccurrence, DepartureCalculation) -> ScheduledReminder
    ) -> ReminderPlan {
        let trips = upcoming.filter { $0.start > now }.sorted(by: DepartureHorizon.isOrderedBefore)
        var reminders: [ScheduledReminder] = []
        var held: Set<OccurrenceID> = []
        var seen: Set<OccurrenceID> = []
        var nextTripGap: ReminderGap?
        for (index, occurrence) in trips.enumerated() where seen.insert(occurrence.id).inserted {
            let gap: ReminderGap?
            switch state(occurrence) {
            case .success(let calculation):
                if calculation.leaveHome > now {
                    if reminders.count < maximumCount {
                        reminders.append(makeReminder(occurrence, calculation))
                    }
                    gap = nil
                } else {
                    gap = .leaveHomePassed(calculation.leaveHome)
                }
            case .refreshing:
                held.insert(occurrence.id)
                gap = nil
            case .loading:
                gap = .waitingForEstimate
            case .unavailable(let reason):
                gap = .estimateUnavailable(reason)
            case .error(let failure), .stale(_, let failure):
                // A kept out-of-date recommendation is not current, so it earns no reminder.
                gap = .estimateFailed(failure)
            }
            if index == 0 {
                nextTripGap = gap
            }
        }
        return ReminderPlan(
            reminders: reminders.sorted(by: ScheduledReminder.isOrderedBefore),
            held: held,
            nextTrip: trips.first,
            nextTripGap: trips.isEmpty ? .noUpcomingTrips : nextTripGap
        )
    }
}

/// The adapter calls that turn what is pending into what the plan wants. Pure.
public struct ReminderChanges: Equatable, Sendable {
    /// Reminders to add or replace, ordered by fire date.
    public let toSchedule: [ScheduledReminder]
    /// Reminders to remove. Applied before `toSchedule`.
    public let toCancel: Set<OccurrenceID>

    public init(toSchedule: [ScheduledReminder], toCancel: Set<OccurrenceID>) {
        self.toSchedule = toSchedule
        self.toCancel = toCancel
    }

    public var isEmpty: Bool {
        toSchedule.isEmpty && toCancel.isEmpty
    }

    /// Schedules every wanted reminder that is missing or different; cancels everything no
    /// longer wanted (deleted or edited occurrences, reminders turned off, failed or unavailable
    /// estimates, reminders that fell due). A held reminder is kept while it is still ahead of
    /// `now`. Wanted reminders are never due: the plan built for the same `now` keeps only
    /// future ones. Duplicate copies of one id are cancelled and scheduled once. Applying the
    /// result and reconciling again with the same plan yields no changes.
    public static func between(pending: [ScheduledReminder], plan: ReminderPlan, now: Date) -> ReminderChanges {
        let wanted = Dictionary(plan.reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let copies = Dictionary(grouping: pending, by: \.id)
        var toCancel: Set<OccurrenceID> = []
        for (id, group) in copies {
            if wanted[id] != nil {
                if group.count > 1 { toCancel.insert(id) }
            } else if plan.held.contains(id), group.count == 1, group.allSatisfy({ $0.fireDate > now }) {
                continue
            } else {
                toCancel.insert(id)
            }
        }
        let toSchedule = plan.reminders.filter { reminder in
            guard let group = copies[reminder.id] else { return true }
            return group.count != 1 || group.first != reminder
        }
        return ReminderChanges(toSchedule: toSchedule.sorted(by: ScheduledReminder.isOrderedBefore), toCancel: toCancel)
    }
}

/// Where keeping the adapter in line with the plan stands. Separate from the user's wish
/// (`UserPreferences.leaveHomeRemindersEnabled`) and never stored.
public enum ReminderSyncState: Equatable, Sendable {
    /// Nothing has been reconciled yet in this launch.
    case idle
    /// The adapter is being updated.
    case updating
    /// The adapter holds exactly what the last plan wanted.
    case synced
    /// The adapter failed. Earlier reminders may still be pending; Try Again reconciles again.
    case failed
    /// Saved activities could not be read, so reminders are left untouched.
    case paused
}

/// What the reminder preview shows (step 0007). Pure, from the preference, the sync state,
/// what the adapter last reported, and the plan.
public enum ReminderPreview: Equatable, Sendable {
    /// Reminders are off and nothing is pending.
    case off
    /// Saved activities could not be read; reminders are paused.
    case paused
    /// The adapter failed. `isEnabled` says whether the user still wants reminders (the
    /// failure may have been removing them).
    case failed(isEnabled: Bool)
    /// The first reconciliation is still running.
    case updating
    /// The next reminder, how many more follow within the horizon, whether its trip is being
    /// re-estimated (the reminder is then out of date until the new estimate arrives), and why
    /// the next trip has no reminder when it is skipped.
    case next(ScheduledReminder, laterCount: Int, isUpdating: Bool, skippedTrip: ActivityOccurrence?, skippedGap: ReminderGap?)
    /// Reminders are on but none can be created, and why.
    case unavailable(trip: ActivityOccurrence?, gap: ReminderGap)

    public static func make(isEnabled: Bool, sync: ReminderSyncState, previews: [ScheduledReminder], plan: ReminderPlan, now: Date) -> ReminderPreview {
        switch sync {
        case .paused:
            return .paused
        case .failed:
            return .failed(isEnabled: isEnabled)
        case .idle, .updating, .synced:
            break
        }
        guard isEnabled else { return .off }
        let ahead = previews.filter { $0.fireDate > now }.sorted(by: ScheduledReminder.isOrderedBefore)
        if let first = ahead.first {
            let skipsNextTrip = plan.nextTrip.map { $0.id != first.id } ?? false
            return .next(
                first,
                laterCount: ahead.count - 1,
                isUpdating: plan.held.contains(first.id),
                skippedTrip: skipsNextTrip && plan.nextTripGap != nil ? plan.nextTrip : nil,
                skippedGap: skipsNextTrip ? plan.nextTripGap : nil
            )
        }
        if sync != .synced || !plan.held.isEmpty {
            return .updating
        }
        guard let gap = plan.nextTripGap else {
            // The plan wanted a reminder that has fallen due since; the next tick reconciles.
            return .updating
        }
        return .unavailable(trip: plan.nextTrip, gap: gap)
    }
}
