import Foundation

/// What `MonitoringStatusView` shows about server-side trip monitoring (stage S3): the Live
/// counterpart of `ReminderPreview`. Decided here, so every state is tested and the view only
/// places it: one status sentence that never promises delivery, the sentences that follow it,
/// and which of the three actions are offered.
public struct MonitoringPresentation: Equatable, Sendable {
    /// What kind of status the sentence is, so the view can choose a symbol.
    public enum Kind: Equatable, Sendable {
        /// Alerts are off, or this build cannot send any.
        case off
        /// The server has not confirmed yet; shown with a progress indicator.
        case waiting
        /// Saved activities could not be read.
        case paused
        /// Something keeps alerts from being described as active.
        case problem
        /// Notifications are not allowed on this device.
        case needsPermission
        /// The server monitors the trips and will try to alert.
        case active
        /// The server confirmed that there is nothing to monitor yet.
        case idle
    }

    public let kind: Kind
    /// The delivery sentence: that the server will try, or the exact obstacle.
    public let status: String
    /// Further sentences, in the order they are shown.
    public let details: [String]
    /// Try Again: synchronize with the server again.
    public let offersRetry: Bool
    /// Allow Notifications: the system prompt has not been answered yet.
    public let offersAllowNotifications: Bool
    /// Open Settings: notifications were turned off for the app.
    public let offersOpenSettings: Bool

    public init(
        kind: Kind,
        status: String,
        details: [String] = [],
        offersRetry: Bool = false,
        offersAllowNotifications: Bool = false,
        offersOpenSettings: Bool = false
    ) {
        self.kind = kind
        self.status = status
        self.details = details
        self.offersRetry = offersRetry
        self.offersAllowNotifications = offersAllowNotifications
        self.offersOpenSettings = offersOpenSettings
    }

