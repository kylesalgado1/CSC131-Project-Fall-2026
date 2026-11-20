import SwiftUI

/// Calendar tab. A Sunday-to-Saturday week header and day strip sit above a time grid that
/// shows duration-sized activity blocks, ideal-arrival markers, and the current time. Narrow
/// screens and accessibility text sizes show the selected day's timeline; wide screens show
/// all seven columns. Step 0004 adds creating (Add Activity, or press and drag on free time),
/// adjusting (press and hold a block, drag it or its handles, then Save or Cancel), and the
/// editor sheet. Step 0005 shows the calculated, read-only leave-home time in the detail sheet
/// and keeps it current: the minute tick re-plans departures as occurrences enter the horizon.
/// Stage S3 presents the details of the trip a notification named (`tripToPresent`) and, for a
/// trip the server monitors, shows its alerts and "I've Left" in the detail sheet.
@MainActor
public struct CalendarScreen: View {
    let model: WaitItOutModel

    /// Public since step 0008 so the team can place this screen in its own tab bar.
    public init(model: WaitItOutModel) {
        self.model = model
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var hourHeight: CGFloat = 60
    /// Current instant from the injected clock, refreshed once a minute while the current
    /// week is visible and every five minutes otherwise. `nil` until the first tick.
    @State private var now: Date?
    @State private var presentedOccurrence: ActivityOccurrence?

    /// The one sheet the Calendar shows: read-only details, or the editor while the model's
    /// draft is in editor mode. Swapping the item swaps the sheet.
    private enum CalendarSheet: Identifiable {
        case detail(ActivityOccurrence)
        case editor(UUID)

        var id: String {
            switch self {
            case .detail(let occurrence):
                return "detail-" + occurrence.id.rawValue
            case .editor(let sessionID):
                return "editor-" + sessionID.uuidString
            }
        }
    }

    private var currentTime: Date { now ?? model.currentDate() }

    private var titleFormatter: WeekTitleFormatter {
        WeekTitleFormatter(calculator: model.weekCalculator, locale: locale)
    }

    private var occurrenceFormatter: OccurrenceFormatter {
        OccurrenceFormatter(calculator: model.weekCalculator, locale: locale)
    }

    private var weekSchedules: [DaySchedule] {
        model.visibleWeek.dayRanges.map(schedule(for:))
    }

    private var selectedSchedule: DaySchedule {
        schedule(for: model.selectedDayRange)
    }

    /// The editor is never dismissed by a swipe, so a nil write only ever closes the details.
    private var sheetBinding: Binding<CalendarSheet?> {
        Binding(
            get: {
                if let session = model.editSession, session.mode == .editor {
                    return .editor(session.id)
                }
                return presentedOccurrence.map { CalendarSheet.detail($0) }
            },
            set: { newValue in
                if newValue == nil {
                    presentedOccurrence = nil
                }
            }
        )
    }

    private var gridEditing: GridEditing {
        let session = model.editSession
        let isBusy = session?.isBusy ?? false
        return GridEditing(
            draft: session?.mode == .calendar ? session?.draft : nil,
            allowsCreation: session == nil,
            allowsAdjusting: !isBusy && (session == nil || session?.mode == .calendar),
            timeZone: model.weekCalculator.timeZone,
            select: { occurrence in
                model.refreshDepartures()
                presentedOccurrence = occurrence
            },
            edit: { occurrence in startEditing(occurrence) },
            create: { interval in _ = model.beginNewActivity(spanning: interval) },
            pickUp: { occurrence in model.beginAdjusting(activityID: occurrence.activity.id) != nil },
            currentDraft: { model.editSession?.draft },
            apply: { draft in model.replaceDraft(draft) },
            openDraft: { model.showDraftInEditor() }
        )
    }

    /// Scroll row shared with the model so it survives tab switches.
    private var scrollHourBinding: Binding<Int?> {
        Binding(
            get: { model.calendarScrollHour },
            set: { model.calendarScrollHour = $0 }
        )
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let mode = CalendarLayoutMode.resolve(availableWidth: proxy.size.width, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
                let schedules = weekSchedules
                VStack(spacing: Spacing.sm) {
                    weekHeader
                        .padding(.horizontal, Spacing.lg)
                    DayStripView(
                        entries: stripEntries(from: schedules),
                        selectedDay: model.selectedDay,
                        today: currentTime,
                        titleFormatter: titleFormatter,
                        occurrenceFormatter: occurrenceFormatter,
                        leadingInset: mode == .fullWeek ? CalendarLayoutMode.timeGutterWidth : 0,
                        onSelect: { index in
                            withAnimation(reduceMotion ? nil : .default) {
                                model.selectDay(at: index)
                            }
                        }
                    )
                    selectedDayTitle(schedule: schedules.indices.contains(model.selectedDayIndex) ? schedules[model.selectedDayIndex] : selectedSchedule)
                        .padding(.horizontal, Spacing.lg)
                    if let failure = model.activitiesStatus.failureMessage {
                        StorageNotice(message: failure)
                            .padding(.horizontal, Spacing.lg)
                    }
                    if let notice = model.calendarNotice {
                        CalendarNoticeView(message: notice) {
                            model.dismissCalendarNotice()
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                    Divider()
                    grid(mode: mode, schedules: schedules)
                }
                .padding(.top, Spacing.sm)
            }
            .safeAreaInset(edge: .bottom) {
                if let session = model.editSession, session.mode == .calendar {
                    DraftBarView(
                        session: session,
                        formatter: occurrenceFormatter,
                        onCancel: { model.cancelDraft() },
                        onEdit: { model.showDraftInEditor() },
                        onSave: { Task { await saveCalendarDraft() } }
                    )
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") {
                        withAnimation(reduceMotion ? nil : .default) {
                            model.showCurrentWeek()
                        }
                        model.calendarScrollHour = selectedSchedule.suggestedScrollHour(currentTime: currentTime)
                    }
                    .accessibilityIdentifier(AccessibilityID.calendarToday)
                    .accessibilityHint("Shows the current week and day and scrolls to the current time")

                    Button {
                        _ = model.beginNewActivity()
                    } label: {
                        Label("Add Activity", systemImage: "plus")
                    }
                    .disabled(model.editSession != nil)
                    .accessibilityIdentifier(AccessibilityID.calendarAddActivity)
                    .accessibilityHint("Creates an activity on the selected day. Set its start and end first, then the ideal campus arrival.")
                }
            }
            .sheet(item: sheetBinding) { sheet in
                switch sheet {
                case .detail(let occurrence):
                    OccurrenceDetailView(
                        occurrence: occurrence,
                        formatter: occurrenceFormatter,
                        destinationName: model.resolvedDestination(occurrence.activity.destination).name,
                        departure: { (model.departureState(for: occurrence), model.currentDate()) },
                        onRetryDeparture: { model.retryDepartures() },
                        usesLiveBackend: model.usesLiveBackend,
                        monitoring: { model.monitoringSummary(for: occurrence) },
                        onMarkDeparted: {
                            Task { await model.markDeparted(occurrence.id, arriveBy: occurrence.idealArrival) }
                        },
                        isEditingBlocked: model.editSession != nil,
                        onEdit: { startEditing(occurrence) },
                        onDelete: { await deleteFromDetails(occurrence) }
                    )
                case .editor:
                    ActivityEditorView(model: model)
                }
            }
            .task(id: model.visibleWeek) {
                await runClock()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    now = model.currentDate()
                    model.refreshDepartures()
                }
            }
            // A tapped notification asks for a trip's details: on appear when the tap brought
            // this tab up, on change when it was already showing, and again once the schedule
            // has loaded or the editor has closed, which are what a request waits for.
            .onAppear {
                presentRequestedTrip()
            }
            .onChange(of: model.tripToPresent) { _, _ in
                presentRequestedTrip()
            }
            .onChange(of: model.tripPresentationStep) { _, _ in
                presentRequestedTrip()
            }
        }
    }

