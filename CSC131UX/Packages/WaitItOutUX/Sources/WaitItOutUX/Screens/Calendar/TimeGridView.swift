import SwiftUI

/// What the time grid may do with touches, supplied by the Calendar screen. Views only report
/// points and occurrences; `GridDrag` turns them into snapped times and the model holds the draft.
struct GridEditing {
    /// The pending calendar draft, drawn dashed with resize handles, or `nil`.
    var draft: ActivityDraft?
    /// Press and drag on empty space creates an activity. Off while any change is pending.
    var allowsCreation: Bool
    /// Press and hold on a block adjusts it. Off while another change is pending or saving.
    var allowsAdjusting: Bool
    /// Zone whose wall clock gestures snap to: the calendar's zone.
    var timeZone: TimeZone
    var select: (ActivityOccurrence) -> Void
    var edit: (ActivityOccurrence) -> Void
    var create: (Range<Date>) -> Void
    /// Starts adjusting the occurrence's activity; `false` when that is not possible now.
    var pickUp: (ActivityOccurrence) -> Bool
    var currentDraft: () -> ActivityDraft?
    var apply: (ActivityDraft) -> Void
    var openDraft: () -> Void
}

/// Vertical time grid: an hour gutter on the left and one `DayColumnView` per schedule. The
/// selected-day layout passes one schedule; the full-week layout passes seven. The gutter
/// follows `gutterLayout`; a column with a different number of rows (the 23- or 25-hour
/// transition day in the seven-column layout) labels its own rows instead. The scroll
/// position is an hour row index owned by the caller so it survives tab switches. While a
/// column reports a creation, move, or resize gesture, the grid stops scrolling, so the
/// timeline cannot slide under the finger during the drag.
struct TimeGridView: View {
    let schedules: [DaySchedule]
    /// Layout whose hour rows label the gutter and define the scroll anchors.
    let gutterLayout: DayTimelineLayout
    let selectedDay: Date
    let now: Date
    let formatter: OccurrenceFormatter
    let titleFormatter: WeekTitleFormatter
    @Binding var scrollHour: Int?
    let editing: GridEditing

    /// Days whose column has a gesture in progress. Scrolling resumes when it is empty again.
    @State private var daysWithActiveGesture: Set<Date> = []

    private var calculator: WeekCalculator { formatter.calculator }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                hourGutter
                ForEach(schedules, id: \.day.lowerBound) { schedule in
                    DayColumnView(
                        schedule: schedule,
                        isSelected: calculator.isSameDay(schedule.day.lowerBound, selectedDay),
                        now: schedule.day.contains(now) ? now : nil,
                        dayLabel: titleFormatter.dayLabel(for: schedule.day.lowerBound),
                        formatter: formatter,
                        editing: editing,
                        labelsOwnHours: schedule.layout.rowsDiffer(from: gutterLayout),
                        onGestureActivity: { isActive in
                            setGestureActivity(isActive, on: schedule.day.lowerBound)
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .scrollDisabled(!daysWithActiveGesture.isEmpty)
        .scrollPosition(id: $scrollHour, anchor: .top)
        .onAppear {
            if scrollHour == nil {
                let selected = schedules.first { calculator.isSameDay($0.day.lowerBound, selectedDay) } ?? schedules.first
                scrollHour = selected?.suggestedScrollHour(currentTime: now) ?? 8
            }
        }
        .accessibilityIdentifier(AccessibilityID.calendarTimeGrid)
    }

    private func setGestureActivity(_ isActive: Bool, on day: Date) {
        if isActive {
            daysWithActiveGesture.insert(day)
        } else {
            daysWithActiveGesture.remove(day)
        }
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(gutterLayout.hourMarks, id: \.index) { mark in
                Text(mark.index == 0 ? "" : formatter.hourLabel(for: mark.instant))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, Spacing.xs)
                    .frame(width: CalendarLayoutMode.timeGutterWidth, height: gutterLayout.hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
                    .id(mark.index)
            }
        }
        .scrollTargetLayout()
        .accessibilityHidden(true)
    }
}

/// One day's column: hour gridlines, the selected or today tint, duration-sized activity
/// blocks laid out side by side when they overlap, ideal-arrival markers, the current time
/// line when the day is today, its own hour labels when the shared gutter cannot describe
/// its rows (`labelsOwnHours`), and the editing gestures of step 0004:
///
/// - Press and hold empty space, then drag, to create an activity. The hold lets ordinary
///   swipes keep scrolling the grid; drags shorter than `GridDrag.minimumDistance` create nothing.
/// - Press and hold a block to adjust it, and keep dragging to move it.
/// - Drag the handles of the block being adjusted to change its start or end. VoiceOver users
///   swipe up or down on a handle instead, and every change also has a picker in the editor.
///
/// From the moment a hold succeeds or a handle is touched until the gesture ends, the column
/// reports itself busy through `onGestureActivity`, and the grid stops scrolling meanwhile.
struct DayColumnView: View {
    let schedule: DaySchedule
    let isSelected: Bool
    /// The current instant when this day is today, otherwise `nil`.
    let now: Date?
    let dayLabel: String
    let formatter: OccurrenceFormatter
    let editing: GridEditing
    /// True when this day's hour rows differ from the shared gutter's, which happens for the
    /// 23- or 25-hour transition day in the seven-column layout. The column then labels its own
    /// rows in a margin on its left, and blocks, markers, and previews start after the margin.
    var labelsOwnHours: Bool = false
    /// Called with `true` when one of this column's gestures takes over the touch and with
    /// `false` when it ends, is cancelled, or the column disappears.
    var onGestureActivity: (Bool) -> Void = { _ in }

