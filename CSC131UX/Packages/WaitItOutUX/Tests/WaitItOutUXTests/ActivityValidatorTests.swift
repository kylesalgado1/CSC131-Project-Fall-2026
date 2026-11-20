import XCTest
@testable import WaitItOutUX

final class ActivityValidatorTests: XCTestCase {
    private let monday9 = TestFixtures.mondayNine

    func testValidOneTimeActivityHasNoIssues() {
        let activity = TestFixtures.activity(start: monday9)
        XCTAssertEqual(ActivityValidator.issues(in: activity), [])
        XCTAssertTrue(ActivityValidator.isValid(activity))
        XCTAssertNoThrow(try ActivityValidator.validate(activity))
        XCTAssertFalse(activity.isRecurring)
        XCTAssertFalse(activity.isSample)
    }

    func testValidRecurringActivityHasNoIssues() {
        let activity = TestFixtures.activity(start: monday9, repeatWeekdays: [.monday, .wednesday, .friday])
        XCTAssertEqual(ActivityValidator.issues(in: activity), [])
        XCTAssertEqual(activity.startWeekday, .monday)
        XCTAssertEqual(activity.startLocalDate?.description, "2026-10-26")
        XCTAssertTrue(activity.isRecurring)
    }

    func testOvernightActivityWithPreviousDayArrivalIsValid() {
        let activity = TestFixtures.activity(
            start: TestFixtures.date(2026, 10, 31, 23, 0),
            end: TestFixtures.date(2026, 11, 1, 1, 0),
            arrival: TestFixtures.date(2026, 10, 31, 22, 15)
        )
        XCTAssertEqual(ActivityValidator.issues(in: activity), [])
        XCTAssertEqual(activity.duration, 2 * 3_600)
        XCTAssertEqual(activity.arrivalLead, 45 * 60)
    }

    func testArrivalOnThePreviousDateForAnEarlyMorningActivityIsValid() {
        let activity = TestFixtures.activity(
            start: TestFixtures.date(2026, 11, 2, 0, 30),
            end: TestFixtures.date(2026, 11, 2, 1, 30),
            arrival: TestFixtures.date(2026, 11, 1, 23, 45)
        )
        XCTAssertEqual(ActivityValidator.issues(in: activity), [])
    }

    func testArrivalEqualToStartIsValid() {
        XCTAssertEqual(ActivityValidator.issues(in: TestFixtures.activity(start: monday9, arrival: monday9)), [])
    }

    func testBlankTitlesAreRejected() {
        for title in ["", "   ", "\n\t"] {
            let activity = TestFixtures.activity(title: title, start: monday9)
            XCTAssertEqual(ActivityValidator.issues(in: activity), [.emptyTitle], "title: \(title.debugDescription)")
        }
        XCTAssertEqual(ActivityValidationIssue.emptyTitle.field, .title)
    }

    func testInvalidCoordinatesAreRejected() {
        let badPoints = [
            GeoCoordinate(latitude: .nan, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: .infinity),
            GeoCoordinate(latitude: 90.5, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: -180.5)
        ]
        for point in badPoints {
            XCTAssertFalse(point.isValid)
            let destination = Destination(id: DestinationID("test"), name: "Somewhere", coordinate: point)
            let activity = TestFixtures.activity(start: monday9, destination: destination)
            XCTAssertEqual(ActivityValidator.issues(in: activity), [.invalidCoordinate])
        }
        let edge = Destination(id: DestinationID("edge"), name: "Edge", coordinate: GeoCoordinate(latitude: -90, longitude: 180))
        XCTAssertTrue(ActivityValidator.isValid(TestFixtures.activity(start: monday9, destination: edge)))
        XCTAssertEqual(ActivityValidationIssue.invalidCoordinate.field, .destination)
    }

    func testEmptyDestinationNameIsRejected() {
        let destination = Destination(id: DestinationID("blank"), name: " ", coordinate: GeoCoordinate(latitude: 1, longitude: 1))
        XCTAssertEqual(ActivityValidator.issues(in: TestFixtures.activity(start: monday9, destination: destination)), [.emptyDestinationName])
    }

    func testEndMustBeAfterStart() {
        XCTAssertEqual(ActivityValidator.issues(in: TestFixtures.activity(start: monday9, end: monday9)), [.endNotAfterStart])
        XCTAssertEqual(ActivityValidator.issues(in: TestFixtures.activity(start: monday9, end: monday9.addingTimeInterval(-60))), [.endNotAfterStart])
        XCTAssertEqual(ActivityValidationIssue.endNotAfterStart.field, .times)
    }

    func testDurationIsLimitedToTwentyFourHours() {
        let exactly = TestFixtures.activity(start: monday9, end: monday9.addingTimeInterval(24 * 3_600))
        XCTAssertEqual(ActivityValidator.issues(in: exactly), [])
        let longer = TestFixtures.activity(start: monday9, end: monday9.addingTimeInterval(24 * 3_600 + 1))
        XCTAssertEqual(ActivityValidator.issues(in: longer), [.durationTooLong])
        XCTAssertEqual(ActivityValidator.maximumDuration, 86_400)
    }

    func testArrivalAfterStartIsRejected() {
        let activity = TestFixtures.activity(start: monday9, arrival: monday9.addingTimeInterval(60))
        XCTAssertEqual(ActivityValidator.issues(in: activity), [.arrivalAfterStart])
        XCTAssertEqual(ActivityValidationIssue.arrivalAfterStart.field, .arrival)
    }