    // MARK: Pieces

    private var weekHeader: some View {
        HStack(spacing: Spacing.md) {
            Button {
                withAnimation(reduceMotion ? nil : .default) { model.showPreviousWeek() }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Previous week")
            .accessibilityIdentifier(AccessibilityID.calendarPreviousWeek)

            VStack(spacing: Spacing.xs) {
                Text(titleFormatter.title(for: model.visibleWeek))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(model.isShowingCurrentWeek ? "This week" : "Sunday to Saturday")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(titleFormatter.accessibilityTitle(for: model.visibleWeek))
            .accessibilityValue(model.isShowingCurrentWeek ? "This week" : "")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AccessibilityID.calendarWeekTitle)

            Button {
                withAnimation(reduceMotion ? nil : .default) { model.showNextWeek() }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Next week")
            .accessibilityIdentifier(AccessibilityID.calendarNextWeek)
        }
    }

    private func selectedDayTitle(schedule: DaySchedule) -> some View {
        let isToday = model.isToday(schedule.day.lowerBound)
        let summary = occurrenceFormatter.daySummary(blockCount: schedule.blocks.count, arrivalOnlyCount: schedule.arrivalOnlyMarkers.count)
        return HStack(spacing: Spacing.sm) {
            Text(titleFormatter.dayLabel(for: schedule.day.lowerBound))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isToday ? PrototypeColor.today : .primary)
            if isToday {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrototypeColor.today)
            }
            Spacer(minLength: Spacing.sm)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(titleFormatter.dayLabel(for: schedule.day.lowerBound))\(isToday ? ", today" : ""), \(summary)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(AccessibilityID.calendarSelectedDayTitle)
    }

    @ViewBuilder
    private func grid(mode: CalendarLayoutMode, schedules: [DaySchedule]) -> some View {
        let selected = schedules.indices.contains(model.selectedDayIndex) ? schedules[model.selectedDayIndex] : selectedSchedule
        let shown = mode == .fullWeek ? schedules : [selected]
        let gutterLayout = mode == .fullWeek
            ? (DayTimelineLayout.sharedGutter(for: shown.map(\.layout)) ?? selected.layout)
            : selected.layout
        ZStack(alignment: .top) {
            TimeGridView(
                schedules: shown,
                gutterLayout: gutterLayout,
                selectedDay: model.selectedDay,
                now: currentTime,
                formatter: occurrenceFormatter,
                titleFormatter: titleFormatter,
                scrollHour: scrollHourBinding,
                editing: gridEditing
            )
            if model.activities.isEmpty, model.editSession == nil {
                emptyState
            } else if mode == .selectedDay, selected.isEmpty {
                dayEmptyNote(for: selected)
            } else if mode == .fullWeek, schedules.allSatisfy(\.isEmpty) {
                dayEmptyNote(for: nil)
            }
        }
    }

    private func dayEmptyNote(for schedule: DaySchedule?) -> some View {
        let text: String
        if let schedule {
            text = "Nothing scheduled on \(titleFormatter.dayLabel(for: schedule.day.lowerBound)). Tap Add, or press and hold a free time and drag to create an activity."
        } else {
            text = "Nothing scheduled this week. Tap Add, press and hold a free time and drag, or use the arrows to look at another week."
        }
        return Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(Spacing.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .padding(.top, Spacing.lg)
            .padding(.horizontal, Spacing.xl)
            .allowsHitTesting(false)
            .accessibilityIdentifier(AccessibilityID.calendarDayEmptyNote)
    }

    /// Card over the top of the grid when nothing is stored. The grid stays visible and
    /// interactive below it, so an activity can be dragged out on an empty calendar too.
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Label("No activities yet", systemImage: "calendar")
                .font(.headline)
            Text(model.activitiesStatus.failureMessage == nil
                 ? "Add an activity, or press and hold a free time on the grid and drag. You can also load the labeled sample schedule in Settings."
                 : "Saved activities could not be read, so the calendar has nothing to show.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    emptyStateButtons
                }
                VStack(spacing: Spacing.sm) {
                    emptyStateButtons
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.top, Spacing.lg)
        .padding(.horizontal, Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.calendarEmptyState)
    }

    @ViewBuilder
    private var emptyStateButtons: some View {
        Button {
            _ = model.beginNewActivity()
        } label: {
            Label("Add Activity", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(AccessibilityID.calendarEmptyAddActivity)
        .accessibilityHint("Creates an activity on the selected day")
        Button("Open Settings") {
            model.selectedTab = .settings
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(AccessibilityID.calendarOpenSettings)
        .accessibilityHint("Switches to the Settings tab, where the sample schedule can be loaded")
    }

    // MARK: Notifications

    /// Presents the details of the trip a notification named, when there is one and nothing
    /// stands in the way (`TripPresentationStep`). The request is cleared only after the
    /// details are set to show, so it is never lost to an open editor or an unloaded schedule.
    private func presentRequestedTrip() {
        switch model.tripPresentationStep {
        case .idle, .wait:
            return
        case .discard:
            model.tripToPresent = nil
        case .present(let occurrence):
            model.refreshDepartures()
            presentedOccurrence = occurrence
            model.tripToPresent = nil
        }
    }

    // MARK: Editing actions

    private func startEditing(_ occurrence: ActivityOccurrence) {
        presentedOccurrence = nil
        _ = model.beginEditing(activityID: occurrence.activity.id)
    }

    @MainActor
    private func deleteFromDetails(_ occurrence: ActivityOccurrence) async -> Bool {
        do {
            try await model.deleteActivity(id: occurrence.activity.id)
            presentedOccurrence = nil
            return true
        } catch {
            return false
        }
    }

    /// Saves a calendar draft. When validation stops it, the editor opens with the inline errors.
    @MainActor
    private func saveCalendarDraft() async {
        let saved = await model.saveDraft()
        guard !saved, let session = model.editSession, session.failureMessage == nil, !session.visibleIssues.isEmpty else { return }
        model.showDraftInEditor()
    }

    // MARK: Helpers

    private func schedule(for day: Range<Date>) -> DaySchedule {
        DaySchedule.make(
            day: day,
            occurrences: model.occurrences(on: day),
            layout: DayTimelineLayout(day: day, hourHeight: hourHeight)
        )
    }

    private func stripEntries(from schedules: [DaySchedule]) -> [DayStripEntry] {
        schedules.enumerated().map { index, schedule in
            DayStripEntry(index: index, day: schedule.day, blockCount: schedule.blocks.count, arrivalOnlyCount: schedule.arrivalOnlyMarkers.count)
        }
    }

    /// Refreshes `now` from the injected clock: at the next whole minute while the current
    /// week is visible, otherwise every five minutes. Cancelled automatically when the tab is
    /// hidden, so nothing ticks in the background. Each tick also re-plans leave-home times,
    /// which is cheap when nothing changed.
    @MainActor
    private func runClock() async {
        while !Task.isCancelled {
            let instant = model.currentDate()
            now = instant
            model.refreshDepartures()
            let delay: TimeInterval
            if model.isShowingCurrentWeek {
                let second = model.weekCalculator.calendar.component(.second, from: instant)
                delay = TimeInterval(max(1, 60 - second))
            } else {
                delay = 300
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }
}

/// Dismissible note, such as an unsaved change discarded because its activity was removed.
private struct CalendarNoticeView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .font(.footnote)
                .buttonStyle(.borderless)
        }
        .padding(Spacing.md)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.calendarNotice)
    }
}

/// Shown when the repository could not be read. The calendar stays usable.
private struct StorageNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(PrototypeColor.demo)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrototypeColor.demo.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .accessibilityIdentifier(AccessibilityID.calendarStorageNotice)
    }
}

#Preview("Calendar - empty") {
    CalendarScreen(model: .preview(initialTab: .calendar))
}

#Preview("Calendar - sample schedule") {
    CalendarScreen(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewSampleActivities()))
}

#Preview("Calendar - crowded, overlaps, overnight") {
    CalendarScreen(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewCrowdedActivities()))
}

#Preview("Calendar - week grid, landscape", traits: .landscapeLeft) {
    CalendarScreen(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewCrowdedActivities()))
}

#Preview("Calendar - large text") {
    CalendarScreen(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewSampleActivities()))
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Calendar - dark") {
    CalendarScreen(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewCrowdedActivities()))
        .preferredColorScheme(.dark)
}
