import Foundation

/// Where server-side trip monitoring stands. Never stored. The app claims that monitoring is
/// active only after the server acknowledged exactly the trips the app wants monitored.
public enum MonitoringStatus: Equatable, Sendable {
    /// Reminders are off, or the Demo data mode is in use.
    case off
    /// Saved activities could not be read; the server is left untouched.
    case paused
    /// Saved settings could not be read, so whether alerts are wanted, and from which server,
    /// is not known; the server is left untouched.
    case settingsUnreadable
    /// Waiting for the server to acknowledge the current trips.
    case pending
    /// The server acknowledged the current trips.
    case active(acknowledgedAt: Date, tripCount: Int)
    /// The trips could not be synchronized. `lastAcknowledgedAt` is when the server last
    /// acknowledged a set in this session, if it ever did.
    case failed(TripMonitoringFailure, lastAcknowledgedAt: Date?)

    /// True only for `.active`.
    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// The failure of a failed synchronization, or `nil`.
    public var failure: TripMonitoringFailure? {
        if case .failed(let failure, _) = self { return failure }
        return nil
    }
}

/// Where telling the server "I've left" stands for one trip.
public enum DepartedState: Equatable, Sendable {
    /// The request is under way.
    case sending
    /// The server answered: monitoring ended for this trip.
    case done
    /// The server could not be told, or it refused.
    case failed(TripMonitoringFailure)
}

/// Where taking this installation's trips off the server stands, after reminders were turned
/// off or the Demo data mode was chosen. Separate from `MonitoringStatus`, which is `.off` at
/// once: nothing is claimed while the server is still being told.
public enum MonitoringWithdrawal: Equatable, Sendable {
    /// Nothing of this installation is known to be left on the server.
    case none
    /// The server is being told.
    case pending
    /// The server could not be told, or did not confirm; it may still send alerts for a while.
    /// Tried again later.
    case failed(TripMonitoringFailure)
}

/// What the user did with a trip notification.
public enum NotificationAction: Equatable, Sendable {
    /// Tapped the notification itself.
    case open
    /// Chose "I've left".
    case left
}

/// The one thing that keeps alerts from being described as active, most actionable first.
/// `nil` from `resolve` means nothing does: the server acknowledged the trips, it can send
/// push notifications to this device, the user allows them, and its monitoring worker runs
/// dependably.
public enum MonitoringObstacle: Equatable, Sendable {
    /// Reminders are off or the Demo data mode is in use.
    case off
    /// Saved activities could not be read.
    case paused
    /// Saved settings could not be read.
    case settingsUnreadable
    /// The server has not acknowledged the current trips yet.
    case pending
    /// The trips could not be synchronized.
    case failed(TripMonitoringFailure)
    /// The user has not been asked about notifications yet.
    case permissionNotDetermined
    /// Notifications are turned off for the app.
    case permissionDenied
    /// The server has no push credentials.
    case serverCannotPush
    /// The server has no usable push token for this device.
    case deviceNotRegistered
    /// The server has not been told yet that notifications are allowed.
    case permissionNotReported
    /// The server does not run its monitoring worker.
    case monitorNotRunning
    /// The server only checks while it is awake.
    case monitorNotDependable

    /// The obstacle for the given state, or `nil` when alerts may be described as active.
    public static func resolve(
        status: MonitoringStatus,
        push: PushDeliveryStatus?,
        monitor: MonitorHealth?,
        permission: NotificationPermission
    ) -> MonitoringObstacle? {
        switch status {
        case .off:
            return .off
        case .paused:
            return .paused
        case .settingsUnreadable:
            return .settingsUnreadable
        case .pending:
            return .pending
        case .failed(let failure, _):
            return .failed(failure)
        case .active:
            break
        }
        switch permission {
        case .denied:
            return .permissionDenied
        case .notDetermined:
            return .permissionNotDetermined
        case .authorized:
            break
        }
        // An acknowledged snapshot always carries both; without them nothing is confirmed.
        guard let push, let monitor else { return .pending }
        if !push.serverConfigured { return .serverCannotPush }
        if !push.deviceRegistered { return .deviceNotRegistered }
        if !push.authorized { return .permissionNotReported }
        if !monitor.enabled { return .monitorNotRunning }
        if !monitor.dependable { return .monitorNotDependable }
        return nil
    }