    /// Gesture locations are measured in the column, so a block moving under the finger never
    /// changes the reference frame of its own drag.
    static let space = NamedCoordinateSpace.named("WaitItOutDayColumn")
    /// How long a press must last before it creates or picks up instead of scrolling.
    static let pressDuration: Double = 0.35
    /// Width of the label margin a column reserves when it labels its own rows.
    static let ownHourLabelWidth: CGFloat = 40

    private struct CreationTouch {
        let startY: CGFloat
        let currentY: CGFloat
    }

    /// The occurrence as it was when a block drag began, plus what the drag changes. Drags are
    /// computed from this snapshot, never from the moving block, so they do not accumulate.
    private struct ActiveDrag {
        let kind: GridDragKind
        let occurrence: ActivityOccurrence
    }

    @GestureState private var creation: CreationTouch? = nil
    /// True once a press on free time has been held long enough to create, until it ends.
    @GestureState private var isHoldingFreeTime = false
    @GestureState private var isDraggingBlock = false
    @State private var activeDrag: ActiveDrag?

    /// True while a creation, move, or resize gesture of this column owns the touch.
    private var hasActiveGesture: Bool {
        isHoldingFreeTime || isDraggingBlock
    }

    private let horizontalInset: CGFloat = 2
    private let columnGap: CGFloat = 2

    /// Where blocks, markers, and previews start: after the label margin when the column
    /// labels its own rows, otherwise the usual inset.
    private var leadingInset: CGFloat {
        labelsOwnHours ? Self.ownHourLabelWidth : horizontalInset
    }

