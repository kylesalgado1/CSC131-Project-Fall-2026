import SwiftUI

/// Seven day buttons for weekly repeats, Sunday first. Each is its own accessible button,
/// named after the weekday, with the selected trait while on. At accessibility text sizes the
/// days become a list of toggles so every label stays readable.
struct WeekdayRepeatPicker: View {
    let selection: Set<Weekday>
    let calendar: Calendar
    let onChange: (Weekday, Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ForEach(Weekday.allCases) { day in
                Toggle(day.name(in: calendar), isOn: Binding(
                    get: { selection.contains(day) },
                    set: { onChange(day, $0) }
                ))
                .accessibilityIdentifier(AccessibilityID.editorRepeatDay(day))
            }
        } else {
            HStack(spacing: Spacing.xs) {
                ForEach(Weekday.allCases) { day in
                    dayButton(day)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func dayButton(_ day: Weekday) -> some View {
        let isOn = selection.contains(day)
        return Button {
            onChange(day, !isOn)
        } label: {
            Text(day.shortName(in: calendar))
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? PrototypeColor.today : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(day.name(in: calendar))
        .accessibilityValue(isOn ? "Repeats" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityIdentifier(AccessibilityID.editorRepeatDay(day))
    }
}