    /// The exact obstacle in one sentence. Never promises delivery.
    public var sentence: String {
        switch self {
        case .off:
            return "Leave-home alerts are off."
        case .paused:
            return "Saved activities could not be read, so trip monitoring is paused. Nothing was changed on the server."
        case .settingsUnreadable:
            return "Saved settings could not be read, so nothing was changed on the server. If leave-home alerts were on, the server may still send them."
        case .pending:
            return "Waiting for the server to confirm monitoring."
        case .failed(let failure):
            return MonitoringText.failureSentence(failure)
        case .permissionNotDetermined:
            return "Notifications have not been allowed for this app yet."
        case .permissionDenied:
            return "Notifications are off for this app in iOS Settings."
        case .serverCannotPush:
            return "The server has no push credentials, so alerts cannot be delivered."
        case .deviceNotRegistered:
            return "This device is not registered for push notifications yet."
        case .permissionNotReported:
            return "The server has not been told yet that notifications are allowed on this device."
        case .monitorNotRunning:
            return "This server is not running trip monitoring."
        case .monitorNotDependable:
            return "This server only checks traffic while it is awake, so alerts can be late or missing when the app is closed."
        }
    }
}

/// What the screens show about one monitored trip: the server's phase and times, what was
/// sent, and an honest sentence about delivery.
public struct MonitoringSummary: Equatable, Sendable {
    public let tripID: OccurrenceID
    public let phase: TripPhase
    /// When active monitoring starts; an estimate until it has started.
    public let monitoringStartsAt: Date?
    /// When active monitoring started, once it has.
    public let monitoringStartedAt: Date?
    /// When the heads-up is due.
    public let headsUpAt: Date?
    /// Set only when the push service accepted the heads-up.
    public let headsUpSentAt: Date?
    /// Set only when the push service accepted the time-to-leave alert.
    public let leaveAlertSentAt: Date?
    /// The recommended departure the time-to-leave alert follows, while the server has a plan.
    public let recommendedDeparture: Date?
    /// True when the server could not refresh that plan on schedule.
    public let planIsStale: Bool
    /// True while the server's plan says the arrival can no longer be met. It then sends a
    /// late alert and no time-to-leave alert.
    public let planIsLate: Bool
    /// For a trip beyond the planning horizon: when the server starts planning it.
    public let planAvailableAt: Date?
    public let lastAlert: TripAlert?
    /// The server's last evaluation failure for this trip, cleared by its next success.
    public let lastErrorCode: String?
    /// The server's own sentence for why it has no departure to recommend yet. Relative to
    /// when it was written, so it is shown only while `noPlanReasonWrittenAfter` is recent.
    public let noPlanReason: String?
    /// A moment on the device clock after which that sentence was written, or `nil` when its
    /// age is unknown.
    public let noPlanReasonWrittenAfter: Date?
    /// How long before the recommended departure active monitoring starts, in the server's
    /// own number.
    public let monitorLead: TimeInterval
    /// How long before the recommended departure the heads-up is sent, in the server's own
    /// number.
    public let headsUpLead: TimeInterval
    /// When the server's state was last read, on the device clock.
    public let lastReadAt: Date?
    /// True when that state should have been read again since and was not for longer than
    /// `MonitoringSnapshot.lifetime`. Its alert times are then not shown.
    public let isOutOfDate: Bool
    /// Where telling the server "I've left" stands, when the user did. A recorded success
    /// counts only while the server itself reports the trip as left.
    public let departed: DepartedState?
    /// What keeps alerts from being described as active, or `nil` when nothing does.
    public let obstacle: MonitoringObstacle?

