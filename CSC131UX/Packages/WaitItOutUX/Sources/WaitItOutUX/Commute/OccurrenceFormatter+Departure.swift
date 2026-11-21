import Foundation

/// Text for calculated leave-home times (step 0005). Pure, like the rest of the formatter:
/// times are rendered in the calculator's zone and every simulated value says so. A backend
/// recommendation (`calculation.recommendation`) gets its own honest wording everywhere: the
/// local formula is never claimed for it, and its source is named as the backend reported it.
/// The demo estimate's sentences are unchanged.
extension OccurrenceFormatter {
    /// "7:15 AM", or with the date when leaving falls on another day than the arrival, such as
    /// "11:30 PM on Monday, November 2". Minutes are truncated, never rounded up, so the shown
    /// time is never later than the calculated one.
    public func leaveHomeText(for calculation: DepartureCalculation) -> String {
        guard !calculator.isSameDay(calculation.leaveHome, calculation.idealArrival) else {
            return clockTime(calculation.leaveHome)
        }
        let dateText = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .format(calculation.leaveHome)
        return "\(clockTime(calculation.leaveHome)) on \(dateText)"
    }

    /// The Map's trip line: "Monday, November 2: arrive by 8:15 AM for the 9:00 AM start". The
    /// arrival carries its own date when it falls on an earlier day than the start.
    public func nextTripScheduleText(for occurrence: ActivityOccurrence) -> String {
        let day = Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.wide)
            .month(.wide)
            .day()
            .format(occurrence.start)
        return "\(day): arrive by \(detailArrivalText(for: occurrence)) for the \(clockTime(occurrence.start)) start"
    }

    /// The value of the "Leave home" row for a current calculation: the leave-home time, or
    /// for a backend "leave now" recommendation "Leave now, as of 7:15 AM".
    public func leaveHomeValueText(for calculation: DepartureCalculation) -> String {
        guard calculation.recommendation?.advice == .leaveNow else { return leaveHomeText(for: calculation) }
        return "Leave now, as of \(leaveHomeText(for: calculation))"
    }

    /// How the time was calculated: "Ideal arrival 8:15 AM minus 1 hour of travel". For a
    /// backend recommendation, what the backend predicts instead of a formula: "Predicted
    /// arrival 8:05 AM after about 50 minutes of driving".
    public func departureFormulaText(for calculation: DepartureCalculation) -> String {
        if let recommendation = calculation.recommendation {
            return "Predicted arrival \(clockTime(recommendation.predictedArrival)) after about \(durationText(calculation.travelTime.seconds)) of driving"
        }
        return "Ideal arrival \(clockTime(calculation.idealArrival)) minus \(durationText(calculation.travelTime.seconds)) of travel"
    }

    /// Where the travel time came from: "Test commute (simulated, not live traffic), estimated
    /// 12:00 PM". For a backend recommendation: "Live traffic (TomTom) via the team backend,
    /// checked 12:00 PM", with the backend's own stamp.
    public func departureSourceText(for calculation: DepartureCalculation) -> String {
        if let recommendation = calculation.recommendation {
            return "\(recommendation.source.label), checked \(clockTime(recommendation.generatedAt))"
        }
        return "\(calculation.sourceLabel), estimated \(clockTime(calculation.estimatedAt))"
    }

    /// The line under a backend recommendation, or `nil` for a demo estimate. While the
    /// backend's sentence is current (see `DepartureRecommendation.isReasonCurrent`) it is
    /// shown verbatim. It is worded relative to when it was written, so afterwards only the
    /// absolute fact the app can state itself remains: the time to spare, when there is any.
    public func recommendationReasonText(for calculation: DepartureCalculation, at now: Date) -> String? {
        guard let recommendation = calculation.recommendation else { return nil }
        if recommendation.isReasonCurrent(at: now), !recommendation.reason.isEmpty {
            return recommendation.reason
        }
        guard recommendation.lateBy == nil, let margin = recommendation.margin, margin >= 60 else { return nil }
        return "About \(durationText(margin)) to spare before your ideal arrival."
    }

    /// "High confidence: Based on plenty of historical data and live traffic.", or `nil` for a
    /// demo estimate.
    public func recommendationConfidenceText(for calculation: DepartureCalculation) -> String? {
        guard let recommendation = calculation.recommendation else { return nil }
        let title = "\(recommendation.confidence.title) confidence"
        return recommendation.confidenceReason.isEmpty ? title : "\(title): \(recommendation.confidenceReason)"
    }

    /// Source with the estimate's age (step 0006): "Test commute (simulated, not live
    /// traffic), estimated 12:00 PM, just now" or "…, 12 minutes ago".
    public func departureSourceText(for calculation: DepartureCalculation, at now: Date) -> String {
        "\(departureSourceText(for: calculation)), \(estimateAgeText(calculation.estimatedAt, at: now))"
    }

    /// "just now" under a minute (or for a timestamp in the future), otherwise "12 minutes ago"
    /// or "1 hour 5 minutes ago".
    public func estimateAgeText(_ estimatedAt: Date, at now: Date) -> String {
        let age = EstimateFreshness.age(of: estimatedAt, at: now)
        guard age >= 60 else { return "just now" }
        return "\(durationText((age / 60).rounded(.down) * 60)) ago"
    }

    /// The Map's simulation line (step 0006): "Test drive 1 hour, Normal scenario" or "Test
    /// drive 1 hour 30 minutes (1 hour plus 50%), Slow scenario". `travelTime` is `nil` for
    /// scenarios without an estimate.
    public func simulationText(
        scenario: TestCommuteProvider.Scenario,
        testDuration: CommuteDuration,
        travelTime: CommuteDuration?
    ) -> String {
        guard let travelTime else {
            return "Test drive \(durationText(testDuration.seconds)) set; \(scenario.title) scenario gives no estimate"
        }
        if travelTime == testDuration {
            return "Test drive \(durationText(travelTime.seconds)), \(scenario.title) scenario"
        }
        // The Slow scenario caps every trip at 12 hours, so say so rather than claim a full 50%.
        let cap = travelTime.wholeMinutes >= CommuteDuration.maximumMinutes ? ", at most 12 hours" : ""
        return "Test drive \(durationText(travelTime.seconds)) (\(durationText(testDuration.seconds)) plus 50%\(cap)), \(scenario.title) scenario"
    }

    /// A note when the trip crosses a daylight-saving change, or `nil`.
    public func departureClockChangeNote(for calculation: DepartureCalculation) -> String? {
        // The note explains the local formula, which a backend recommendation does not use.
        guard calculation.recommendation == nil, calculation.crossesClockChange(in: calculator.timeZone) else { return nil }
        return "Clocks change during this trip. The travel time is real elapsed time, so the clock times are \(durationText(calculation.travelTime.seconds)) apart in real time."
    }

    /// Warning once the leave-home time has passed, or `nil` while it is still ahead. The
    /// calculated time is never replaced by the current time.
    ///
    /// A backend recommendation never gets the local "may miss" warning: the backend itself
    /// says when the ideal arrival can no longer be reached (`lateBy`), and a planned time that
    /// has just passed is handed back to the backend instead of being judged here.
    public func departureTimingText(for calculation: DepartureCalculation, at now: Date) -> String? {
        if let recommendation = calculation.recommendation {
            if now > calculation.idealArrival {
                return "The \(clockTime(calculation.idealArrival)) arrival target has passed."
            }
            guard let lateBy = recommendation.lateBy else { return nil }
            return "Your ideal arrival is no longer reachable: leaving now you would arrive about \(durationText(lateBy)) late."
        }
        switch calculation.timing(at: now) {
        case .upcoming:
            return nil
        case .departurePassed:
            return "The \(clockTime(calculation.leaveHome)) leave-home time has passed. Leaving now may miss the \(clockTime(calculation.idealArrival)) arrival target."
        case .arrivalPassed:
            return "The \(clockTime(calculation.idealArrival)) arrival target has passed."
        }
    }

    /// One sentence for every state without a leave-home time, or `nil` for a success.
    public func departureMessage(for state: DepartureState) -> String? {
        switch state {
        case .success:
            return nil
        case .loading:
            return "Calculating the leave-home time\u{2026}"
        case .refreshing(let stale):
            if stale.recommendation != nil {
                return "Out of date: checking the backend again\u{2026}"
            }
            return "Out of date: updating the commute estimate from \(clockTime(stale.estimatedAt))\u{2026}"
        case .stale(let kept, let failure):
            let checked = clockTime(kept.recommendation?.generatedAt ?? kept.estimatedAt)
            return "Could not refresh since \(checked): \(departureFailureSentence(failure)) Showing the last recommendation, which may be wrong."
        case .unavailable(let reason):
            switch reason {
            case .noDestination:
                return "This activity has no usable destination, so no leave-home time can be calculated. Check the campus in Settings under Home and campus."
            case .noEstimate(let message):
                return "\(message) No leave-home time is shown."
            case .activityEnded:
                return "This occurrence is over, so no leave-home time is calculated."
            case .beyondHorizon:
                return "Leave-home times are calculated for the next \(DepartureHorizon.lookaheadDays) days. This occurrence is further ahead."
            case .unsavedChanges:
                return "Save the change to calculate the leave-home time."
            case .notYetPlannable(let message, _):
                return message
            }
        case .error(let failure):
            switch failure {
            case .providerFailed:
                return "The commute estimate could not be loaded, so no leave-home time is shown."
            case .invalidEstimate(let issue):
                return "The commute estimate was not usable (\(invalidEstimateReason(issue))), so it was ignored and no leave-home time is shown."
            case .provider, .staleServerData:
                return "\(departureFailureSentence(failure)) No leave-home time is shown."
            }
        }
    }

    /// What went wrong, as one or two complete sentences without the "no leave-home time"
    /// ending, so the same words serve the error message and the kept out-of-date recommendation.
    public func departureFailureSentence(_ failure: DepartureFailure) -> String {
        switch failure {
        case .providerFailed:
            return "The request failed."
        case .invalidEstimate(let issue):
            return "The answer was not usable (\(invalidEstimateReason(issue)))."
        case .staleServerData:
            return "The server could not re-check traffic on schedule."
        case .provider(let kind):
            switch kind {
            case .notConfigured:
                return "No backend address is set. Add one in Settings, Data source."
            case .offline:
                return "The backend could not be reached. Check the connection."
            case .timedOut:
                return "The backend did not answer in time. It may be waking up; this is retried automatically."
            case .routingUnavailable:
                return "The routing service could not plan this trip right now."
            case .server(let status):
                return "The backend had a problem (HTTP \(status))."
            case .invalidResponse:
                return "The backend's answer could not be read."
            case .unauthorized:
                return "The backend did not accept this device."
            }
        }
    }

    /// Spoken form of an out-of-date time shown while refreshing: "Leave home at 7:15 AM, out
    /// of date. Updating the commute estimate. Simulated test data, not live traffic." The last
    /// sentence appears only for a simulated estimate, as in `departureAccessibilityLabel`.
    ///
    /// For a backend recommendation: "Leave home at 7:15 AM, out of date. Checking the backend
    /// again.", with "Test fixture traffic, not live." for fixture data.
    public func staleDepartureAccessibilityLabel(for calculation: DepartureCalculation) -> String {
        if calculation.recommendation != nil {
            var parts = ["Leave home at \(leaveHomeText(for: calculation)), out of date", "Checking the backend again"]
            if calculation.isSimulated {
                parts.append("Test fixture traffic, not live")
            }
            return parts.joined(separator: ". ") + "."
        }
        var parts = ["Leave home at \(leaveHomeText(for: calculation)), out of date", "Updating the commute estimate"]
        if calculation.isSimulated {
            parts.append("Simulated test data, not live traffic")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// Spoken form of a recommendation kept after a failed refresh: "Leave home at 7:15 AM, out
    /// of date. The last recommendation could not be refreshed and may be wrong."
    public func unrefreshedDepartureAccessibilityLabel(for calculation: DepartureCalculation) -> String {
        var parts = ["Leave home at \(leaveHomeText(for: calculation)), out of date", "The last recommendation could not be refreshed and may be wrong"]
        if calculation.isSimulated {
            parts.append("Test fixture traffic, not live")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// Spoken form: "Leave home at 7:15 AM. Ideal arrival 8:15 AM minus 1 hour of travel. Simulated test data."
    /// For a backend recommendation: "Leave home at 7:15 AM. Predicted arrival 8:05 AM after
    /// about 50 minutes of driving.", or "Leave now, as of 7:15 AM. ..." for "leave now".
    public func departureAccessibilityLabel(for calculation: DepartureCalculation, at now: Date) -> String {
        if let recommendation = calculation.recommendation {
            let lead = recommendation.advice == .leaveNow
                ? leaveHomeValueText(for: calculation)
                : "Leave home at \(leaveHomeText(for: calculation))"
            var parts = [lead, departureFormulaText(for: calculation)]
            if calculation.isSimulated {
                parts.append("Test fixture traffic, not live")
            }
            if let timing = departureTimingText(for: calculation, at: now) {
                parts.append(timing)
            }
            return parts.joined(separator: ". ")
        }
        var parts = ["Leave home at \(leaveHomeText(for: calculation))", departureFormulaText(for: calculation)]
        if calculation.isSimulated {
            parts.append("Simulated test data, not live traffic")
        }
        if let timing = departureTimingText(for: calculation, at: now) {
            parts.append(timing)
        }
        return parts.joined(separator: ". ")
    }

    private func invalidEstimateReason(_ issue: CommuteEstimateIssue) -> String {
        switch issue {
        case .travelTime(.notPositive):
            return "zero or negative travel time"
        case .travelTime(.notFinite), .travelTime(.notANumber), .travelTime(.empty), .travelTime(.notWholeMinutes):
            return "travel time is not a finite number"
        case .travelTime(.tooLong):
            return "travel time longer than 12 hours"
        case .timestamp:
            return "no valid estimate time"
        case .missingSourceLabel:
            return "no source label"
        case .arrival:
            return "no valid ideal arrival"
        }
    }
}
