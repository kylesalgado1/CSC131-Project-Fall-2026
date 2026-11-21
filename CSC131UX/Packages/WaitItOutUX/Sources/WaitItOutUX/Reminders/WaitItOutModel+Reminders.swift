import Foundation

/// Leave-home reminders (step 0007). The user's wish lives in
/// `UserPreferences.leaveHomeRemindersEnabled` and is stored; what the adapter holds lives in
/// `reminderSync` and `reminderPreviews` and is never stored.
///
/// `reconcileReminders()` rebuilds the `ReminderPlan` from the saved upcoming occurrences and
/// their departure states, reads what the injected `ReminderScheduling` adapter holds, and
/// applies only the difference (`ReminderChanges`), so repeating it changes nothing. It runs:
/// - after every departure refresh and every estimate that arrives, which covers saving,
///   editing, and deleting activities, sample loads and clears, provider settings, places, and
///   the Map's and Calendar's minute ticks (reminders that fall due drop out);
/// - when reminders or the failure simulation are toggled, on Try Again, after the schedule
///   loads at launch (relaunch), and when the app returns to the foreground.
/// Reconciliations run one at a time and always use the newest plan. While saved activities
/// cannot be read, reminders are paused and the adapter is left untouched.
///
/// With the live backend (stage S2) the server monitors the trips and sends the alerts, so in
/// Live mode the adapter is not used at all and the app schedules no local reminder: every
/// reconciliation goes to `reconcileMonitoring()` instead. The one exception is the switch
/// from the Demo data mode, which empties the adapter once so local and remote reminders never
/// compete. In the Demo data mode the adapter works exactly as before and the server holds no
/// trips.
extension WaitItOutModel {
    /// Whether the user wants leave-home reminders.
    public var remindersEnabled: Bool {
        preferences.leaveHomeRemindersEnabled
    }

    /// How the injected adapter delivers reminders. The prototype's is an in-app preview.
    public var reminderDelivery: ReminderDelivery {
        reminderScheduler.delivery
    }

    /// True when the adapter is the prototype's preview adapter, so Settings offers its
    /// failure simulation.
    public var usesPreviewReminders: Bool {
        previewReminderScheduler != nil
    }

    /// Prototype testing: whether the preview adapter fails every update.
    public var simulatesReminderFailure: Bool {
        preferences.simulatesReminderFailure
    }

    /// What the reminder preview shows now. With the live backend in use there are no local
    /// previews (the server sends the alerts), so this is `.off`; the screens show
    /// `monitoringStatus` instead.
    public var reminderPreview: ReminderPreview {
        guard !usesLiveBackend else { return .off }
        return ReminderPreview.make(
            isEnabled: remindersEnabled,
            sync: reminderSync,
            previews: reminderPreviews,
            plan: reminderPlan,
            now: currentDate()
        )
    }

    /// Turns leave-home reminders on or off, stores the wish, and reconciles at once. With the
    /// live backend, turning them on also asks for notification permission (the system prompt
    /// appears when the user turns the feature on) and synchronizes the trips; turning them
    /// off takes the trips off the server.
    public func setRemindersEnabled(_ isEnabled: Bool) {
        guard preferences.leaveHomeRemindersEnabled != isEnabled else { return }
        preferences.leaveHomeRemindersEnabled = isEnabled
        monitoringTracking.hasExplicitChoice = true
        persistPreferences()
        if isEnabled, usesTripMonitoring {
            requestNotificationPermission()
        }
        reconcileReminders(force: true)
    }

    /// Prototype testing: switches the preview adapter's failure simulation, stores it, and
    /// reconciles at once, so turning it off recovers without Try Again.
    public func setSimulatesReminderFailure(_ isOn: Bool) {
        guard preferences.simulatesReminderFailure != isOn else { return }
        preferences.simulatesReminderFailure = isOn
        persistPreferences()
        applyReminderSettings()
        reconcileReminders(force: true)
    }

    /// Try Again after an adapter failure, or after a failed trip synchronization in Live mode.
    public func retryReminders() {
        guard usesTripMonitoring else {
            reconcileReminders(force: true)
            return
        }
        retryMonitoring()
        reconcileLocalReminders(force: true)
    }

    /// The app returned to the foreground: re-plan leave-home times and check the adapter again,
    /// because time has passed and a system adapter may have changed meanwhile. With the live
    /// backend, the notification permission and the push registration are checked, the trips
    /// are synchronized with the server, transient failures are asked again at once, and an
    /// old or missing route is requested again.
    public func appDidBecomeActive() {
        guard usesLiveBackend else {
            refreshDepartures(retryingFailures: false, skippingBackoff: false)
            reconcileReminders(force: true)
            return
        }
        // The server's state is asked for first, so the refresh below does not ask the backend
        // directly for a trip the server is monitoring.
        refreshPushRegistration()
        reconcileMonitoring(force: true)
        refreshDepartures(retryingFailures: false, skippingBackoff: true)
        refreshRouteOnForeground()
        reconcileLocalReminders(force: true)
    }

