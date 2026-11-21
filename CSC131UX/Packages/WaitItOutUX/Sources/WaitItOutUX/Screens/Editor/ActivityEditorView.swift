import Accessibility
import SwiftUI

/// Compact activity editor, shown as a sheet for Add Activity, drag creation, and Edit. The
/// user sets the activity's start and end first and the ideal campus arrival second; the
/// leave-home time is never an input. Step 0005 shows it as a read-only line under the
/// arrival, recalculated by the model whenever the arrival or destination changes. Every control writes to the model's pending draft and
/// nothing is stored until Save, which validates through `ActivityValidator` and writes once.
/// The sheet cannot be swiped away, so a change always ends with Save or Cancel.
@MainActor
struct ActivityEditorView: View {
    let model: WaitItOutModel

    @Environment(\.locale) private var locale
    @FocusState private var isTitleFocused: Bool
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            if let session = model.editSession {
                editor(session: session)
            } else {
                // The session ended, by Save, Cancel, or Delete, while the sheet animates away.
                Color.clear
            }
        }
        .interactiveDismissDisabled()
        // One container element carries the sheet's identifier; its controls keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.editorSheet)
    }

    private func editor(session: ActivityEditSession) -> some View {
        let draft = session.draft
        let zone = draft.timeZone ?? model.campusTimeZone
        let formatter = OccurrenceFormatter(calculator: WeekCalculator(timeZone: zone, locale: locale), locale: locale)
        return Form {
            if draft.editsSeries {
                Section {
                    Label(seriesNote(for: draft, formatter: formatter), systemImage: "repeat")
                        .font(.footnote)
                        .accessibilityIdentifier(AccessibilityID.editorSeriesNote)
                }
            }
            activitySection(session: session)
            timeSection(session: session, formatter: formatter, zone: zone)
            arrivalSection(session: session, formatter: formatter)
            repeatSection(session: session, formatter: formatter)
            if draft.source == .sample {
                Section {
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        DemoBadge(text: "SAMPLE")
                        Text("This is labeled sample content. It stays labeled after your changes, and Clear sample activities in Settings still removes it.")
                            .font(.footnote)
                    }
                }
            }
            if let failure = session.failureMessage {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PrototypeColor.demo)
                        .accessibilityIdentifier(AccessibilityID.editorFailure)
                }
            }
            if !draft.isNew {
                deleteSection(draft: draft)
            }
        }
        .environment(\.timeZone, zone)
        .disabled(session.isBusy)
        .navigationTitle(navigationTitle(for: draft))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.cancelDraft()
                }
                .disabled(session.isBusy)
                .accessibilityIdentifier(AccessibilityID.editorCancel)
                .accessibilityHint("Discards every change in this editor")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(session.isBusy)
                .accessibilityIdentifier(AccessibilityID.editorSave)
                .accessibilityHint(draft.editsSeries ? "Saves the change for every occurrence in the series" : "Saves the activity")
            }
        }
        .confirmationDialog(deleteQuestion(for: draft), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(deleteTitle(for: draft), role: .destructive) {
                Task { await model.deleteDraftActivity() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(for: draft, formatter: formatter))
        }
    }

    // MARK: Sections

    private func activitySection(session: ActivityEditSession) -> some View {
        Section {
            TextField("Title", text: titleBinding, prompt: Text("For example, CSC 131 lecture"))
                .focused($isTitleFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .accessibilityIdentifier(AccessibilityID.editorTitle)
            EditorIssueRows(issues: session.visibleIssues(for: .title))
            LabeledContent("Destination") {
                HStack(spacing: Spacing.sm) {
                    Text(model.resolvedDestination(session.draft.destination).name)
                    if session.draft.destination.id == model.sampleCampus.destinationID, model.isSamplePlace(.campus) {
                        DemoBadge(text: "SAMPLE")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.editorDestination)
            EditorIssueRows(issues: session.visibleIssues(for: .destination))
        } header: {
            Text("Activity")
        } footer: {
            Text("Every activity goes to the campus set in Settings under Home and campus, and the leave-home time is calculated for the trip from home.")
        }
    }

    private func timeSection(session: ActivityEditSession, formatter: OccurrenceFormatter, zone: TimeZone) -> some View {
        let draft = session.draft
        return Section {
            DatePicker("Starts", selection: startBinding)
                .accessibilityIdentifier(AccessibilityID.editorStart)
            DatePicker("Ends", selection: endBinding)
                .accessibilityIdentifier(AccessibilityID.editorEnd)
            LabeledContent("Duration", value: formatter.durationText(draft.duration))
                .accessibilityIdentifier(AccessibilityID.editorDuration)
            if let note = formatter.endDayNote(start: draft.start, end: draft.end) {
                Label(note, systemImage: "moon.stars")
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.editorEndNote)
            }
            EditorIssueRows(issues: session.visibleIssues(for: .times) + session.visibleIssues(for: .timeZone))
        } header: {
            Text("1. Activity time")
        } footer: {
            Text(timeFooter(for: draft, zone: zone))
        }
    }

    private func arrivalSection(session: ActivityEditSession, formatter: OccurrenceFormatter) -> some View {
        let draft = session.draft
        return Section {
            DatePicker("Arrive by", selection: arrivalBinding)
                .accessibilityIdentifier(AccessibilityID.editorArrival)
            LabeledContent("Lead time", value: formatter.leadText(arrival: draft.idealArrival, start: draft.start))
                .accessibilityIdentifier(AccessibilityID.editorLead)
            if let note = formatter.arrivalDayNote(arrival: draft.idealArrival, start: draft.start) {
                Label(note, systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.editorArrivalNote)
            }
            EditorIssueRows(issues: session.visibleIssues(for: .arrival))
            // With the live backend a series whose first occurrence has passed is previewed
            // through its next one; the note says which arrival the time below is for.
            if let next = model.draftPreviewOccurrence {
                Label(DepartureWording.nextOccurrenceNote(arrival: formatter.reminderTimestamp(next.idealArrival)), systemImage: "calendar")
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.editorDepartureOccurrence)
            }
            DepartureRows(
                state: model.draftDeparture?.state ?? .loading,
                formatter: formatter,
                now: model.currentDate(),
                identifierPrefix: AccessibilityID.editorDeparture,
                showsTiming: draft.start > model.currentDate() || model.draftPreviewOccurrence != nil,
                usesLiveBackend: model.usesLiveBackend,
                onRetry: { model.retryDepartures() }
            )
        } header: {
            Text("2. Ideal campus arrival")
        } footer: {
            Text(arrivalFooter(for: draft))
        }
    }

    private func repeatSection(session: ActivityEditSession, formatter: OccurrenceFormatter) -> some View {
        let draft = session.draft
        return Section {
            Toggle("Repeat weekly", isOn: repeatsBinding)
                .accessibilityIdentifier(AccessibilityID.editorRepeatToggle)
            if let weekdays = draft.repeatWeekdays {
                WeekdayRepeatPicker(selection: weekdays, calendar: formatter.calculator.calendar) { weekday, isOn in
                    model.updateDraft { $0.setRepeat(weekday, isOn: isOn) }
                }
            }
            EditorIssueRows(issues: session.visibleIssues(for: .recurrence))
            if draft.removesRepeats {
                Text("Repeat is off, so saving keeps only the first occurrence, on \(formatter.fullDate(draft.start)). Every later occurrence is removed.")
                    .font(.footnote)
                    .foregroundStyle(PrototypeColor.demo)
            }
        } header: {
            Text("Repeat")
        } footer: {
            Text(repeatFooter(for: draft, formatter: formatter))
        }
    }

    private func deleteSection(draft: ActivityDraft) -> some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label(deleteTitle(for: draft), systemImage: "trash")
            }
            .accessibilityIdentifier(AccessibilityID.editorDelete)
        } footer: {
            if draft.editsSeries {
                Text("Deletes every occurrence of this weekly series. Deleting a single occurrence is not available in this prototype.")
            }
        }
    }

    // MARK: Bindings: each control calls one ActivityDraft operation through the model

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.editSession?.draft.title ?? "" },
            set: { value in model.updateDraft { $0.title = value } }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { model.editSession?.draft.start ?? model.currentDate() },
            set: { value in model.updateDraft { $0.setStart(value) } }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { model.editSession?.draft.end ?? model.currentDate() },
            set: { value in model.updateDraft { $0.setEnd(value) } }
        )
    }

    private var arrivalBinding: Binding<Date> {
        Binding(
            get: { model.editSession?.draft.idealArrival ?? model.currentDate() },
            set: { value in model.updateDraft { $0.setArrival(value) } }
        )
    }

    private var repeatsBinding: Binding<Bool> {
        Binding(
            get: { model.editSession?.draft.isRecurring ?? false },
            set: { value in model.updateDraft { $0.setRepeats(value) } }
        )
    }

    // MARK: Actions and text

    @MainActor
    private func save() async {
        let saved = await model.saveDraft()
        guard !saved, let session = model.editSession else { return }
        if let failure = session.failureMessage {
            AccessibilityNotification.Announcement(failure).post()
            return
        }
        let issues = session.visibleIssues
        guard !issues.isEmpty else { return }
        if issues.contains(where: { $0.field == .title }) {
            isTitleFocused = true
        }
        AccessibilityNotification.Announcement("Not saved. " + issues.map(\.message).joined(separator: " ")).post()
    }

    private func navigationTitle(for draft: ActivityDraft) -> String {
        if draft.isNew { return "New Activity" }
        return draft.editsSeries ? "Edit Series" : "Edit Activity"
    }

    private func seriesNote(for draft: ActivityDraft, formatter: OccurrenceFormatter) -> String {
        let days = draft.original?.repeatWeekdays.map { Weekday.summary(of: $0, in: formatter.calculator.calendar) } ?? ""
        return "Editing the whole weekly series: every \(days). Saving changes every occurrence. A single occurrence cannot be changed on its own in this prototype."
    }

    private func timeFooter(for draft: ActivityDraft, zone: TimeZone) -> String {
        var text = draft.isRecurring
            ? "For a weekly series, Starts is the first occurrence. Changing Starts moves Ends and the ideal arrival with it."
            : "Changing Starts moves Ends and the ideal arrival with it, so the length and the arrival lead stay the same."
        if zone.identifier != model.weekCalculator.timeZone.identifier {
            let name = zone.localizedName(for: .generic, locale: locale) ?? zone.identifier
            text += " Times are in \(name), the campus time zone."
        }
        return text
    }

    private func arrivalFooter(for draft: ActivityDraft) -> String {
        DepartureWording.editorArrivalFooter(usesLiveBackend: model.usesLiveBackend, isRecurring: draft.isRecurring)
    }

    private func repeatFooter(for draft: ActivityDraft, formatter: OccurrenceFormatter) -> String {
        guard draft.isRecurring, let weekday = draft.startWeekday else {
            return "A one-time activity happens only on the date it starts."
        }
        return "Repeats every week on the chosen days from \(formatter.fullDate(draft.start)), with no end date. The days must include \(weekday.name(in: formatter.calculator.calendar)), the day the series starts."
    }

    private func deleteTitle(for draft: ActivityDraft) -> String {
        draft.editsSeries ? "Delete Series" : "Delete Activity"
    }

    private func deleteQuestion(for draft: ActivityDraft) -> String {
        draft.editsSeries ? "Delete the whole series?" : "Delete this activity?"
    }

    private func deleteMessage(for draft: ActivityDraft, formatter: OccurrenceFormatter) -> String {
        guard let original = draft.original else { return "" }
        let title = "\u{201C}\(original.title)\u{201D}"
        if let weekdays = original.repeatWeekdays {
            return "Every \(Weekday.summary(of: weekdays, in: formatter.calculator.calendar)) occurrence of \(title) is removed. Deleting a single occurrence is not available in this prototype."
        }
        return "\(title) on \(formatter.fullDate(original.start)) is removed."
    }
}

/// Inline validation messages for one editor field, worded by `ActivityValidator`.
struct EditorIssueRows: View {
    let issues: [ActivityValidationIssue]

    var body: some View {
        ForEach(issues, id: \.self) { issue in
            Label(issue.message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(issue.message)
                .accessibilityIdentifier(AccessibilityID.editorIssue)
        }
    }
}

#Preview("Editor - new activity") {
    ActivityEditorView(model: .previewEditingNewActivity())
}

#Preview("Editor - sample series") {
    ActivityEditorView(model: .previewEditingSampleSeries())
}