    private var gridDrag: GridDrag {
        GridDrag(layout: schedule.layout, timeZone: editing.timeZone)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usableWidth = max(0, width - leadingInset - horizontalInset)
            ZStack(alignment: .topLeading) {
                if isSelected || now != nil {
                    Rectangle()
                        .fill(PrototypeColor.today.opacity(now != nil ? 0.07 : 0.04))
                        .allowsHitTesting(false)
                }
                gridlines(width: width)
                    .allowsHitTesting(false)
                if labelsOwnHours {
                    ownHourLabels
                }
                creationSurface
                ForEach(Array(DraftPreview.originalFrames(for: editing.draft, layout: schedule.layout).enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous)
                        .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: usableWidth, height: frame.height)
                        .offset(x: leadingInset, y: frame.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ForEach(schedule.blocks) { block in
                    blockView(block, usableWidth: usableWidth)
                }
                ForEach(schedule.arrivalMarkers) { marker in
                    ArrivalMarkerView(marker: marker, day: schedule.day, formatter: formatter)
                        .frame(width: max(24, marker.placement.widthFraction * usableWidth - columnGap), alignment: .topLeading)
                        .offset(x: leadingInset + marker.placement.leadingFraction * usableWidth, y: marker.offset)
                        .allowsHitTesting(false)
                }
                if let creation, let interval = gridDrag.creationInterval(fromOffset: creation.startY, toOffset: creation.currentY),
                   let frame = schedule.layout.frame(for: interval) {
                    creationPreview(interval: interval, frame: frame, width: usableWidth)
                }
                if let now {
                    CurrentTimeLineView(label: formatter.currentTimeLabel(for: now))
                        .frame(width: width)
                        .offset(x: -4, y: schedule.layout.offset(for: now) - 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: schedule.layout.height, alignment: .topLeading)
            .coordinateSpace(Self.space)
        }
        .frame(height: schedule.layout.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(dayLabel), \(formatter.daySummary(blockCount: schedule.blocks.count, arrivalOnlyCount: schedule.arrivalOnlyMarkers.count))")
        .onChange(of: isDraggingBlock) { _, isActive in
            if !isActive {
                activeDrag = nil
            }
        }
        .onChange(of: hasActiveGesture) { _, isActive in
            onGestureActivity(isActive)
        }
        .onDisappear {
            onGestureActivity(false)
        }
    }

    // MARK: Creation

    /// Empty grid space. Blocks sit above it, so only touches on free time reach it.
    private var creationSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(creationGesture, including: editing.allowsCreation ? .all : .subviews)
            .accessibilityHidden(true)
    }

    private var creationGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.pressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: Self.space))
            .updating($isHoldingFreeTime) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .updating($creation) { value, state, _ in
                if case .second(true, let drag?) = value {
                    state = CreationTouch(startY: drag.startLocation.y, currentY: drag.location.y)
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let interval = gridDrag.creationInterval(fromOffset: drag.startLocation.y, toOffset: drag.location.y) else {
                    return
                }
                editing.create(interval)
            }
    }

    private func creationPreview(interval: Range<Date>, frame: DayTimelineLayout.BlockFrame, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous)
            .fill(PrototypeColor.today.opacity(0.15))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous)
                    .strokeBorder(PrototypeColor.today, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            .overlay(alignment: .topLeading) {
                Text(formatter.timeRangeText(interval))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(Spacing.xs)
            }
            .frame(width: width, height: frame.height)
            .offset(x: leadingInset, y: frame.minY)
            .allowsHitTesting(false)
            .accessibilityIdentifier(AccessibilityID.calendarCreationPreview)
    }

    // MARK: Blocks

    private func blockView(_ block: DaySchedule.Block, usableWidth: CGFloat) -> some View {
        let isDraft = editing.draft?.id == block.occurrence.activity.id
        let canPickUp = editing.allowsAdjusting && (editing.draft == nil || isDraft)
        let blockWidth = max(24, block.placement.widthFraction * usableWidth - columnGap)
        return OccurrenceBlockView(block: block, day: schedule.day, formatter: formatter, isDraft: isDraft)
            .accessibilityAction {
                activate(block, isDraft: isDraft)
            }
            .accessibilityAction(named: "Edit") {
                editing.edit(block.occurrence)
            }
            .frame(width: blockWidth, height: block.frame.height)
            .overlay(alignment: .top) {
                if isDraft && !block.frame.isClippedAtStart {
                    handle(.resizeStart, for: block)
                }
            }
            .overlay(alignment: .bottom) {
                if isDraft && !block.frame.isClippedAtEnd {
                    handle(.resizeEnd, for: block)
                }
            }
            .onTapGesture {
                activate(block, isDraft: isDraft)
            }
            .gesture(pickUpGesture(for: block), including: canPickUp ? .all : .subviews)
            .offset(x: leadingInset + block.placement.leadingFraction * usableWidth, y: block.frame.minY)
    }

    private func activate(_ block: DaySchedule.Block, isDraft: Bool) {
        if isDraft {
            editing.openDraft()
        } else {
            editing.select(block.occurrence)
        }
    }

