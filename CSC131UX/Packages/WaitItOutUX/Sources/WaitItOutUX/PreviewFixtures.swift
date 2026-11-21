import Foundation

/// Pinned values for previews. 2026-10-30 12:00 Pacific, a Friday.
private enum PreviewClock {
    static let now = Date(timeIntervalSince1970: 1_793_386_800)
    static let zone = TimeZone(identifier: "America/Los_Angeles") ?? .current
    /// 2026-11-02 06:30 Pacific, the Monday after: the sample morning class is being monitored.
    static let mondayMorning = Date(timeIntervalSince1970: 1_793_629_800)
}

/// Preview stand-in for the team backend's recommendations: every trip leaves 55 minutes
/// before its ideal arrival. Preview use only; nothing here opens a connection.
private struct PreviewBackendEstimator: CommuteEstimating {
    let clock: any WallClock

    func estimateCommute(for request: CommuteRequest) async throws -> CommuteEstimateResponse {
        let now = clock.now()
        return .recommendation(DepartureRecommendation(
            advice: .leaveLater,
            recommendedDeparture: request.arriveBy.addingTimeInterval(-55 * 60),
            predictedArrival: request.arriveBy.addingTimeInterval(-15 * 60),
            reason: "Leaving then still gets you there with 15 minutes to spare.",
            confidence: .high,
            confidenceReason: "Based on plenty of historical data and live traffic.",
            margin: 15 * 60,
            generatedAt: now,
            receivedAt: now,
            source: RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true)
        ))
    }
}

/// Preview stand-in for server-side trip monitoring: it acknowledges whatever it is given,
/// reports the first trip as actively monitored with its heads-up sent, and the rest as
/// planned. Preview use only; nothing here opens a connection or asks for a permission.
private actor PreviewTripMonitor: TripMonitoring {
    private let clock: any WallClock
    private let permission: NotificationPermission
    private let failure: TripMonitoringFailure?
    private var held: [MonitoredTrip] = []
    private var departed: Set<OccurrenceID> = []

    init(clock: any WallClock, permission: NotificationPermission, failure: TripMonitoringFailure?) {
        self.clock = clock
        self.permission = permission
        self.failure = failure
    }

    func synchronize(_ trips: [MonitoredTrip]) async throws -> MonitoringSnapshot {
        if let failure { throw failure }
        held = trips
        return snapshot()
    }

    func refresh() async throws -> MonitoringSnapshot {
        if let failure { throw failure }
        return snapshot()
    }

    func refreshTrip(_ id: OccurrenceID) async throws -> MonitoredTripState? {
        if let failure { throw failure }
        return snapshot().trips[id]
    }

    func markDeparted(_ id: OccurrenceID, arriveBy: Date) async -> Result<MonitoredTripState, TripMonitoringFailure> {
        if let failure { return .failure(failure) }
        guard held.contains(where: { $0.id == id }) else { return .failure(.notMonitored) }
        departed.insert(id)
        guard let state = snapshot().trips[id] else { return .failure(.notMonitored) }
        return .success(state)
    }

    func unregister(from address: URL?) async throws {
        if let failure { throw failure }
        held = []
    }

    func withdrawTrips() async throws {
        if let failure { throw failure }
        held = []
    }

    func notificationPermission() async -> NotificationPermission {
        permission
    }

    func requestNotificationPermission() async -> NotificationPermission {
        permission
    }

    func refreshPushRegistration() async {}

    private func snapshot() -> MonitoringSnapshot {
        let now = clock.now()
        var trips: [OccurrenceID: MonitoredTripState] = [:]
        let limits = MonitoringLimits.fallback
        for (index, trip) in held.sorted(by: { $0.arriveBy < $1.arriveBy }).enumerated() {
            let departAt = trip.arriveBy.addingTimeInterval(-55 * 60)
            let startsAt = departAt.addingTimeInterval(-limits.monitorLead)
            let headsUpAt = departAt.addingTimeInterval(-limits.headsUpLead)
            let isFirst = index == 0
            let phase: TripPhase = departed.contains(trip.id) ? .departed : (isFirst ? .monitoring : .planned)
            let plan = MonitoredPlan(
                advice: .leaveLater,
                departAt: departAt,
                arriveAt: trip.arriveBy.addingTimeInterval(-15 * 60),
                driveMinutes: 40,
                reason: "Leaving then still gets you there with 15 minutes to spare.",
                confidence: .high,
                confidenceReason: "Based on plenty of historical data and live traffic.",
                notes: [],
                lateBy: nil,
                margin: 15 * 60,
                evaluatedAt: now,
                source: RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true),
                isStale: false
            )
            trips[trip.id] = MonitoredTripState(
                id: trip.id,
                arriveBy: trip.arriveBy,
                phase: phase,
                plan: phase == .departed ? nil : plan,
                noPlanReason: nil,
                planAvailableAt: nil,
                monitoringStartsAt: startsAt,
                monitoringStartedAt: isFirst ? startsAt : nil,
                headsUpAt: headsUpAt,
                headsUpSentAt: isFirst ? headsUpAt : nil,
                leaveAlertSentAt: nil,
                lastAlert: isFirst ? TripAlert(kind: .headsUp, status: .sent, at: headsUpAt, reason: nil) : nil,
                endsAt: trip.arriveBy,
                nextCheckAt: nil,
                lastErrorCode: nil,
                lastErrorAt: nil
            )
        }
        return MonitoringSnapshot(
            trips: trips,
            push: PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: permission == .authorized, lastFailure: nil),
            limits: limits,
            acknowledgedAt: now,
            serverTime: now,
            monitor: MonitorHealth(enabled: true, dependable: true, lastTickAt: now)
        )
    }
}