    /// Pure: the presentation for the given state.
    ///
    /// - `isAvailable`: the host composed a monitoring service (`usesTripMonitoring`).
    /// - `statusLine`: the formatter's line for the status, with its clock times
    ///   (`OccurrenceFormatter.monitoringStatusText`); used by the full form only.
    /// - `tripHeading` and `tripLines`: the server's plan for one trip, already limited to what
    ///   may be listed (`OccurrenceFormatter.monitoringPlanLines`).
    /// - `inactiveTripSentence`: set when the server reports a problem with that trip
    ///   (`MonitoringSummary.hasServerProblem`). With nothing else in the way it replaces the
    ///   sentence that says the server will try to alert, and the kind is `.problem`: alerts
    ///   are never described as active above a trip the server cannot plan or re-check.
    /// - `coverageLine`: how far ahead alerts are set up (the full form only).
    /// - `pushFailure`: the server's note about its last attempt to reach this device.
    /// - `registrationFailure`: why this device could not register with the push service.
    /// - `isCompact`: the Map card's short form.
    ///
    /// The permission actions appear only once the server answered or failed: while it is
    /// still being asked the permission may not have been read yet, and a button that flashes
    /// at launch would ask for something that is already granted.
    public static func make(
        isAvailable: Bool,
        remindersEnabled: Bool,
        status: MonitoringStatus,
        obstacle: MonitoringObstacle?,
        permission: NotificationPermission,
        withdrawal: MonitoringWithdrawal,
        appName: String,
        statusLine: String? = nil,
        tripHeading: String? = nil,
        tripLines: [String] = [],
        inactiveTripSentence: String? = nil,
        coverageLine: String? = nil,
        pushFailure: String? = nil,
        registrationFailure: String? = nil,
        isCompact: Bool = false
    ) -> MonitoringPresentation {
        guard isAvailable else {
            return MonitoringPresentation(kind: .off, status: MonitoringText.notAvailable)
        }
        if status == .settingsUnreadable {
            // Said whatever the toggle shows: the toggle shows a default, not the user's wish.
            return MonitoringPresentation(kind: .paused, status: MonitoringObstacle.settingsUnreadable.sentence)
        }
        guard remindersEnabled else {
            var details: [String] = []
            if let sentence = MonitoringText.withdrawalSentence(withdrawal) {
                details.append(sentence)
            }
            var withdrawalFailed = false
            if case .failed = withdrawal {
                withdrawalFailed = true
            }
            return MonitoringPresentation(
                kind: .off,
                status: isCompact ? MonitoringObstacle.off.sentence : MonitoringText.offInvitation,
                details: details,
                offersRetry: withdrawalFailed
            )
        }
        switch status {
        case .off, .pending:
            // With reminders on, "off" only means the saved schedule has not been read yet.
            return MonitoringPresentation(kind: .waiting, status: MonitoringObstacle.pending.sentence)
        case .paused:
            return MonitoringPresentation(kind: .paused, status: MonitoringObstacle.paused.sentence)
        case .settingsUnreadable:
            return MonitoringPresentation(kind: .paused, status: MonitoringObstacle.settingsUnreadable.sentence)
        case .failed(let failure, _):
            let sentence = MonitoringText.failureSentence(failure)
            var details: [String] = []
            if let notice = permissionNotice(permission, appName: appName) {
                details.append(notice)
            }
            return MonitoringPresentation(
                kind: .problem,
                status: isCompact ? sentence : (statusLine ?? sentence),
                details: details,
                offersRetry: true,
                offersAllowNotifications: permission == .notDetermined,
                offersOpenSettings: permission == .denied
            )
        case .active(_, let tripCount):
            let kind: Kind
            let sentence: String
            switch obstacle {
            case .none:
                if tripCount > 0, let inactiveTripSentence {
                    kind = .problem
                    sentence = inactiveTripSentence
                } else {
                    kind = tripCount > 0 ? .active : .idle
                    sentence = MonitoringText.deliverySentence(for: nil, tripCount: tripCount)
                }
            case .some(.permissionNotDetermined):
                kind = .needsPermission
                sentence = MonitoringObstacle.permissionNotDetermined.sentence
            case .some(.permissionDenied):
                kind = .needsPermission
                sentence = MonitoringText.permissionDeniedSentence(appName: appName)
            case .some(let other):
                kind = .problem
                sentence = other.sentence
            }
            var details: [String] = []
            if !isCompact, tripCount > 0, let statusLine {
                details.append(statusLine)
            }
            if !isCompact, tripCount > 0, let coverageLine {
                details.append(coverageLine)
            }
            if !tripLines.isEmpty {
                if let tripHeading {
                    details.append(tripHeading)
                }
                details.append(contentsOf: tripLines)
            }
            if !isCompact, let pushFailure, !pushFailure.isEmpty {
                details.append(MonitoringText.pushFailureSentence(pushFailure))
            }
            if !isCompact, let registrationFailure, !registrationFailure.isEmpty {
                details.append(MonitoringText.registrationFailureSentence(registrationFailure))
            }
            return MonitoringPresentation(
                kind: kind,
                status: sentence,
                details: details,
                offersAllowNotifications: obstacle == .permissionNotDetermined,
                offersOpenSettings: obstacle == .permissionDenied
            )
        }
    }

    /// The sentence about a missing notification permission, or `nil` when it is granted.
    static func permissionNotice(_ permission: NotificationPermission, appName: String) -> String? {
        switch permission {
        case .authorized:
            return nil
        case .notDetermined:
            return MonitoringObstacle.permissionNotDetermined.sentence
        case .denied:
            return MonitoringText.permissionDeniedSentence(appName: appName)
        }
    }
}