    public init(
        trip: MonitoredTripState,
        departed: DepartedState?,
        obstacle: MonitoringObstacle?,
        limits: MonitoringLimits = .fallback,
        noPlanReasonWrittenAfter: Date? = nil,
        lastReadAt: Date? = nil,
        isOutOfDate: Bool = false
    ) {
        tripID = trip.id
        phase = trip.phase
        monitoringStartsAt = trip.monitoringStartsAt
        monitoringStartedAt = trip.monitoringStartedAt
        headsUpAt = trip.headsUpAt
        headsUpSentAt = trip.headsUpSentAt
        leaveAlertSentAt = trip.leaveAlertSentAt
        recommendedDeparture = trip.plan?.departAt
        planIsStale = trip.plan?.isStale ?? false
        planIsLate = trip.plan?.lateBy != nil
        planAvailableAt = trip.planAvailableAt
        lastAlert = trip.lastAlert
        lastErrorCode = trip.lastErrorCode
        noPlanReason = trip.noPlanReason
        self.noPlanReasonWrittenAfter = noPlanReasonWrittenAfter
        monitorLead = limits.monitorLead
        headsUpLead = limits.headsUpLead
        self.lastReadAt = lastReadAt
        self.isOutOfDate = isOutOfDate
        // The server's phase decides: a trip it monitors again was not left for this arrival.
        self.departed = departed == .done && trip.phase != .departed ? nil : departed
        self.obstacle = obstacle
    }

    /// True while the server itself says that it cannot plan or re-check this trip (its last
    /// traffic check failed), or that it has no departure to recommend for it yet. Alerts are
    /// then not described as active for the trip, whatever the delivery path looks like.
    public var hasServerProblem: Bool {
        guard phase != .departed, phase != .ended else { return false }
        return lastErrorCode != nil || (recommendedDeparture == nil && noPlanReason != nil)
    }

    /// True only when alerts may be described as active for this trip.
    public var alertsAreActive: Bool {
        obstacle == nil && !hasServerProblem && phase != .departed && phase != .ended
    }

    /// True once the server reports that the user left, from this session or an earlier one.
    public var isDeparted: Bool {
        phase == .departed
    }

    /// True while the server's own alert times may be listed: it is actively monitoring the
    /// trip with a plan it could refresh on schedule. Only then do the screens take their
    /// leave-home time from the same plan, so the two can never name different departures;
    /// before that the alerts are described relative to "the recommended departure".
    public var showsPlanTimes: Bool {
        phase == .monitoring && recommendedDeparture != nil && !planIsStale
    }

    /// True when "I've Left" should be offered: the server is actively monitoring the trip, or
    /// it already sent the time-to-leave alert, and the user has not left yet. Offered again
    /// after a failed attempt, and not while one is under way.
    public var canMarkDeparted: Bool {
        guard !isDeparted, phase != .ended, departed != .sending else { return false }
        return phase == .monitoring || leaveAlertSentAt != nil
    }

    /// The honest sentence about delivery: that the server will try, the exact obstacle, or
    /// that alerts are not active for this trip while the server reports a problem with it.
    public var deliverySentence: String {
        if obstacle == nil, hasServerProblem { return MonitoringText.tripAlertsNotActive }
        return MonitoringText.deliverySentence(for: obstacle, tripCount: 1)
    }

    /// What became of the last alert when it was not sent, or `nil`: "Heads-up queued; not sent
    /// yet." or "The last alert could not be sent: reason."
    public var alertSentence: String? {
        MonitoringText.alertSentence(lastAlert)
    }

    /// The sentence for the "I've left" state, or `nil` before the user said so.
    public var departedSentence: String? {
        if let departed { return MonitoringText.departedSentence(departed) }
        return phase == .departed ? MonitoringText.departedSentence(.done) : nil
    }
}

