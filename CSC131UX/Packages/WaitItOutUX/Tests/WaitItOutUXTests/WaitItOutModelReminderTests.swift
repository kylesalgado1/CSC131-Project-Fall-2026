import XCTest
@testable import WaitItOutUX

/// Step 0007 leave-home reminders: off by default, one preview per upcoming trip at its
/// leave-home time, idempotent reconciliation, cancellation after deletes, edits, and turning
/// reminders off, no reminder without a current estimate, passed leave-home times skipped and
/// explained, deterministic adapter failure and recovery, relaunch against a persistent
/// adapter, paused reminders while the schedule cannot be read, the foreground check,
/// reminders dropping out as they fall due, and a changed estimate that keeps each reminder,
/// marked out of date, until it moves to the new leave-home time.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. With the default 60-minute test commute the five
/// sample trips inside the horizon leave home at Mon 11/2 7:15, Tue 11/3 10:15, Wed 11/4 7:15,
/// Thu 11/5 10:15, and Fri 11/6 7:15 AM PST.
@MainActor
final class WaitItOutModelReminderTests: XCTestCase {
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private func occurrenceID(_ activityID: UUID, month: Int, day: Int) -> OccurrenceID {
        OccurrenceID(activityID: activityID, date: LocalDate.of(pacific(2026, month, day, 12), in: TestFixtures.pacific))
    }

    private var mondayClass: OccurrenceID {
        occurrenceID(SampleActivities.morningClassID, month: 11, day: 2)
    }

    private var tuesdayLab: OccurrenceID {
        occurrenceID(SampleActivities.afternoonLabID, month: 11, day: 3)
    }

    /// Leave-home times of the five sample trips at the fixture clock, in order.
    private var sampleFireDates: [Date] {
        [
            pacific(2026, 11, 2, 7, 15),
            pacific(2026, 11, 3, 10, 15),
            pacific(2026, 11, 4, 7, 15),
            pacific(2026, 11, 5, 10, 15),
            pacific(2026, 11, 6, 7, 15)
        ]
    }

    private var remindersOn: UserPreferences {
        UserPreferences(leaveHomeRemindersEnabled: true)
    }

    private func settle(_ model: WaitItOutModel) async {
        await model.waitForDepartures()
        await model.waitForReminders()
    }

    /// Samples loaded, reminders turned on, every estimate and reconciliation finished.
    private func makeRemindingModel(
        clock: any WallClock = FixedWallClock(TestFixtures.fridayNoon),
        scheduler: (any ReminderScheduling)? = nil
    ) async -> WaitItOutModel {
        let model = TestFixtures.makeModel(clock: clock, reminderScheduler: scheduler)
        await model.loadPreferences()
        await model.loadSampleActivities()
        model.setRemindersEnabled(true)
        await settle(model)
        return model
    }

    private func reminder(_ id: OccurrenceID, fireDate: Date, message: String = "Left over from an earlier launch, test data") -> ScheduledReminder {
        ScheduledReminder(id: id, fireDate: fireDate, title: "Time to leave, test data", message: message)
    }

    // MARK: Off by default and enabling

    func testRemindersAreOffByDefaultAndNothingIsScheduled() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = TestFixtures.makeModel(reminderScheduler: scheduler)
        await model.loadPreferences()
        await model.loadSampleActivities()
        await settle(model)

