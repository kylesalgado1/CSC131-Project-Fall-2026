import SwiftUI

/// The leave-home reminder preview (step 0007): when the next reminder is due, its title and
/// message, or why no preview can be created, always followed by the adapter's delivery
/// disclosure ("Preview only - no system notification will be sent." for the prototype).
/// Read-only apart from Try Again after an adapter failure. Settings shows the full preview;
/// the Map's trip card shows the compact form while reminders are on.
@MainActor
struct ReminderPreviewView: View {
    let model: WaitItOutModel
    /// `AccessibilityID.settingsReminderPreview` or `AccessibilityID.mapReminderPreview`.
    let identifierPrefix: String
    var isCompact = false

    @Environment(\.locale) private var locale

    var body: some View {
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: locale)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            content(formatter: formatter)
            Text(model.reminderDelivery.disclosure)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PrototypeColor.demo)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .disclosure))
        }
    }

    @ViewBuilder
    private func content(formatter: OccurrenceFormatter) -> some View {
        switch model.reminderPreview {
        case .off:
            status("Leave-home reminders are off. Turn them on to preview the next one.", systemImage: "bell.slash")
        case .paused:
            status("Reminder previews are paused because saved activities could not be read. Nothing was changed.", systemImage: "pause.circle")
        case .updating:
            status("Updating reminder previews\u{2026}", systemImage: "hourglass")
        case .failed(let isEnabled):
            status(failureText(isEnabled: isEnabled), systemImage: "exclamationmark.triangle")
            Button {
                model.retryReminders()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .retry))
            .accessibilityHint("Updates the reminder previews again")
        case .next(let reminder, let laterCount, let isUpdating, let skippedTrip, let skippedGap):
            if let skippedGap {
                status(formatter.reminderGapText(skippedGap, trip: skippedTrip), systemImage: "info.circle")
            }
            Label("Next reminder \(formatter.reminderTimestamp(reminder.fireDate))", systemImage: "bell")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .time))
            Text(reminder.title)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .title))
            if !isCompact {
                Text(reminder.message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .message))
            }
            if isUpdating {
                status("Out of date: updating with the new commute estimate\u{2026}", systemImage: "hourglass")
            }
            if laterCount > 0 && !isCompact {
                Text("\(CountPhrase.make(laterCount, singular: "more reminder preview", plural: "more reminder previews")) in the next \(DepartureHorizon.lookaheadDays) days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let trip, let gap):
            status(formatter.reminderGapText(gap, trip: trip), systemImage: "info.circle")
        }
    }

    private func failureText(isEnabled: Bool) -> String {
        let cause = model.simulatesReminderFailure ? " (simulated reminder failure)" : ""
        return isEnabled
            ? "Reminder previews could not be updated\(cause). Earlier previews may be out of date."
            : "Reminders are off, but earlier previews could not be removed\(cause)."
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.reminder(identifierPrefix, .status))
    }
}

#Preview("Reminder preview - on, sample schedule") {
    Form {
        ReminderPreviewView(model: .previewWithReminders(), identifierPrefix: AccessibilityID.settingsReminderPreview)
    }
}

#Preview("Reminder preview - simulated failure") {
    Form {
        ReminderPreviewView(model: .previewWithReminders(simulatesFailure: true), identifierPrefix: AccessibilityID.settingsReminderPreview)
    }
}
