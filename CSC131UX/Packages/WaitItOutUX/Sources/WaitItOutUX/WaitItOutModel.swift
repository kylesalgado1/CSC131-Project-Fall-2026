import Foundation
import Observation

/// Outcome of the most recent load or save against one storage boundary.
public enum StorageStatus: Equatable, Sendable {
    case notLoaded
    case ready
    case failed(message: String)

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Shared feature state for every tab. The app host creates exactly one instance and
/// hands it to `WaitItOutRootView`; the package never reaches for host types.
///
/// Mutations happen on the main actor. Storage work is awaited through the injected
/// `PreferencesStoring` and `ActivityRepository` implementations so file-backed stores
/// never block the UI thread, commute estimates through `CommuteEstimating`, and reminders
/// through `ReminderScheduling` (step 0007).
@MainActor
@Observable
public final class WaitItOutModel {
    public var selectedTab: PrototypeTab
    public private(set) var visibleWeek: WeekInterval
    /// First instant of the day the Calendar focuses on. Always inside `visibleWeek`; week
    /// navigation keeps the same weekday and "Today" returns to the current day. Kept here so
    /// the selection survives tab switches.
    public private(set) var selectedDay: Date
    /// Hour row the Calendar's time grid is scrolled to, kept across tab switches. `nil` until
    /// the Calendar has been shown once; the Calendar then picks a sensible first row.
    public var calendarScrollHour: Int?
    /// Appearance, the Settings test commute and scenario, and home and campus (step 0006).
    /// Changed only through the model's setters, which persist and recalculate.
    public internal(set) var preferences: UserPreferences
    public private(set) var preferencesStatus: StorageStatus = .notLoaded

    /// Every stored activity, sorted by start. Reloaded from the repository after each load
    /// or write, so the Calendar shows actual repository contents rather than a second list.
    public private(set) var activities: [Activity] = []
    public private(set) var activitiesStatus: StorageStatus = .notLoaded
    /// Outcome of the last sample-schedule action, in words Settings can show.
    public private(set) var sampleActivitiesMessage: String?
    /// The one pending creation or edit (step 0004), shared by the Calendar's drag preview and
    /// the editor sheet so it survives tab switches. `nil` when nothing is being edited.
    public internal(set) var editSession: ActivityEditSession?
    /// Short message for the Calendar, such as a draft discarded because its activity was removed.
    public internal(set) var calendarNotice: String?
    /// Leave-home calculations for the saved upcoming occurrences (step 0005), keyed by
    /// occurrence. Derived from `activities` and the commute provider; never stored on an
    /// activity. See `WaitItOutModel+Departures.swift`.
    public internal(set) var departures: [OccurrenceID: DepartureEntry] = [:]
    /// Leave-home preview for the pending draft, shown read-only in the editor.
    public internal(set) var draftDeparture: DepartureEntry?
    /// Stored activities that could not be read (step 0007). While set, the repository refuses
    /// writes and reminders are paused; Settings offers Try Again and Keep a Copy and Start Over.
    public internal(set) var activityStorageIssue: StorageIssue?
    /// Stored settings that could not be read (step 0007). Defaults apply meanwhile.
    public internal(set) var preferencesStorageIssue: StorageIssue?
    /// Outcome of the last Saved data action, in words Settings can show.
    public internal(set) var storageRecoveryMessage: String?
    /// True while a Saved data action runs. Settings disables its buttons meanwhile.
    public internal(set) var isRecoveringStorage = false
    /// Where reconciling the reminder adapter stands (step 0007). Never stored.
    public internal(set) var reminderSync: ReminderSyncState = .idle
    /// What the reminder adapter reported after the last successful reconciliation.
    public internal(set) var reminderPreviews: [ScheduledReminder] = []
    /// The reminders that should exist now, and why the next trip has none when it has none.
    public internal(set) var reminderPlan: ReminderPlan = .none
    /// What the Map draws between home and campus: the schematic line, or the live backend's
    /// driving route when one arrived. Never stored. See `WaitItOutModel+Route.swift`.
    public internal(set) var routeState: RouteState = .schematic
    /// Where server-side trip monitoring stands (stage S2). Never stored. `.active` only after
    /// the server acknowledged the current trips. See `WaitItOutModel+Monitoring.swift`.
    public internal(set) var monitoringStatus: MonitoringStatus = .off
    /// What the server reports about each monitored trip, keyed by occurrence. Never stored.
    public internal(set) var monitoredTrips: [OccurrenceID: MonitoredTripState] = [:]
    /// Whether alerts can reach this device, as the server last said; `nil` before it answered.
    public internal(set) var pushDelivery: PushDeliveryStatus?
    /// Whether the server's monitoring worker can be relied on; `nil` before it answered.
    public internal(set) var monitorHealth: MonitorHealth?
    /// The server's monitoring numbers; the fallback until it reports its own.
    public internal(set) var monitoringLimits: MonitoringLimits = .fallback
    /// The notification permission as last read from the system through the monitoring service.
    public internal(set) var notificationPermission: NotificationPermission = .notDetermined
    /// Where telling the server "I've left" stands, per trip the user said it for.
    public internal(set) var departedStates: [OccurrenceID: DepartedState] = [:]
    /// Where taking this installation off the server stands after reminders were turned off.
    public internal(set) var monitoringWithdrawal: MonitoringWithdrawal = .none
    /// True when a server left behind by an address change could not be told to forget this
    /// installation, so it may still send alerts for a while.
    public internal(set) var previousServerMayStillAlert = false
    /// The trip whose details the Calendar should present, set by `openTrip(_:)` after a
    /// notification was tapped. The Calendar clears it once the details are on screen.
    public var tripToPresent: OccurrenceID?

