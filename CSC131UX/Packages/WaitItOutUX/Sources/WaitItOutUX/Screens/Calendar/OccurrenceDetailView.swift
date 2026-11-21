import SwiftUI

/// Details of one occurrence, shown as a sheet from the calendar, with Edit and Delete. For a
/// weekly series both act on the whole series and say so; single-occurrence exceptions are not
/// part of the prototype. Deleting asks for confirmation. The leave-home time (step 0005) is a
/// read-only section calculated from the ideal arrival; there is no departure control. While
/// the server monitors the trip (stage S3, Live data mode with reminders on) a "Leave-home
/// alerts" section follows: the honest delivery sentence, the server's plan, and "I've Left".
@MainActor
struct OccurrenceDetailView: View {
    let occurrence: ActivityOccurrence
    let formatter: OccurrenceFormatter
    /// Where the occurrence takes place: the campus currently set in Settings for campus
    /// activities (step 0006).
    let destinationName: String
    /// The occurrence's current leave-home state and the instant to judge it against. Read in
    /// `body`, so the sheet updates as soon as an estimate finishes.
    let departure: @MainActor () -> (state: DepartureState, now: Date)
    /// Try Again after a provider error.
    let onRetryDeparture: () -> Void
    /// True while leave-home times come from the team backend, which changes the explanation
    /// under the leave-home section.
    var usesLiveBackend: Bool = false
    /// What the server reports about this trip, read in `body` so the sheet follows the
    /// server; `nil` when the trip is not monitored, which is always the case in the demo.
    var monitoring: @MainActor () -> MonitoringSummary? = { nil }
    /// "I've Left": tells the server the user has left for this trip.
    var onMarkDeparted: () -> Void = {}
    /// True while another unsaved change is pending; editing and deleting wait for it.
    var isEditingBlocked: Bool = false
    let onEdit: () -> Void
    /// Deletes the activity; returns `false` when storage failed.
    let onDelete: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteFailed = false

    private var activity: Activity { occurrence.activity }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Date", value: formatter.fullDate(occurrence.start))
                    LabeledContent("Time", value: formatter.timeRange(for: occurrence, on: occurrence.start..<occurrence.end))
                    LabeledContent("Duration", value: formatter.durationText(occurrence.end.timeIntervalSince(occurrence.start)))
                    if !formatter.calculator.isSameDay(occurrence.start, occurrence.end.addingTimeInterval(-1)) {
                        Text("Ends on \(formatter.fullDate(occurrence.end))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Activity")
                }

                Section {
                    LabeledContent("Ideal arrival", value: formatter.detailArrivalText(for: occurrence))
                    LabeledContent("Lead time", value: formatter.arrivalLeadText(for: occurrence))
                } header: {
                    Text("Campus arrival")
                } footer: {
                    Text("Ideal arrival already includes any study, parking, or buffer time you planned.")
                }

                departureSection

                monitoringSection

                Section {
                    LabeledContent("Repeats", value: formatter.recurrenceText(for: activity).map { $0.replacingOccurrences(of: "Repeats ", with: "") } ?? "Does not repeat")
                    LabeledContent("Destination", value: destinationName)
                    LabeledContent("Time zone", value: zoneDescription)
                } header: {
                    Text("Schedule")
                } footer: {
                    if let note = formatter.timeZoneNote(for: activity) {
                        Text(note)
                    }
                }

