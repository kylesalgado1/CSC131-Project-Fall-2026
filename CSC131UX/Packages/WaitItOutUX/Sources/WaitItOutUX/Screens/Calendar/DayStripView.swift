import SwiftUI

/// What the day strip knows about one day of the visible week.
struct DayStripEntry: Identifiable, Hashable {
    let index: Int
    let day: Range<Date>
    let blockCount: Int
    let arrivalOnlyCount: Int

    var id: Int { index }
    var hasContent: Bool { blockCount > 0 || arrivalOnlyCount > 0 }
}

/// Sunday-to-Saturday strip of tappable day cells. The selected day is filled, today is
/// ringed and tinted, and a dot marks days with activity. At accessibility text sizes the
/// strip scrolls horizontally so every cell keeps a readable label and a full touch target.
struct DayStripView: View {
    let entries: [DayStripEntry]
    let selectedDay: Date
    let today: Date
    let titleFormatter: WeekTitleFormatter
    let occurrenceFormatter: OccurrenceFormatter
    /// Space reserved on the left so cells line up with the week grid's day columns.
    var leadingInset: CGFloat = 0
    let onSelect: (Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(entries) { entry in
                        cell(for: entry)
                            .frame(minWidth: 88)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
        } else {
            HStack(spacing: Spacing.xs) {
                if leadingInset > 0 {
                    Color.clear.frame(width: leadingInset)
                }
                ForEach(entries) { entry in
                    cell(for: entry)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, leadingInset > 0 ? 0 : Spacing.lg)
        }
    }

    private func cell(for entry: DayStripEntry) -> some View {
        let calculator = titleFormatter.calculator
        let isSelected = calculator.isSameDay(entry.day.lowerBound, selectedDay)
        let isToday = calculator.isSameDay(entry.day.lowerBound, today)
        return Button {
            onSelect(entry.index)
        } label: {
            VStack(spacing: Spacing.xs) {
                Text(weekdayText(entry.day.lowerBound))
                    .font(.caption)
                    .foregroundStyle(isToday ? PrototypeColor.today : .secondary)
                Text(dayNumberText(entry.day.lowerBound))
                    .font(.body.weight(isSelected || isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color(.systemBackground) : (isToday ? PrototypeColor.today : .primary))
                    .frame(minWidth: 36, minHeight: 36)
                    .background(isSelected ? PrototypeColor.today : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(isToday ? PrototypeColor.today : .clear, lineWidth: 2))
                Circle()
                    .fill(entry.hasContent ? (isSelected ? PrototypeColor.today : .secondary) : Color.clear)
                    .frame(width: 6, height: 6)
            }
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(titleFormatter.dayLabel(for: entry.day.lowerBound))
        .accessibilityValue(accessibilityValue(for: entry, isToday: isToday))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Shows this day's timeline")
        .accessibilityIdentifier(AccessibilityID.calendarDay(entry.index))
    }

    private func accessibilityValue(for entry: DayStripEntry, isToday: Bool) -> String {
        var parts: [String] = []
        if isToday {
            parts.append("Today")
        }
        parts.append(occurrenceFormatter.daySummary(blockCount: entry.blockCount, arrivalOnlyCount: entry.arrivalOnlyCount))
        return parts.joined(separator: ", ")
    }

    private func weekdayText(_ day: Date) -> String {
        day.formatted(style.weekday(.abbreviated))
    }

    private func dayNumberText(_ day: Date) -> String {
        day.formatted(style.day())
    }

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: titleFormatter.locale, calendar: titleFormatter.calculator.calendar, timeZone: titleFormatter.calculator.timeZone)
    }
}
