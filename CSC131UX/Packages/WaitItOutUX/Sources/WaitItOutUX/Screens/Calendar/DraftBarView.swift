import SwiftUI

/// Bar below the time grid while a block is being adjusted on the calendar. It previews the
/// unsaved times, says when the change applies to a whole weekly series, and offers Cancel,
/// Edit Details, and Save. Nothing is stored until Save.
struct DraftBarView: View {
    let session: ActivityEditSession
    let formatter: OccurrenceFormatter
    let onCancel: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void

    private var draft: ActivityDraft { session.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(draft.hasChanges ? "Unsaved change: \(draft.title)" : "Adjusting \(draft.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if !draft.hasChanges {
                    Text("Drag the block to move it, or drag a handle to change the start or end. Nothing is saved until you tap Save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(formatter.draftSummary(draft))
                    .font(.footnote)
                    .monospacedDigit()
                if let original = draft.original, draft.changesSchedule {
                    Text("Was \(formatter.draftTimeRange(ActivityDraft(editing: original))), \(formatter.draftArrivalText(ActivityDraft(editing: original)).lowercased())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if draft.editsSeries {
                    Text("Saving changes every occurrence of this weekly series.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let failure = session.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(PrototypeColor.demo)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.calendarDraftSummary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    buttons
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    buttons
                }
            }
            .disabled(session.isBusy)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.calendarDraftBar)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Cancel", role: .cancel, action: onCancel)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.calendarDraftCancel)
            .accessibilityHint("Restores the activity as it was")
        Button("Edit Details", action: onEdit)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.calendarDraftEdit)
            .accessibilityHint("Opens the editor with this unsaved change")
        Button("Save", action: onSave)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.calendarDraftSave)
            .accessibilityHint(draft.editsSeries ? "Saves the change for every occurrence in the series" : "Saves the change")
    }
}