extension WaitItOutModel {
    /// Fixture for SwiftUI previews and screenshots. Time is pinned so previews are stable,
    /// and preferences and activities live in memory. Never used by the app host.
    /// `commute` configures the preview's own `TestCommuteProvider`, for example
    /// `.init(scenario: .error)` to preview the error state. The scenario is mirrored into the
    /// preview's preferences, so Settings and the Map's labels show it too.
    static func preview(
        now: Date = PreviewClock.now,
        timeZone: TimeZone = PreviewClock.zone,
        initialTab: PrototypeTab = .map,
        preferences: UserPreferences = .default,
        activities: [Activity] = [],
        commute: TestCommuteProvider.Configuration = .init()
    ) -> WaitItOutModel {
        let clock = FixedWallClock(now)
        var stored = preferences
        stored.testCommuteScenario = commute.scenario
        stored.testCommuteDuration = commute.duration
        let model = WaitItOutModel(
            clock: clock,
            preferencesStore: InMemoryPreferencesStore(initial: stored),
            activityRepository: InMemoryActivityRepository(initial: activities),
            commuteEstimator: TestCommuteProvider(clock: clock, configuration: commute),
            weekCalculator: WeekCalculator(timeZone: timeZone),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "WAIT IT OUT UX Prototype", version: "1.0", build: "preview"),
            initialTab: initialTab
        )
        // Screen previews do not run the root view's task, so pull the fixtures in here.
        Task {
            await model.loadPreferences()
            if !activities.isEmpty {
                await model.loadActivities()
            }
        }
        return model
    }

    /// A model with the sample schedule and leave-home reminders on, so the in-app preview
    /// adapter holds the next reminders; `simulatesFailure` previews the adapter failure.
    /// Preview use only.
    static func previewWithReminders(simulatesFailure: Bool = false) -> WaitItOutModel {
        preview(
            initialTab: .settings,
            preferences: UserPreferences(leaveHomeRemindersEnabled: true, simulatesReminderFailure: simulatesFailure),
            activities: previewSampleActivities()
        )
    }

    /// A model on the team backend's stand-ins (stage S3): the Live data mode with the sample
    /// schedule on the Monday morning after the preview Friday, leave-home reminders on, and
    /// the server monitoring the morning class. `permission` is what the notification
    /// permission reads as and `failure` makes every monitoring call fail, to preview those
    /// states. Preview use only; nothing here talks to a backend.
    static func previewLive(
        initialTab: PrototypeTab = .settings,
        remindersOn: Bool = true,
        permission: NotificationPermission = .authorized,
        failure: TripMonitoringFailure? = nil
    ) -> WaitItOutModel {
        let now = PreviewClock.mondayMorning
        let clock = FixedWallClock(now)
        let model = WaitItOutModel(
            clock: clock,
            preferencesStore: InMemoryPreferencesStore(initial: UserPreferences(leaveHomeRemindersEnabled: remindersOn)),
            activityRepository: InMemoryActivityRepository(initial: previewSampleActivities(now: now)),
            weekCalculator: WeekCalculator(timeZone: PreviewClock.zone),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "WAIT IT OUT UX Prototype", version: "1.0", build: "preview"),
            liveBackend: LiveBackend(
                commuteEstimator: PreviewBackendEstimator(clock: clock),
                tripMonitor: PreviewTripMonitor(clock: clock, permission: permission, failure: failure),
                configuration: BackendConfiguration(defaultBaseURL: URL(string: "https://backend.example"))
            ),
            initialTab: initialTab
        )
        // Screen previews do not run the root view's task, so pull the fixtures in here.
        Task {
            await model.loadStoredState()
        }
        return model
    }

    /// A model whose editor shows a new activity draft on the preview Friday. Preview use only.
    static func previewEditingNewActivity() -> WaitItOutModel {
        let model = preview(initialTab: .calendar)
        _ = model.beginNewActivity()
        return model
    }

    /// A model whose editor shows the sample morning class series. The sample is passed in as
    /// already stored, so the draft opens without waiting for the repository. Preview use only.
    static func previewEditingSampleSeries() -> WaitItOutModel {
        let samples = previewSampleActivities()
        let model = preview(initialTab: .calendar, activities: samples)
        if let first = samples.first {
            model.editSession = ActivityEditSession(draft: ActivityDraft(editing: first), mode: .editor)
            model.syncDraftDeparture()
        }
        return model
    }

    /// A 60-minute test-commute departure for `occurrence`, judged at the preview clock.
    /// Preview use only; the app asks its injected provider instead.
    static func previewDeparture(for occurrence: ActivityOccurrence, now: Date = PreviewClock.now) -> (state: DepartureState, now: Date) {
        let estimate = CommuteEstimate(
            travelTime: CommuteDuration.testDefault.seconds,
            sourceLabel: TestCommuteProvider.sourceLabel,
            estimatedAt: now,
            isSimulated: true
        )
        let request = CommuteRequest(occurrence: occurrence, origin: CommutePlaces.sample.home)
        return (DepartureState.resolving(.estimate(estimate), for: request), now)
    }

    /// Backend recommendation states for the leave-home rows, judged at the preview clock: a
    /// planned departure, a "leave now" that will arrive late, an out-of-date time while the
    /// backend is checked again, a recommendation kept after a failed refresh, and a trip the
    /// forecast does not reach yet. Preview use only; nothing here talks to a backend.
    static func previewBackendDepartures(now: Date = PreviewClock.now) -> (now: Date, states: [(title: String, state: DepartureState)]) {
        let arrival = now.addingTimeInterval(135 * 60)
        func calculation(_ recommendation: DepartureRecommendation) -> DepartureCalculation? {
            try? DepartureCalculation.make(idealArrival: arrival, recommendation: recommendation).get()
        }
        let planned = calculation(DepartureRecommendation(
            advice: .leaveLater,
            recommendedDeparture: now.addingTimeInterval(75 * 60),
            predictedArrival: now.addingTimeInterval(120 * 60),
            reason: "Your deadline is 2 hr 15 min away, so there is no rush. Leaving in 1 hr 15 min still gets you there with 15 minutes to spare.",
            confidence: .high,
            confidenceReason: "Based on plenty of historical data and live traffic.",
            notes: ["Light rain is expected, so drive times include extra delay."],
            margin: 15 * 60,
            generatedAt: now,
            receivedAt: now,
            source: RecommendationSource(baseline: .tomTom, usedFallback: false, hasLiveTraffic: true)
        ))
        let late = calculation(DepartureRecommendation(
            advice: .leaveNow,
            recommendedDeparture: now,
            predictedArrival: arrival.addingTimeInterval(40 * 60),
            reason: "Leave now, you may be late by about 40 minutes.",
            confidence: .medium,
            confidenceReason: "Live traffic is unavailable, so this uses typical conditions.",
            lateBy: 40 * 60,
            generatedAt: now,
            receivedAt: now,
            source: RecommendationSource(baseline: .pems, usedFallback: true, hasLiveTraffic: false)
        ))
        var states: [(title: String, state: DepartureState)] = []
        if let planned {
            states.append(("Recommended", .success(planned)))
            states.append(("Checking again", .refreshing(planned)))
            states.append(("Refresh failed", .stale(planned, .provider(.offline))))
        }
        if let late {
            states.append(("Arrival not reachable", .success(late)))
        }
        states.append(("Backend unreachable", .error(.provider(.timedOut))))
        states.append((
            "Beyond the forecast",
            .unavailable(.notYetPlannable(
                message: "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after Sat, Oct 31, 7:30 AM.",
                askAgainAt: now.addingTimeInterval(19 * 3_600 + 30 * 60)
            ))
        ))
        return (now, states)
    }

    /// The preview week: Sun 2026-10-25 to Sat 2026-10-31, Pacific.
    static func previewWeek(now: Date = PreviewClock.now, timeZone: TimeZone = PreviewClock.zone) -> WeekInterval {
        WeekCalculator(timeZone: timeZone).week(containing: now)
    }

    static func previewOccurrenceFormatter(timeZone: TimeZone = PreviewClock.zone) -> OccurrenceFormatter {
        OccurrenceFormatter(calculator: WeekCalculator(timeZone: timeZone))
    }

    /// The two labeled sample classes, anchored to the preview week. Preview use only.
    static func previewSampleActivities(now: Date = PreviewClock.now, timeZone: TimeZone = PreviewClock.zone) -> [Activity] {
        SampleActivities.make(weekContaining: now, timeZone: timeZone, destination: SampleLocation.demoCampus.destination)
    }

    /// A crowded preview week on top of the samples: three overlapping Friday activities, a
    /// 15-minute check-in, an overnight Saturday study session whose arrival is before the
    /// activity, and an all-day Sunday event. Every title says "Preview" so none can be
    /// mistaken for user or sample data. Preview use only.
    static func previewCrowdedActivities(now: Date = PreviewClock.now, timeZone: TimeZone = PreviewClock.zone) -> [Activity] {
        let week = previewWeek(now: now, timeZone: timeZone)
        let destination = SampleLocation.demoCampus.destination
        func make(_ title: String, day: Int, start: (Int, Int), minutes: Int, leadMinutes: Int, repeats: Set<Weekday>? = nil) -> Activity? {
            guard week.dayStarts.indices.contains(day), let wall = WallTime(hour: start.0, minute: start.1) else { return nil }
            let date = LocalDate.of(week.dayStarts[day], in: timeZone)
            let startInstant = LocalTimeResolver.instant(of: wall, on: date, in: timeZone)
            return Activity(
                title: title,
                start: startInstant,
                end: startInstant.addingTimeInterval(TimeInterval(minutes) * 60),
                idealArrival: startInstant.addingTimeInterval(-TimeInterval(leadMinutes) * 60),
                destination: destination,
                timeZoneIdentifier: timeZone.identifier,
                repeatWeekdays: repeats,
                source: .user
            )
        }
        let extras: [Activity?] = [
            make("Preview office hours", day: 5, start: (9, 30), minutes: 60, leadMinutes: 15),
            make("Preview seminar", day: 5, start: (10, 0), minutes: 90, leadMinutes: 30),
            make("Preview advising", day: 5, start: (10, 30), minutes: 30, leadMinutes: 10),
            make("Preview check-in", day: 5, start: (13, 0), minutes: 15, leadMinutes: 5),
            make("Preview overnight study session", day: 6, start: (22, 0), minutes: 240, leadMinutes: 45),
            make("Preview all-day orientation", day: 0, start: (0, 0), minutes: 24 * 60, leadMinutes: 0)
        ]
        return previewSampleActivities(now: now, timeZone: timeZone) + extras.compactMap { $0 }
    }
}