/// Sentences of the monitoring screens (stage S3). Like the rest of `MonitoringText`, nothing
/// here promises delivery.
extension MonitoringText {
    /// Shown when the live backend is in use and the host composed no monitoring service.
    public static let notAvailable = "This build has no trip-monitoring service, so no leave-home alerts are sent while live data is in use."
    /// Shown in Settings while leave-home alerts are off.
    public static let offInvitation = "Leave-home alerts are off. Turn them on to have the server watch your upcoming trips and try to alert you when it is time to leave."
    /// Title of the action that tells the server the user has left.
    public static let departedButtonTitle = "I've Left"
    /// VoiceOver hint of that action.
    public static let departedButtonHint = "Tells the server you have left, which ends its monitoring of this trip"
    /// Explains the action where there is room for it.
    public static let departedFooter = "I've Left tells the server you are on your way. It then stops monitoring this trip and sends no more alerts for it."

    /// "Notifications are off for WAIT IT OUT UX. Turn them on in iOS Settings to get alerts."
    /// `appName` is the name iOS Settings lists the app under.
    public static func permissionDeniedSentence(appName: String) -> String {
        "Notifications are off for \(appName). Turn them on in iOS Settings to get alerts."
    }

    /// What the server noted about its last attempt to reach this device, in its own words.
    public static func pushFailureSentence(_ reason: String) -> String {
        "The server's last attempt to reach this device failed (\(reason))."
    }

    /// The title of the "I've left" action after `state`: "Try Again" when the server could
    /// not be told, otherwise "I've Left". A rescheduled or unknown trip was answered for
    /// good, so asking again is not a retry.
    public static func departedButtonTitle(after state: DepartedState?) -> String {
        switch state {
        case .none, .some(.sending), .some(.done), .some(.failed(.superseded)), .some(.failed(.notMonitored)):
            return departedButtonTitle
        case .some(.failed):
            return "Try Again"
        }
    }
}

extension MonitoringSummary {
    /// True when the server's plan for this trip may be listed under the delivery sentence:
    /// nothing keeps alerts from reaching the device, or the only caveat is a server that
    /// checks while it is awake, or the trip is over. With any other obstacle the plan would
    /// read like alerts that will arrive, so only the obstacle is named.
    public var listsServerPlan: Bool {
        obstacle == nil || obstacle == .monitorNotDependable || phase == .ended
    }
}

extension OccurrenceFormatter {
    /// The server's plan for one trip as the screens list it under a delivery sentence:
    /// `monitoringLines` while the plan may be listed (`MonitoringSummary.listsServerPlan`), and
    /// nothing once the user has left, because the "I've left" sentence says that.
    public func monitoringPlanLines(for summary: MonitoringSummary, at now: Date) -> [String] {
        guard !summary.isDeparted, summary.listsServerPlan else { return [] }
        return monitoringLines(for: summary, at: now)
    }

    /// The sentences of a trip's own "Leave-home alerts" rows (detail sheet): the delivery
    /// sentence while alerts can still matter for the trip (that the server will try, the
    /// obstacle, or that alerts are not active while the server reports a problem with the
    /// trip), then the server's plan.
    public func tripMonitoringSentences(for summary: MonitoringSummary, at now: Date) -> [String] {
        var sentences: [String] = []
        if !summary.isDeparted, summary.phase != .ended {
            sentences.append(summary.deliverySentence)
        }
        sentences.append(contentsOf: monitoringPlanLines(for: summary, at: now))
        return sentences
    }

    /// "Next monitored trip: Lecture, arrive by 8:15 AM." The day is named when it is not today.
    public func monitoredTripHeading(title: String, arriveBy: Date, at now: Date) -> String {
        "Next monitored trip: \(title), arrive by \(monitoringTime(arriveBy, at: now))."
    }
}

/// What the Calendar does about the trip a notification asked it to present
/// (`WaitItOutModel.tripToPresent`). Pure, so the rule is tested: the details are presented
/// only once the schedule is loaded and no editor is open, and the request is kept meanwhile.
public enum TripPresentationStep: Equatable, Sendable {
    /// No trip was asked for.
    case idle
    /// Keep the request: the schedule is still loading, or the editor is open.
    case wait
    /// Present this occurrence's details, then clear the request.
    case present(ActivityOccurrence)
    /// The trip is no longer in the calendar: clear the request.
    case discard