        XCTAssertFalse(model.remindersEnabled)
        XCTAssertEqual(model.reminderPlan, ReminderPlan.none)
        XCTAssertEqual(model.reminderPreview, .off)
        XCTAssertTrue(model.reminderPreviews.isEmpty)
        XCTAssertFalse(model.usesPreviewReminders, "A team adapter hides the preview's failure simulation")
        let pending = await scheduler.pending
        let scheduleCalls = await scheduler.scheduleCalls
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(scheduleCalls, 0)
    }

    func testEnablingRemindersPreviewsEveryUpcomingTripAtItsLeaveHomeTime() async throws {
        let model = await makeRemindingModel()

        XCTAssertTrue(model.remindersEnabled)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)
        XCTAssertEqual(model.reminderPreviews, model.reminderPlan.reminders, "The adapter holds exactly the plan")
        let first = try XCTUnwrap(model.reminderPreviews.first)
        XCTAssertEqual(first.id, mondayClass)
        XCTAssertEqual(first.identifier, "leave-home." + mondayClass.rawValue)
        XCTAssertEqual(first.title, "Time to leave for Sample morning class")
        XCTAssertTrue(first.message.contains("7:15"), first.message)
        XCTAssertTrue(first.message.contains("simulated"), first.message)
        XCTAssertEqual(model.reminderPlan.nextTrip?.id, mondayClass)
        XCTAssertNil(model.reminderPlan.nextTripGap)

        guard case .next(let next, let laterCount, let isUpdating, let skippedTrip, let skippedGap) = model.reminderPreview else {
            return XCTFail("Expected the next reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(next, first)
        XCTAssertEqual(laterCount, 4)
        XCTAssertFalse(isUpdating)
        XCTAssertNil(skippedTrip)
        XCTAssertNil(skippedGap)

        XCTAssertTrue(model.usesPreviewReminders)
        XCTAssertEqual(model.reminderDelivery, .inAppPreview)
        XCTAssertEqual(model.reminderDelivery.disclosure, "Preview only - no system notification will be sent.")
    }

    func testReconcilingAgainChangesNothing() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        let previews = model.reminderPreviews
        XCTAssertEqual(previews.map(\.fireDate), sampleFireDates)
        let schedulesBefore = await scheduler.scheduleCalls
        let cancelsBefore = await scheduler.cancelCalls
        let readsBefore = await scheduler.readCalls
        XCTAssertGreaterThan(schedulesBefore, 0)

        model.refreshDepartures()
        await settle(model)
        model.retryReminders()
        await settle(model)
        model.retryReminders()
        await settle(model)

        let schedulesAfter = await scheduler.scheduleCalls
        let cancelsAfter = await scheduler.cancelCalls
        let readsAfter = await scheduler.readCalls
        let pending = await scheduler.pending
        XCTAssertEqual(schedulesAfter, schedulesBefore, "Nothing new to schedule")
        XCTAssertEqual(cancelsAfter, cancelsBefore, "Nothing to cancel")
        XCTAssertGreaterThan(readsAfter, readsBefore, "Try Again checks the adapter again")
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews, previews)
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(Set(pending), Set(previews))
    }

    // MARK: Schedule changes

    func testDeletingAnActivityCancelsItsReminders() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        let cancelsBefore = await scheduler.cancelCalls

        try await model.deleteActivity(id: SampleActivities.afternoonLabID)
        await settle(model)

        let cancelsAfter = await scheduler.cancelCalls
        let pending = await scheduler.pending
        XCTAssertGreaterThan(cancelsAfter, cancelsBefore)
        XCTAssertEqual(pending.count, 3)
        XCTAssertFalse(pending.contains { $0.id.activityID == SampleActivities.afternoonLabID })
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [
            pacific(2026, 11, 2, 7, 15),
            pacific(2026, 11, 4, 7, 15),
            pacific(2026, 11, 6, 7, 15)
        ])
        XCTAssertEqual(Set(pending), Set(model.reminderPreviews))
    }

    func testEditingTheArrivalReschedulesWithoutDuplicates() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        var edited = try XCTUnwrap(model.activities.first { $0.id == SampleActivities.morningClassID })
        edited.idealArrival = edited.start.addingTimeInterval(-60 * 60)

        try await model.saveActivity(edited)
        await settle(model)

        let pending = await scheduler.pending
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(Set(pending.map(\.id)).count, pending.count, "One reminder per occurrence")
        let monday = try XCTUnwrap(pending.first { $0.id == mondayClass })
        XCTAssertEqual(monday.fireDate, pacific(2026, 11, 2, 7))
        XCTAssertTrue(monday.message.contains("8:00"), monday.message)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [
            pacific(2026, 11, 2, 7),
            pacific(2026, 11, 3, 10, 15),
            pacific(2026, 11, 4, 7),
            pacific(2026, 11, 5, 10, 15),
            pacific(2026, 11, 6, 7)
        ])
        XCTAssertEqual(Set(pending), Set(model.reminderPreviews))
        XCTAssertEqual(model.reminderSync, .synced)
    }

    func testDisablingCancelsEveryReminder() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        let before = await scheduler.pending
        XCTAssertEqual(before.count, 5)

        model.setRemindersEnabled(false)
        await settle(model)

        let pending = await scheduler.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertTrue(model.reminderPreviews.isEmpty)
        XCTAssertEqual(model.reminderPlan, ReminderPlan.none)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreview, .off)
    }

    // MARK: No current estimate

    func testUnavailableEstimateLeavesNoReminderAndSaysWhy() async throws {
        let model = await makeRemindingModel()
        XCTAssertEqual(model.reminderPreviews.count, 5)

        model.setTestCommuteScenario(.unavailable)
        await settle(model)

        XCTAssertTrue(model.reminderPreviews.isEmpty)
        XCTAssertTrue(model.reminderPlan.reminders.isEmpty)
        guard case .unavailable(let trip, let gap) = model.reminderPreview else {
            return XCTFail("Expected no reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(trip?.id, mondayClass)
        XCTAssertEqual(gap, .estimateUnavailable(.noEstimate(message: TestCommuteProvider.unavailableMessage)))
    }

    func testFailedEstimateLeavesNoReminderAndSaysWhy() async throws {
        let model = await makeRemindingModel()
        XCTAssertEqual(model.reminderPreviews.count, 5)

        model.setTestCommuteScenario(.error)
        await settle(model)

        XCTAssertTrue(model.reminderPreviews.isEmpty)
        guard case .unavailable(let trip, let gap) = model.reminderPreview else {
            return XCTFail("Expected no reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(trip?.id, mondayClass)
        XCTAssertEqual(gap, .estimateFailed(.providerFailed))
    }

    func testPassedLeaveHomeTimeIsSkippedAndExplained() async throws {
        // Monday 7:30 AM PST: the class's leave-home time (7:15) has passed, its start (9:00) has not.
        let clock = ManualWallClock(pacific(2026, 11, 2, 7, 30))
        let model = await makeRemindingModel(clock: clock)

        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), [
            pacific(2026, 11, 3, 10, 15),
            pacific(2026, 11, 4, 7, 15),
            pacific(2026, 11, 5, 10, 15),
            pacific(2026, 11, 6, 7, 15)
        ])
        XCTAssertTrue(model.reminderPreviews.allSatisfy { $0.fireDate > clock.now() }, "Nothing is due in the past")
        XCTAssertEqual(model.reminderPlan.nextTrip?.id, mondayClass)
        XCTAssertEqual(model.reminderPlan.nextTripGap, .leaveHomePassed(pacific(2026, 11, 2, 7, 15)))
        guard case .next(let next, let laterCount, _, let skippedTrip, let skippedGap) = model.reminderPreview else {
            return XCTFail("Expected the next reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(next.id, tuesdayLab)
        XCTAssertEqual(next.fireDate, pacific(2026, 11, 3, 10, 15))
        XCTAssertEqual(laterCount, 3)
        XCTAssertEqual(skippedTrip?.id, mondayClass)
        XCTAssertEqual(skippedGap, .leaveHomePassed(pacific(2026, 11, 2, 7, 15)))
    }

    // MARK: Adapter failure

    func testAdapterFailureIsReportedUntilTheSimulationEnds() async throws {
        let model = await makeRemindingModel()
        XCTAssertEqual(model.reminderPreviews.count, 5)

        model.setSimulatesReminderFailure(true)
        await settle(model)
        XCTAssertTrue(model.simulatesReminderFailure)
        XCTAssertEqual(model.previewReminderScheduler?.simulatesFailure, true)
        XCTAssertEqual(model.reminderSync, .failed)
        XCTAssertEqual(model.reminderPreview, .failed(isEnabled: true))

        model.retryReminders()
        await settle(model)
        XCTAssertEqual(model.reminderSync, .failed, "The simulation fails every attempt")
        XCTAssertEqual(model.reminderPreview, .failed(isEnabled: true))

        model.setSimulatesReminderFailure(false)
        await settle(model)
        XCTAssertEqual(model.previewReminderScheduler?.simulatesFailure, false)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)
        guard case .next(_, let laterCount, _, _, _) = model.reminderPreview else {
            return XCTFail("Expected the next reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(laterCount, 4)
    }

    func testResetPrototypeTestingAlsoEndsTheReminderFailureSimulation() async throws {
        let model = await makeRemindingModel()
        model.setSimulatesReminderFailure(true)
        await settle(model)
        XCTAssertEqual(model.reminderSync, .failed)
        XCTAssertFalse(model.isPrototypeTestingAtDefaults)

        model.resetPrototypeTesting()
        await settle(model)

        XCTAssertTrue(model.isPrototypeTestingAtDefaults)
        XCTAssertFalse(model.simulatesReminderFailure)
        XCTAssertEqual(model.previewReminderScheduler?.simulatesFailure, false)
        XCTAssertEqual(model.reminderSync, .synced)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)
    }

    // MARK: Relaunch and storage

    func testRelaunchReconcilesAPersistentAdapterToExactlyTheWantedReminders() async throws {
        let stale = reminder(occurrenceID(UUID(), month: 11, day: 2), fireDate: pacific(2026, 11, 2, 6))
        let firstCopy = reminder(mondayClass, fireDate: pacific(2026, 11, 2, 7, 15))
        let secondCopy = reminder(mondayClass, fireDate: pacific(2026, 11, 2, 7, 15), message: "Second copy, test data")
        let past = reminder(occurrenceID(SampleActivities.morningClassID, month: 10, day: 30), fireDate: pacific(2026, 10, 30, 8))
        let scheduler = RecordingReminderScheduler(initial: [stale, firstCopy, secondCopy, past])
        let model = TestFixtures.makeModel(store: InMemoryPreferencesStore(initial: remindersOn), reminderScheduler: scheduler)

        await model.loadPreferences()
        XCTAssertTrue(model.remindersEnabled)
        await model.loadSampleActivities()
        await settle(model)

        let pending = await scheduler.pending
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(Set(pending.map(\.id)).count, 5, "Duplicate copies were reduced to one")
        XCTAssertEqual(Set(pending), Set(model.reminderPlan.reminders))
        XCTAssertEqual(pending.sorted(by: ScheduledReminder.isOrderedBefore), model.reminderPreviews)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)
        XCTAssertFalse(pending.contains(stale), "A reminder for a deleted occurrence is cancelled")
        XCTAssertFalse(pending.contains(past), "A reminder already due is cancelled")
        XCTAssertFalse(pending.contains(firstCopy), "Outdated content is replaced")
        XCTAssertFalse(pending.contains(secondCopy))
        XCTAssertEqual(model.reminderSync, .synced)
    }

    func testNothingIsReconciledBeforeTheScheduleLoads() async throws {
        let held = reminder(mondayClass, fireDate: pacific(2026, 11, 2, 7, 15))
        let scheduler = RecordingReminderScheduler(initial: [held])
        let model = TestFixtures.makeModel(store: InMemoryPreferencesStore(initial: remindersOn), reminderScheduler: scheduler)

        await model.loadPreferences()
        model.retryReminders()
        model.appDidBecomeActive()
        await settle(model)

        XCTAssertTrue(model.remindersEnabled)
        XCTAssertEqual(model.activitiesStatus, .notLoaded)
        XCTAssertEqual(model.reminderSync, .idle)
        let pending = await scheduler.pending
        let reads = await scheduler.readCalls
        let cancels = await scheduler.cancelCalls
        XCTAssertEqual(pending, [held], "An empty schedule that was never read must not clear the adapter")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(cancels, 0)
    }

    func testUnreadableSchedulePausesRemindersAndLeavesTheAdapterUntouched() async throws {
        let held = reminder(mondayClass, fireDate: pacific(2026, 11, 2, 7, 15))
        let stranger = reminder(occurrenceID(UUID(), month: 11, day: 3), fireDate: pacific(2026, 11, 3, 9))
        let scheduler = RecordingReminderScheduler(initial: [held, stranger])
        let samples = SampleActivities.make(
            weekContaining: TestFixtures.fridayNoon,
            timeZone: TestFixtures.pacific,
            destination: TestFixtures.demoDestination
        )
        XCTAssertEqual(samples.count, 2)
        let repository = ScriptedActivityRepository(initial: samples)
        await repository.setFailReads(true)
        let model = TestFixtures.makeModel(
            store: InMemoryPreferencesStore(initial: remindersOn),
            repository: repository,
            reminderScheduler: scheduler
        )

        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)

        XCTAssertEqual(model.activityStorageIssue?.error, .readFailed)
        XCTAssertEqual(model.reminderSync, .paused)
        XCTAssertEqual(model.reminderPreview, .paused)
        model.appDidBecomeActive()
        model.retryReminders()
        await settle(model)
        XCTAssertEqual(model.reminderSync, .paused)
        let pending = await scheduler.pending
        let reads = await scheduler.readCalls
        let schedules = await scheduler.scheduleCalls
        let cancels = await scheduler.cancelCalls
        XCTAssertEqual(pending, [held, stranger])
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(schedules, 0)
        XCTAssertEqual(cancels, 0)

        await repository.setFailReads(false)
        await model.retryLoadingStorage()
        await settle(model)

        XCTAssertNil(model.activityStorageIssue)
        XCTAssertEqual(model.reminderSync, .synced)
        let recovered = await scheduler.pending
        XCTAssertEqual(Set(recovered), Set(model.reminderPlan.reminders))
        XCTAssertFalse(recovered.contains(stranger))
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)
    }

    // MARK: Foreground and the minute tick

    func testReturningToTheForegroundRereadsTheAdapter() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        let wanted = model.reminderPreviews
        XCTAssertEqual(wanted.count, 5)
        let stranger = reminder(occurrenceID(UUID(), month: 11, day: 4), fireDate: pacific(2026, 11, 4, 6))
        await scheduler.inject(stranger)
        await scheduler.remove(id: tuesdayLab)
        let readsBefore = await scheduler.readCalls

        model.appDidBecomeActive()
        await settle(model)

        let readsAfter = await scheduler.readCalls
        let pending = await scheduler.pending
        XCTAssertGreaterThan(readsAfter, readsBefore)
        XCTAssertFalse(pending.contains(stranger), "A reminder added behind the model's back is removed")
        XCTAssertEqual(Set(pending), Set(wanted), "A reminder removed behind the model's back is restored")
        XCTAssertEqual(model.reminderPreviews, wanted)
        XCTAssertEqual(model.reminderSync, .synced)
    }

    func testReminderThatFallsDueDropsOutOnTheNextTick() async throws {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(clock: clock, scheduler: scheduler)
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), sampleFireDates)

        clock.set(pacific(2026, 11, 2, 7, 16))
        model.refreshDepartures()
        await settle(model)

        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), Array(sampleFireDates.dropFirst()))
        let pending = await scheduler.pending
        XCTAssertEqual(pending.count, 4)
        XCTAssertFalse(pending.contains { $0.id == mondayClass })
        guard case .next(let next, let laterCount, _, let skippedTrip, let skippedGap) = model.reminderPreview else {
            return XCTFail("Expected the next reminder, got \(model.reminderPreview)")
        }
        XCTAssertEqual(next.id, tuesdayLab)
        XCTAssertEqual(laterCount, 3)
        XCTAssertEqual(skippedTrip?.id, mondayClass)
        XCTAssertEqual(skippedGap, .leaveHomePassed(pacific(2026, 11, 2, 7, 15)))
    }

    // MARK: Changed estimates

    func testChangedEstimateKeepsEachReminderOutOfDateThenMovesItInPlace() async throws {
        let scheduler = RecordingReminderScheduler()
        let model = await makeRemindingModel(scheduler: scheduler)
        let before = model.reminderPreviews
        XCTAssertEqual(before.map(\.fireDate), sampleFireDates)
        let first = try XCTUnwrap(before.first)
        let cancelsBefore = await scheduler.cancelCalls

        // A 45-minute test commute: every trip is asked again and keeps its earlier time, out of
        // date, until the new estimate arrives, so its reminder is held rather than dropped.
        XCTAssertNil(model.applyTestCommuteMinutes("45"))
        let monday = try XCTUnwrap(model.reminderPlan.nextTrip)
        XCTAssertEqual(monday.id, mondayClass)
        XCTAssertEqual(model.departureState(for: monday).staleCalculation?.leaveHome, pacific(2026, 11, 2, 7, 15))
        XCTAssertEqual(model.reminderPlan.held, Set(before.map(\.id)))
        XCTAssertTrue(model.reminderPlan.reminders.isEmpty, "An out-of-date estimate never creates a reminder")
        XCTAssertNil(model.reminderPlan.nextTripGap)
        XCTAssertEqual(model.reminderPreview, .next(first, laterCount: 4, isUpdating: true, skippedTrip: nil, skippedGap: nil))

        await settle(model)

        let moved = [
            pacific(2026, 11, 2, 7, 30),
            pacific(2026, 11, 3, 10, 30),
            pacific(2026, 11, 4, 7, 30),
            pacific(2026, 11, 5, 10, 30),
            pacific(2026, 11, 6, 7, 30)
        ]
        XCTAssertEqual(model.reminderPreviews.map(\.fireDate), moved, "Ideal arrival minus 45 minutes")
        XCTAssertEqual(model.reminderPreviews.map(\.id), before.map(\.id), "Same occurrences, same ids")
        XCTAssertEqual(model.reminderPreviews, model.reminderPlan.reminders)
        XCTAssertTrue(model.reminderPlan.held.isEmpty)
        XCTAssertEqual(model.reminderSync, .synced)
        let pending = await scheduler.pending
        let cancelsAfter = await scheduler.cancelCalls
        XCTAssertEqual(pending.count, 5, "Each reminder was replaced, never duplicated")
        XCTAssertEqual(Set(pending), Set(model.reminderPreviews))
        XCTAssertEqual(cancelsAfter, cancelsBefore, "Held reminders are replaced in place, never cancelled first")
        let mondayReminder = try XCTUnwrap(model.reminderPreviews.first)
        XCTAssertTrue(mondayReminder.message.contains("7:30"), mondayReminder.message)
        XCTAssertTrue(mondayReminder.message.contains("45 minutes"), mondayReminder.message)
        XCTAssertEqual(model.reminderPreview, .next(mondayReminder, laterCount: 4, isUpdating: false, skippedTrip: nil, skippedGap: nil))
    }
}