    public let weekCalculator: WeekCalculator
    /// The labeled sample campus: the campus time zone, the campus destination id, and the
    /// value "Reset to sample locations" restores.
    public let sampleCampus: SampleLocation
    /// The labeled sample home "Reset to sample locations" restores (step 0006).
    public let sampleHome: SampleLocation
    public let prototypeInfo: PrototypeInfo

    /// Where preferences live, in words the Settings tab can show.
    public var preferencesPersistenceDescription: String {
        preferencesStore.persistenceDescription
    }

    /// Where activities live, in words the Settings tab can show.
    public var activitiesPersistenceDescription: String {
        activityRepository.persistenceDescription
    }

    /// Zone the sample campus keeps its schedule in. Sample activities use it, and the
    /// activity editor defaults new activities to it.
    public var campusTimeZone: TimeZone {
        sampleCampus.timeZone
    }

    /// True while a repository write is in flight. Settings disables its buttons meanwhile.
    public var isUpdatingActivities: Bool {
        pendingWrites > 0
    }

    private let clock: any WallClock
    private let preferencesStore: any PreferencesStoring
    private let activityRepository: any ActivityRepository
    /// The commute-estimation boundary. The host injects `TestCommuteProvider`.
    let commuteEstimator: any CommuteEstimating
    /// The injected estimator when it is the prototype's test provider; Settings configures it.
    let testCommuteProvider: TestCommuteProvider?
    /// The reminders boundary (step 0007). The host injects `PreviewReminderScheduler`.
    let reminderScheduler: any ReminderScheduling
    /// The injected adapter when it is the prototype's preview adapter; Settings configures it.
    let previewReminderScheduler: PreviewReminderScheduler?
    /// The team backend, when the host supplies one. `nil` in the standalone prototype, in
    /// previews, and in most tests: the model then behaves exactly as it did without it.
    let liveBackend: LiveBackend?
    private var pendingWrites = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var departureTasks: [OccurrenceID: Task<Void, Never>] = [:]
    @ObservationIgnored var draftDepartureTask: Task<Void, Never>?
    @ObservationIgnored var departureTokenCounter: UInt64 = 0
    /// Bumped whenever the provider's settings change, so every earlier result is stale.
    @ObservationIgnored var commuteRevision: UInt64 = 0
    @ObservationIgnored var reminderTask: Task<Void, Never>?
    @ObservationIgnored var reminderNeedsReconcile = false
    @ObservationIgnored var lastReconciledReminderPlan: ReminderPlan?
    @ObservationIgnored var routeTask: Task<Void, Never>?
    @ObservationIgnored var routeTracking = RouteTracking()
    @ObservationIgnored var monitoringTracking = MonitoringTracking()
    /// A trip a notification named before the schedule had loaded; opened right after the load.
    @ObservationIgnored var pendingTripToOpen: OccurrenceID?
    /// The one running launch load, so a notification response never starts a second one.
    @ObservationIgnored var storedStateTask: Task<Void, Never>?
    /// True while the local reminder adapter may still hold reminders from the Demo data mode.
    @ObservationIgnored var localRemindersMayExist = false