    /// Waits until reconciliation is idle. Tests use this; the UI never needs to.
    public func waitForReminders() async {
        while let task = reminderTask {
            await task.value
        }
    }

    /// The plan at `now` for the saved upcoming occurrences; `.none` while reminders are off
    /// and while the live backend is in use, where the server sends the alerts and no local
    /// reminder may exist.
    func makeReminderPlan(at now: Date) -> ReminderPlan {
        guard remindersEnabled, !usesLiveBackend else { return .none }
        let formatter = OccurrenceFormatter(calculator: weekCalculator, locale: weekCalculator.calendar.locale ?? .autoupdatingCurrent)
        return ReminderPlan.make(
            upcoming: DepartureHorizon.upcomingOccurrences(of: activities, at: now),
            at: now,
            state: { departureState(for: $0, at: now) },
            makeReminder: { occurrence, calculation in
                ScheduledReminder(
                    id: occurrence.id,
                    fireDate: calculation.leaveHome,
                    title: formatter.reminderTitle(for: occurrence),
                    message: formatter.reminderMessage(
                        for: calculation,
                        destinationName: resolvedDestination(occurrence.activity.destination).name
                    )
                )
            }
        )
    }

    /// Pushes the stored failure simulation into the preview adapter.
    func applyReminderSettings() {
        previewReminderScheduler?.setSimulatesFailure(preferences.simulatesReminderFailure)
    }

    /// Brings reminders in line with the saved schedule. When the host supplied a live backend,
    /// the server's trip monitoring is reconciled first (it withdraws the trips in the Demo
    /// data mode); then the local adapter, which Live mode does not use.
    func reconcileReminders(force: Bool = false) {
        // Nothing is touched before the schedule has been read once: reconciling against an
        // empty list at launch would remove reminders a system adapter still holds, and would
        // cancel every trip the server still monitors.
        guard activitiesStatus != .notLoaded else { return }
        if hasLiveBackend {
            reconcileMonitoring(force: force)
        }
        reconcileLocalReminders(force: force)
    }

    /// Brings the adapter in line with the current plan. Cheap when the plan is unchanged since
    /// the last attempt, unless `force` asks to check the adapter again. After a failure, only a
    /// changed plan or a forced call (Try Again, toggles, launch, foreground) tries again, so the
    /// minute ticks never turn the failure into a loop of retries. With the live backend in use
    /// the adapter is left alone, except to empty it once after the Demo data mode.
    func reconcileLocalReminders(force: Bool = false) {
        guard activitiesStatus != .notLoaded else { return }
        let plan = makeReminderPlan(at: currentDate())
        if plan != reminderPlan {
            reminderPlan = plan
        }
        if usesLiveBackend, !localRemindersMayExist {
            if reminderTask == nil {
                if reminderSync != .idle {
                    reminderSync = .idle
                }
                if !reminderPreviews.isEmpty {
                    reminderPreviews = []
                }
            }
            return
        }
        if !force, reminderTask == nil, reminderSync == .synced || reminderSync == .failed, lastReconciledReminderPlan == plan {
            return
        }
        reminderNeedsReconcile = true
        guard reminderTask == nil else { return }
        reminderTask = Task { [weak self] in
            await self?.runReminderReconciliation()
        }
    }

    private func runReminderReconciliation() async {
        while reminderNeedsReconcile {
            reminderNeedsReconcile = false
            guard activityStorageIssue == nil else {
                reminderSync = .paused
                lastReconciledReminderPlan = nil
                continue
            }
            let now = currentDate()
            let plan = makeReminderPlan(at: now)
            reminderPlan = plan
            reminderSync = .updating
            let scheduler = reminderScheduler
            do {
                let pending = try await scheduler.pendingReminders()
                let changes = ReminderChanges.between(pending: pending, plan: plan, now: now)
                if !changes.toCancel.isEmpty {
                    try await scheduler.cancelReminders(withIDs: changes.toCancel)
                }
                if !changes.toSchedule.isEmpty {
                    try await scheduler.schedule(changes.toSchedule)
                }
                let current = changes.isEmpty ? pending : try await scheduler.pendingReminders()
                reminderPreviews = current.sorted(by: ScheduledReminder.isOrderedBefore)
                lastReconciledReminderPlan = plan
                reminderSync = .synced
                localRemindersMayExist = !current.isEmpty
                if usesLiveBackend, current.isEmpty {
                    // Emptied after the Demo data mode; the adapter is not used again while live.
                    reminderSync = .idle
                }
            } catch {
                // Remembered as attempted, so only a new plan or a forced call tries again.
                lastReconciledReminderPlan = plan
                reminderSync = .failed
                localRemindersMayExist = true
            }
        }
        reminderTask = nil
    }
}