                if occurrence.isSample {
                    Section {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            DemoBadge(text: "SAMPLE")
                            Text("This is labeled sample content loaded from Settings. It can be cleared there at any time.")
                                .font(.footnote)
                        }
                    }
                }

                Section {
                    Button {
                        onEdit()
                    } label: {
                        Label(activity.isRecurring ? "Edit Series" : "Edit Activity", systemImage: "pencil")
                    }
                    .disabled(isEditingBlocked || isDeleting)
                    .accessibilityIdentifier(AccessibilityID.calendarDetailEdit)
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label(deleteTitle, systemImage: "trash")
                    }
                    .disabled(isEditingBlocked || isDeleting)
                    .accessibilityIdentifier(AccessibilityID.calendarDetailDelete)
                    if deleteFailed {
                        Label("The activity could not be deleted. Nothing changed.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(PrototypeColor.demo)
                            .accessibilityIdentifier(AccessibilityID.calendarDetailError)
                    }
                } footer: {
                    if isEditingBlocked {
                        Text("Save or cancel the unsaved change on the calendar first.")
                    } else if activity.isRecurring {
                        Text("This is one occurrence of a weekly series. Editing or deleting applies to every occurrence; a single occurrence cannot be changed on its own in this prototype.")
                    }
                }
            }
            .confirmationDialog(activity.isRecurring ? "Delete the whole series?" : "Delete this activity?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(deleteTitle, role: .destructive) {
                    Task {
                        isDeleting = true
                        let deleted = await onDelete()
                        isDeleting = false
                        deleteFailed = !deleted
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .navigationTitle(activity.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.calendarDetailDone)
                }
            }
        }
        // One container element carries the sheet's identifier; its controls keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.calendarDetailSheet)
    }

    private var departureSection: some View {
        let current = departure()
        return Section {
            DepartureRows(
                state: current.state,
                formatter: formatter,
                now: current.now,
                identifierPrefix: AccessibilityID.calendarDetailDeparture,
                usesLiveBackend: usesLiveBackend,
                onRetry: onRetryDeparture
            )
        } header: {
            Text("Leave home")
        } footer: {
            Text(DepartureWording.detailFooter(usesLiveBackend: usesLiveBackend))
        }
    }

    /// The server's monitoring of this trip. Absent unless the server monitors it.
    @ViewBuilder
    private var monitoringSection: some View {
        if let summary = monitoring() {
            Section {
                ForEach(Array(formatter.tripMonitoringSentences(for: summary, at: departure().now).enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(.footnote)
                        .accessibilityIdentifier(AccessibilityID.calendarDetailMonitoring)
                }
                TripDepartedControl(
                    summary: summary,
                    buttonIdentifier: AccessibilityID.calendarDetailLeft,
                    statusIdentifier: AccessibilityID.calendarDetailLeftStatus,
                    onMarkDeparted: onMarkDeparted
                )
            } header: {
                Text("Leave-home alerts")
            } footer: {
                if summary.canMarkDeparted {
                    Text(MonitoringText.departedFooter)
                }
            }
        }
    }

    private var deleteTitle: String {
        activity.isRecurring ? "Delete Series" : "Delete Activity"
    }

    private var deleteMessage: String {
        let title = "\u{201C}\(activity.title)\u{201D}"
        if let weekdays = activity.repeatWeekdays {
            return "Every \(Weekday.summary(of: weekdays, in: formatter.calculator.calendar)) occurrence of \(title) is removed. Deleting a single occurrence is not available in this prototype."
        }
        return "\(title) on \(formatter.fullDate(occurrence.start)) is removed."
    }

    private var zoneDescription: String {
        guard let zone = activity.timeZone else { return activity.timeZoneIdentifier }
        return zone.localizedName(for: .generic, locale: formatter.locale) ?? zone.identifier
    }
}

#Preview("Detail - sample class") {
    let occurrences = OccurrenceExpander.occurrences(
        of: WaitItOutModel.previewSampleActivities(),
        in: WaitItOutModel.previewWeek().range
    )
    if let first = occurrences.first {
        OccurrenceDetailView(
            occurrence: first,
            formatter: WaitItOutModel.previewOccurrenceFormatter(),
            destinationName: first.activity.destination.name,
            departure: { WaitItOutModel.previewDeparture(for: first) },
            onRetryDeparture: {},
            onEdit: {},
            onDelete: { false }
        )
    } else {
        Text("No preview occurrence")
    }
}