    /// `commuteEstimator` defaults to a `TestCommuteProvider` on the same clock and
    /// `reminderScheduler` to a `PreviewReminderScheduler`, which is what the prototype host
    /// injects explicitly; the team passes its own implementations. Home and campus start as
    /// the labeled samples until stored preferences load. `liveBackend` makes the team backend
    /// the normal flow; `commuteEstimator` and `reminderScheduler` then serve only the explicit
    /// Demo data mode.
    public init(
        clock: any WallClock,
        preferencesStore: any PreferencesStoring,
        activityRepository: any ActivityRepository,
        commuteEstimator: (any CommuteEstimating)? = nil,
        reminderScheduler: (any ReminderScheduling)? = nil,
        weekCalculator: WeekCalculator,
        sampleCampus: SampleLocation,
        sampleHome: SampleLocation = .demoHome,
        prototypeInfo: PrototypeInfo,
        liveBackend: LiveBackend? = nil,
        initialTab: PrototypeTab = .map
    ) {
        self.clock = clock
        self.preferencesStore = preferencesStore
        self.activityRepository = activityRepository
        let estimator = commuteEstimator ?? TestCommuteProvider(clock: clock)
        let testProvider = estimator as? TestCommuteProvider
        self.commuteEstimator = estimator
        testCommuteProvider = testProvider
        let scheduler = reminderScheduler ?? PreviewReminderScheduler()
        let previewScheduler = scheduler as? PreviewReminderScheduler
        self.reminderScheduler = scheduler
        previewReminderScheduler = previewScheduler
        self.liveBackend = liveBackend
        self.weekCalculator = weekCalculator
        self.sampleCampus = sampleCampus
        self.sampleHome = sampleHome
        self.prototypeInfo = prototypeInfo
        selectedTab = initialTab
        // Until stored preferences load, the test provider's own duration and scenario are the
        // setting, and home and campus are the labeled samples.
        preferences = UserPreferences(
            testCommuteDuration: testProvider?.configuration.duration ?? .testDefault,
            testCommuteScenario: testProvider?.configuration.scenario ?? .normal,
            places: CommutePlaces.sample(home: sampleHome, campus: sampleCampus),
            simulatesReminderFailure: previewScheduler?.simulatesFailure ?? false
        )
        let now = clock.now()
        let week = weekCalculator.week(containing: now)
        visibleWeek = week
        selectedDay = Self.dayStart(in: week, containing: now, calculator: weekCalculator)
    }

    // MARK: Time

    /// The current instant according to the injected clock.
    public func currentDate() -> Date {
        clock.now()
    }

    public var isShowingCurrentWeek: Bool {
        visibleWeek == weekCalculator.week(containing: clock.now())
    }

    /// True when `date` falls on the current day according to the injected clock.
    public func isToday(_ date: Date) -> Bool {
        weekCalculator.isSameDay(date, clock.now())
    }

    /// True when the selected day is the current day.
    public var isShowingToday: Bool {
        isToday(selectedDay)
    }

    // MARK: Week and day navigation

    /// Sunday-first index of the selected day within the visible week.
    public var selectedDayIndex: Int {
        visibleWeek.dayIndex(containing: selectedDay) ?? weekCalculator.weekdayIndex(of: selectedDay)
    }

    /// Half-open range of the selected day, one local midnight to the next.
    public var selectedDayRange: Range<Date> {
        visibleWeek.dayRange(at: selectedDayIndex) ?? visibleWeek.range
    }

    /// Previous week, keeping the same weekday selected.
    public func showPreviousWeek() {
        show(week: weekCalculator.previousWeek(before: visibleWeek), dayIndex: selectedDayIndex)
    }

    /// Next week, keeping the same weekday selected.
    public func showNextWeek() {
        show(week: weekCalculator.nextWeek(after: visibleWeek), dayIndex: selectedDayIndex)
    }

    /// The current week with the current day selected.
    public func showCurrentWeek() {
        let now = clock.now()
        let week = weekCalculator.week(containing: now)
        show(week: week, dayIndex: week.dayIndex(containing: now) ?? weekCalculator.weekdayIndex(of: now))
    }

    /// Focuses the day containing `date`, moving the visible week when it lies elsewhere.
    public func selectDay(_ date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let week = visibleWeek.contains(date) ? visibleWeek : weekCalculator.week(containing: date)
        show(week: week, dayIndex: week.dayIndex(containing: date) ?? weekCalculator.weekdayIndex(of: date))
    }

