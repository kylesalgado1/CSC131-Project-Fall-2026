import Foundation

/// The two demo classes that Settings can load on request. They never load on their own.
///
/// Fixed ids make loading idempotent: loading again finds the same ids already stored and
/// adds nothing. The `sample` source and the word "Sample" in each title keep the content
/// visibly labeled wherever it appears.
public enum SampleActivities {
    /// Mon, Wed, Fri 9:00 to 9:50 AM, ideal arrival 8:15 AM.
    public static let morningClassID = fixedID(0xA1)
    /// Tue, Thu 12:00 to 5:15 PM, ideal arrival 11:15 AM.
    public static let afternoonLabID = fixedID(0xA2)

    public static let ids: Set<UUID> = [morningClassID, afternoonLabID]

    /// Builds both samples anchored to the Sunday-to-Saturday week that contains `now` in
    /// `zone`, which should be the campus time zone. Returns fewer than two activities only
    /// if a wall time could not be formed, which the literal times below never trigger.
    public static func make(weekContaining now: Date, timeZone zone: TimeZone, destination: Destination) -> [Activity] {
        let today = LocalDate.of(now, in: zone)
        let sunday = today.adding(days: -today.weekday.sundayFirstIndex)
        let monday = sunday.adding(days: 1)
        let tuesday = sunday.adding(days: 2)
        let specs: [Spec] = [
            Spec(
                id: morningClassID,
                title: "Sample morning class",
                day: monday,
                start: WallTime(hour: 9, minute: 0),
                end: WallTime(hour: 9, minute: 50),
                arrival: WallTime(hour: 8, minute: 15),
                weekdays: [.monday, .wednesday, .friday]
            ),
            Spec(
                id: afternoonLabID,
                title: "Sample afternoon lab",
                day: tuesday,
                start: WallTime(hour: 12, minute: 0),
                end: WallTime(hour: 17, minute: 15),
                arrival: WallTime(hour: 11, minute: 15),
                weekdays: [.tuesday, .thursday]
            )
        ]
        return specs.compactMap { $0.activity(in: zone, destination: destination) }
    }

    private struct Spec {
        let id: UUID
        let title: String
        let day: LocalDate
        let start: WallTime?
        let end: WallTime?
        let arrival: WallTime?
        let weekdays: Set<Weekday>

        func activity(in zone: TimeZone, destination: Destination) -> Activity? {
            guard let start, let end, let arrival else { return nil }
            return Activity(
                id: id,
                title: title,
                start: LocalTimeResolver.instant(of: start, on: day, in: zone),
                end: LocalTimeResolver.instant(of: end, on: day, in: zone),
                idealArrival: LocalTimeResolver.instant(of: arrival, on: day, in: zone),
                destination: destination,
                timeZoneIdentifier: zone.identifier,
                repeatWeekdays: weekdays,
                source: .sample
            )
        }
    }

    private static func fixedID(_ last: UInt8) -> UUID {
        UUID(uuid: (0x5A, 0x17, 0x00, 0x02, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, last))
    }
}