/// Every sentence about trip monitoring that does not need a clock or a formatter. Pure, so
/// each wording is tested. Nothing here promises delivery or an on-time arrival: the server
/// "will try", and an alert is "sent" when the push service accepted it, never "delivered".
public enum MonitoringText {
    /// Shown only when nothing stands in the way.
    public static let activeDelivery = "The server is monitoring your upcoming trips and will try to alert you. Delivery is not guaranteed."
    /// Shown when the server acknowledged an empty set.
    public static let nothingToMonitor = "Nothing saved has an arrival in the next \(DepartureHorizon.lookaheadDays) days, so there is nothing to monitor yet."
    /// Shown after the server address changed and the earlier server could not be told.
    public static let previousServerWarning = "The previous server may still send alerts for a while."
    /// Shown when a notification names a trip the calendar no longer has.
    public static let tripNoLongerInCalendar = "That trip is no longer in your calendar."
    /// Shown when a notification names a trip while saved activities cannot be read.
    public static let tripUnreadable = "Saved activities could not be read, so that trip cannot be shown."
    /// Shown in place of `activeDelivery` for a trip the server reports a problem with.
    public static let tripAlertsNotActive = "Alerts are not active for this trip right now."
    /// The same where the trip is the next one of several, as in Settings.
    public static let nextTripAlertsNotActive = "The server confirmed your trips, but alerts are not active for the next one right now."

    /// The same where the server reports a problem with other trips than the next one, or with
    /// several: "… but alerts are not active for 2 of them right now."
    public static func someTripsAlertsNotActive(count: Int) -> String {
        "The server confirmed your trips, but alerts are not active for \(count) of them right now."
    }
    /// Shown for a trip without a plan once the server's own sentence about it is too old to
    /// repeat, or when its age is unknown.
    public static let noDepartureYet = "The server has no departure to recommend for this trip yet."

    /// What the server's last failed traffic check means for a trip, by its code.
    /// `routing_unavailable`, `internal`, and any code this build does not know are failures
    /// the server retries shortly.
    public static func evaluationFailureSentence(code: String) -> String {
        switch code {
        case "no_coverage":
            return "The server has no traffic data for this route, so it cannot plan or alert for this trip."
        case "budget_exhausted":
            return "The server has used up its traffic checks for today, so this trip is not being re-checked. A time-to-leave alert is still sent from the last plan, if there is one."
        default:
            return "The server could not check traffic for this trip just now. It keeps trying."
        }
    }

    /// Why this device could not register with the push service, as a failure of this device
    /// (not of the server): "This device could not register for push notifications (reason)."
    public static func registrationFailureSentence(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        guard !text.isEmpty else { return "This device could not register for push notifications." }
        return "This device could not register for push notifications (\(text))."
    }

    /// The delivery sentence: the obstacle's own words, or that the server will try.
    public static func deliverySentence(for obstacle: MonitoringObstacle?, tripCount: Int) -> String {
        if let obstacle { return obstacle.sentence }
        return tripCount > 0 ? activeDelivery : nothingToMonitor
    }

    /// Why a synchronization failed, as one complete sentence.
    public static func failureSentence(_ failure: TripMonitoringFailure) -> String {
        switch failure {
        case .rejected(let message):
            return "The server did not accept these trips: \(message)"
        case .unavailableOnServer:
            return "This server does not support trip monitoring yet."
        case .notConfigured, .offline, .timedOut, .server, .invalidResponse, .reregistered,
             .notRegistered, .superseded, .notMonitored, .credentialStorage:
            return "Trips could not be synchronized: \(failureReason(failure))."
        }
    }

    /// The failure as a clause without a capital or a period, for use inside a sentence.
    public static func failureReason(_ failure: TripMonitoringFailure) -> String {
        switch failure {
        case .notConfigured:
            return "no backend address is set"
        case .offline:
            return "the backend could not be reached"
        case .timedOut:
            return "the backend did not answer in time"
        case .server(let status):
            return "the backend had a problem (HTTP \(status))"
        case .invalidResponse:
            return "the backend's answer could not be read"
        case .unavailableOnServer:
            return "this server does not support trip monitoring yet"
        case .rejected(let message):
            return "the server did not accept the request (\(message))"
        case .reregistered:
            return "the server no longer knew this device"
        case .notRegistered:
            return "this device is not registered with the server"
        case .superseded:
            return "the trip was rescheduled"
        case .notMonitored:
            return "the server is not monitoring that trip"
        case .credentialStorage:
            return "this device's server credential could not be read or saved"
        }
    }