    /// Focuses the day at a Sunday-first index of the visible week. Out-of-range indices are ignored.
    public func selectDay(at index: Int) {
        guard visibleWeek.dayStarts.indices.contains(index) else { return }
        show(week: visibleWeek, dayIndex: index)
    }

    private func show(week: WeekInterval, dayIndex: Int) {
        let index = min(week.dayStarts.count - 1, max(0, dayIndex))
        visibleWeek = week
        selectedDay = week.dayStarts.indices.contains(index) ? week.dayStarts[index] : week.start
    }

    private static func dayStart(in week: WeekInterval, containing date: Date, calculator: WeekCalculator) -> Date {
        if let index = week.dayIndex(containing: date), week.dayStarts.indices.contains(index) {
            return week.dayStarts[index]
        }
        return calculator.startOfDay(for: date)
    }

    // MARK: Activities

    public var sampleActivities: [Activity] {
        activities.filter(\.isSample)
    }

    public var userActivities: [Activity] {
        activities.filter { !$0.isSample }
    }

    /// True when every sample id is stored, so loading the samples again would add nothing.
    public var allSamplesLoaded: Bool {
        SampleActivities.ids.isSubset(of: Set(activities.map(\.id)))
    }

    /// Occurrences of the stored activities that intersect `range`, sorted by start.
    public func occurrences(in range: Range<Date>) -> [ActivityOccurrence] {
        OccurrenceExpander.occurrences(of: activities, in: range)
    }

    /// What the Calendar tab shows for the visible week: stored activities, with a pending
    /// draft previewed in place of its original (see `calendarActivities`).
    public var visibleWeekOccurrences: [ActivityOccurrence] {
        OccurrenceExpander.occurrences(of: calendarActivities, in: visibleWeek.range)
    }

    /// The visible week's occurrences whose planned time touches `day`.
    public func occurrences(on day: Range<Date>) -> [ActivityOccurrence] {
        visibleWeekOccurrences.filter { $0.intersects(day) }
    }

    /// Launch and relaunch: stored settings, then the stored schedule. A call made while a load
    /// is under way joins it instead of starting a second one, so the root view and a
    /// notification response can both ask.
    public func loadStoredState() async {
        if let running = storedStateTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            await self?.loadPreferences()
            await self?.loadActivities()
        }
        storedStateTask = task
        await task.value
        if storedStateTask == task {
            storedStateTask = nil
        }
    }

    /// Loads stored activities at launch and on Try Again. A failure leaves the list empty,
    /// records the issue and a user-facing message, and keeps the rest of the app usable; the
    /// repository then refuses writes, so the unreadable file is never replaced. Reminders are
    /// reconciled afterwards, which is how a relaunch recreates them. With the live backend the
    /// notification permission and the push registration are checked too, and a trip a
    /// notification named before the load is opened.
    public func loadActivities() async {
        do {
            try await refreshActivities()
            activityStorageIssue = nil
        } catch {
            let issue = StorageIssue(area: .activities, error: error as? PersistenceError ?? .readFailed)
            activityStorageIssue = issue
            activitiesStatus = .failed(message: issue.message)
        }
        reconcileReminders(force: true)
        // A cold launch does not always bring a scene-phase change, so this does not wait for one.
        refreshPushRegistration()
        openPendingTrip()
    }

    /// Saved data "Try Again": reads every store that could not be read again.
    public func retryLoadingStorage() async {
        guard !isRecoveringStorage else { return }
        isRecoveringStorage = true
        defer { isRecoveringStorage = false }
        storageRecoveryMessage = nil
        if preferencesStorageIssue != nil {
            await loadPreferences()
        }
        if activityStorageIssue != nil {
            await loadActivities()
        }
        let stillFailing = activityStorageIssue != nil || preferencesStorageIssue != nil
        storageRecoveryMessage = stillFailing
            ? "Saved data still could not be read. Nothing was overwritten."
            : "Saved data was read successfully."
    }

