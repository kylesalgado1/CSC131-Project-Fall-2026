import Foundation
@testable import WaitItOutUX

enum TestFixtures {
    static let pacific: TimeZone = {
        guard let zone = TimeZone(identifier: "America/Los_Angeles") else {
            preconditionFailure("America/Los_Angeles must exist in the test host's tz database")
        }
        return zone
    }()

    static let utc: TimeZone = {
        guard let zone = TimeZone(identifier: "UTC") else {
            preconditionFailure("UTC must exist")
        }
        return zone
    }()

    static let enUS = Locale(identifier: "en_US")

    /// 2026-10-30 12:00 Pacific (a Friday).
    static let fridayNoon = Date(timeIntervalSince1970: 1_793_386_800)

    /// Mon 2026-10-26 09:00 PDT: the Monday of the week that contains `fridayNoon`.
    static let mondayNine = Date(timeIntervalSince1970: 1_793_030_400)

    static let demoDestination = SampleLocation.demoCampus.destination

    static func pacificCalculator() -> WeekCalculator {
        WeekCalculator(timeZone: pacific, locale: enUS)
    }

    /// Builds a date from local wall-clock components in `zone`.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, in zone: TimeZone = pacific) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid fixture components \(components)")
        }
        return date
    }

    /// A valid activity. Defaults: 50 minutes long, ideal arrival 45 minutes before start,
    /// Pacific zone, demo campus destination, created by the user.
    static func activity(
        id: UUID = UUID(),
        title: String = "Lecture",
        start: Date,
        end: Date? = nil,
        arrival: Date? = nil,
        repeatWeekdays: Set<Weekday>? = nil,
        timeZone: TimeZone = pacific,
        destination: Destination = demoDestination,
        source: ActivitySource = .user
    ) -> Activity {
        Activity(
            id: id,
            title: title,
            start: start,
            end: end ?? start.addingTimeInterval(50 * 60),
            idealArrival: arrival ?? start.addingTimeInterval(-45 * 60),
            destination: destination,
            timeZoneIdentifier: timeZone.identifier,
            repeatWeekdays: repeatWeekdays,
            source: source
        )
    }

    @MainActor
    static func makeModel(
        clock: any WallClock = FixedWallClock(fridayNoon),
        store: any PreferencesStoring = InMemoryPreferencesStore(),
        repository: any ActivityRepository = InMemoryActivityRepository(),
        commuteEstimator: (any CommuteEstimating)? = nil,
        reminderScheduler: (any ReminderScheduling)? = nil,
        timeZone: TimeZone = pacific,
        initialTab: PrototypeTab = .map
    ) -> WaitItOutModel {
        WaitItOutModel(
            clock: clock,
            preferencesStore: store,
            activityRepository: repository,
            commuteEstimator: commuteEstimator,
            reminderScheduler: reminderScheduler,
            weekCalculator: WeekCalculator(timeZone: timeZone, locale: enUS),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "Test", version: "1", build: "1"),
            initialTab: initialTab
        )
    }
}
