import XCTest
@testable import WaitItOutUX

/// Step 0007: which leave-home reminders should exist (`ReminderPlan`), the adapter calls that
/// reconcile what is pending with them (`ReminderChanges`), what the preview shows
/// (`ReminderPreview`), the in-app preview adapter (`PreviewReminderScheduler`), and the
/// reminder text.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. Clocks fall back on Sun 2026-11-01, so every
/// expected time from Monday on is built in Pacific with `TestFixtures.date`, never by adding
/// whole days of seconds. Times in text are matched on digits because iOS 17 puts a narrow
/// no-break space before AM and PM.
final class ReminderPlanTests: XCTestCase {
    private let now = TestFixtures.fridayNoon
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)

    /// The reminder the model would build, with placeholder text: due at the leave-home time.
    private let makeReminder: (ActivityOccurrence, DepartureCalculation) -> ScheduledReminder = { occurrence, departure in
        ScheduledReminder(id: occurrence.id, fireDate: departure.leaveHome, title: "T", message: "M")
    }

    // MARK: Helpers

    /// The two sample classes, anchored to the week of the fixture clock.
    private func sampleSchedule() -> [Activity] {
        SampleActivities.make(weekContaining: TestFixtures.fridayNoon, timeZone: TestFixtures.pacific, destination: TestFixtures.demoDestination)
    }

    private func sampleUpcoming(at instant: Date) -> [ActivityOccurrence] {
        DepartureHorizon.upcomingOccurrences(of: sampleSchedule(), at: instant)
    }

    /// The current calculation for `occurrence` from a simulated estimate of `minutes`.
    private func calculation(for occurrence: ActivityOccurrence, minutes: Double = 60) throws -> DepartureCalculation {
        try DepartureCalculation.make(idealArrival: occurrence.idealArrival, estimate: testEstimate(minutes: minutes)).get()
    }

    /// `.success` with a simulated estimate of `minutes`, as the model stores a current answer.
    private func currentState(for occurrence: ActivityOccurrence, minutes: Double = 60) -> DepartureState {
        switch DepartureCalculation.make(idealArrival: occurrence.idealArrival, estimate: testEstimate(minutes: minutes)) {
        case .success(let departure):
            return .success(departure)
        case .failure(let issue):
            return .error(.invalidEstimate(issue))
        }
    }

    /// The plan for `activities` at `instant` when every trip has a current estimate.
    private func makePlan(for activities: [Activity], at instant: Date, minutes: Double = 60) -> ReminderPlan {
        ReminderPlan.make(
            upcoming: DepartureHorizon.upcomingOccurrences(of: activities, at: instant),
            at: instant,
            state: { self.currentState(for: $0, minutes: minutes) },
            makeReminder: makeReminder
        )
    }

    private func samplePlan(at instant: Date, minutes: Double = 60) -> ReminderPlan {
        makePlan(for: sampleSchedule(), at: instant, minutes: minutes)
    }

    private func occurrenceID(_ activityID: UUID, _ year: Int, _ month: Int, _ day: Int) -> OccurrenceID {
        OccurrenceID(activityID: activityID, date: LocalDate.of(TestFixtures.date(year, month, day, 12, 0), in: TestFixtures.pacific))
    }

    /// What an adapter that keys reminders by occurrence id holds after `changes`:
    /// cancellations first, then each scheduled reminder added or replacing the one with its id.
    private func applying(_ changes: ReminderChanges, to pending: [ScheduledReminder]) -> [ScheduledReminder] {
        var result = pending.filter { !changes.toCancel.contains($0.id) }
        for reminder in changes.toSchedule {
            result.removeAll(where: { $0.id == reminder.id })
            result.append(reminder)
        }
        return result.sorted(by: ScheduledReminder.isOrderedBefore)
    }

    /// Runs `operation` and checks that it throws the preview adapter's simulated failure.
    private func assertSimulatedFailure(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(label) should fail while the failure simulation is on", file: file, line: line)
        } catch {
            XCTAssertTrue(error is PreviewReminderSchedulerError, "\(label) threw \(error)", file: file, line: line)
        }
    }

    // MARK: Plan

    func testSampleScheduleGetsOneReminderPerUpcomingClassAtItsLeaveHomeTime() throws {
        let plan = samplePlan(at: now)
        let morning = SampleActivities.morningClassID
        let lab = SampleActivities.afternoonLabID
        XCTAssertEqual(plan.reminders.count, 5)
        XCTAssertEqual(
            plan.reminders.map(\.fireDate),
            [
                TestFixtures.date(2026, 11, 2, 7, 15),
                TestFixtures.date(2026, 11, 3, 10, 15),
                TestFixtures.date(2026, 11, 4, 7, 15),
                TestFixtures.date(2026, 11, 5, 10, 15),
                TestFixtures.date(2026, 11, 6, 7, 15)
            ],
            "Ideal arrival minus 60 minutes, in Pacific standard time after the fall-back weekend"
        )
        XCTAssertEqual(plan.reminders.map(\.id.activityID), [morning, lab, morning, lab, morning])
        XCTAssertEqual(plan.reminders.map(\.id.date.description), ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"])
        XCTAssertEqual(Set(plan.reminders.map(\.id)).count, plan.reminders.count, "One reminder per occurrence")
        XCTAssertEqual(plan.reminders, plan.reminders.sorted(by: ScheduledReminder.isOrderedBefore), "Ordered by fire date")
        XCTAssertTrue(plan.reminders.allSatisfy({ $0.fireDate > now }))
        XCTAssertTrue(plan.reminders.allSatisfy({ $0.title == "T" && $0.message == "M" }), "Text comes from the caller")
        XCTAssertTrue(plan.held.isEmpty)
        XCTAssertNil(plan.nextTripGap)

        let monday = try XCTUnwrap(LocalDate(year: 2026, month: 11, day: 2))
        XCTAssertEqual(plan.nextTrip?.id, OccurrenceID(activityID: morning, date: monday))
        XCTAssertEqual(plan.reminders.first?.id, plan.nextTrip?.id)
        XCTAssertEqual(plan.reminders.first?.identifier, "leave-home.\(morning.uuidString)@2026-11-02")
    }

    func testRecurringOccurrencesGetDistinctIDsThatStayStableAcrossPlans() throws {
        let first = samplePlan(at: now)
        let morningIDs = first.reminders.map(\.id).filter { $0.activityID == SampleActivities.morningClassID }
        XCTAssertEqual(morningIDs.count, 3)
        XCTAssertEqual(Set(morningIDs).count, 3, "Each weekly occurrence has its own id")
        XCTAssertEqual(morningIDs.map(\.date.description), ["2026-11-02", "2026-11-04", "2026-11-06"])

        let again = samplePlan(at: now)
        XCTAssertEqual(again.reminders.map(\.id), first.reminders.map(\.id), "Fresh activities and a fresh expansion give the same ids")
        XCTAssertEqual(again, first, "Same inputs, same plan")

        let saturdayMorning = TestFixtures.date(2026, 10, 31, 10, 0)
        let later = samplePlan(at: saturdayMorning)
        XCTAssertEqual(later.reminders.map(\.id), first.reminders.map(\.id), "Planning a day later finds the same occurrences under the same ids")
        XCTAssertEqual(later, first)

        let upcoming = sampleUpcoming(at: now)
        let shuffled = ReminderPlan.make(
            upcoming: Array(upcoming.reversed()) + upcoming,
            at: now,
            state: { self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        XCTAssertEqual(shuffled, first, "Input order and repeated occurrences do not change the plan")
    }

    func testTripWhoseLeaveHomeTimeHasPassedGetsNoReminder() throws {
        let sevenFifteen = TestFixtures.date(2026, 11, 2, 7, 15)
        let sevenThirty = TestFixtures.date(2026, 11, 2, 7, 30)
        let plan = samplePlan(at: sevenThirty)
        let next = try XCTUnwrap(plan.nextTrip)
        XCTAssertEqual(next.id.activityID, SampleActivities.morningClassID)
        XCTAssertEqual(next.id.date.description, "2026-11-02")
        XCTAssertGreaterThan(next.start, sevenThirty, "The class has not started")
        XCTAssertEqual(plan.nextTripGap, .leaveHomePassed(sevenFifteen), "The calculated time is reported, not moved to now")
        XCTAssertFalse(plan.reminders.contains(where: { $0.id == next.id }))
        XCTAssertEqual(plan.reminders.map(\.id.date.description), ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"])
        XCTAssertTrue(plan.reminders.allSatisfy({ $0.fireDate > sevenThirty }), "Nothing in the plan is due at or before now")

        let atLeaveHome = samplePlan(at: sevenFifteen)
        XCTAssertEqual(atLeaveHome.nextTripGap, .leaveHomePassed(sevenFifteen), "Due exactly now counts as passed")
        XCTAssertFalse(atLeaveHome.reminders.contains(where: { $0.id == next.id }))
        XCTAssertTrue(atLeaveHome.reminders.allSatisfy({ $0.fireDate > sevenFifteen }))

        let justBefore = samplePlan(at: TestFixtures.date(2026, 11, 2, 7, 14))
        XCTAssertNil(justBefore.nextTripGap)
        XCTAssertEqual(justBefore.reminders.first?.id, next.id)
        XCTAssertEqual(justBefore.reminders.first?.fireDate, sevenFifteen)
    }

    func testOccurrencesThatHaveStartedAreNotTrips() throws {
        let nineTwenty = TestFixtures.date(2026, 11, 2, 9, 20)
        let upcoming = sampleUpcoming(at: nineTwenty)
        let inProgress = try XCTUnwrap(upcoming.first)
        XCTAssertEqual(inProgress.id.date.description, "2026-11-02")
        XCTAssertLessThan(inProgress.start, nineTwenty)
        XCTAssertGreaterThan(inProgress.end, nineTwenty)

        // Even a current calculation whose leave-home time is still ahead gives no reminder.
        let ahead = try DepartureCalculation.make(idealArrival: nineTwenty.addingTimeInterval(2 * 3_600), estimate: testEstimate(minutes: 60)).get()
        XCTAssertGreaterThan(ahead.leaveHome, nineTwenty)
        let plan = ReminderPlan.make(
            upcoming: upcoming,
            at: nineTwenty,
            state: { $0.id == inProgress.id ? .success(ahead) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        XCTAssertFalse(plan.reminders.contains(where: { $0.id == inProgress.id }))
        XCTAssertEqual(plan.nextTrip?.id.activityID, SampleActivities.afternoonLabID)
        XCTAssertEqual(plan.nextTrip?.id.date.description, "2026-11-03")
        XCTAssertNil(plan.nextTripGap)
        XCTAssertEqual(plan.reminders.map(\.id.date.description), ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-09"])

        let atStart = samplePlan(at: TestFixtures.date(2026, 11, 2, 9, 0))
        XCTAssertEqual(atStart.nextTrip?.id.date.description, "2026-11-03", "Starting exactly now counts as started")
        XCTAssertFalse(atStart.reminders.contains(where: { $0.id == inProgress.id }))

        let onlyStarted = ReminderPlan.make(upcoming: [inProgress], at: nineTwenty, state: { _ in .success(ahead) }, makeReminder: makeReminder)
        XCTAssertTrue(onlyStarted.reminders.isEmpty)
        XCTAssertNil(onlyStarted.nextTrip)
        XCTAssertEqual(onlyStarted.nextTripGap, .noUpcomingTrips)
    }

    func testNextTripWithoutACurrentEstimateExplainsTheGap() throws {
        let upcoming = sampleUpcoming(at: now)
        let next = try XCTUnwrap(upcoming.first)
        let expectations: [(DepartureState, ReminderGap)] = [
            (.loading, .waitingForEstimate),
            (.unavailable(.noEstimate(message: "No route (test).")), .estimateUnavailable(.noEstimate(message: "No route (test)."))),
            (.unavailable(.noDestination), .estimateUnavailable(.noDestination)),
            (.error(.providerFailed), .estimateFailed(.providerFailed)),
            (.error(.invalidEstimate(.travelTime(.notPositive))), .estimateFailed(.invalidEstimate(.travelTime(.notPositive))))
        ]
        for (nextState, gap) in expectations {
            let plan = ReminderPlan.make(
                upcoming: upcoming,
                at: now,
                state: { $0.id == next.id ? nextState : self.currentState(for: $0) },
                makeReminder: makeReminder
            )
            XCTAssertEqual(plan.nextTrip?.id, next.id, "\(nextState)")
            XCTAssertEqual(plan.nextTripGap, gap, "\(nextState)")
            XCTAssertFalse(plan.reminders.contains(where: { $0.id == next.id }), "\(nextState) never produces a reminder")
            XCTAssertEqual(plan.reminders.count, 4, "Later trips keep their reminders: \(nextState)")
            XCTAssertTrue(plan.held.isEmpty, "\(nextState)")
        }

        let second = try XCTUnwrap(upcoming.dropFirst().first)
        let laterFailure = ReminderPlan.make(
            upcoming: upcoming,
            at: now,
            state: { $0.id == second.id ? .error(.providerFailed) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        XCTAssertNil(laterFailure.nextTripGap, "Only the next trip decides the gap")
        XCTAssertFalse(laterFailure.reminders.contains(where: { $0.id == second.id }))
        XCTAssertEqual(laterFailure.reminders.count, 4)
    }

    func testRefreshingTripIsHeldWithoutAReminderOrAGap() throws {
        let upcoming = sampleUpcoming(at: now)
        let next = try XCTUnwrap(upcoming.first)
        let stale = try calculation(for: next, minutes: 45)
        let plan = ReminderPlan.make(
            upcoming: upcoming,
            at: now,
            state: { $0.id == next.id ? .refreshing(stale) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        XCTAssertEqual(plan.held, [next.id])
        XCTAssertFalse(plan.reminders.contains(where: { $0.id == next.id }), "An out-of-date estimate never creates a reminder")
        XCTAssertEqual(plan.reminders.count, 4)
        XCTAssertNil(plan.nextTripGap)
        XCTAssertEqual(plan.nextTrip?.id, next.id)
    }

    func testNoUpcomingTripsIsItsOwnGap() {
        let empty = ReminderPlan.make(upcoming: [], at: now, state: { _ in .loading }, makeReminder: makeReminder)
        XCTAssertEqual(empty, ReminderPlan(reminders: [], held: [], nextTrip: nil, nextTripGap: .noUpcomingTrips))

        let farAway = TestFixtures.activity(title: "Far away", start: TestFixtures.date(2026, 11, 20, 9, 0))
        let beyond = makePlan(for: [farAway], at: now)
        XCTAssertTrue(beyond.reminders.isEmpty)
        XCTAssertNil(beyond.nextTrip)
        XCTAssertEqual(beyond.nextTripGap, .noUpcomingTrips)
    }

    func testPlanKeepsAtMostTwentyRemindersTheEarliestOnes() throws {
        let everyDay = Set(Weekday.allCases)
        let dailyEarly = TestFixtures.activity(title: "Daily early", start: TestFixtures.date(2026, 10, 31, 7, 0), repeatWeekdays: everyDay)
        let dailyMidday = TestFixtures.activity(title: "Daily midday", start: TestFixtures.date(2026, 10, 31, 13, 30), repeatWeekdays: everyDay)
        let dailyEvening = TestFixtures.activity(title: "Daily evening", start: TestFixtures.date(2026, 10, 30, 18, 0), repeatWeekdays: everyDay)
        let activities = sampleSchedule() + [dailyEarly, dailyMidday, dailyEvening]
        let upcoming = DepartureHorizon.upcomingOccurrences(of: activities, at: now)
        let trips = upcoming.filter { $0.start > now }
        XCTAssertEqual(trips.count, 25, "5 sample classes plus 7, 6, and 7 daily occurrences within the horizon")
        XCTAssertGreaterThan(trips.count, ReminderPlan.maximumCount)

        let plan = ReminderPlan.make(upcoming: upcoming, at: now, state: { self.currentState(for: $0) }, makeReminder: makeReminder)
        XCTAssertEqual(ReminderPlan.maximumCount, 20)
        XCTAssertEqual(plan.reminders.count, ReminderPlan.maximumCount)
        XCTAssertEqual(Set(plan.reminders.map(\.id)).count, ReminderPlan.maximumCount)
        XCTAssertNil(plan.nextTripGap, "The bound is not a gap")
        XCTAssertEqual(plan.reminders.first?.fireDate, TestFixtures.date(2026, 10, 30, 16, 15))

        let lastKept = try XCTUnwrap(plan.reminders.last)
        XCTAssertEqual(lastKept.fireDate, TestFixtures.date(2026, 11, 5, 5, 15))
        XCTAssertEqual(lastKept.id.activityID, dailyEarly.id)

        let kept = Set(plan.reminders.map(\.id))
        let dropped = trips.filter { !kept.contains($0.id) }
        XCTAssertEqual(dropped.count, trips.count - ReminderPlan.maximumCount)
        for trip in dropped {
            let leaveHome = try calculation(for: trip).leaveHome
            XCTAssertGreaterThan(leaveHome, lastKept.fireDate, "\(trip.activity.title) on \(trip.id.date) is later than every kept reminder")
        }
        let firstDropped = try XCTUnwrap(dropped.min(by: { $0.idealArrival < $1.idealArrival }))
        XCTAssertEqual(firstDropped.activity.id, SampleActivities.afternoonLabID)
        XCTAssertEqual(firstDropped.id.date.description, "2026-11-05")

        let earlyDays = plan.reminders.filter { $0.id.activityID == dailyEarly.id }.map(\.id.date.description)
        XCTAssertEqual(earlyDays, ["2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"], "One id per day of the daily series")
    }

    // MARK: Changes

    func testTurningRemindersOffCancelsEveryPendingReminder() {
        let none = ReminderPlan.none
        XCTAssertTrue(none.reminders.isEmpty)
        XCTAssertTrue(none.held.isEmpty)
        XCTAssertNil(none.nextTrip)
        XCTAssertNil(none.nextTripGap)

        let pending = samplePlan(at: now).reminders
        XCTAssertEqual(pending.count, 5)
        let changes = ReminderChanges.between(pending: pending, plan: ReminderPlan.none, now: now)
        XCTAssertEqual(changes.toCancel, Set(pending.map(\.id)))
        XCTAssertTrue(changes.toSchedule.isEmpty)

        let cleared = applying(changes, to: pending)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(ReminderChanges.between(pending: cleared, plan: ReminderPlan.none, now: now).isEmpty)
        XCTAssertEqual(ReminderPreview.make(isEnabled: false, sync: .synced, previews: cleared, plan: ReminderPlan.none, now: now), .off)
    }

    func testEmptyAdapterGetsEveryWantedReminder() {
        let plan = samplePlan(at: now)
        let changes = ReminderChanges.between(pending: [], plan: plan, now: now)
        XCTAssertEqual(changes.toSchedule, plan.reminders)
        XCTAssertTrue(changes.toCancel.isEmpty)
        XCTAssertFalse(changes.isEmpty)
        XCTAssertTrue(ReminderChanges.between(pending: [], plan: ReminderPlan.none, now: now).isEmpty)
    }

    func testApplyingTheChangesAndReconcilingAgainChangesNothing() throws {
        let plan = samplePlan(at: now)
        let first = try XCTUnwrap(plan.reminders.first)
        let second = try XCTUnwrap(plan.reminders.dropFirst().first)
        let outdated = ScheduledReminder(id: first.id, fireDate: first.fireDate.addingTimeInterval(-600), title: first.title, message: "Older estimate")
        let deleted = ScheduledReminder(id: occurrenceID(UUID(), 2026, 11, 3), fireDate: TestFixtures.date(2026, 11, 3, 6, 0), title: "Deleted", message: "M")
        let due = ScheduledReminder(id: occurrenceID(UUID(), 2026, 10, 30), fireDate: now.addingTimeInterval(-60), title: "Due", message: "M")
        let pending = [outdated, second, second, deleted, due] + Array(plan.reminders.dropFirst(2))

        let changes = ReminderChanges.between(pending: pending, plan: plan, now: now)
        XCTAssertEqual(changes.toCancel, [second.id, deleted.id, due.id])
        XCTAssertEqual(changes.toSchedule, [first, second])

        let applied = applying(changes, to: pending)
        XCTAssertEqual(applied, plan.reminders)
        XCTAssertTrue(ReminderChanges.between(pending: applied, plan: plan, now: now).isEmpty, "Reconciling twice changes nothing the second time")
        XCTAssertEqual(ReminderChanges.between(pending: pending, plan: plan, now: now), changes, "Pure")
    }

    func testChangedReminderIsScheduledAgainWithoutCancelling() throws {
        let plan = samplePlan(at: now)
        let wanted = try XCTUnwrap(plan.reminders.dropFirst().first)

        let earlier = ScheduledReminder(id: wanted.id, fireDate: wanted.fireDate.addingTimeInterval(-15 * 60), title: wanted.title, message: wanted.message)
        let moved = ReminderChanges.between(pending: plan.reminders.map { $0.id == wanted.id ? earlier : $0 }, plan: plan, now: now)
        XCTAssertEqual(moved.toSchedule, [wanted])
        XCTAssertTrue(moved.toCancel.isEmpty, "Scheduling the same id replaces it")

        let reworded = ScheduledReminder(id: wanted.id, fireDate: wanted.fireDate, title: wanted.title, message: "Older text")
        let rewritten = ReminderChanges.between(pending: plan.reminders.map { $0.id == wanted.id ? reworded : $0 }, plan: plan, now: now)
        XCTAssertEqual(rewritten.toSchedule, [wanted])
        XCTAssertTrue(rewritten.toCancel.isEmpty)
    }

    func testEditedAndDeletedOccurrencesLoseTheirOldReminders() throws {
        let lectureID = UUID()
        let original = TestFixtures.activity(id: lectureID, title: "Lecture", start: TestFixtures.date(2026, 11, 2, 9, 0))
        let before = makePlan(for: [original], at: now)
        XCTAssertEqual(before.reminders.count, 1)
        let mondayReminder = try XCTUnwrap(before.reminders.first)
        XCTAssertEqual(mondayReminder.fireDate, TestFixtures.date(2026, 11, 2, 7, 15))

        let retimed = makePlan(for: [TestFixtures.activity(id: lectureID, title: "Lecture", start: TestFixtures.date(2026, 11, 2, 10, 0))], at: now)
        XCTAssertEqual(retimed.reminders.first?.id, mondayReminder.id, "Same day, same occurrence id")
        let retimedChanges = ReminderChanges.between(pending: before.reminders, plan: retimed, now: now)
        XCTAssertEqual(retimedChanges.toSchedule.map(\.fireDate), [TestFixtures.date(2026, 11, 2, 8, 15)])
        XCTAssertTrue(retimedChanges.toCancel.isEmpty)

        let moved = makePlan(for: [TestFixtures.activity(id: lectureID, title: "Lecture", start: TestFixtures.date(2026, 11, 3, 9, 0))], at: now)
        let movedChanges = ReminderChanges.between(pending: before.reminders, plan: moved, now: now)
        XCTAssertEqual(movedChanges.toCancel, [mondayReminder.id])
        XCTAssertEqual(movedChanges.toSchedule.map(\.id.date.description), ["2026-11-03"])

        let deletedChanges = ReminderChanges.between(pending: before.reminders, plan: makePlan(for: [], at: now), now: now)
        XCTAssertEqual(deletedChanges.toCancel, [mondayReminder.id])
        XCTAssertTrue(deletedChanges.toSchedule.isEmpty)
    }

    func testHeldReminderIsKeptWhileAheadAndCancelledOnceDue() throws {
        let pending = samplePlan(at: now).reminders
        let upcoming = sampleUpcoming(at: now)
        let monday = try XCTUnwrap(upcoming.first)
        let mondayReminder = try XCTUnwrap(pending.first)
        XCTAssertEqual(mondayReminder.id, monday.id)
        let stale = try calculation(for: monday)

        let refreshing = ReminderPlan.make(
            upcoming: upcoming,
            at: now,
            state: { $0.id == monday.id ? .refreshing(stale) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        let kept = ReminderChanges.between(pending: pending, plan: refreshing, now: now)
        XCTAssertTrue(kept.isEmpty, "The pending reminder stays while its estimate refreshes: \(kept)")

        let fromEmpty = ReminderChanges.between(pending: [], plan: refreshing, now: now)
        XCTAssertFalse(fromEmpty.toSchedule.contains(where: { $0.id == monday.id }), "A held trip is never newly scheduled")
        XCTAssertEqual(fromEmpty.toSchedule.count, 4)

        let sevenTwenty = TestFixtures.date(2026, 11, 2, 7, 20)
        let stillRefreshing = ReminderPlan.make(
            upcoming: sampleUpcoming(at: sevenTwenty),
            at: sevenTwenty,
            state: { $0.id == monday.id ? .refreshing(stale) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        XCTAssertEqual(stillRefreshing.held, [monday.id])
        let fallenDue = ReminderChanges.between(pending: pending, plan: stillRefreshing, now: sevenTwenty)
        XCTAssertEqual(fallenDue.toCancel, [monday.id], "Already due, so it goes even though it is held")
        XCTAssertTrue(fallenDue.toSchedule.isEmpty)

        let heldOnly = ReminderPlan(reminders: [], held: [monday.id], nextTrip: monday, nextTripGap: nil)
        let atFireDate = ReminderChanges.between(pending: [mondayReminder], plan: heldOnly, now: mondayReminder.fireDate)
        XCTAssertEqual(atFireDate.toCancel, [monday.id], "Due exactly now counts as due")
        XCTAssertTrue(atFireDate.toSchedule.isEmpty)
        XCTAssertTrue(ReminderChanges.between(pending: [mondayReminder], plan: heldOnly, now: now).isEmpty)
    }

    func testDuplicateCopiesOfAWantedReminderAreReplacedByOne() throws {
        let plan = samplePlan(at: now)
        let first = try XCTUnwrap(plan.reminders.first)
        let pending = plan.reminders + [first]
        let changes = ReminderChanges.between(pending: pending, plan: plan, now: now)
        XCTAssertEqual(changes.toCancel, [first.id])
        XCTAssertEqual(changes.toSchedule, [first])

        let applied = applying(changes, to: pending)
        XCTAssertEqual(applied, plan.reminders)
        XCTAssertTrue(ReminderChanges.between(pending: applied, plan: plan, now: now).isEmpty)
    }

    // MARK: Preview

    func testPreviewIsOffPausedOrFailedBeforeLookingAtReminders() {
        let plan = samplePlan(at: now)
        XCTAssertEqual(ReminderPreview.make(isEnabled: false, sync: .synced, previews: [], plan: ReminderPlan.none, now: now), .off)
        XCTAssertEqual(ReminderPreview.make(isEnabled: false, sync: .idle, previews: [], plan: ReminderPlan.none, now: now), .off)
        for isEnabled in [true, false] {
            XCTAssertEqual(ReminderPreview.make(isEnabled: isEnabled, sync: .paused, previews: plan.reminders, plan: plan, now: now), .paused)
            XCTAssertEqual(
                ReminderPreview.make(isEnabled: isEnabled, sync: .failed, previews: plan.reminders, plan: plan, now: now),
                .failed(isEnabled: isEnabled)
            )
        }
    }

    func testPreviewIsUpdatingUntilTheFirstReconciliationFinishes() {
        let plan = samplePlan(at: now)
        XCTAssertEqual(ReminderPreview.make(isEnabled: true, sync: .idle, previews: [], plan: plan, now: now), .updating)
        XCTAssertEqual(ReminderPreview.make(isEnabled: true, sync: .updating, previews: [], plan: plan, now: now), .updating)
    }

    func testPreviewShowsTheNextReminderAndHowManyFollow() throws {
        let plan = samplePlan(at: now)
        let first = try XCTUnwrap(plan.reminders.first)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: Array(plan.reminders.reversed()), plan: plan, now: now),
            .next(first, laterCount: 4, isUpdating: false, skippedTrip: nil, skippedGap: nil)
        )
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .updating, previews: plan.reminders, plan: plan, now: now),
            .next(first, laterCount: 4, isUpdating: false, skippedTrip: nil, skippedGap: nil),
            "isUpdating means the trip is being re-estimated, not that the adapter is busy"
        )
    }

    func testPreviewMarksAHeldReminderAsUpdating() throws {
        let pending = samplePlan(at: now).reminders
        let upcoming = sampleUpcoming(at: now)
        let monday = try XCTUnwrap(upcoming.first)
        let stale = try calculation(for: monday)
        let refreshing = ReminderPlan.make(
            upcoming: upcoming,
            at: now,
            state: { $0.id == monday.id ? .refreshing(stale) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        let held = try XCTUnwrap(pending.first)
        XCTAssertEqual(held.id, monday.id)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: pending, plan: refreshing, now: now),
            .next(held, laterCount: 4, isUpdating: true, skippedTrip: nil, skippedGap: nil)
        )

        let onlyHeld = ReminderPlan.make(upcoming: [monday], at: now, state: { _ in .refreshing(stale) }, makeReminder: makeReminder)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: [], plan: onlyHeld, now: now),
            .updating,
            "A held trip with nothing pending is waiting for its estimate, not unavailable"
        )
    }

    func testPreviewNamesTheSkippedNextTripWhenALaterReminderExists() throws {
        let sevenThirty = TestFixtures.date(2026, 11, 2, 7, 30)
        let passed = samplePlan(at: sevenThirty)
        let skipped = try XCTUnwrap(passed.nextTrip)
        let tuesday = try XCTUnwrap(passed.reminders.first)
        XCTAssertEqual(tuesday.id.activityID, SampleActivities.afternoonLabID)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: passed.reminders, plan: passed, now: sevenThirty),
            .next(tuesday, laterCount: 3, isUpdating: false, skippedTrip: skipped, skippedGap: .leaveHomePassed(TestFixtures.date(2026, 11, 2, 7, 15)))
        )

        let upcoming = sampleUpcoming(at: now)
        let monday = try XCTUnwrap(upcoming.first)
        let failing = ReminderPlan.make(
            upcoming: upcoming,
            at: now,
            state: { $0.id == monday.id ? .error(.providerFailed) : self.currentState(for: $0) },
            makeReminder: makeReminder
        )
        let laterReminder = try XCTUnwrap(failing.reminders.first)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: failing.reminders, plan: failing, now: now),
            .next(laterReminder, laterCount: 3, isUpdating: false, skippedTrip: monday, skippedGap: .estimateFailed(.providerFailed))
        )
    }

    func testPreviewExplainsWhyNoReminderExists() throws {
        let upcoming = sampleUpcoming(at: now)
        let monday = try XCTUnwrap(upcoming.first)
        let failing = ReminderPlan.make(upcoming: upcoming, at: now, state: { _ in .error(.providerFailed) }, makeReminder: makeReminder)
        XCTAssertTrue(failing.reminders.isEmpty)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: [], plan: failing, now: now),
            .unavailable(trip: monday, gap: .estimateFailed(.providerFailed))
        )

        let empty = ReminderPlan.make(upcoming: [], at: now, state: { _ in .loading }, makeReminder: makeReminder)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: [], plan: empty, now: now),
            .unavailable(trip: nil, gap: .noUpcomingTrips)
        )
    }

    func testPreviewIgnoresRemindersAlreadyDue() throws {
        let plan = samplePlan(at: now)
        let first = try XCTUnwrap(plan.reminders.first)
        let dueNow = ScheduledReminder(id: occurrenceID(UUID(), 2026, 10, 30), fireDate: now, title: "Due", message: "M")
        let past = ScheduledReminder(id: occurrenceID(UUID(), 2026, 10, 30), fireDate: now.addingTimeInterval(-3_600), title: "Past", message: "M")
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: [past, dueNow] + plan.reminders, plan: plan, now: now),
            .next(first, laterCount: 4, isUpdating: false, skippedTrip: nil, skippedGap: nil)
        )

        let failing = ReminderPlan.make(upcoming: sampleUpcoming(at: now), at: now, state: { _ in .error(.providerFailed) }, makeReminder: makeReminder)
        XCTAssertEqual(
            ReminderPreview.make(isEnabled: true, sync: .synced, previews: [past, dueNow], plan: failing, now: now),
            .unavailable(trip: failing.nextTrip, gap: .estimateFailed(.providerFailed))
        )
    }

    // MARK: Preview adapter

    func testPreviewSchedulerAddsReplacesAndCancelsByOccurrenceID() async throws {
        let scheduler = PreviewReminderScheduler()
        XCTAssertEqual(scheduler.delivery, .inAppPreview)
        XCTAssertEqual(scheduler.delivery.disclosure, "Preview only - no system notification will be sent.")
        XCTAssertNotEqual(ReminderDelivery.systemNotification.disclosure, scheduler.delivery.disclosure)
        XCTAssertFalse(scheduler.simulatesFailure)
        let initial = try await scheduler.pendingReminders()
        XCTAssertTrue(initial.isEmpty)

        let mondayID = occurrenceID(SampleActivities.morningClassID, 2026, 11, 2)
        let tuesdayID = occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 3)
        let monday = ScheduledReminder(id: mondayID, fireDate: TestFixtures.date(2026, 11, 2, 7, 15), title: "Monday", message: "M")
        let sameTime = ScheduledReminder(id: occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 2), fireDate: monday.fireDate, title: "Same time", message: "M")
        let tuesday = ScheduledReminder(id: tuesdayID, fireDate: TestFixtures.date(2026, 11, 3, 10, 15), title: "Tuesday", message: "M")
        XCTAssertTrue(ScheduledReminder.isOrderedBefore(monday, sameTime), "Equal fire dates are ordered by occurrence id")
        XCTAssertFalse(ScheduledReminder.isOrderedBefore(sameTime, monday))

        try await scheduler.schedule([tuesday, sameTime, monday])
        let scheduled = try await scheduler.pendingReminders()
        XCTAssertEqual(scheduled, [monday, sameTime, tuesday], "Sorted by fire date, then occurrence id")

        let moved = ScheduledReminder(id: tuesdayID, fireDate: TestFixtures.date(2026, 11, 3, 9, 45), title: "Tuesday, earlier", message: "M")
        try await scheduler.schedule([moved])
        let replaced = try await scheduler.pendingReminders()
        XCTAssertEqual(replaced, [monday, sameTime, moved], "Scheduling an id again replaces it")

        let unknown = occurrenceID(UUID(), 2026, 11, 4)
        try await scheduler.cancelReminders(withIDs: [mondayID, unknown])
        let afterCancel = try await scheduler.pendingReminders()
        XCTAssertEqual(afterCancel, [sameTime, moved])

        try await scheduler.cancelReminders(withIDs: [unknown])
        let unchanged = try await scheduler.pendingReminders()
        XCTAssertEqual(unchanged, [sameTime, moved], "Unknown ids are ignored")
    }

    func testPreviewSchedulerFailureSimulationThrowsAndChangesNothing() async throws {
        let scheduler = PreviewReminderScheduler()
        let kept = ScheduledReminder(id: occurrenceID(SampleActivities.morningClassID, 2026, 11, 2), fireDate: TestFixtures.date(2026, 11, 2, 7, 15), title: "Kept", message: "M")
        let added = ScheduledReminder(id: occurrenceID(SampleActivities.afternoonLabID, 2026, 11, 3), fireDate: TestFixtures.date(2026, 11, 3, 10, 15), title: "Added", message: "M")
        try await scheduler.schedule([kept])

        scheduler.setSimulatesFailure(true)
        XCTAssertTrue(scheduler.simulatesFailure)
        for attempt in 1...2 {
            await assertSimulatedFailure("Reading, attempt \(attempt)") { _ = try await scheduler.pendingReminders() }
            await assertSimulatedFailure("Scheduling, attempt \(attempt)") { try await scheduler.schedule([added]) }
            await assertSimulatedFailure("Cancelling, attempt \(attempt)") { try await scheduler.cancelReminders(withIDs: [kept.id]) }
        }

        scheduler.setSimulatesFailure(false)
        XCTAssertFalse(scheduler.simulatesFailure)
        let untouched = try await scheduler.pendingReminders()
        XCTAssertEqual(untouched, [kept], "Nothing changed while failing")
        try await scheduler.schedule([added])
        try await scheduler.cancelReminders(withIDs: [kept.id])
        let recovered = try await scheduler.pendingReminders()
        XCTAssertEqual(recovered, [added])

        let failingFromStart = PreviewReminderScheduler(simulatesFailure: true)
        XCTAssertTrue(failingFromStart.simulatesFailure)
        await assertSimulatedFailure("Reading from an adapter created failing") { _ = try await failingFromStart.pendingReminders() }
        failingFromStart.setSimulatesFailure(false)
        let nothing = try await failingFromStart.pendingReminders()
        XCTAssertTrue(nothing.isEmpty)
    }

    func testReconcilingThePreviewSchedulerTwiceChangesNothingTheSecondTime() async throws {
        let scheduler = PreviewReminderScheduler()
        let plan = samplePlan(at: now)
        let initial = try await scheduler.pendingReminders()
        let changes = ReminderChanges.between(pending: initial, plan: plan, now: now)
        XCTAssertEqual(changes.toSchedule, plan.reminders)
        try await scheduler.cancelReminders(withIDs: changes.toCancel)
        try await scheduler.schedule(changes.toSchedule)
        let pending = try await scheduler.pendingReminders()
        XCTAssertEqual(pending, plan.reminders)
        XCTAssertTrue(ReminderChanges.between(pending: pending, plan: plan, now: now).isEmpty)

        let off = ReminderChanges.between(pending: pending, plan: ReminderPlan.none, now: now)
        try await scheduler.cancelReminders(withIDs: off.toCancel)
        let cleared = try await scheduler.pendingReminders()
        XCTAssertTrue(cleared.isEmpty)
    }

    // MARK: Text

    func testReminderTitleAndMessageNameTheTripAndTheSource() throws {
        let monday = try XCTUnwrap(sampleUpcoming(at: now).first)
        XCTAssertEqual(formatter.reminderTitle(for: monday), "Time to leave for Sample morning class")
        XCTAssertTrue(formatter.reminderTitle(for: monday).contains(monday.activity.title))

        let simulated = try calculation(for: monday)
        let message = formatter.reminderMessage(for: simulated, destinationName: TestFixtures.demoDestination.name)
        XCTAssertTrue(message.hasPrefix("Leave home at "), message)
        XCTAssertTrue(message.contains("7:15"), "Leave-home time: \(message)")
        XCTAssertTrue(message.contains("8:15"), "Ideal arrival: \(message)")
        XCTAssertTrue(message.contains(TestFixtures.demoDestination.name), message)
        XCTAssertTrue(message.contains("1 hour"), message)
        XCTAssertTrue(message.contains("simulated test estimate, not live traffic"), message)
        XCTAssertFalse(message.contains("9:00"), "The class start plays no part: \(message)")

        let live = try DepartureCalculation.make(
            idealArrival: monday.idealArrival,
            estimate: CommuteEstimate(travelTime: 45 * 60, sourceLabel: "Team commute service", estimatedAt: now, isSimulated: false)
        ).get()
        let liveMessage = formatter.reminderMessage(for: live, destinationName: "North campus")
        XCTAssertTrue(liveMessage.contains("7:30"), liveMessage)
        XCTAssertTrue(liveMessage.contains("45 minutes"), liveMessage)
        XCTAssertTrue(liveMessage.contains("Team commute service"), liveMessage)
        XCTAssertFalse(liveMessage.contains("simulated"), liveMessage)
    }

    func testReminderTimestampNamesTheDayAndTheTime() {
        let text = formatter.reminderTimestamp(TestFixtures.date(2026, 11, 2, 7, 15))
        for part in ["Mon", "Nov", "2", "7:15", "AM"] {
            XCTAssertTrue(text.contains(part), "\(part) in \(text)")
        }
    }

    func testReminderGapTextExplainsEveryGap() throws {
        let monday = try XCTUnwrap(sampleUpcoming(at: now).first)
        let expectations: [(ReminderGap, String)] = [
            (.waitingForEstimate, "Waiting"),
            (.estimateUnavailable(.noEstimate(message: "No route (test).")), "No route (test)."),
            (.estimateUnavailable(.noDestination), "no usable destination"),
            (.estimateUnavailable(.activityEnded), "no leave-home time"),
            (.estimateUnavailable(.beyondHorizon), "no leave-home time"),
            (.estimateUnavailable(.unsavedChanges), "no leave-home time"),
            (.estimateFailed(.providerFailed), "Try Again"),
            (.estimateFailed(.invalidEstimate(.missingSourceLabel)), "Try Again"),
            (.leaveHomePassed(TestFixtures.date(2026, 11, 2, 7, 15)), "7:15")
        ]
        for (gap, expected) in expectations {
            let named = formatter.reminderGapText(gap, trip: monday)
            XCTAssertFalse(named.isEmpty, "\(gap)")
            XCTAssertTrue(named.contains(monday.activity.title), "Names the trip: \(named)")
            XCTAssertTrue(named.contains("9:00"), "Names the trip's start: \(named)")
            XCTAssertTrue(named.contains(expected), named)

            let unnamed = formatter.reminderGapText(gap, trip: nil)
            XCTAssertFalse(unnamed.isEmpty, "\(gap)")
            XCTAssertTrue(unnamed.contains("the next trip"), unnamed)
            XCTAssertTrue(unnamed.contains(expected), unnamed)
        }

        let nothingSaved = formatter.reminderGapText(.noUpcomingTrips, trip: nil)
        XCTAssertTrue(nothingSaved.contains("next 7 days"), nothingSaved)
        XCTAssertFalse(formatter.reminderGapText(.noUpcomingTrips, trip: monday).isEmpty)
    }
}