    /// The sentence for each "I've left" state. Success is claimed only after the server
    /// answered.
    public static func departedSentence(_ state: DepartedState) -> String {
        switch state {
        case .sending:
            return "Telling the server\u{2026}"
        case .done:
            return "Marked as left. Monitoring ended for this trip."
        case .failed(.superseded):
            return "This trip was rescheduled; monitoring continues for the new time."
        case .failed(.notMonitored):
            return "The server is not monitoring this trip, so there was nothing to end."
        case .failed:
            return "Could not tell the server you left; it may still send alerts for this trip."
        }
    }

    /// What became of the last alert when it was not sent, or `nil` when it was sent or there
    /// is none.
    public static func alertSentence(_ alert: TripAlert?) -> String? {
        guard let alert else { return nil }
        switch alert.status {
        case .sent:
            return nil
        case .queued:
            return "\(alertName(alert.kind)) queued; not sent yet."
        case .dropped, .failed:
            guard let reason = alert.reason, !reason.isEmpty else { return "The last alert could not be sent." }
            return "The last alert could not be sent: \(reason)"
        }
    }

    /// "Heads-up", "Update", "Time-to-leave alert", or "Late alert".
    public static func alertName(_ kind: TripAlert.Kind) -> String {
        switch kind {
        case .headsUp:
            return "Heads-up"
        case .update:
            return "Update"
        case .leaveNow:
            return "Time-to-leave alert"
        case .late:
            return "Late alert"
        }
    }

    /// The sentence while this installation is being taken off the server, or `nil` when
    /// there is nothing to say.
    public static func withdrawalSentence(_ withdrawal: MonitoringWithdrawal) -> String? {
        switch withdrawal {
        case .none:
            return nil
        case .pending:
            return "Telling the server to stop monitoring\u{2026}"
        case .failed(let failure):
            // Only a failure that can clear on its own is retried on the minute ticks.
            let retry = failure.isTransient
                ? "This is tried again automatically."
                : "It is tried again when you tap Try Again or open the app again."
            return "The server could not be told to stop (\(failureReason(failure))), so it may still send alerts for a while. \(retry)"
        }
    }

    /// What server-side monitoring does, in the server's own numbers, how far ahead it
    /// reaches, and what it keeps. For the Settings section footer in Live mode.
    public static func remindersFooter(limits: MonitoringLimits) -> String {
        let lead = duration(limits.monitorLead)
        let headsUp = duration(limits.headsUpLead)
        let shift = duration(limits.meaningfulShift)
        return "The team backend watches traffic for your upcoming trips, starting about \(lead) before the recommended departure. It sends a heads-up about \(headsUp) before, an update only when the departure moves by at least \(shift), and an alert when it is time to leave. Delivery is best effort and needs notification permission. \(coverageSentence(limits: limits)) Trips are removed from the server after they end; turning this off deletes this installation's data from the server."
    }

    /// How far ahead the server is told about trips, and what that means: the app sends them
    /// only while it is open, so alerts for later trips need the app to be opened again.
    public static func coverageSentence(limits: MonitoringLimits) -> String {
        let most = max(0, min(WaitItOutModel.monitoredTripLimit, limits.maxTrips))
        return "The app sends your trips for the next \(DepartureHorizon.lookaheadDays) days (at most \(most)) to the server each time it is opened or brought to the foreground, so alerts stop for later trips unless you open the app again."
    }

    /// What is sent to the backend, for the Settings "Data source" footer: every field, and
    /// nothing that is not sent.
    public static func dataSentFooter(remindersEnabled: Bool) -> String {
        var text = "For a recommendation the app sends the home and campus coordinates and your ideal arrival to the team backend."
        if remindersEnabled {
            text += " With leave-home alerts on it also sends, for each upcoming trip, an id the app makes up, the title, the home and destination coordinates, the ideal arrival, and the time zone, together with an anonymous installation id and this device's push token."
        }
        return text + " There is no account, and your location is never read."
    }

    /// "2 hours", "90 minutes", "5 minutes", "1 hour 30 minutes" would read oddly for a lead,
    /// so whole hours are given in hours and everything else in minutes.
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes >= 60, minutes % 60 == 0 {
            return CountPhrase.make(minutes / 60, singular: "hour", plural: "hours")
        }
        return CountPhrase.make(minutes, singular: "minute", plural: "minutes")
    }
}
