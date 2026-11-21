import Foundation

/// Text for server-side trip monitoring that needs a clock time. Pure, like the rest of the
/// formatter: times are rendered in the calculator's zone. An alert is "sent" only when the
/// server reports that the push service accepted it; nothing is ever called "delivered".
///
/// A clock time of the server's plan is printed only while the screens take their leave-home
/// time from that same plan (`MonitoringSummary.showsPlanTimes`), so the two can never show
/// different departures; before that the alerts are described relative to "the recommended
/// departure". No line promises an alert at a time that has passed, after a late alert, or
/// from a state that could not be read again.
extension OccurrenceFormatter {
    /// "7:15 AM" on the day of `now`, otherwise "Mon, Nov 2, 7:15 AM".
    public func monitoringTime(_ date: Date, at now: Date) -> String {
        calculator.isSameDay(date, now) ? clockTime(date) : reminderTimestamp(date)
    }

    /// What the server plans for one monitored trip, one sentence per line, in the order the
    /// user meets them: where monitoring stands, the heads-up, the time-to-leave alert, what
    /// the server itself reports as a problem with the trip, and what became of the last alert
    /// when it was not sent.
    public func monitoringLines(for summary: MonitoringSummary, at now: Date) -> [String] {
        let isOver = summary.phase == .departed || summary.phase == .ended
        if summary.isOutOfDate, !isOver {
            return [outOfDateLine(for: summary, at: now)]
        }
        var lines: [String] = []
        switch summary.phase {
        case .scheduled:
            if let planAvailableAt = summary.planAvailableAt {
                lines.append("The server plans this trip from about \(monitoringTime(planAvailableAt, at: now)).")
            } else {
                lines.append("The server plans this trip closer to its arrival time.")
            }
            if let problem = problemLine(for: summary, at: now) {
                lines.append(problem)
            }
        case .planning:
            lines.append(problemLine(for: summary, at: now) ?? "The server is working out when you should leave.")
        case .planned:
            lines.append("Monitoring starts about \(MonitoringText.duration(summary.monitorLead)) before the recommended departure.")
            lines.append(contentsOf: alertLines(for: summary, at: now))
            if let problem = problemLine(for: summary, at: now) {
                lines.append(problem)
            }
        case .monitoring:
            if let startedAt = summary.monitoringStartedAt {
                lines.append("Monitoring started \(monitoringTime(startedAt, at: now)).")
            } else {
                lines.append("The server is monitoring this trip.")
            }
            lines.append(contentsOf: alertLines(for: summary, at: now))
            if let problem = problemLine(for: summary, at: now) {
                lines.append(problem)
            }
        case .departed:
            lines.append(MonitoringText.departedSentence(.done))
        case .ended:
            lines.append("Monitoring ended: the arrival time has passed.")
        }
        if !isOver, let alert = summary.alertSentence {
            lines.append(alert)
        }
        return lines
    }

    /// The heads-up and time-to-leave lines. "Sent" appears only with the server's own stamp.
    private func alertLines(for summary: MonitoringSummary, at now: Date) -> [String] {
        guard summary.recommendedDeparture != nil || summary.headsUpSentAt != nil || summary.leaveAlertSentAt != nil else {
            return []
        }
        var lines: [String] = []
        if let sentAt = summary.headsUpSentAt {
            lines.append("Heads-up sent \(monitoringTime(sentAt, at: now)).")
        } else if summary.recommendedDeparture != nil {
            if !summary.showsPlanTimes {
                lines.append("Heads-up about \(MonitoringText.duration(summary.headsUpLead)) before the recommended departure.")
            } else if let headsUpAt = summary.headsUpAt, headsUpAt > now {
                lines.append("Heads-up about \(monitoringTime(headsUpAt, at: now)).")
            }
        }
        if let line = leaveAlertLine(for: summary, at: now) {
            lines.append(line)
        }
        return lines
    }

