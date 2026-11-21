import XCTest
@testable import WaitItOutUX

final class SampleActivitiesTests: XCTestCase {
    private let destination = SampleLocation.demoCampus.destination

    private func samples(now: Date = TestFixtures.fridayNoon, zone: TimeZone = TestFixtures.pacific) -> [Activity] {
        SampleActivities.make(weekContaining: now, timeZone: zone, destination: destination)
    }

    func testSamplesMatchTheSpecifiedSchedule() throws {
        let samples = samples()
        XCTAssertEqual(samples.count, 2)
        let morning = try XCTUnwrap(samples.first { $0.id == SampleActivities.morningClassID })
        XCTAssertEqual(morning.start, Date(timeIntervalSince1970: 1_793_030_400), "Mon 2026-10-26 09:00 PDT")
        XCTAssertEqual(morning.end, Date(timeIntervalSince1970: 1_793_033_400), "09:50")
        XCTAssertEqual(morning.idealArrival, Date(timeIntervalSince1970: 1_793_027_700), "08:15")
        XCTAssertEqual(morning.repeatWeekdays, [.monday, .wednesday, .friday])
        let lab = try XCTUnwrap(samples.first { $0.id == SampleActivities.afternoonLabID })
        XCTAssertEqual(lab.start, Date(timeIntervalSince1970: 1_793_127_600), "Tue 2026-10-27 12:00 PDT")
        XCTAssertEqual(lab.end, Date(timeIntervalSince1970: 1_793_146_500), "17:15")
        XCTAssertEqual(lab.idealArrival, Date(timeIntervalSince1970: 1_793_124_900), "11:15")
        XCTAssertEqual(lab.repeatWeekdays, [.tuesday, .thursday])
        for sample in samples {
            XCTAssertEqual(sample.source, .sample)
            XCTAssertTrue(sample.isSample)
            XCTAssertTrue(sample.title.localizedCaseInsensitiveContains("sample"), "Sample content is visibly labeled")
            XCTAssertEqual(sample.destination, destination)
            XCTAssertEqual(sample.timeZoneIdentifier, "America/Los_Angeles")
            XCTAssertEqual(ActivityValidator.issues(in: sample), [])
        }
    }

    func testSamplesAreAnchoredToTheWeekContainingNow() {
        let lateSaturday = TestFixtures.date(2026, 10, 31, 23, 59, 59)
        XCTAssertEqual(samples(now: lateSaturday).first { $0.id == SampleActivities.morningClassID }?.start, Date(timeIntervalSince1970: 1_793_030_400))
        let sundayAfter = TestFixtures.date(2026, 11, 1, 0, 0)
        let nextWeek = samples(now: sundayAfter)
        XCTAssertEqual(nextWeek.first { $0.id == SampleActivities.morningClassID }?.start, Date(timeIntervalSince1970: 1_793_638_800), "Mon 2026-11-02 09:00 PST")
        XCTAssertEqual(nextWeek.first { $0.id == SampleActivities.afternoonLabID }?.start, Date(timeIntervalSince1970: 1_793_736_000), "Tue 2026-11-03 12:00 PST")
        XCTAssertEqual(nextWeek.first { $0.id == SampleActivities.afternoonLabID }?.startWeekday, .tuesday)
    }

    func testSamplesUseTheCampusTimeZone() throws {
        let utcSamples = samples(zone: TestFixtures.utc)
        let morning = try XCTUnwrap(utcSamples.first { $0.id == SampleActivities.morningClassID })
        XCTAssertEqual(morning.start, Date(timeIntervalSince1970: 1_793_005_200), "Mon 2026-10-26 09:00 UTC")
        XCTAssertEqual(morning.timeZone?.secondsFromGMT(for: morning.start), 0)
        XCTAssertEqual(morning.startWeekday, .monday)
        XCTAssertEqual(ActivityValidator.issues(in: morning), [])
    }

    func testRepeatedCallsProduceIdenticalActivitiesWithFixedIds() {
        let first = samples()
        let second = samples(now: TestFixtures.fridayNoon.addingTimeInterval(3_600))
        XCTAssertEqual(first, second)
        XCTAssertEqual(SampleActivities.ids, Set(first.map(\.id)))
        XCTAssertNotEqual(SampleActivities.morningClassID, SampleActivities.afternoonLabID)
        XCTAssertEqual(SampleActivities.morningClassID.uuidString, "5A170002-0000-4000-8000-0000000000A1")
        XCTAssertEqual(SampleActivities.afternoonLabID.uuidString, "5A170002-0000-4000-8000-0000000000A2")
    }

    func testSamplesExpandToFiveOccurrencesInTheirWeek() {
        let week = TestFixtures.pacificCalculator().week(containing: TestFixtures.fridayNoon)
        let occurrences = OccurrenceExpander.occurrences(of: samples(), in: week.range)
        XCTAssertEqual(occurrences.map(\.id.date.description), ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"])
        XCTAssertEqual(occurrences.map { WallTime.of($0.idealArrival, in: TestFixtures.pacific).hour }, [8, 11, 8, 11, 8])
        XCTAssertEqual(occurrences.map { WallTime.of($0.start, in: TestFixtures.pacific).hour }, [9, 12, 9, 12, 9])
    }
}
