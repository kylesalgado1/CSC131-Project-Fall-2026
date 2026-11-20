import SwiftUI

/// The Map's small, plain marker (stage S3) that leave-home times come from the team backend.
/// It sits where `DemoEstimateLabel` sits in the Demo data mode and deliberately looks
/// different: no badge color, because nothing here is simulated by the app. It names the data
/// mode and nothing more, so it stays true whatever the backend answers with: live traffic,
/// typical or historical traffic, a test fixture, or no answer at all. Each recommendation
/// names its own traffic source.
///
/// The text keeps its own width: a navigation bar offers a leading item very little room and
/// would otherwise cut the two words short.
struct LiveDataLabel: View {
    /// The words on screen. They say where the answers come from, never how fresh they are.
    static let title = "Team backend"

    var body: some View {
        Text(Self.title)
            .lineLimit(1)
            .fixedSize()
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(Self.title). Leave-home times come from the team backend, which names its traffic source with each one.")
            .accessibilityIdentifier(AccessibilityID.mapLiveDataLabel)
    }
}