    /// Saved data "Keep a Copy and Start Over", chosen explicitly and confirmed: each unreadable
    /// file is renamed (never deleted) and the app continues with an empty schedule or the
    /// settings in effect now, which are then saved.
    public func setAsideUnreadableStorage() async {
        guard !isRecoveringStorage else { return }
        isRecoveringStorage = true
        defer { isRecoveringStorage = false }
        var kept: [String] = []
        var failed = false
        if activityStorageIssue != nil {
            do {
                if let backup = try await activityRepository.setAsideUnreadableData() {
                    kept.append(backup)
                }
                await loadActivities()
            } catch {
                failed = true
            }
        }
        if preferencesStorageIssue != nil {
            do {
                if let backup = try await preferencesStore.setAsideUnreadableData() {
                    kept.append(backup)
                }
                await loadPreferences()
                if preferencesStorageIssue == nil {
                    persistPreferences()
                }
            } catch {
                failed = true
            }
        }
        if failed {
            storageRecoveryMessage = "The unreadable data could not be set aside, so nothing changed. Try again later."
        } else if activityStorageIssue != nil || preferencesStorageIssue != nil {
            let copies = kept.isEmpty ? "" : " A copy was kept as \(kept.joined(separator: " and "))."
            storageRecoveryMessage = "Saved data still could not be read after starting over.\(copies) Nothing else was changed."
        } else if kept.isEmpty {
            storageRecoveryMessage = "Saved data can be read again; nothing needed setting aside."
        } else {
            storageRecoveryMessage = "Kept a copy of the unreadable data as \(kept.joined(separator: " and ")) next to the saved files, and started over."
        }
    }

    /// Validates, stores, and reloads. Throws `ActivityValidationError` with every issue when
    /// the activity is invalid, or `ActivityStorageError` when the repository fails. Saving an
    /// activity whose id is already stored replaces it.
    public func saveActivity(_ activity: Activity) async throws {
        try ActivityValidator.validate(activity)
        try await write { repository in
            try await repository.upsert([activity])
        }
    }

    /// Removes one activity. Unknown ids are a no-op. Throws `ActivityStorageError` on failure.
    public func deleteActivity(id: UUID) async throws {
        try await write { repository in
            try await repository.delete(ids: [id])
        }
    }

    /// Explicit Settings action: stores whichever of the two labeled sample activities are
    /// missing, anchored to the current week in the campus time zone. Loading again adds
    /// nothing. The outcome is reported through `sampleActivitiesMessage`.
    public func loadSampleActivities() async {
        let samples = SampleActivities.make(
            weekContaining: clock.now(),
            timeZone: campusTimeZone,
            destination: campusDestination
        )
        guard samples.count == SampleActivities.ids.count, samples.allSatisfy(ActivityValidator.isValid) else {
            sampleActivitiesMessage = "The sample schedule could not be prepared for the campus time zone, so nothing was added."
            return
        }
        do {
            let added: Int = try await write { repository in
                let stored = try await repository.fetchAll()
                let existing = Set(stored.map(\.id))
                let missing = samples.filter { !existing.contains($0.id) }
                if !missing.isEmpty {
                    try await repository.upsert(missing)
                }
                return missing.count
            }
            if added == 0 {
                sampleActivitiesMessage = "The sample schedule is already loaded; nothing was added."
            } else {
                sampleActivitiesMessage = "Added \(CountPhrase.make(added, singular: "sample activity", plural: "sample activities")) to the calendar."
            }
        } catch {
            sampleActivitiesMessage = "The sample schedule could not be stored. Nothing changed."
        }
    }

    /// Explicit Settings action: removes every activity marked as sample content and nothing
    /// else, so the user's own activities, past or future, are untouched.
    public func clearSampleActivities() async {
        do {
            let removed: Int = try await write { repository in
                let stored = try await repository.fetchAll()
                let sampleIDs = Set(stored.filter(\.isSample).map(\.id))
                if !sampleIDs.isEmpty {
                    try await repository.delete(ids: sampleIDs)
                }
                return sampleIDs.count
            }
            if removed == 0 {
                sampleActivitiesMessage = "There are no sample activities to remove."
            } else {
                sampleActivitiesMessage = "Removed \(CountPhrase.make(removed, singular: "sample activity", plural: "sample activities")). Activities you added yourself were kept."
            }
        } catch {
            sampleActivitiesMessage = "Sample activities could not be removed. Nothing changed."
        }
    }

    /// Runs one repository operation, then reloads so state mirrors storage. Any failure is
    /// recorded in `activitiesStatus` and rethrown as `ActivityStorageError`.
    private func write<Value>(_ operation: (any ActivityRepository) async throws -> Value) async throws -> Value {
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        do {
            let value = try await operation(activityRepository)
            try await refreshActivities()
            return value
        } catch {
            let message: String
            if let issue = activityStorageIssue {
                message = issue.message
            } else if (error as? PersistenceError) == .unreadableDataProtected {
                message = "The change was not saved: saved activities could not be read, and saving now would replace them."
            } else {
                message = "The change could not be stored. The calendar shows the last schedule that was read successfully."
            }
            let failure = ActivityStorageError(message: message)
            activitiesStatus = .failed(message: failure.message)
            throw failure
        }
    }

