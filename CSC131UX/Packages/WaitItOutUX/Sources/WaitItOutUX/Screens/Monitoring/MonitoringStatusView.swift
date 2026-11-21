import SwiftUI
import UIKit

/// Server-side trip monitoring as the user sees it (stage S3): the Live counterpart of
/// `ReminderPreviewView`, in the same two places. Settings shows the full form; the Map's trip
/// card shows the compact form while reminders are on. It prints the honest delivery sentence
/// (the server "will try", or the exact obstacle), the server's plan for one trip, and the
/// actions that can help: Try Again after a failed synchronization, Allow Notifications while
/// the system has not asked yet, and Open Settings when notifications were turned off. What is
/// shown is decided by `MonitoringPresentation`; this view only places it.
@MainActor
struct MonitoringStatusView: View {
    let model: WaitItOutModel
    /// `AccessibilityID.settingsMonitoring` or `AccessibilityID.mapMonitoring`.
    let identifierPrefix: String
    var isCompact = false
    /// The occurrence whose server plan is listed, such as the Map card's own trip. Without
    /// one the next monitored trip is listed under its title.
    var trip: ActivityOccurrence?
    /// The instant times are worded against: the minute tick of the Map or of Settings.
    /// Without one (a preview) the injected clock is read when the view draws.
    var now: Date?

    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL

    var body: some View {
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: locale)
        let presentation = model.monitoringPresentation(
            formatter: formatter,
            at: now ?? model.currentDate(),
            isCompact: isCompact,
            trip: trip
        )
        VStack(alignment: .leading, spacing: Spacing.xs) {
            statusLine(presentation)
            ForEach(Array(presentation.details.enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .detail))
            }
            if presentation.offersRetry {
                Button {
                    model.retryReminders()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .retry))
                .accessibilityHint("Synchronizes your trips with the server again")
            }
            if presentation.offersAllowNotifications {
                Button {
                    model.requestNotificationPermission()
                } label: {
                    Label("Allow Notifications", systemImage: "bell.badge")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .allow))
                .accessibilityHint("Shows the system question about notifications for this app")
            }
            if presentation.offersOpenSettings {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .openSettings))
                .accessibilityHint("Opens this app's page in iOS Settings, where notifications are turned on")
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ presentation: MonitoringPresentation) -> some View {
        if presentation.kind == .waiting {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text(presentation.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .status))
        } else {
            Label(presentation.status, systemImage: Self.symbol(for: presentation.kind))
                .font(.footnote)
                .foregroundStyle(Self.isQuiet(presentation.kind) ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.monitoring(identifierPrefix, .status))
        }
    }

    private static func symbol(for kind: MonitoringPresentation.Kind) -> String {
        switch kind {
        case .off, .needsPermission:
            return "bell.slash"
        case .waiting:
            return "hourglass"
        case .paused:
            return "pause.circle"
        case .problem:
            return "exclamationmark.triangle"
        case .active:
            return "bell"
        case .idle:
            return "info.circle"
        }
    }

    /// Off, paused, and nothing-to-do read as secondary text, like the preview's status lines.
    private static func isQuiet(_ kind: MonitoringPresentation.Kind) -> Bool {
        switch kind {
        case .off, .waiting, .paused, .idle:
            return true
        case .problem, .needsPermission, .active:
            return false
        }
    }
}

/// "I've Left" for one monitored trip (stage S3), shared by the Calendar's detail sheet and the
/// Map's trip card: where telling the server stands, and the action while the server is
/// actively monitoring the trip or already sent its time-to-leave alert. Success is shown only
/// after the server answered. The two parts are siblings, so a list shows them as two rows.
struct TripDepartedControl: View {
    let summary: MonitoringSummary
    /// `AccessibilityID.calendarDetailLeft` or `AccessibilityID.mapNextTripLeft`.
    let buttonIdentifier: String
    /// `AccessibilityID.calendarDetailLeftStatus` or `AccessibilityID.mapNextTripLeftStatus`.
    let statusIdentifier: String
    /// True on a card, where the action needs its own outline; false in a list row.
    var isBordered = false
    let onMarkDeparted: () -> Void

    var body: some View {
        if let sentence = summary.departedSentence {
            HStack(spacing: Spacing.sm) {
                if summary.departed == .sending {
                    ProgressView()
                }
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(summary.isDeparted || summary.departed == .sending ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(statusIdentifier)
        }
        if summary.canMarkDeparted {
            if isBordered {
                button.buttonStyle(.bordered)
            } else {
                button
            }
        }
    }

    private var button: some View {
        Button(action: onMarkDeparted) {
            Label(MonitoringText.departedButtonTitle(after: summary.departed), systemImage: "figure.walk.departure")
        }
        .accessibilityIdentifier(buttonIdentifier)
        .accessibilityHint(MonitoringText.departedButtonHint)
    }
}

#Preview("Monitoring - alerts on, sample schedule") {
    Form {
        MonitoringStatusView(model: .previewLive(), identifierPrefix: AccessibilityID.settingsMonitoring)
    }
}

#Preview("Monitoring - notifications turned off") {
    Form {
        MonitoringStatusView(model: .previewLive(permission: .denied), identifierPrefix: AccessibilityID.settingsMonitoring)
    }
}

#Preview("Monitoring - server unreachable") {
    Form {
        MonitoringStatusView(model: .previewLive(failure: .offline), identifierPrefix: AccessibilityID.settingsMonitoring)
    }
}
