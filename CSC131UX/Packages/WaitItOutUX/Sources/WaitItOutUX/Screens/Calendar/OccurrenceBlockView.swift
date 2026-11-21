import SwiftUI

/// One activity block on the time grid, sized by the activity's duration. The day column
/// attaches the tap (details), press-and-hold (adjust), and VoiceOver actions. The amount of
/// text adapts to the block's height so short activities stay legible, and arrows mark blocks
/// that continue from or into a neighboring day. A pending calendar draft gets a stronger tint
/// and a dashed border so the unsaved change is obvious.
struct OccurrenceBlockView: View {
    let block: DaySchedule.Block
    let day: Range<Date>
    let formatter: OccurrenceFormatter
    var isDraft: Bool = false

    private var occurrence: ActivityOccurrence { block.occurrence }
    private var tint: Color { occurrence.isSample ? PrototypeColor.demo : PrototypeColor.today }
    private var detail: BlockDetail { BlockDetail.resolve(height: block.frame.height) }

    var body: some View {
        content
            .padding(.leading, Spacing.sm + 3)
            .padding(.trailing, Spacing.xs)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint.opacity(isDraft ? 0.3 : 0.18), in: RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .padding(.leading, 2)
            }
            .overlay {
                if isDraft {
                    RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous)
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .overlay(alignment: .topTrailing) {
                if block.frame.isClippedAtStart {
                    continuationArrow("arrow.up.to.line")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if block.frame.isClippedAtEnd {
                    continuationArrow("arrow.down.to.line")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isDraft ? "Unsaved change, " + formatter.accessibilityLabel(for: occurrence, on: day) : formatter.accessibilityLabel(for: occurrence, on: day))
            .accessibilityHint(isDraft ? "Opens the unsaved change in the editor" : "Shows details")
            .accessibilityIdentifier(AccessibilityID.calendarOccurrenceBlock)
    }

    @ViewBuilder
    private var content: some View {
        switch detail {
        case .compact:
            titleLine(lineLimit: 1)
        case .titleAndTime:
            VStack(alignment: .leading, spacing: 1) {
                titleLine(lineLimit: 1)
                timeLine
            }
        case .full:
            VStack(alignment: .leading, spacing: 2) {
                titleLine(lineLimit: 2)
                timeLine
                Text(formatter.arrivalText(for: occurrence, on: day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if occurrence.isSample {
                    DemoBadge(text: "SAMPLE")
                }
            }
        }
    }

    private func titleLine(lineLimit: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(occurrence.activity.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.85)
            if occurrence.isRecurring {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timeLine: some View {
        Text(formatter.timeRange(for: occurrence, on: day))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func continuationArrow(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(3)
    }
}

/// Ideal-arrival marker: a small capsule at the arrival instant with a dashed leader down to
/// the activity block, or to the bottom of the day when the activity starts the next day.
struct ArrivalMarkerView: View {
    let marker: DaySchedule.ArrivalMarker
    let day: Range<Date>
    let formatter: OccurrenceFormatter

    private var tint: Color { marker.occurrence.isSample ? PrototypeColor.demo : PrototypeColor.today }

    var body: some View {
        let leaderHeight = max(0, marker.leaderEndOffset - marker.offset)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 4, y: 0))
                path.addLine(to: CGPoint(x: 4, y: leaderHeight))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: max(leaderHeight, 1))
            HStack(spacing: Spacing.xs) {
                Image(systemName: "figure.walk")
                    .font(.caption2)
                Text(formatter.arrivalMarkerText(for: marker.occurrence, on: day))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 2)
            .background(Color(.systemBackground).opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .offset(x: 8, y: -9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatter.arrivalMarkerAccessibilityLabel(for: marker.occurrence, on: day))
        .accessibilityIdentifier(AccessibilityID.calendarArrivalMarker)
    }
}

/// Horizontal line at the current time, drawn only on today's column.
struct CurrentTimeLineView: View {
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(Color.red)
                .frame(height: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(AccessibilityID.calendarCurrentTimeLine)
    }
}