    private func refreshActivities() async throws {
        let stored = try await activityRepository.fetchAll()
        activities = stored.sorted(by: Self.isOrderedBefore)
        activitiesStatus = .ready
        // A successful read resolves any earlier storage issue.
        activityStorageIssue = nil
        reconcileEditSession()
        refreshDepartures()
    }

    private static func isOrderedBefore(_ lhs: Activity, _ rhs: Activity) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: Preferences

    /// Loads stored preferences at launch and on Try Again. A failure keeps the settings in
    /// effect, records the issue and a user-facing message, and keeps the app usable; the store
    /// then refuses writes until the issue is resolved. Stored test settings reach the test
    /// provider and the reminder adapter, and stored home and campus values recalculate every
    /// leave-home time. With a live backend, the stored server address and data mode apply too.
    public func loadPreferences() async {
        let placesBefore = preferences.places
        let wasLive = usesLiveBackend
        let addressBefore = liveBackend?.configuration.baseURL
        do {
            if let stored = try await preferencesStore.loadPreferences() {
                preferences = stored
            }
            preferencesStatus = .ready
            preferencesStorageIssue = nil
        } catch {
            let issue = StorageIssue(area: .settings, error: error as? PersistenceError ?? .readFailed)
            preferencesStorageIssue = issue
            preferencesStatus = .failed(message: issue.message)
        }
        // The stored server address and data mode decide where leave-home times come from. When
        // that differs from what was in effect, nothing computed under the other source is kept.
        applyStoredBackendAddress()
        monitoringAddressDidChange(from: addressBefore, to: liveBackend?.configuration.baseURL)
        let sourceChanged = usesLiveBackend != wasLive
            || (usesLiveBackend && liveBackend?.configuration.baseURL != addressBefore)
        let testSettingsChanged = testCommuteProvider.map {
            $0.configuration.duration != preferences.testCommuteDuration
                || $0.configuration.scenario != preferences.testCommuteScenario
        } ?? false
        if sourceChanged {
            applyTestCommuteSettings()
            dataSourceDidChange()
        } else if testSettingsChanged && !usesLiveBackend {
            commuteSettingsDidChange()
        } else {
            if testSettingsChanged {
                applyTestCommuteSettings()
            }
            if preferences.places != placesBefore {
                placesDidChange()
            }
        }
        applyReminderSettings()
        reconcileReminders(force: true)
        refreshRoute()
    }

    /// Applies the appearance immediately and persists it in the background.
    public func setAppearance(_ appearance: AppearancePreference) {
        guard preferences.appearance != appearance else { return }
        preferences.appearance = appearance
        persistPreferences()
    }

    /// Settings test commute (step 0005): stores the duration, hands it to the test provider,
    /// and recalculates every leave-home time, including the editor's preview. Validation
    /// happens before this point: `CommuteDuration` only holds valid values.
    public func setTestCommuteDuration(_ duration: CommuteDuration) {
        guard preferences.testCommuteDuration != duration else { return }
        preferences.testCommuteDuration = duration
        persistPreferences()
        commuteSettingsDidChange()
    }

    /// Waits for any in-flight save to finish. Tests use this; the UI never needs to.
    public func flushPendingSaves() async {
        await saveTask?.value
    }

    /// Saves the current preferences in the background; a newer save cancels an older one.
    func persistPreferences() {
        saveTask?.cancel()
        let snapshot = preferences
        let store = preferencesStore
        saveTask = Task { [weak self] in
            do {
                try await store.savePreferences(snapshot)
                guard !Task.isCancelled else { return }
                self?.preferencesStatus = .ready
            } catch {
                guard !Task.isCancelled, let self else { return }
                if let issue = self.preferencesStorageIssue {
                    self.preferencesStatus = .failed(message: issue.message)
                } else if (error as? PersistenceError) == .unreadableDataProtected {
                    self.preferencesStatus = .failed(message: "Your settings apply now but were not saved: saved settings could not be read, and saving now would replace them.")
                } else {
                    self.preferencesStatus = .failed(message: "Your settings apply now but could not be saved.")
                }
            }
        }
    }
}