    /// Press and hold picks the block up; continuing to drag moves it.
    private func pickUpGesture(for block: DaySchedule.Block) -> some Gesture {
        LongPressGesture(minimumDuration: Self.pressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: Self.space))
            .updating($isDraggingBlock) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if activeDrag == nil {
                    guard editing.pickUp(block.occurrence) else { return }
                    activeDrag = ActiveDrag(kind: .move, occurrence: block.occurrence)
                }
                guard let drag, let active = activeDrag, active.kind == .move else { return }
                apply(active, translation: drag.translation.height)
            }
            .onEnded { _ in
                activeDrag = nil
            }
    }

    private func handle(_ kind: GridDragKind, for block: DaySchedule.Block) -> some View {
        let tint = block.occurrence.isSample ? PrototypeColor.demo : PrototypeColor.today
        let isStart = kind == .resizeStart
        return Capsule()
            .fill(tint)
            .overlay(Capsule().strokeBorder(Color(.systemBackground), lineWidth: 1))
            .frame(width: 28, height: 7)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(y: isStart ? -22 : 22)
            .gesture(resizeGesture(kind, for: block))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isStart ? "Start time" : "End time")
            .accessibilityValue(formatter.clockTime(isStart ? block.occurrence.start : block.occurrence.end))
            .accessibilityHint("Swipe up or down to change it by 15 minutes")
            .accessibilityAdjustableAction { direction in
                nudge(kind, for: block, direction: direction)
            }
            .accessibilityIdentifier(isStart ? AccessibilityID.calendarResizeStartHandle : AccessibilityID.calendarResizeEndHandle)
    }

    private func resizeGesture(_ kind: GridDragKind, for block: DaySchedule.Block) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: Self.space)
            .updating($isDraggingBlock) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if activeDrag == nil {
                    activeDrag = ActiveDrag(kind: kind, occurrence: block.occurrence)
                }
                guard let active = activeDrag, active.kind == kind else { return }
                apply(active, translation: value.translation.height)
            }
            .onEnded { _ in
                activeDrag = nil
            }
    }

    private func apply(_ active: ActiveDrag, translation: CGFloat) {
        guard let current = editing.currentDraft() else { return }
        editing.apply(gridDrag.draft(current, dragging: active.occurrence, kind: active.kind, translation: translation))
    }

    /// VoiceOver equivalent of dragging a handle by one snap interval.
    private func nudge(_ kind: GridDragKind, for block: DaySchedule.Block, direction: AccessibilityAdjustmentDirection) {
        guard let current = editing.currentDraft() else { return }
        let step = max(GridDrag.minimumDistance, schedule.layout.hourHeight * CGFloat(gridDrag.snapInterval / 3_600))
        let translation: CGFloat
        switch direction {
        case .increment:
            translation = step
        case .decrement:
            translation = -step
        @unknown default:
            return
        }
        editing.apply(gridDrag.draft(current, dragging: block.occurrence, kind: kind, translation: translation))
    }

    /// Hour labels inside the column for a day whose rows differ from the shared gutter's:
    /// the 25-hour fall-back day shows two "1 AM" rows and the 23-hour spring-forward day has
    /// no "2 AM" row, which a gutter shared with ordinary days cannot show. Offsets come from
    /// the column's own `DayTimelineLayout`, like everything else in the column.
    private var ownHourLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(schedule.layout.hourMarks, id: \.index) { mark in
                if mark.index > 0 {
                    Text(formatter.hourLabel(for: mark.instant))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: Self.ownHourLabelWidth - Spacing.xs, alignment: .trailing)
                        .offset(y: mark.offset - 7)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gridlines(width: CGFloat) -> some View {
        Path { path in
            for mark in schedule.layout.hourMarks {
                path.move(to: CGPoint(x: 0, y: mark.offset))
                path.addLine(to: CGPoint(x: width, y: mark.offset))
            }
            path.move(to: CGPoint(x: 0, y: schedule.layout.height))
            path.addLine(to: CGPoint(x: width, y: schedule.layout.height))
        }
        .stroke(Color(.separator), lineWidth: 0.5)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
        }
        .accessibilityHidden(true)
    }
}
