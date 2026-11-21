import XCTest
@testable import WaitItOutUX

/// Stage S2: every sentence about trip monitoring. Alerts are described as active only when
/// nothing stands in the way; otherwise the exact obstacle is named. Nothing promises
/// delivery, and an alert is "sent" only with the server's own stamp.
final class MonitoringTextTests: XCTestCase {
    private let now = TestFixtures.date(2026, 10, 26, 6)
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
    private let ready = PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil)
    private let healthy = MonitorHealth(enabled: true, dependable: true, lastTickAt: nil)

    private var active: MonitoringStatus {
        .active(acknowledgedAt: now, tripCount: 2)
    }

    private func obstacle(
        status: MonitoringStatus? = nil,
        push: PushDeliveryStatus? = nil,
        monitor: MonitorHealth? = nil,
        permission: NotificationPermission = .authorized
    ) -> MonitoringObstacle? {
        MonitoringObstacle.resolve(status: status ?? active, push: push ?? ready, monitor: monitor ?? healthy, permission: permission)
    }

    private func trip(
        phase: TripPhase,
        plan: MonitoredPlan? = nil,
        planAvailableAt: Date? = nil,
        startsAt: Date? = nil,
        startedAt: Date? = nil,
        headsUpAt: Date? = nil,
        headsUpSentAt: Date? = nil,
        leaveAlertSentAt: Date? = nil,
        lastAlert: TripAlert? = nil,
        lastErrorCode: String? = nil,
        noPlanReason: String? = nil
    ) -> MonitoredTripState {
        MonitoredTripState(
            id: OccurrenceID(activityID: UUID(), date: LocalDate.of(now, in: TestFixtures.pacific)),
            arriveBy: TestFixtures.date(2026, 10, 26, 8, 15),
            phase: phase,
            plan: plan,
            noPlanReason: noPlanReason,
            planAvailableAt: planAvailableAt,
            monitoringStartsAt: startsAt,
            monitoringStartedAt: startedAt,
            headsUpAt: headsUpAt,
            headsUpSentAt: headsUpSentAt,
            leaveAlertSentAt: leaveAlertSentAt,
            lastAlert: lastAlert,
            endsAt: TestFixtures.date(2026, 10, 26, 8, 15),
            nextCheckAt: nil,
            lastErrorCode: lastErrorCode,
            lastErrorAt: lastErrorCode == nil ? nil : now
        )
    }

    private var plan: MonitoredPlan {
        TestBackend.plan(departure: TestFixtures.date(2026, 10, 26, 7, 5), arrival: TestFixtures.date(2026, 10, 26, 7, 50), evaluatedAt: now)
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> String {
        formatter.clockTime(TestFixtures.date(2026, 10, 26, hour, minute))
    }

    // MARK: Obstacles

    func testAlertsAreActiveOnlyWhenNothingStandsInTheWay() {
        XCTAssertNil(obstacle())
        XCTAssertEqual(MonitoringText.deliverySentence(for: nil, tripCount: 2), "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed.")
        XCTAssertEqual(MonitoringText.deliverySentence(for: nil, tripCount: 0), "Nothing saved has an arrival in the next 7 days, so there is nothing to monitor yet.")
    }

    func testEveryObstacleHasItsOwnSentence() {
        let cases: [(MonitoringObstacle?, MonitoringObstacle, String)] = [
            (obstacle(status: .off), .off, "Leave-home alerts are off."),
            (obstacle(status: .paused), .paused, "Saved activities could not be read, so trip monitoring is paused. Nothing was changed on the server."),
            (obstacle(status: .settingsUnreadable), .settingsUnreadable, "Saved settings could not be read, so nothing was changed on the server. If leave-home alerts were on, the server may still send them."),
            (obstacle(status: .pending), .pending, "Waiting for the server to confirm monitoring."),
            (obstacle(status: .failed(.timedOut, lastAcknowledgedAt: now)), .failed(.timedOut), "Trips could not be synchronized: the backend did not answer in time."),
            (obstacle(permission: .denied), .permissionDenied, "Notifications are off for this app in iOS Settings."),
            (obstacle(permission: .notDetermined), .permissionNotDetermined, "Notifications have not been allowed for this app yet."),
            (obstacle(push: PushDeliveryStatus(serverConfigured: false, deviceRegistered: true, authorized: true, lastFailure: nil)), .serverCannotPush, "The server has no push credentials, so alerts cannot be delivered."),
            (obstacle(push: PushDeliveryStatus(serverConfigured: true, deviceRegistered: false, authorized: true, lastFailure: nil)), .deviceNotRegistered, "This device is not registered for push notifications yet."),
            (obstacle(push: PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: false, lastFailure: nil)), .permissionNotReported, "The server has not been told yet that notifications are allowed on this device."),
            (obstacle(monitor: MonitorHealth(enabled: false, dependable: true, lastTickAt: nil)), .monitorNotRunning, "This server is not running trip monitoring."),
            (obstacle(monitor: MonitorHealth(enabled: true, dependable: false, lastTickAt: now)), .monitorNotDependable, "This server only checks traffic while it is awake, so alerts can be late or missing when the app is closed.")
        ]
        for (resolved, expected, sentence) in cases {
            XCTAssertEqual(resolved, expected)
            XCTAssertEqual(expected.sentence, sentence)
            XCTAssertEqual(MonitoringText.deliverySentence(for: expected, tripCount: 2), sentence, "The obstacle replaces the claim that the server will alert")
            XCTAssertFalse(sentence.contains("will be delivered") || sentence.contains("was delivered"), "No obstacle sentence claims a delivery: \(sentence)")
        }
    }

    func testTheMostActionableObstacleComesFirst() {
        let nothingWorks = PushDeliveryStatus(serverConfigured: false, deviceRegistered: false, authorized: false, lastFailure: nil)
        let idle = MonitorHealth(enabled: false, dependable: false, lastTickAt: nil)
        XCTAssertEqual(obstacle(status: .pending, push: nothingWorks, monitor: idle, permission: .denied), .pending, "Nothing is known before the server acknowledged")
        XCTAssertEqual(obstacle(push: nothingWorks, monitor: idle, permission: .denied), .permissionDenied, "What the user can fix first")
        XCTAssertEqual(obstacle(push: nothingWorks, monitor: idle), .serverCannotPush)
        XCTAssertEqual(obstacle(push: PushDeliveryStatus(serverConfigured: true, deviceRegistered: false, authorized: false, lastFailure: nil), monitor: idle), .deviceNotRegistered)
        XCTAssertEqual(obstacle(monitor: idle), .monitorNotRunning)
        XCTAssertEqual(
            MonitoringObstacle.resolve(status: active, push: nil, monitor: nil, permission: .authorized),
            .pending,
            "Without the server's word on push and its worker, nothing is confirmed"
        )
    }

    func testEveryFailureHasASentence() {
        let cases: [(TripMonitoringFailure, String)] = [
            (.notConfigured, "Trips could not be synchronized: no backend address is set."),
            (.offline, "Trips could not be synchronized: the backend could not be reached."),
            (.timedOut, "Trips could not be synchronized: the backend did not answer in time."),
            (.server(status: 503), "Trips could not be synchronized: the backend had a problem (HTTP 503)."),
            (.invalidResponse, "Trips could not be synchronized: the backend's answer could not be read."),
            (.unavailableOnServer, "This server does not support trip monitoring yet."),
            (.rejected(message: "Two trips in the list have the same id."), "The server did not accept these trips: Two trips in the list have the same id."),
            (.reregistered, "Trips could not be synchronized: the server no longer knew this device."),
            (.notRegistered, "Trips could not be synchronized: this device is not registered with the server."),
            (.superseded, "Trips could not be synchronized: the trip was rescheduled."),
            (.notMonitored, "Trips could not be synchronized: the server is not monitoring that trip."),
            (.credentialStorage, "Trips could not be synchronized: this device's server credential could not be read or saved.")
        ]
        for (failure, sentence) in cases {
            XCTAssertEqual(MonitoringText.failureSentence(failure), sentence)
            XCTAssertEqual(MonitoringObstacle.failed(failure).sentence, sentence)
        }
    }

    // MARK: "I've left", alerts, withdrawal

    func testIveLeftSentencesClaimSuccessOnlyWhenDone() {
        XCTAssertEqual(MonitoringText.departedSentence(.sending), "Telling the server\u{2026}")
        XCTAssertEqual(MonitoringText.departedSentence(.done), "Marked as left. Monitoring ended for this trip.")
        XCTAssertEqual(MonitoringText.departedSentence(.failed(.superseded)), "This trip was rescheduled; monitoring continues for the new time.")
        XCTAssertEqual(MonitoringText.departedSentence(.failed(.notMonitored)), "The server is not monitoring this trip, so there was nothing to end.")
        for failure in [TripMonitoringFailure.offline, .timedOut, .server(status: 500), .notRegistered, .invalidResponse] {
            XCTAssertEqual(MonitoringText.departedSentence(.failed(failure)), "Could not tell the server you left; it may still send alerts for this trip.")
        }
    }

    func testAnAlertThatWasNotSentSaysSo() {
        XCTAssertNil(MonitoringText.alertSentence(nil))
        XCTAssertNil(MonitoringText.alertSentence(TripAlert(kind: .headsUp, status: .sent, at: now, reason: nil)), "A sent alert is shown through its own stamp")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .headsUp, status: .queued, at: now, reason: nil)), "Heads-up queued; not sent yet.")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .update, status: .queued, at: now, reason: nil)), "Update queued; not sent yet.")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .leaveNow, status: .queued, at: now, reason: nil)), "Time-to-leave alert queued; not sent yet.")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .late, status: .queued, at: now, reason: nil)), "Late alert queued; not sent yet.")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .headsUp, status: .dropped, at: now, reason: nil)), "The last alert could not be sent.")
        XCTAssertEqual(MonitoringText.alertSentence(TripAlert(kind: .leaveNow, status: .failed, at: now, reason: "BadDeviceToken")), "The last alert could not be sent: BadDeviceToken")
    }

    func testWithdrawalAndFooterSentences() {
        XCTAssertNil(MonitoringText.withdrawalSentence(.none))
        XCTAssertEqual(MonitoringText.withdrawalSentence(.pending), "Telling the server to stop monitoring\u{2026}")
        XCTAssertEqual(
            MonitoringText.withdrawalSentence(.failed(.server(status: 502))),
            "The server could not be told to stop (the backend had a problem (HTTP 502)), so it may still send alerts for a while. This is tried again automatically."
        )
        // "Automatically" is said only of a failure the minute ticks do retry.
        for failure in [TripMonitoringFailure.offline, .timedOut, .server(status: 503)] {
            XCTAssertTrue(MonitoringText.withdrawalSentence(.failed(failure))?.hasSuffix("This is tried again automatically.") ?? false, "\(failure)")
        }
        XCTAssertEqual(
            MonitoringText.withdrawalSentence(.failed(.unavailableOnServer)),
            "The server could not be told to stop (this server does not support trip monitoring yet), so it may still send alerts for a while. It is tried again when you tap Try Again or open the app again."
        )
        for failure in [TripMonitoringFailure.invalidResponse, .credentialStorage, .server(status: 404), .rejected(message: "No.")] {
            let sentence = MonitoringText.withdrawalSentence(.failed(failure)) ?? ""
            XCTAssertFalse(sentence.contains("automatically"), "\(failure) is not retried on the ticks: \(sentence)")
            XCTAssertTrue(sentence.hasSuffix("It is tried again when you tap Try Again or open the app again."), sentence)
        }
        XCTAssertEqual(MonitoringText.previousServerWarning, "The previous server may still send alerts for a while.")
        XCTAssertEqual(
            MonitoringText.remindersFooter(limits: .fallback),
            "The team backend watches traffic for your upcoming trips, starting about 2 hours before the recommended departure. It sends a heads-up about 90 minutes before, an update only when the departure moves by at least 5 minutes, and an alert when it is time to leave. Delivery is best effort and needs notification permission. The app sends your trips for the next 7 days (at most 20) to the server each time it is opened or brought to the foreground, so alerts stop for later trips unless you open the app again. Trips are removed from the server after they end; turning this off deletes this installation's data from the server."
        )
        XCTAssertEqual(
            MonitoringText.coverageSentence(limits: .fallback),
            "The app sends your trips for the next 7 days (at most 20) to the server each time it is opened or brought to the foreground, so alerts stop for later trips unless you open the app again."
        )
        let small = MonitoringLimits(planningHorizon: 690 * 60, monitorLead: 120 * 60, headsUpLead: 90 * 60, meaningfulShift: 5 * 60, maxTrips: 8)
        XCTAssertTrue(MonitoringText.coverageSentence(limits: small).contains("(at most 8)"), "A server that takes fewer trips is quoted with its own number")
        XCTAssertEqual(
            MonitoringText.dataSentFooter(remindersEnabled: false),
            "For a recommendation the app sends the home and campus coordinates and your ideal arrival to the team backend. There is no account, and your location is never read."
        )
        XCTAssertEqual(
            MonitoringText.dataSentFooter(remindersEnabled: true),
            "For a recommendation the app sends the home and campus coordinates and your ideal arrival to the team backend. With leave-home alerts on it also sends, for each upcoming trip, an id the app makes up, the title, the home and destination coordinates, the ideal arrival, and the time zone, together with an anonymous installation id and this device's push token. There is no account, and your location is never read."
        )
        XCTAssertEqual(MonitoringText.duration(7_200), "2 hours")
        XCTAssertEqual(MonitoringText.duration(3_600), "1 hour")
        XCTAssertEqual(MonitoringText.duration(5_400), "90 minutes")
        XCTAssertEqual(MonitoringText.duration(60), "1 minute")
        XCTAssertEqual(MonitoringText.duration(-5), "0 minutes")
    }

    // MARK: Summaries and their lines

    func testAPlannedTripSaysWhatTheServerIntends() {
        let departure = TestFixtures.date(2026, 10, 26, 7, 5)
        let summary = MonitoringSummary(
            trip: trip(phase: .planned, plan: plan, startsAt: TestFixtures.date(2026, 10, 26, 5, 5), headsUpAt: TestFixtures.date(2026, 10, 26, 6, 35)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(summary.recommendedDeparture, departure)
        XCTAssertTrue(summary.alertsAreActive)
        XCTAssertFalse(summary.canMarkDeparted)
        XCTAssertFalse(summary.isDeparted)
        XCTAssertEqual(summary.deliverySentence, MonitoringText.activeDelivery)
        XCTAssertFalse(summary.showsPlanTimes, "Before monitoring starts the screens ask the backend directly, so the server's own times are not printed beside that answer")
        let lines = formatter.monitoringLines(for: summary, at: now)
        XCTAssertEqual(lines, [
            "Monitoring starts about 2 hours before the recommended departure.",
            "Heads-up about 90 minutes before the recommended departure.",
            "Time-to-leave alert at the recommended departure."
        ])
        for line in lines {
            XCTAssertFalse(line.contains("AM") || line.contains("currently"), "No clock time that could differ from the leave-home row: \(line)")
        }

        // The leads are the server's own numbers.
        let limits = MonitoringLimits(planningHorizon: 690 * 60, monitorLead: 180 * 60, headsUpLead: 45 * 60, meaningfulShift: 5 * 60, maxTrips: 50)
        let other = MonitoringSummary(trip: trip(phase: .planned, plan: plan), departed: nil, obstacle: nil, limits: limits)
        XCTAssertEqual(formatter.monitoringLines(for: other, at: now), [
            "Monitoring starts about 3 hours before the recommended departure.",
            "Heads-up about 45 minutes before the recommended departure.",
            "Time-to-leave alert at the recommended departure."
        ])
    }

    // MARK: What the server reports as a problem with one trip

    func testAFailedTrafficCheckIsNamedByItsCodeInsteadOfWorkingOut() {
        let sentences: [(String, String)] = [
            ("no_coverage", "The server has no traffic data for this route, so it cannot plan or alert for this trip."),
            ("budget_exhausted", "The server has used up its traffic checks for today, so this trip is not being re-checked. A time-to-leave alert is still sent from the last plan, if there is one."),
            ("routing_unavailable", "The server could not check traffic for this trip just now. It keeps trying."),
            ("internal", "The server could not check traffic for this trip just now. It keeps trying."),
            ("a_code_from_a_newer_server", "The server could not check traffic for this trip just now. It keeps trying.")
        ]
        for (code, sentence) in sentences {
            XCTAssertEqual(MonitoringText.evaluationFailureSentence(code: code), sentence)

            let planning = MonitoringSummary(trip: trip(phase: .planning, lastErrorCode: code), departed: nil, obstacle: nil)
            XCTAssertEqual(formatter.monitoringLines(for: planning, at: now), [sentence], "\(code): never \"working out when you should leave\"")
            XCTAssertTrue(planning.hasServerProblem)
            XCTAssertFalse(planning.alertsAreActive, "\(code): alerts are not described as active for a trip the server cannot plan")
            XCTAssertEqual(planning.deliverySentence, "Alerts are not active for this trip right now.")
            XCTAssertEqual(formatter.tripMonitoringSentences(for: planning, at: now), ["Alerts are not active for this trip right now.", sentence])

            // With a plan from before the failure, the plan's lines stay and the failure follows.
            let monitored = MonitoringSummary(
                trip: trip(phase: .monitoring, plan: plan, startedAt: TestFixtures.date(2026, 10, 26, 5, 5), lastErrorCode: code),
                departed: nil,
                obstacle: nil
            )
            XCTAssertEqual(formatter.monitoringLines(for: monitored, at: now), [
                "Monitoring started \(time(5, 5)).",
                "Time-to-leave alert at the recommended departure, currently \(time(7, 5)).",
                sentence
            ])
            XCTAssertFalse(monitored.alertsAreActive)

            // The server keeps the phase "monitoring" for a trip it has no plan for.
            let unplanned = MonitoringSummary(trip: trip(phase: .monitoring, lastErrorCode: code), departed: nil, obstacle: nil)
            XCTAssertEqual(formatter.monitoringLines(for: unplanned, at: now), ["The server is monitoring this trip.", sentence])
        }

        // An obstacle of the delivery path is still named first; the problem never hides it.
        let blocked = MonitoringSummary(trip: trip(phase: .planning, lastErrorCode: "no_coverage"), departed: nil, obstacle: .permissionDenied)
        XCTAssertEqual(blocked.deliverySentence, MonitoringObstacle.permissionDenied.sentence)
        // A trip that is over has no problem worth naming.
        let ended = MonitoringSummary(trip: trip(phase: .ended, lastErrorCode: "no_coverage"), departed: nil, obstacle: nil)
        XCTAssertFalse(ended.hasServerProblem)
        // Without an error the planning line is unchanged.
        let planning = MonitoringSummary(trip: trip(phase: .planning), departed: nil, obstacle: nil)
        XCTAssertFalse(planning.hasServerProblem)
        XCTAssertTrue(planning.alertsAreActive)
        XCTAssertEqual(planning.deliverySentence, MonitoringText.activeDelivery)
    }

    func testTheServersNoPlanSentenceIsShownOnlyWhileItIsFresh() {
        let reason = "Your deadline is 5 hours away, so there is no need to leave yet."
        let readBefore = now.addingTimeInterval(-60)
        let fresh = MonitoringSummary(
            trip: trip(phase: .planning, noPlanReason: reason),
            departed: nil,
            obstacle: nil,
            noPlanReasonWrittenAfter: readBefore
        )
        XCTAssertTrue(fresh.hasServerProblem)
        XCTAssertFalse(fresh.alertsAreActive, "No departure to recommend means no alert is set up for it yet")
        XCTAssertEqual(formatter.monitoringLines(for: fresh, at: now), [reason], "Written at most a minute ago: the server's own words")
        XCTAssertEqual(formatter.monitoringLines(for: fresh, at: readBefore.addingTimeInterval(120)), [reason])
        XCTAssertEqual(
            formatter.monitoringLines(for: fresh, at: readBefore.addingTimeInterval(121)),
            ["The server has no departure to recommend for this trip yet."],
            "The sentence is relative to when it was written, so after two minutes only the plain fact remains"
        )

        let unknownAge = MonitoringSummary(trip: trip(phase: .planning, noPlanReason: reason), departed: nil, obstacle: nil)
        XCTAssertEqual(
            formatter.monitoringLines(for: unknownAge, at: now),
            ["The server has no departure to recommend for this trip yet."],
            "A sentence of unknown age is never repeated"
        )
        XCTAssertEqual(MonitoringText.noDepartureYet, "The server has no departure to recommend for this trip yet.")

        // A failed check is the more specific news.
        let failed = MonitoringSummary(
            trip: trip(phase: .planning, lastErrorCode: "budget_exhausted", noPlanReason: reason),
            departed: nil,
            obstacle: nil,
            noPlanReasonWrittenAfter: readBefore
        )
        XCTAssertEqual(formatter.monitoringLines(for: failed, at: now), [MonitoringText.evaluationFailureSentence(code: "budget_exhausted")])

        // With a plan there is a departure to recommend, whatever sentence is left over.
        let planned = MonitoringSummary(trip: trip(phase: .planned, plan: plan, noPlanReason: reason), departed: nil, obstacle: nil)
        XCTAssertFalse(planned.hasServerProblem)
    }

    // MARK: Alert lines never promise what will not come

    func testNoTimeToLeaveAlertIsPromisedAfterALateAlert() {
        let lateAt = TestFixtures.date(2026, 10, 26, 5, 45)
        let latePlan = TestBackend.plan(advice: .leaveNow, departure: lateAt, arrival: TestFixtures.date(2026, 10, 26, 8, 30), lateBy: 15 * 60, margin: nil, evaluatedAt: lateAt)
        let sent = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: latePlan, startedAt: lateAt, lastAlert: TripAlert(kind: .late, status: .sent, at: lateAt, reason: nil)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertTrue(sent.planIsLate)
        let lines = formatter.monitoringLines(for: sent, at: now)
        XCTAssertEqual(lines, ["Monitoring started \(time(5, 45)).", "Late alert sent \(time(5, 45))."])
        for line in lines {
            XCTAssertFalse(line.contains("Time-to-leave alert at"), "The server sends no time-to-leave alert after a late alert: \(line)")
            XCTAssertFalse(line.contains("currently"), line)
        }

        // The late alert is still on its way: it is not called sent, and nothing else is promised.
        let queued = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: latePlan, lastAlert: TripAlert(kind: .late, status: .queued, at: lateAt, reason: nil)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(formatter.monitoringLines(for: queued, at: now), ["The server is monitoring this trip.", "Late alert queued; not sent yet."])

        // The plan recovered but the last alert is still the late one: still no promise.
        let recovered = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: plan, lastAlert: TripAlert(kind: .late, status: .sent, at: lateAt, reason: nil)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(formatter.monitoringLines(for: recovered, at: now), ["The server is monitoring this trip.", "Late alert sent \(time(5, 45))."])

        // A plan that cannot meet the arrival, before any alert went out.
        let late = MonitoringSummary(trip: trip(phase: .monitoring, plan: latePlan), departed: nil, obstacle: nil)
        XCTAssertEqual(
            formatter.monitoringLines(for: late, at: now),
            ["The server is monitoring this trip.", "No time-to-leave alert while the arrival time cannot be met."]
        )
    }

    func testAPassedDepartureIsNeverAnnouncedAsAComingAlert() {
        let sevenTen = TestFixtures.date(2026, 10, 26, 7, 10)
        let passed = MonitoringSummary(trip: trip(phase: .monitoring, plan: plan), departed: nil, obstacle: nil)
        XCTAssertEqual(
            formatter.monitoringLines(for: passed, at: now),
            ["The server is monitoring this trip.", "Time-to-leave alert at the recommended departure, currently \(time(7, 5))."],
            "Ahead: the alert is still to come"
        )
        XCTAssertEqual(
            formatter.monitoringLines(for: passed, at: sevenTen),
            ["The server is monitoring this trip.", "The recommended departure, \(time(7, 5)), has passed; no time-to-leave alert is recorded as sent."],
            "Passed without a stamp: nothing is promised for a time that is over"
        )

        // The alert was queued at the departure but the push service has not accepted it yet.
        let queued = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: plan, lastAlert: TripAlert(kind: .leaveNow, status: .queued, at: TestFixtures.date(2026, 10, 26, 7, 5), reason: nil)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(
            formatter.monitoringLines(for: queued, at: sevenTen),
            ["The server is monitoring this trip.", "Time-to-leave alert queued; not sent yet."]
        )
        let failed = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: plan, lastAlert: TripAlert(kind: .leaveNow, status: .failed, at: TestFixtures.date(2026, 10, 26, 7, 5), reason: "BadDeviceToken")),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(
            formatter.monitoringLines(for: failed, at: sevenTen),
            ["The server is monitoring this trip.", "The last alert could not be sent: BadDeviceToken"]
        )
    }

    func testAPlanTheServerCouldNotRefreshIsDescribedWithoutItsTimes() {
        let stalePlan = TestBackend.plan(departure: TestFixtures.date(2026, 10, 26, 7, 5), arrival: TestFixtures.date(2026, 10, 26, 7, 50), evaluatedAt: now.addingTimeInterval(-40 * 60), isStale: true)
        let stale = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: stalePlan, startedAt: TestFixtures.date(2026, 10, 26, 5, 5), headsUpAt: TestFixtures.date(2026, 10, 26, 6, 35)),
            departed: nil,
            obstacle: nil
        )
        XCTAssertTrue(stale.planIsStale)
        XCTAssertFalse(stale.showsPlanTimes, "The screens ask the backend directly then, so the stale plan's times would sit beside another departure")
        XCTAssertEqual(formatter.monitoringLines(for: stale, at: now), [
            "Monitoring started \(time(5, 5)).",
            "Heads-up about 90 minutes before the recommended departure.",
            "Time-to-leave alert at the recommended departure."
        ])
    }

    func testAStateThatCouldNotBeReadAgainShowsNoAlertTimes() {
        let readAt = TestFixtures.date(2026, 10, 26, 5, 56)
        let outOfDate = MonitoringSummary(
            trip: trip(phase: .monitoring, plan: plan, startedAt: TestFixtures.date(2026, 10, 26, 5, 5), headsUpAt: TestFixtures.date(2026, 10, 26, 6, 35)),
            departed: nil,
            obstacle: nil,
            lastReadAt: readAt,
            isOutOfDate: true
        )
        let lines = formatter.monitoringLines(for: outOfDate, at: now)
        XCTAssertEqual(lines, ["The server's plan for this trip was last read \(time(5, 56)), so its alert times are not shown until it is read again."])
        XCTAssertFalse(lines.joined().contains("currently"))
        XCTAssertFalse(lines.joined().contains("Heads-up"))

        let unknown = MonitoringSummary(trip: trip(phase: .planning), departed: nil, obstacle: nil, isOutOfDate: true)
        XCTAssertEqual(formatter.monitoringLines(for: unknown, at: now), ["The server's plan for this trip has not been read again, so its alert times are not shown."])

        // What is over stays said as it is: the server reported it before.
        let left = MonitoringSummary(trip: trip(phase: .departed), departed: nil, obstacle: nil, lastReadAt: readAt, isOutOfDate: true)
        XCTAssertEqual(formatter.monitoringLines(for: left, at: now), ["Marked as left. Monitoring ended for this trip."])
    }

    // MARK: Push registration and coverage

    func testALocalRegistrationFailureIsWordedAsThisDevices() {
        XCTAssertEqual(
            MonitoringText.registrationFailureSentence("no valid aps-environment entitlement string found for application"),
            "This device could not register for push notifications (no valid aps-environment entitlement string found for application)."
        )
        XCTAssertEqual(
            MonitoringText.registrationFailureSentence(" The operation could not be completed. "),
            "This device could not register for push notifications (The operation could not be completed).",
            "The reason's own period does not double the sentence's"
        )
        XCTAssertEqual(MonitoringText.registrationFailureSentence("  "), "This device could not register for push notifications.")
        XCTAssertFalse(MonitoringText.registrationFailureSentence("x").contains("server"), "Nothing the server attempted is claimed")
    }

    func testTheCoverageLineNamesTheLastDayAlertsAreSetUpFor() {
        let last = TestFixtures.date(2026, 11, 2, 8, 15)
        XCTAssertEqual(
            formatter.monitoringCoverageText(through: last),
            "Alerts are set up for trips through Monday, November 2. Open the app again before then to keep them coming."
        )
    }

    func testAMonitoredTripSaysSentOnlyWithTheServersStamp() {
        let monitored = MonitoringSummary(
            trip: trip(
                phase: .monitoring,
                plan: plan,
                startsAt: TestFixtures.date(2026, 10, 26, 5, 5),
                startedAt: TestFixtures.date(2026, 10, 26, 5, 6),
                headsUpAt: TestFixtures.date(2026, 10, 26, 5, 35),
                lastAlert: TripAlert(kind: .headsUp, status: .queued, at: TestFixtures.date(2026, 10, 26, 5, 35), reason: nil)
            ),
            departed: nil,
            obstacle: .monitorNotDependable
        )
        XCTAssertTrue(monitored.canMarkDeparted)
        XCTAssertFalse(monitored.alertsAreActive, "An obstacle means nothing is described as active")
        XCTAssertEqual(monitored.deliverySentence, MonitoringObstacle.monitorNotDependable.sentence)
        XCTAssertEqual(formatter.monitoringLines(for: monitored, at: now), [
            "Monitoring started \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 5, 6))).",
            "Time-to-leave alert at the recommended departure, currently \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 7, 5))).",
            "Heads-up queued; not sent yet."
        ], "The heads-up time has passed and no stamp says it was sent, so it is not claimed")

        let sent = MonitoringSummary(
            trip: trip(
                phase: .monitoring,
                plan: plan,
                headsUpAt: TestFixtures.date(2026, 10, 26, 5, 35),
                headsUpSentAt: TestFixtures.date(2026, 10, 26, 5, 36),
                leaveAlertSentAt: TestFixtures.date(2026, 10, 26, 5, 59),
                lastAlert: TripAlert(kind: .leaveNow, status: .sent, at: TestFixtures.date(2026, 10, 26, 5, 59), reason: nil)
            ),
            departed: nil,
            obstacle: nil
        )
        XCTAssertEqual(formatter.monitoringLines(for: sent, at: now), [
            "The server is monitoring this trip.",
            "Heads-up sent \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 5, 36))).",
            "Time-to-leave alert sent \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 5, 59)))."
        ])
        for line in formatter.monitoringLines(for: sent, at: now) {
            XCTAssertFalse(line.lowercased().contains("delivered"), line)
        }
    }

    func testTheOtherPhasesHaveTheirOwnLines() {
        let scheduled = MonitoringSummary(trip: trip(phase: .scheduled, planAvailableAt: TestFixtures.date(2026, 10, 27, 20, 45)), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringLines(for: scheduled, at: now), ["The server plans this trip from about \(formatter.reminderTimestamp(TestFixtures.date(2026, 10, 27, 20, 45)))."])
        XCTAssertFalse(scheduled.canMarkDeparted)
        let unscheduled = MonitoringSummary(trip: trip(phase: .scheduled), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringLines(for: unscheduled, at: now), ["The server plans this trip closer to its arrival time."])

        let planning = MonitoringSummary(trip: trip(phase: .planning), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringLines(for: planning, at: now), ["The server is working out when you should leave."])

        let departed = MonitoringSummary(trip: trip(phase: .departed, lastAlert: TripAlert(kind: .late, status: .dropped, at: now, reason: nil)), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringLines(for: departed, at: now), ["Marked as left. Monitoring ended for this trip."])
        XCTAssertTrue(departed.isDeparted)
        XCTAssertFalse(departed.canMarkDeparted)
        XCTAssertFalse(departed.alertsAreActive)
        XCTAssertEqual(departed.departedSentence, "Marked as left. Monitoring ended for this trip.", "Known from the server even after a relaunch")

        let ended = MonitoringSummary(trip: trip(phase: .ended), departed: nil, obstacle: nil)
        XCTAssertEqual(formatter.monitoringLines(for: ended, at: now), ["Monitoring ended: the arrival time has passed."])
        XCTAssertFalse(ended.canMarkDeparted)
        XCTAssertFalse(ended.alertsAreActive)

        // The time-to-leave alert went out before monitoring was reported: "I've left" is offered.
        let alerted = MonitoringSummary(trip: trip(phase: .planned, plan: plan, leaveAlertSentAt: now), departed: nil, obstacle: nil)
        XCTAssertTrue(alerted.canMarkDeparted)
        let sending = MonitoringSummary(trip: trip(phase: .monitoring, plan: plan), departed: .sending, obstacle: nil)
        XCTAssertFalse(sending.canMarkDeparted, "Not twice at once")
        XCTAssertEqual(sending.departedSentence, "Telling the server\u{2026}")
    }

    func testTimesNameTheDayOnlyWhenItIsNotToday() {
        let today = TestFixtures.date(2026, 10, 26, 7, 5)
        XCTAssertEqual(formatter.monitoringTime(today, at: now), formatter.clockTime(today))
        XCTAssertTrue(formatter.monitoringTime(today, at: now).contains("7:05"))
        let tomorrow = TestFixtures.date(2026, 10, 27, 20, 45)
        let text = formatter.monitoringTime(tomorrow, at: now)
        XCTAssertEqual(text, formatter.reminderTimestamp(tomorrow))
        for part in ["Tue", "Oct", "27", "8:45", "PM"] {
            XCTAssertTrue(text.contains(part), "\(part) in \(text)")
        }
    }

    func testTheStatusLine() {
        XCTAssertEqual(formatter.monitoringStatusText(for: .active(acknowledgedAt: TestFixtures.date(2026, 10, 26, 5, 58), tripCount: 3), at: now), "The server confirmed 3 trips at \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 5, 58))).")
        XCTAssertEqual(formatter.monitoringStatusText(for: .active(acknowledgedAt: now, tripCount: 1), at: now), "The server confirmed 1 trip at \(formatter.clockTime(TestFixtures.date(2026, 10, 26, 6, 0))).")
        XCTAssertEqual(formatter.monitoringStatusText(for: .active(acknowledgedAt: now, tripCount: 0), at: now), MonitoringText.nothingToMonitor)
        XCTAssertEqual(formatter.monitoringStatusText(for: .off, at: now), "Leave-home alerts are off.")
        XCTAssertEqual(formatter.monitoringStatusText(for: .pending, at: now), "Waiting for the server to confirm monitoring.")
        XCTAssertEqual(formatter.monitoringStatusText(for: .paused, at: now), MonitoringObstacle.paused.sentence)
        XCTAssertEqual(formatter.monitoringStatusText(for: .settingsUnreadable, at: now), MonitoringObstacle.settingsUnreadable.sentence)
        XCTAssertEqual(formatter.monitoringStatusText(for: .failed(.offline, lastAcknowledgedAt: nil), at: now), "Trips could not be synchronized: the backend could not be reached.")
        XCTAssertEqual(
            formatter.monitoringStatusText(for: .failed(.offline, lastAcknowledgedAt: TestFixtures.date(2026, 10, 25, 21, 30)), at: now),
            "Trips could not be synchronized: the backend could not be reached. The server last confirmed your trips at \(formatter.reminderTimestamp(TestFixtures.date(2026, 10, 25, 21, 30)))."
        )
        XCTAssertTrue(MonitoringStatus.active(acknowledgedAt: now, tripCount: 1).isActive)
        XCTAssertFalse(MonitoringStatus.pending.isActive)
        XCTAssertEqual(MonitoringStatus.failed(.offline, lastAcknowledgedAt: nil).failure, .offline)
        XCTAssertNil(MonitoringStatus.off.failure)
    }
}