    func testArrivalLeadIsLimitedToTwentyFourHours() {
        let exactly = TestFixtures.activity(start: monday9, arrival: monday9.addingTimeInterval(-24 * 3_600))
        XCTAssertEqual(ActivityValidator.issues(in: exactly), [])
        let earlier = TestFixtures.activity(start: monday9, arrival: monday9.addingTimeInterval(-24 * 3_600 - 1))
        XCTAssertEqual(ActivityValidator.issues(in: earlier), [.arrivalTooEarly])
    }

    func testUnknownTimeZoneIsRejected() {
        var activity = TestFixtures.activity(start: monday9)
        activity.timeZoneIdentifier = "Mars/Olympus_Mons"
        XCTAssertEqual(ActivityValidator.issues(in: activity), [.unknownTimeZone("Mars/Olympus_Mons")])
        XCTAssertNil(activity.timeZone)
        XCTAssertNil(activity.startWeekday)
        activity.timeZoneIdentifier = ""
        XCTAssertEqual(ActivityValidator.issues(in: activity), [.unknownTimeZone("")])
        XCTAssertTrue(ActivityValidationIssue.unknownTimeZone("").message.contains("none"))
        XCTAssertEqual(ActivityValidationIssue.unknownTimeZone("").field, .timeZone)
    }

    func testRecurringActivityNeedsAtLeastOneWeekday() {
        let activity = TestFixtures.activity(start: monday9, repeatWeekdays: [])
        XCTAssertEqual(ActivityValidator.issues(in: activity), [.noRepeatWeekdays])
        XCTAssertTrue(activity.isRecurring)
        XCTAssertEqual(ActivityValidationIssue.noRepeatWeekdays.field, .recurrence)
    }

    func testRecurringWeekdaysMustIncludeTheStartDay() {
        let activity = TestFixtures.activity(start: monday9, repeatWeekdays: [.tuesday, .thursday])
        XCTAssertEqual(ActivityValidator.issues(in: activity), [.repeatWeekdaysExcludeStartDay(.monday)])
        let issue = ActivityValidationIssue.repeatWeekdaysExcludeStartDay(.monday)
        XCTAssertEqual(issue.field, .recurrence)
        XCTAssertFalse(issue.message.isEmpty)
    }

    func testStartWeekdayUsesTheActivityZone() {
        // 2026-11-01 03:30 UTC is Sunday in UTC but still Saturday evening in the Pacific zone.
        let instant = TestFixtures.date(2026, 11, 1, 3, 30, 0, in: TestFixtures.utc)
        let pacific = TestFixtures.activity(start: instant, repeatWeekdays: [.saturday])
        XCTAssertEqual(pacific.startWeekday, .saturday)
        XCTAssertEqual(ActivityValidator.issues(in: pacific), [])
        let utc = TestFixtures.activity(start: instant, repeatWeekdays: [.saturday], timeZone: TestFixtures.utc)
        XCTAssertEqual(utc.startWeekday, .sunday)
        XCTAssertEqual(ActivityValidator.issues(in: utc), [.repeatWeekdaysExcludeStartDay(.sunday)])
    }

    func testNonFiniteDatesAreRejectedWithoutCrashing() {
        let activity = TestFixtures.activity(start: Date(timeIntervalSince1970: .nan), end: monday9, arrival: monday9, repeatWeekdays: [.monday])
        let issues = ActivityValidator.issues(in: activity)
        XCTAssertEqual(issues, [.invalidDate])
        XCTAssertEqual(ActivityValidationIssue.invalidDate.field, .times)
    }

    func testMultipleIssuesAreReportedTogetherAndThrown() {
        var activity = TestFixtures.activity(title: " ", start: monday9, end: monday9, arrival: monday9.addingTimeInterval(3_600), repeatWeekdays: [])
        activity.timeZoneIdentifier = "Nowhere/Here"
        let issues = ActivityValidator.issues(in: activity)
        XCTAssertEqual(issues, [.emptyTitle, .endNotAfterStart, .arrivalAfterStart, .unknownTimeZone("Nowhere/Here"), .noRepeatWeekdays])
        XCTAssertThrowsError(try ActivityValidator.validate(activity)) { error in
            XCTAssertEqual(error as? ActivityValidationError, ActivityValidationError(issues: issues))
        }
        XCTAssertFalse(ActivityValidator.isValid(activity))
    }

    func testEveryIssueHasAnActionableMessageAndAField() {
        let issues: [ActivityValidationIssue] = [
            .emptyTitle, .emptyDestinationName, .invalidCoordinate, .invalidDate, .endNotAfterStart, .durationTooLong,
            .arrivalAfterStart, .arrivalTooEarly, .unknownTimeZone("X/Y"), .noRepeatWeekdays, .repeatWeekdaysExcludeStartDay(.friday)
        ]
        for issue in issues {
            XCTAssertFalse(issue.message.isEmpty)
            XCTAssertTrue(issue.message.hasSuffix("."), issue.message)
        }
        XCTAssertEqual(Set(issues.map(\.field)), Set([.title, .destination, .times, .arrival, .timeZone, .recurrence]))
    }

    func testActivityStoresNoDeparture() {
        // Departure is derived later from ideal arrival; the stored schedule holds only these fields.
        let labels = Mirror(reflecting: TestFixtures.activity(start: monday9)).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), Set(["id", "title", "start", "end", "idealArrival", "destination", "timeZoneIdentifier", "repeatWeekdays", "source"]))
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("depart") || $0.localizedCaseInsensitiveContains("leave") })
    }

    func testActivityRoundTripsThroughCodable() throws {
        let original = TestFixtures.activity(start: monday9, repeatWeekdays: [.monday, .friday], source: .sample)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Activity.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.repeatWeekdays, [.monday, .friday])
        XCTAssertEqual(decoded.source, .sample)
    }
}
