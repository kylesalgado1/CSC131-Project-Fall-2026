import SwiftUI

/// Spacing scale shared by every screen. Values are points; layouts combine them with
/// Dynamic Type-aware text so nothing is sized in fixed text heights.
public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
}

/// Corner radii shared by cards and badges.
public enum CornerRadius {
    public static let card: CGFloat = 12
    public static let badge: CGFloat = 6
}

/// Semantic colors. Everything else uses system semantic colors so light and dark
/// appearance and increased-contrast settings come for free.
public enum PrototypeColor {
    /// Used for every "demo / sample data" marker so simulated content is recognizable.
    public static let demo = Color.orange
    /// Highlight for the current day in the week strip.
    public static let today = Color.accentColor
}

/// Small capsule that marks demo content. Always paired with explanatory text nearby.
struct DemoBadge: View {
    var text: String = "DEMO"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(PrototypeColor.demo.opacity(0.2), in: RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous))
            .foregroundStyle(PrototypeColor.demo)
            .accessibilityLabel("Demo data")
    }
}
