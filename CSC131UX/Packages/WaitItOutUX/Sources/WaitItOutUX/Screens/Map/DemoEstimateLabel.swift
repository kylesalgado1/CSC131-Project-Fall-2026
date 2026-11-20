import SwiftUI

/// The Map's always-visible, unobtrusive marker (step 0006) that every estimate on the tab is
/// simulated. Names the Prototype testing scenario when it is not Normal.
struct DemoEstimateLabel: View {
    let scenario: TestCommuteProvider.Scenario

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "testtube.2")
                .accessibilityHidden(true)
            Text(scenario == .normal ? "Demo estimate" : "Demo estimate \u{00B7} \(scenario.title)")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(PrototypeColor.demo.opacity(0.15), in: Capsule())
        .foregroundStyle(PrototypeColor.demo)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Demo estimate, \(scenario.title) scenario. Commute times are simulated, not live traffic.")
        .accessibilityIdentifier(AccessibilityID.mapDemoEstimateLabel)
    }
}
