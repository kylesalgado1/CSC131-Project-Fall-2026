import Foundation

/// Text for leave-home reminder previews (step 0007). Pure, like the rest of the formatter.
extension OccurrenceFormatter {
    /// "Time to leave for Sample morning class".
    public func reminderTitle(for occurrence: ActivityOccurrence) -> String {
        "Time to leave for \(occurrence.activity.title)"
    }

    /// "Leave home at 7:15 AM to reach Sample campus by your ideal arrival, 8:15 AM. Travel
    /// time 1 hour (simulated test estimate, not live traffic)." For a backend recommendation
    /// the travel-time formula is not claimed; the sentence ends with the backend's source:
    /// "... by your ideal arrival, 8:15 AM. Live traffic (TomTom) via the team backend."
    public func reminderMessage(for calculation: DepartureCalculation, destinationName: String) -> String {
        if let recommendation = calculation.recommendation {
            return "Leave home at \(leaveHomeText(for: calculation)) to reach \(destinationName) by your ideal arrival, \(clockTime(calculation.idealArrival)). \(recommendation.source.label)."
        }
        let source = calculation.isSimulated ? "simulated test estimate, not live traffic" : calculation.sourceLabel
        return "Leave home at \(leaveHomeText(for: calculation)) to reach \(destinationName) by your ideal arrival, \(clockTime(calculation.idealArrival)). Travel time \(durationText(calculation.travelTime.seconds)) (\(source))."
    }

    /// When a reminder is due: "Mon, Nov 2, 7:15 AM".
    public func reminderTimestamp(_ date: Date) -> String {
        Date.FormatStyle(locale: locale, calendar: calculator.calendar, timeZone: calculator.timeZone)
            .weekday(.abbreviated)
            .month(.abbreviated)
            .day()
            .hour()
            .minute()
            .format(date)
    }

    /// Why no reminder preview exists for `trip`, in one sentence.
    public func reminderGapText(_ gap: ReminderGap, trip: ActivityOccurrence?) -> String {
        let name = trip.map { "\($0.activity.title) on \(reminderTimestamp($0.start))" } ?? "the next trip"
        switch gap {
        case .noUpcomingTrips:
            return "No reminder to preview: nothing saved starts in the next \(DepartureHorizon.lookaheadDays) days."
        case .waitingForEstimate:
            return "Waiting for the commute estimate for \(name) before its reminder preview can be created."
        case .estimateUnavailable(let reason):
            switch reason {
            case .noEstimate(let message):
                return "No reminder preview for \(name): the commute provider gave no estimate, so there is no leave-home time. \(message)"
            case .noDestination:
                return "No reminder preview for \(name): it has no usable destination, so there is no leave-home time."
            case .activityEnded, .beyondHorizon, .unsavedChanges, .notYetPlannable:
                return "No reminder preview for \(name): there is no leave-home time for it yet."
            }
        case .estimateFailed:
            return "No reminder preview for \(name): its commute estimate failed. Use Try Again on the trip to ask again."
        case .leaveHomePassed(let leaveHome):
            return "No reminder for \(name): its leave-home time, \(clockTime(leaveHome)), has already passed."
        }
    }
}
