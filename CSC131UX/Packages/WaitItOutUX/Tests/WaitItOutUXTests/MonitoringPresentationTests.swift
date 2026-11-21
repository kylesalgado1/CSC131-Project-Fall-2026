import XCTest
@testable import WaitItOutUX

/// Stage S3: what the monitoring status view, the detail sheet, and the Map card show about
/// server-side trip monitoring. Every state has one honest status sentence; the actions appear
/// only where they can help; the server's plan is listed only when alerts can reach the
/// device; and nothing promises delivery.
///
/// Fixture clock: Mon 2026-10-26 06:00 PDT. The trip's ideal arrival is 8:15 AM and the server
/// plans to leave at 7:05 AM.
final class MonitoringPresentationTests: XCTestCase {
    private let now = TestFixtures.date(2026, 10, 26, 6)
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
    private let appName = "WAIT IT OUT UX"
    private let ready = PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil)
    private let healthy = MonitorHealth(enabled: true, dependable: true, lastTickAt: nil)
    private let confirmed = "The server confirmed 2 trips at 6:00 AM."

    private var active: MonitoringStatus {
        .active(acknowledgedAt: now, tripCount: 2)
    }

    /// A clock time on the fixture day as the formatter writes it, so no test depends on the
    /// space the system puts before "AM".
    private func time(_ hour: Int, _ minute: Int = 0) -> String {
        formatter.clockTime(TestFixtures.date(2026, 10, 26, hour, minute))
    }

    private var plan: MonitoredPlan {
        TestBackend.plan(departure: TestFixtures.date(2026, 10, 26, 7, 5), arrival: TestFixtures.date(2026, 10, 26, 7, 50), evaluatedAt: now)
    }

    /// The presentation for a state, with the obstacle resolved as the model resolves it.
    private func present(
        isAvailable: Bool = true,
        remindersEnabled: Bool = true,
        status: MonitoringStatus,
        push: PushDeliveryStatus? = nil,
        monitor: MonitorHealth? = nil,
        permission: NotificationPermission = .authorized,
        withdrawal: MonitoringWithdrawal = .none,
        statusLine: String? = nil,
        tripHeading: String? = nil,
        tripLines: [String] = [],
        inactiveTripSentence: String? = nil,
        coverageLine: String? = nil,
        pushFailure: String? = nil,
        registrationFailure: String? = nil,
        isCompact: Bool = false
    ) -> MonitoringPresentation {
        MonitoringPresentation.make(
            isAvailable: isAvailable,
            remindersEnabled: remindersEnabled,
            status: status,
            obstacle: MonitoringObstacle.resolve(status: status, push: push ?? ready, monitor: monitor ?? healthy, permission: permission),
            permission: permission,
            withdrawal: withdrawal,
            appName: appName,
            statusLine: statusLine,
            tripHeading: tripHeading,
            tripLines: tripLines,
            inactiveTripSentence: inactiveTripSentence,
            coverageLine: coverageLine,
            pushFailure: pushFailure,
            registrationFailure: registrationFailure,
            isCompact: isCompact
        )
    }

    private func trip(
        phase: TripPhase,
        plan: MonitoredPlan? = nil,
        startedAt: Date? = nil,
        headsUpSentAt: Date? = nil,
        leaveAlertSentAt: Date? = nil,
        lastErrorCode: String? = nil,
        noPlanReason: String? = nil
    ) -> MonitoredTripState {
        MonitoredTripState(
            id: OccurrenceID(activityID: UUID(), date: LocalDate.of(now, in: TestFixtures.pacific)),
            arriveBy: TestFixtures.date(2026, 10, 26, 8, 15),
            phase: phase,
            plan: plan,
            noPlanReason: noPlanReason,
            planAvailableAt: nil,
            monitoringStartsAt: nil,
            monitoringStartedAt: startedAt,
            headsUpAt: nil,
            headsUpSentAt: headsUpSentAt,
            leaveAlertSentAt: leaveAlertSentAt,
            lastAlert: nil,
            endsAt: TestFixtures.date(2026, 10, 26, 8, 15),
            nextCheckAt: nil,
            lastErrorCode: lastErrorCode,
            lastErrorAt: lastErrorCode == nil ? nil : now
        )
    }

    private func monitored(obstacle: MonitoringObstacle? = nil, departed: DepartedState? = nil) -> MonitoringSummary {
        MonitoringSummary(
            trip: trip(phase: .monitoring, plan: plan, startedAt: TestFixtures.date(2026, 10, 26, 5, 5), headsUpSentAt: TestFixtures.date(2026, 10, 26, 5, 35)),
            departed: departed,
            obstacle: obstacle
        )
    }

    /// The trip after the server confirmed that the user left.
    private func left(departed: DepartedState? = .done) -> MonitoringSummary {
        MonitoringSummary(trip: trip(phase: .departed), departed: departed, obstacle: nil)
    }

    // MARK: The status view

    func testWithoutAMonitoringServiceNoAlertIsClaimed() {
        let shown = present(isAvailable: false, status: active)
        XCTAssertEqual(shown, MonitoringPresentation(kind: .off, status: "This build has no trip-monitoring service, so no leave-home alerts are sent while live data is in use."))
        XCTAssertFalse(shown.offersRetry || shown.offersAllowNotifications || shown.offersOpenSettings)
    }

    func testOffInvitesInSettingsAndStaysShortOnTheMap() {
        let full = present(remindersEnabled: false, status: .off, permission: .notDetermined)
        XCTAssertEqual(full.kind, .off)
        XCTAssertEqual(full.status, "Leave-home alerts are off. Turn them on to have the server watch your upcoming trips and try to alert you when it is time to leave.")
        XCTAssertEqual(full.details, [])
        XCTAssertFalse(full.offersRetry || full.offersAllowNotifications || full.offersOpenSettings, "Nothing is asked for while alerts are off")

        let compact = present(remindersEnabled: false, status: .off, isCompact: true)
        XCTAssertEqual(compact.status, "Leave-home alerts are off.")
    }

    func testTurningOffSaysWhenTheServerCouldNotBeTold() {
        let telling = present(remindersEnabled: false, status: .off, withdrawal: .pending)
        XCTAssertEqual(telling.details, ["Telling the server to stop monitoring\u{2026}"])
        XCTAssertFalse(telling.offersRetry)

        let failed = present(remindersEnabled: false, status: .off, withdrawal: .failed(.offline), isCompact: true)
        XCTAssertEqual(failed.kind, .off)
        XCTAssertEqual(failed.details, ["The server could not be told to stop (the backend could not be reached), so it may still send alerts for a while. This is tried again automatically."])
        XCTAssertTrue(failed.offersRetry)
        XCTAssertFalse(failed.offersAllowNotifications || failed.offersOpenSettings)
    }

    func testWaitingShowsNoActionsEvenBeforeThePermissionIsKnown() {
        for status in [MonitoringStatus.pending, .off] {
            let shown = present(status: status, permission: .notDetermined)
            XCTAssertEqual(shown, MonitoringPresentation(kind: .waiting, status: "Waiting for the server to confirm monitoring."), "\(status)")
        }
    }

    func testPausedLeavesTheServerAlone() {
        let shown = present(status: .paused, permission: .denied)
        XCTAssertEqual(shown, MonitoringPresentation(kind: .paused, status: "Saved activities could not be read, so trip monitoring is paused. Nothing was changed on the server."))
    }

    func testAFailureOffersTryAgain() {
        let status = MonitoringStatus.failed(.offline, lastAcknowledgedAt: TestFixtures.date(2026, 10, 26, 5, 58))
        let line = formatter.monitoringStatusText(for: status, at: now)
        XCTAssertEqual(line, "Trips could not be synchronized: the backend could not be reached. The server last confirmed your trips at \(time(5, 58)).")

        let full = present(status: status, statusLine: line, tripHeading: "Next monitored trip", tripLines: ["Monitoring started 5:05 AM."])
        XCTAssertEqual(full.kind, .problem)
        XCTAssertEqual(full.status, line)
        XCTAssertEqual(full.details, [], "An unconfirmed plan is not listed")
        XCTAssertTrue(full.offersRetry)
        XCTAssertFalse(full.offersAllowNotifications || full.offersOpenSettings)

        let compact = present(status: status, statusLine: line, isCompact: true)
        XCTAssertEqual(compact.status, "Trips could not be synchronized: the backend could not be reached.")
        XCTAssertTrue(compact.offersRetry)

        let refused = present(status: .failed(.unavailableOnServer, lastAcknowledgedAt: nil))
        XCTAssertEqual(refused.status, "This server does not support trip monitoring yet.")
        XCTAssertTrue(refused.offersRetry)
    }

    func testAFailureStillOffersThePermissionActions() {
        let status = MonitoringStatus.failed(.timedOut, lastAcknowledgedAt: nil)
        let unasked = present(status: status, permission: .notDetermined)
        XCTAssertEqual(unasked.details, ["Notifications have not been allowed for this app yet."])
        XCTAssertTrue(unasked.offersRetry)
        XCTAssertTrue(unasked.offersAllowNotifications)
        XCTAssertFalse(unasked.offersOpenSettings)

        let denied = present(status: status, permission: .denied)
        XCTAssertEqual(denied.details, ["Notifications are off for WAIT IT OUT UX. Turn them on in iOS Settings to get alerts."])
        XCTAssertTrue(denied.offersOpenSettings)
        XCTAssertFalse(denied.offersAllowNotifications)
    }

    func testActiveSaysTheServerWillTryAndListsItsPlan() {
        let lines = ["Monitoring started 5:05 AM.", "Time-to-leave alert at the recommended departure, currently 7:05 AM."]
        let full = present(
            status: active,
            statusLine: confirmed,
            tripHeading: "Next monitored trip: Lecture, arrive by 8:15 AM.",
            tripLines: lines,
            pushFailure: "BadDeviceToken"
        )
        XCTAssertEqual(full.kind, .active)
        XCTAssertEqual(full.status, "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed.")
        XCTAssertEqual(full.details, [confirmed, "Next monitored trip: Lecture, arrive by 8:15 AM."] + lines + ["The server's last attempt to reach this device failed (BadDeviceToken)."])
        XCTAssertFalse(full.offersRetry || full.offersAllowNotifications || full.offersOpenSettings)

        let compact = present(status: active, statusLine: confirmed, tripLines: lines, pushFailure: "BadDeviceToken", isCompact: true)
        XCTAssertEqual(compact.status, full.status)
        XCTAssertEqual(compact.details, lines, "The Map card lists only its own trip's plan")
    }

    func testAProblemWithTheListedTripReplacesTheSentenceThatAlertsAreActive() {
        let problem = "The server has no traffic data for this route, so it cannot plan or alert for this trip."
        let full = present(
            status: active,
            statusLine: confirmed,
            tripHeading: "Next monitored trip: Lecture, arrive by 8:15 AM.",
            tripLines: [problem],
            inactiveTripSentence: MonitoringText.nextTripAlertsNotActive
        )
        XCTAssertEqual(full.kind, .problem, "Not the bell of active alerts")
        XCTAssertEqual(full.status, "The server confirmed your trips, but alerts are not active for the next one right now.")
        XCTAssertFalse(full.status.contains("will try to alert"), full.status)
        XCTAssertEqual(full.details, [confirmed, "Next monitored trip: Lecture, arrive by 8:15 AM.", problem])
        XCTAssertFalse(full.offersRetry, "Synchronizing again does not help: the server has the trip")

        let compact = present(status: active, tripLines: [problem], inactiveTripSentence: MonitoringText.tripAlertsNotActive, isCompact: true)
        XCTAssertEqual(compact.kind, .problem)
        XCTAssertEqual(compact.status, "Alerts are not active for this trip right now.")
        XCTAssertEqual(compact.details, [problem])

        // An obstacle of the delivery path is the more actionable news and stays in front.
        let denied = present(status: active, permission: .denied, tripLines: [], inactiveTripSentence: MonitoringText.tripAlertsNotActive)
        XCTAssertEqual(denied.kind, .needsPermission)
        XCTAssertEqual(denied.status, "Notifications are off for WAIT IT OUT UX. Turn them on in iOS Settings to get alerts.")
        // Nothing to monitor stays "nothing to monitor".
        let empty = present(status: .active(acknowledgedAt: now, tripCount: 0), inactiveTripSentence: MonitoringText.tripAlertsNotActive)
        XCTAssertEqual(empty.kind, .idle)
    }

    func testTheCoverageLineSaysHowFarAheadAlertsAreSetUp() {
        let coverage = formatter.monitoringCoverageText(through: TestFixtures.date(2026, 11, 2, 8, 15))
        let full = present(status: active, statusLine: confirmed, tripLines: ["Monitoring started 5:05 AM."], coverageLine: coverage)
        XCTAssertEqual(full.details, [
            confirmed,
            "Alerts are set up for trips through Monday, November 2. Open the app again before then to keep them coming.",
            "Monitoring started 5:05 AM."
        ])
        let compact = present(status: active, statusLine: confirmed, tripLines: ["Monitoring started 5:05 AM."], coverageLine: coverage, isCompact: true)
        XCTAssertEqual(compact.details, ["Monitoring started 5:05 AM."], "The Map card stays short; Settings carries the line")
        let empty = present(status: .active(acknowledgedAt: now, tripCount: 0), coverageLine: coverage)
        XCTAssertEqual(empty.details, [], "Nothing is set up when nothing is monitored")
        let failed = present(status: .failed(.offline, lastAcknowledgedAt: now), coverageLine: coverage)
        XCTAssertFalse(failed.details.contains(coverage), "Not claimed for a set the server did not confirm")
    }

    func testAFailedRegistrationOnThisDeviceIsNotCalledAServerAttempt() {
        let unregistered = PushDeliveryStatus(
            serverConfigured: true,
            deviceRegistered: false,
            authorized: true,
            lastFailure: nil,
            registrationFailure: "no valid aps-environment entitlement string found for application"
        )
        let shown = present(status: active, push: unregistered, statusLine: confirmed, registrationFailure: unregistered.registrationFailure)
        XCTAssertEqual(shown.kind, .problem)
        XCTAssertEqual(shown.status, "This device is not registered for push notifications yet.")
        XCTAssertEqual(shown.details, [
            confirmed,
            "This device could not register for push notifications (no valid aps-environment entitlement string found for application)."
        ])
        for detail in shown.details {
            XCTAssertFalse(detail.contains("The server's last attempt"), "The server has no token and attempted nothing: \(detail)")
        }

        // The server's own note keeps its own sentence, and the two can stand side by side.
        let both = present(status: active, statusLine: confirmed, pushFailure: "BadDeviceToken", registrationFailure: "The operation could not be completed.")
        XCTAssertEqual(both.details, [
            confirmed,
            "The server's last attempt to reach this device failed (BadDeviceToken).",
            "This device could not register for push notifications (The operation could not be completed)."
        ])
        let compact = present(status: active, registrationFailure: "x", isCompact: true)
        XCTAssertEqual(compact.details, [])
    }

    func testUnreadableSettingsAreSaidWhateverTheToggleShows() {
        let sentence = "Saved settings could not be read, so nothing was changed on the server. If leave-home alerts were on, the server may still send them."
        for remindersEnabled in [false, true] {
            for isCompact in [false, true] {
                let shown = present(remindersEnabled: remindersEnabled, status: .settingsUnreadable, permission: .notDetermined, isCompact: isCompact)
                XCTAssertEqual(shown, MonitoringPresentation(kind: .paused, status: sentence), "The toggle shows a default, so \"alerts are off\" would not be known to be true")
            }
        }
        let unavailable = present(isAvailable: false, status: .settingsUnreadable)
        XCTAssertEqual(unavailable.status, MonitoringText.notAvailable)
    }

    func testAnAcknowledgedEmptySetSaysThereIsNothingToMonitor() {
        let status = MonitoringStatus.active(acknowledgedAt: now, tripCount: 0)
        let shown = present(status: status, statusLine: formatter.monitoringStatusText(for: status, at: now))
        XCTAssertEqual(shown.kind, .idle)
        XCTAssertEqual(shown.status, MonitoringText.nothingToMonitor)
        XCTAssertEqual(shown.details, [], "The same sentence is not repeated as a detail")
    }

    func testAMissingPermissionOffersExactlyTheActionThatHelps() {
        let unasked = present(status: active, permission: .notDetermined, statusLine: confirmed)
        XCTAssertEqual(unasked.kind, .needsPermission)
        XCTAssertEqual(unasked.status, "Notifications have not been allowed for this app yet.")
        XCTAssertEqual(unasked.details, [confirmed])
        XCTAssertTrue(unasked.offersAllowNotifications)
        XCTAssertFalse(unasked.offersOpenSettings || unasked.offersRetry)

        let denied = present(status: active, permission: .denied, statusLine: confirmed)
        XCTAssertEqual(denied.kind, .needsPermission)
        XCTAssertEqual(denied.status, "Notifications are off for WAIT IT OUT UX. Turn them on in iOS Settings to get alerts.")
        XCTAssertTrue(denied.offersOpenSettings)
        XCTAssertFalse(denied.offersAllowNotifications || denied.offersRetry)
    }

    func testEveryServerSideObstacleIsNamedWithoutAnAction() {
        let cases: [(PushDeliveryStatus?, MonitorHealth?, String)] = [
            (PushDeliveryStatus(serverConfigured: false, deviceRegistered: true, authorized: true, lastFailure: nil), nil, "The server has no push credentials, so alerts cannot be delivered."),
            (PushDeliveryStatus(serverConfigured: true, deviceRegistered: false, authorized: true, lastFailure: nil), nil, "This device is not registered for push notifications yet."),
            (PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: false, lastFailure: nil), nil, "The server has not been told yet that notifications are allowed on this device."),
            (nil, MonitorHealth(enabled: false, dependable: false, lastTickAt: nil), "This server is not running trip monitoring."),
            (nil, MonitorHealth(enabled: true, dependable: false, lastTickAt: nil), "This server only checks traffic while it is awake, so alerts can be late or missing when the app is closed.")
        ]
        for (push, monitor, sentence) in cases {
            let shown = present(status: active, push: push, monitor: monitor)
            XCTAssertEqual(shown.kind, .problem, sentence)
            XCTAssertEqual(shown.status, sentence)
            XCTAssertFalse(shown.offersRetry || shown.offersAllowNotifications || shown.offersOpenSettings, sentence)
        }
    }

    func testNoSentencePromisesDelivery() {
        var sentences: [String] = [
            MonitoringText.notAvailable, MonitoringText.offInvitation, MonitoringText.departedFooter, MonitoringText.departedButtonHint,
            MonitoringText.tripAlertsNotActive, MonitoringText.nextTripAlertsNotActive, MonitoringText.noDepartureYet,
            MonitoringText.evaluationFailureSentence(code: "no_coverage"), MonitoringText.evaluationFailureSentence(code: "budget_exhausted"),
            MonitoringText.evaluationFailureSentence(code: "routing_unavailable"), MonitoringText.registrationFailureSentence("no token"),
            MonitoringText.coverageSentence(limits: .fallback), formatter.monitoringCoverageText(through: now)
        ]
        let statuses: [MonitoringStatus] = [.off, .paused, .settingsUnreadable, .pending, active, .failed(.offline, lastAcknowledgedAt: now)]
        for status in statuses {
            for permission in [NotificationPermission.authorized, .notDetermined, .denied] {
                let shown = present(status: status, permission: permission, statusLine: formatter.monitoringStatusText(for: status, at: now), pushFailure: "Unregistered")
                sentences.append(shown.status)
                sentences.append(contentsOf: shown.details)
            }
        }
        sentences.append(contentsOf: formatter.tripMonitoringSentences(for: monitored(), at: now))
        for sentence in sentences {
            let lowered = sentence.lowercased()
            XCTAssertFalse(lowered.contains("delivered") && !lowered.contains("cannot be delivered"), sentence)
            XCTAssertFalse(lowered.contains("will alert"), sentence)
            XCTAssertFalse(lowered.contains("will be alerted"), sentence)
            XCTAssertFalse(lowered.contains("on time"), sentence)
        }
    }

    // MARK: One trip's plan

    func testThePlanIsListedOnlyWhenAlertsCanReachTheDevice() {
        let lines = ["Monitoring started \(time(5, 5)).", "Heads-up sent \(time(5, 35)).", "Time-to-leave alert at the recommended departure, currently \(time(7, 5))."]
        XCTAssertEqual(formatter.monitoringPlanLines(for: monitored(), at: now), lines)
        XCTAssertEqual(formatter.monitoringPlanLines(for: monitored(obstacle: .monitorNotDependable), at: now), lines, "Late or missing is a caveat, not a blocker")
        let blockers: [MonitoringObstacle] = [.pending, .failed(.offline), .permissionNotDetermined, .permissionDenied, .serverCannotPush, .deviceNotRegistered, .permissionNotReported, .monitorNotRunning]
        for obstacle in blockers {
            XCTAssertEqual(formatter.monitoringPlanLines(for: monitored(obstacle: obstacle), at: now), [], "\(obstacle)")
            XCTAssertFalse(monitored(obstacle: obstacle).listsServerPlan)
        }
        XCTAssertEqual(formatter.monitoringPlanLines(for: left(), at: now), [], "The I've-left sentence says it")
        XCTAssertEqual(
            formatter.monitoringPlanLines(for: monitored(departed: .done), at: now),
            lines,
            "A trip the server monitors again after a reschedule is listed again, whatever was recorded for the earlier time"
        )

        let ended = MonitoringSummary(trip: trip(phase: .ended), departed: nil, obstacle: .permissionDenied)
        XCTAssertEqual(formatter.monitoringPlanLines(for: ended, at: now), ["Monitoring ended: the arrival time has passed."])
        let left = MonitoringSummary(trip: trip(phase: .departed), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringPlanLines(for: left, at: now), [])
    }

    func testTheDetailSheetLeadsWithTheDeliverySentence() {
        XCTAssertEqual(formatter.tripMonitoringSentences(for: monitored(), at: now), [
            "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed.",
            "Monitoring started \(time(5, 5)).",
            "Heads-up sent \(time(5, 35)).",
            "Time-to-leave alert at the recommended departure, currently \(time(7, 5))."
        ])
        XCTAssertEqual(
            formatter.tripMonitoringSentences(for: monitored(obstacle: .permissionDenied), at: now),
            ["Notifications are off for this app in iOS Settings."],
            "With an obstacle only the obstacle is named"
        )
        XCTAssertEqual(formatter.tripMonitoringSentences(for: left(), at: now), [])
        let ended = MonitoringSummary(trip: trip(phase: .ended), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.tripMonitoringSentences(for: ended, at: now), ["Monitoring ended: the arrival time has passed."])
    }

    func testTheHeadingNamesTheTripAndItsArrival() {
        XCTAssertEqual(
            formatter.monitoredTripHeading(title: "Lecture", arriveBy: TestFixtures.date(2026, 10, 26, 8, 15), at: now),
            "Next monitored trip: Lecture, arrive by \(time(8, 15))."
        )
        let tomorrow = TestFixtures.date(2026, 10, 27, 8, 15)
        XCTAssertEqual(
            formatter.monitoredTripHeading(title: "Lab", arriveBy: tomorrow, at: now),
            "Next monitored trip: Lab, arrive by \(formatter.reminderTimestamp(tomorrow))."
        )
    }

    // MARK: "I've left"

    func testIveLeftIsRetriedOnlyWhenTheServerCouldNotBeTold() {
        XCTAssertEqual(MonitoringText.departedButtonTitle, "I've Left")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: nil), "I've Left")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .sending), "I've Left")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .done), "I've Left")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .failed(.superseded)), "I've Left", "A rescheduled trip was answered for good")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .failed(.notMonitored)), "I've Left")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .failed(.offline)), "Try Again")
        XCTAssertEqual(MonitoringText.departedButtonTitle(after: .failed(.server(status: 503))), "Try Again")

        XCTAssertTrue(monitored().canMarkDeparted)
        XCTAssertFalse(monitored(departed: .sending).canMarkDeparted)
        XCTAssertTrue(monitored(departed: .failed(.offline)).canMarkDeparted)
        XCTAssertEqual(monitored(departed: .failed(.offline)).departedSentence, "Could not tell the server you left; it may still send alerts for this trip.")
        XCTAssertFalse(left().canMarkDeparted)
        XCTAssertTrue(left().isDeparted)
        XCTAssertEqual(left().departedSentence, "Marked as left. Monitoring ended for this trip.")
        XCTAssertEqual(left(departed: nil).departedSentence, "Marked as left. Monitoring ended for this trip.", "Also when the user left in an earlier session")
    }

    func testARecordedDepartureCountsOnlyWhileTheServerSaysTheUserLeft() {
        // The user tapped I've Left, then moved the activity: the server restarted the trip and
        // monitors it again for the new time.
        let rescheduled = monitored(departed: .done)
        XCTAssertNil(rescheduled.departed, "The earlier success says nothing about the new arrival time")
        XCTAssertFalse(rescheduled.isDeparted)
        XCTAssertNil(rescheduled.departedSentence, "Nothing claims that monitoring ended")
        XCTAssertTrue(rescheduled.canMarkDeparted, "I've Left is offered again for the new time")
        XCTAssertTrue(rescheduled.alertsAreActive)

        // Every other outcome is kept as it was recorded.
        XCTAssertEqual(monitored(departed: .sending).departed, .sending)
        XCTAssertEqual(monitored(departed: .failed(.superseded)).departed, .failed(.superseded))
        XCTAssertEqual(monitored(departed: .failed(.superseded)).departedSentence, "This trip was rescheduled; monitoring continues for the new time.")
    }

    // MARK: Presenting a trip from a notification

    func testATripIsPresentedOnlyWhenNothingStandsInTheWay() throws {
        let activity = TestFixtures.activity(start: TestFixtures.date(2026, 10, 26, 9))
        let occurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: [activity], in: TestFixtures.date(2026, 10, 26)..<TestFixtures.date(2026, 10, 27)).first)
        let find: (OccurrenceID) -> ActivityOccurrence? = { $0 == occurrence.id ? occurrence : nil }

        XCTAssertEqual(TripPresentationStep.resolve(requested: nil, isScheduleLoaded: true, isEditorOpen: false, occurrence: find), .idle)
        XCTAssertEqual(TripPresentationStep.resolve(requested: occurrence.id, isScheduleLoaded: true, isEditorOpen: false, occurrence: find), .present(occurrence))
        XCTAssertEqual(TripPresentationStep.resolve(requested: occurrence.id, isScheduleLoaded: true, isEditorOpen: true, occurrence: find), .wait, "The editor is never replaced")
        XCTAssertEqual(TripPresentationStep.resolve(requested: occurrence.id, isScheduleLoaded: false, isEditorOpen: false, occurrence: find), .wait, "An unloaded schedule is not an empty one")
        let gone = OccurrenceID(activityID: UUID(), date: occurrence.id.date)
        XCTAssertEqual(TripPresentationStep.resolve(requested: gone, isScheduleLoaded: true, isEditorOpen: false, occurrence: find), .discard)
        XCTAssertEqual(TripPresentationStep.resolve(requested: gone, isScheduleLoaded: true, isEditorOpen: true, occurrence: find), .wait)
    }
}