    public static func resolve(
        requested: OccurrenceID?,
        isScheduleLoaded: Bool,
        isEditorOpen: Bool,
        occurrence: (OccurrenceID) -> ActivityOccurrence?
    ) -> TripPresentationStep {
        guard let requested else { return .idle }
        guard isScheduleLoaded, !isEditorOpen else { return .wait }
        guard let found = occurrence(requested) else { return .discard }
        return .present(found)
    }
}

extension WaitItOutModel {
    /// What `MonitoringStatusView` shows now. `trip` is the occurrence whose server plan is
    /// listed, such as the Map card's own trip; without one the next monitored trip is listed
    /// under its title.
    public func monitoringPresentation(
        formatter: OccurrenceFormatter,
        at now: Date,
        isCompact: Bool = false,
        trip: ActivityOccurrence? = nil
    ) -> MonitoringPresentation {
        var heading: String?
        var lines: [String] = []
        var inactiveTripSentence: String?
        if let trip {
            if let summary = monitoringSummary(for: trip) {
                lines = formatter.monitoringPlanLines(for: summary, at: now)
                if summary.hasServerProblem {
                    inactiveTripSentence = MonitoringText.tripAlertsNotActive
                }
            }
        } else {
            let upcoming = upcomingMonitoringSummaries(at: now)
            if let summary = upcoming.first {
                lines = formatter.monitoringPlanLines(for: summary, at: now)
                if !lines.isEmpty, let next = occurrence(for: summary.tripID) {
                    heading = formatter.monitoredTripHeading(title: next.activity.title, arriveBy: next.idealArrival, at: now)
                }
            }
            // The sentence above the list speaks for every upcoming trip, so one the server
            // reports a problem with keeps it from saying that alerts are active.
            let troubled = upcoming.filter(\.hasServerProblem).count
            if troubled == 1, upcoming.first?.hasServerProblem == true {
                inactiveTripSentence = MonitoringText.nextTripAlertsNotActive
            } else if troubled > 0 {
                inactiveTripSentence = MonitoringText.someTripsAlertsNotActive(count: troubled)
            }
        }
        return MonitoringPresentation.make(
            isAvailable: usesTripMonitoring,
            remindersEnabled: remindersEnabled,
            status: monitoringStatus,
            obstacle: monitoringObstacle,
            permission: notificationPermission,
            withdrawal: monitoringWithdrawal,
            appName: prototypeInfo.appName,
            statusLine: formatter.monitoringStatusText(for: monitoringStatus, at: now),
            tripHeading: heading,
            tripLines: lines,
            inactiveTripSentence: inactiveTripSentence,
            coverageLine: monitoringCoverageEnd.map { formatter.monitoringCoverageText(through: $0) },
            pushFailure: pushDelivery?.lastFailure,
            registrationFailure: pushDelivery?.registrationFailure,
            isCompact: isCompact
        )
    }

    /// True when the Map's trip card shows the monitoring status under the leave-home time:
    /// the live backend is in use and leave-home reminders are on, or they are off and the
    /// server could not be told to stop, or saved settings could not be read, so that the
    /// toggle does not say what the server was last asked to do.
    public var showsMonitoringOnMap: Bool {
        guard usesLiveBackend else { return false }
        if remindersEnabled || monitoringStatus == .settingsUnreadable { return true }
        if case .failed = monitoringWithdrawal { return true }
        return false
    }

    /// What the Calendar should do about `tripToPresent` now.
    public var tripPresentationStep: TripPresentationStep {
        TripPresentationStep.resolve(
            requested: tripToPresent,
            isScheduleLoaded: activitiesStatus != .notLoaded,
            isEditorOpen: editSession?.mode == .editor,
            occurrence: { occurrence(for: $0) }
        )
    }
}