    /// The time-to-leave line. A coming alert is promised only while the server would still
    /// send one: not after it sent or queued a late or time-to-leave alert, not while its plan
    /// cannot meet the arrival time, and not at a departure that has already passed.
    private func leaveAlertLine(for summary: MonitoringSummary, at now: Date) -> String? {
        if let sentAt = summary.leaveAlertSentAt {
            return "Time-to-leave alert sent \(monitoringTime(sentAt, at: now))."
        }
        if let alert = summary.lastAlert, alert.kind == .late || alert.kind == .leaveNow {
            // Queued, dropped, and failed alerts are worded by `alertSentence`.
            guard alert.kind == .late, alert.status == .sent else { return nil }
            return "Late alert sent \(monitoringTime(alert.at, at: now))."
        }
        guard let departure = summary.recommendedDeparture else { return nil }
        if summary.planIsLate {
            return "No time-to-leave alert while the arrival time cannot be met."
        }
        guard summary.showsPlanTimes else {
            return "Time-to-leave alert at the recommended departure."
        }
        guard departure > now else {
            return "The recommended departure, \(monitoringTime(departure, at: now)), has passed; no time-to-leave alert is recorded as sent."
        }
        return "Time-to-leave alert at the recommended departure, currently \(monitoringTime(departure, at: now))."
    }

    /// What the server itself reports as a problem with the trip, or `nil`: its last failed
    /// traffic check by code, or, for a trip without a plan, its own sentence while that is at
    /// most `DepartureRecommendation.reasonLifetime` old (it is worded relative to when it was
    /// written) and a plain statement afterwards.
    private func problemLine(for summary: MonitoringSummary, at now: Date) -> String? {
        if let code = summary.lastErrorCode {
            return MonitoringText.evaluationFailureSentence(code: code)
        }
        guard summary.recommendedDeparture == nil, let reason = summary.noPlanReason else { return nil }
        if let writtenAfter = summary.noPlanReasonWrittenAfter, !reason.isEmpty,
           now.timeIntervalSince(writtenAfter) <= DepartureRecommendation.reasonLifetime {
            return reason
        }
        return MonitoringText.noDepartureYet
    }

    /// Shown instead of the plan when the server's state could not be read again in time.
    private func outOfDateLine(for summary: MonitoringSummary, at now: Date) -> String {
        guard let lastReadAt = summary.lastReadAt else {
            return "The server's plan for this trip has not been read again, so its alert times are not shown."
        }
        return "The server's plan for this trip was last read \(monitoringTime(lastReadAt, at: now)), so its alert times are not shown until it is read again."
    }

    /// "Alerts are set up for trips through Thursday, November 5. Open the app again before
    /// then to keep them coming." `date` is the arrival of the last trip the server holds.
    public func monitoringCoverageText(through date: Date) -> String {
        let day = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .format(date)
        return "Alerts are set up for trips through \(day). Open the app again before then to keep them coming."
    }

    /// The Settings status line: "The server confirmed 3 trips at 7:02 AM." for an acknowledged
    /// set, or the waiting, paused, failed, and off wording of `MonitoringObstacle`. A failure
    /// also says when the server last confirmed, when it ever did.
    public func monitoringStatusText(for status: MonitoringStatus, at now: Date) -> String {
        switch status {
        case .active(let acknowledgedAt, let tripCount):
            guard tripCount > 0 else { return MonitoringText.nothingToMonitor }
            let trips = CountPhrase.make(tripCount, singular: "trip", plural: "trips")
            return "The server confirmed \(trips) at \(monitoringTime(acknowledgedAt, at: now))."
        case .off:
            return MonitoringObstacle.off.sentence
        case .paused:
            return MonitoringObstacle.paused.sentence
        case .settingsUnreadable:
            return MonitoringObstacle.settingsUnreadable.sentence
        case .pending:
            return MonitoringObstacle.pending.sentence
        case .failed(let failure, let lastAcknowledgedAt):
            guard let lastAcknowledgedAt else { return MonitoringText.failureSentence(failure) }
            return "\(MonitoringText.failureSentence(failure)) The server last confirmed your trips at \(monitoringTime(lastAcknowledgedAt, at: now))."
        }
    }
}
