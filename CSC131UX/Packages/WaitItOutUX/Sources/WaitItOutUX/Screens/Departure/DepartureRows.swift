import SwiftUI

/// Read-only leave-home rows for a `Form` or `List` section, shared by the Calendar detail
/// sheet, the activity editor, and the Map's next trip. The time is calculated or recommended,
/// never entered: there is no control here apart from Try Again after a failure. Step 0006 adds
/// the estimate's age and the out-of-date time shown while a refresh is in flight.
///
/// A backend recommendation is shown as the backend gave it: the recommended departure, the
/// predicted arrival, the backend's reason, its source and confidence, and its notes. A
/// recommendation kept after a failed refresh is marked out of date and never styled as current.
struct DepartureRows: View {
    let state: DepartureState
    let formatter: OccurrenceFormatter
    /// Instant the missed-target note is judged against.
    let now: Date
    /// Identifier prefix, such as `AccessibilityID.calendarDetailDeparture`.
    let identifierPrefix: String
    /// False when the warning about a passed leave-home time does not apply, such as a series
    /// whose first occurrence the editor shows is already in the past.
    var showsTiming = true
    /// True while leave-home times come from the team backend; only the Try Again hint differs.
    var usesLiveBackend = false
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text(formatter.departureMessage(for: state) ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .message))
        case .refreshing(let stale):
            outOfDateTime(stale, label: formatter.staleDepartureAccessibilityLabel(for: stale))
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text(formatter.departureMessage(for: state) ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .message))
        case .stale(let kept, _):
            outOfDateTime(kept, label: formatter.unrefreshedDepartureAccessibilityLabel(for: kept))
            Label(formatter.departureMessage(for: state) ?? "", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .message))
            retryButton
        case .success(let calculation):
            LabeledContent("Leave home", value: formatter.leaveHomeValueText(for: calculation))
                .font(.body.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(formatter.departureAccessibilityLabel(for: calculation, at: now))
                .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .leaveHome))
            Text(formatter.departureFormulaText(for: calculation))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let reason = formatter.recommendationReasonText(for: calculation, at: now) {
                Text(reason)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .reason))
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                if calculation.isSimulated {
                    DemoBadge(text: "TEST DATA")
                }
                Text(formatter.departureSourceText(for: calculation, at: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .source))
            if let confidence = formatter.recommendationConfidenceText(for: calculation) {
                Text(confidence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .confidence))
            }
            ForEach(Array((calculation.recommendation?.notes ?? []).enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .notes))
            }
            if let note = formatter.departureClockChangeNote(for: calculation) {
                Label(note, systemImage: "clock.arrow.2.circlepath")
                    .font(.footnote)
            }
            if showsTiming, let warning = formatter.departureTimingText(for: calculation, at: now) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(PrototypeColor.demo)
                    .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .status))
            }
        case .unavailable, .error:
            Label(formatter.departureMessage(for: state) ?? "", systemImage: state.isRetryable ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote)
                .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .message))
            if state.isRetryable {
                retryButton
            }
        }
    }

    /// A kept time that is not current: secondary style, marked "out of date", and still
    /// carrying its TEST DATA badge when the value is simulated or fixture data.
    private func outOfDateTime(_ calculation: DepartureCalculation, label: String) -> some View {
        LabeledContent("Leave home") {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                if calculation.isSimulated {
                    DemoBadge(text: "TEST DATA")
                }
                Text("\(formatter.leaveHomeText(for: calculation)), out of date")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .leaveHome))
    }

    @ViewBuilder
    private var retryButton: some View {
        if let onRetry {
            Button("Try Again", action: onRetry)
                .accessibilityIdentifier(AccessibilityID.departure(identifierPrefix, .retry))
                .accessibilityHint(DepartureWording.retryHint(usesLiveBackend: usesLiveBackend))
        }
    }
}

#Preview("Leave home - backend states") {
    let formatter = WaitItOutModel.previewOccurrenceFormatter()
    let preview = WaitItOutModel.previewBackendDepartures()
    List {
        ForEach(Array(preview.states.enumerated()), id: \.offset) { _, item in
            Section(item.title) {
                DepartureRows(
                    state: item.state,
                    formatter: formatter,
                    now: preview.now,
                    identifierPrefix: "preview.departure",
                    usesLiveBackend: true,
                    onRetry: {}
                )
            }
        }
    }
}
