import Foundation

/// Sentences that explain where a leave-home time comes from. They depend on the data mode:
/// the demo calculates ideal arrival minus a simulated commute; with the live backend the team
/// backend decides. Pure, so both wordings are testable; the demo wording is the prototype's
/// original text, unchanged.
public enum DepartureWording {
    /// Footer of the detail sheet's "Leave home" section.
    public static func detailFooter(usesLiveBackend: Bool) -> String {
        guard usesLiveBackend else {
            return "Calculated automatically for the trip from home: ideal arrival minus the commute estimate. Nothing else is subtracted, and it cannot be edited. Change the ideal arrival, home and campus, or the Settings Prototype testing values to change it."
        }
        return "Recommended by the team backend from traffic for the trip from home to your ideal arrival; it cannot be edited. When the backend plans a later departure it keeps its own margin of at least 10 minutes before the ideal arrival, and the app adds none. Change the ideal arrival or home and campus to change it."
    }

    /// Footer of the editor's "Ideal campus arrival" section.
    public static func editorArrivalFooter(usesLiveBackend: Bool, isRecurring: Bool) -> String {
        guard usesLiveBackend else {
            var text = "Set this after the activity time. It already includes any study, parking, or buffer time. Leave home is calculated from it automatically, ideal arrival minus the commute, and cannot be edited."
            if isRecurring {
                text += " The same calculation applies to every occurrence of the series."
            }
            return text
        }
        var text = "Set this after the activity time. It already includes any study, parking, or buffer time. The leave-home time is the team backend's traffic-based recommendation for this arrival and cannot be edited; the app adds no margin of its own."
        if isRecurring {
            text += " Every occurrence of the series gets its own recommendation."
        }
        return text
    }

    /// The editor's note above a leave-home preview that is not for the first occurrence the
    /// editor shows: with the live backend, a repeating activity whose first occurrence has
    /// passed is previewed through its next one. `arrival` is that occurrence's ideal arrival
    /// with its day, such as "Mon, Nov 2, 8:15 AM".
    public static func nextOccurrenceNote(arrival: String) -> String {
        "The first occurrence has passed, so the leave-home time below is for the next one: arrive by \(arrival)."
    }

    /// VoiceOver hint of Try Again under a failed leave-home time.
    public static func retryHint(usesLiveBackend: Bool) -> String {
        usesLiveBackend
            ? "Asks the team backend for the recommendation again"
            : "Asks the commute provider for the estimate again"
    }
}
