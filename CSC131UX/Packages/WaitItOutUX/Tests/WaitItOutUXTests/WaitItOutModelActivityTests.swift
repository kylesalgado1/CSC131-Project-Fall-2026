import XCTest
@testable import WaitItOutUX

@MainActor
final class WaitItOutModelActivityTests: XCTestCase {
    private let monday9 = TestFixtures.mondayNine

    func testStartsEmptyAndLoadsRepositoryContents() async {
        let later = TestFixtures.activity(title: "Later", start: monday9.addingTimeInterval(3_600))
        let earlier = TestFixtures.activity(title: "Earlier", start: monday9)
        let model = TestFixtures.makeModel(repository: InMemoryActivityRepository(initial: [later, earlier]))
        XCTAssertEqual(model.activities, [])
        XCTAssertEqual(model.activitiesStatus, .notLoaded)
        XCTAssertEqual(model.visibleWeekOccurrences, [])
        await model.loadActivities()
        XCTAssertEqual(model.activities, [earlier, later], "Sorted by start")
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertEqual(model.visibleWeekOccurrences.map(\.activity.title), ["Earlier", "Later"])
        XCTAssertEqual(model.campusTimeZone.identifier, "America/Los_Angeles")
        XCTAssertTrue(model.activitiesPersistenceDescription.localizedCaseInsensitiveContains("memory"))
    }

    func testSamplesNeverLoadOnTheirOwn() async {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        XCTAssertEqual(model.activities, [])
        XCTAssertEqual(model.sampleActivities, [])
        XCTAssertFalse(model.allSamplesLoaded)
        XCTAssertNil(model.sampleActivitiesMessage)
    }

    func testCalendarOccurrencesFollowRepositoryContents() async {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        await model.loadSampleActivities()
        XCTAssertEqual(model.visibleWeekOccurrences.map(\.activity.title), [
            "Sample morning class", "Sample afternoon lab", "Sample morning class", "Sample afternoon lab", "Sample morning class"
        ])
        model.showNextWeek()
        XCTAssertEqual(model.visibleWeekOccurrences.count, 5, "Weekly repeats continue into the fall-back week")
        model.showPreviousWeek()
        model.showPreviousWeek()
        XCTAssertEqual(model.visibleWeekOccurrences.count, 0, "Nothing before the samples' first week")
        model.showCurrentWeek()
        await model.clearSampleActivities()
        XCTAssertEqual(model.visibleWeekOccurrences, [])
    }

    func testLoadSampleActivitiesTwiceIsIdempotent() async throws {
        let repository = InMemoryActivityRepository()
        let model = TestFixtures.makeModel(repository: repository)
        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivities.count, 2)
        XCTAssertTrue(model.allSamplesLoaded)
        XCTAssertEqual(model.sampleActivitiesMessage, "Added 2 sample activities to the calendar.")
        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivities.count, 2)
        XCTAssertEqual(model.sampleActivitiesMessage, "The sample schedule is already loaded; nothing was added.")
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(model.sampleActivities.map(\.id)), SampleActivities.ids)
        XCTAssertTrue(model.sampleActivities.allSatisfy { $0.title.localizedCaseInsensitiveContains("sample") })
        XCTAssertEqual(model.activitiesStatus, .ready)
    }

    func testLoadSamplesRestoresAMissingSampleWithoutTouchingTheOther() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        try await model.deleteActivity(id: SampleActivities.afternoonLabID)
        XCTAssertEqual(model.sampleActivities.map(\.id), [SampleActivities.morningClassID])
        XCTAssertFalse(model.allSamplesLoaded)
        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "Added 1 sample activity to the calendar.")
        XCTAssertEqual(Set(model.sampleActivities.map(\.id)), SampleActivities.ids)
    }

    func testClearSamplesKeepsUserActivitiesIncludingFutureOnes() async throws {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        let pastUser = TestFixtures.activity(title: "Past study group", start: TestFixtures.date(2026, 9, 1, 10))
        let futureUser = TestFixtures.activity(title: "Future exam", start: TestFixtures.date(2026, 12, 15, 8))
        try await model.saveActivity(pastUser)
        try await model.saveActivity(futureUser)
        await model.loadSampleActivities()
        XCTAssertEqual(model.activities.count, 4)
        await model.clearSampleActivities()
        XCTAssertEqual(model.activities, [pastUser, futureUser])
        XCTAssertEqual(model.sampleActivities, [])
        XCTAssertEqual(model.userActivities.map(\.title), ["Past study group", "Future exam"])
        XCTAssertEqual(model.sampleActivitiesMessage, "Removed 2 sample activities. Activities you added yourself were kept.")
        await model.clearSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "There are no sample activities to remove.")
        XCTAssertEqual(model.activities.count, 2)
    }

    func testClearRemovesEditedSamplesBySourceNotByTitle() async throws {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        var edited = try XCTUnwrap(model.sampleActivities.first { $0.id == SampleActivities.morningClassID })
        edited.title = "Renamed by the user"
        try await model.saveActivity(edited)
        let userActivity = TestFixtures.activity(title: "Sample-looking user activity", start: monday9)
        try await model.saveActivity(userActivity)
        await model.clearSampleActivities()
        XCTAssertEqual(model.activities.map(\.title), ["Sample-looking user activity"])
    }

    func testSaveValidActivityAppearsSortedAndReplacesById() async throws {
        let model = TestFixtures.makeModel()
        await model.loadActivities()
        let second = TestFixtures.activity(title: "Second", start: monday9.addingTimeInterval(7_200))
        let first = TestFixtures.activity(title: "First", start: monday9)
        try await model.saveActivity(second)
        try await model.saveActivity(first)
        XCTAssertEqual(model.activities, [first, second])
        XCTAssertEqual(model.userActivities.count, 2)
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertFalse(model.isUpdatingActivities)
        var renamed = first
        renamed.title = "First, renamed"
        try await model.saveActivity(renamed)
        XCTAssertEqual(model.activities.map(\.title), ["First, renamed", "Second"], "Saving an existing id replaces it")
    }

    func testSaveInvalidActivityThrowsAndStoresNothing() async throws {
        let repository = InMemoryActivityRepository()
        let model = TestFixtures.makeModel(repository: repository)
        await model.loadActivities()
        let invalid = TestFixtures.activity(title: "", start: monday9, end: monday9)
        do {
            try await model.saveActivity(invalid)
            XCTFail("Expected a validation error")
        } catch let error as ActivityValidationError {
            XCTAssertEqual(error.issues, [.emptyTitle, .endNotAfterStart])
        }
        XCTAssertEqual(model.activities, [])
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [])
        XCTAssertEqual(model.activitiesStatus, .ready)
    }

    func testDeleteActivityRemovesItAndIgnoresUnknownIds() async throws {
        let model = TestFixtures.makeModel()
        let activity = TestFixtures.activity(start: monday9)
        try await model.saveActivity(activity)
        try await model.deleteActivity(id: UUID())
        XCTAssertEqual(model.activities, [activity])
        try await model.deleteActivity(id: activity.id)
        XCTAssertEqual(model.activities, [])
    }

    func testActivitiesSurviveTabSwitchesAndWeekNavigation() async {
        let model = TestFixtures.makeModel()
        await model.loadSampleActivities()
        model.selectedTab = .calendar
        model.showNextWeek()
        model.selectedTab = .map
        model.selectedTab = .settings
        model.selectedTab = .calendar
        XCTAssertEqual(model.sampleActivities.count, 2)
        XCTAssertFalse(model.isShowingCurrentWeek)
        XCTAssertEqual(model.visibleWeekOccurrences.count, 5)
    }

    func testFailedReadKeepsTheAppUsableAndRecovers() async {
        let repository = ScriptedActivityRepository()
        await repository.setFailReads(true)
        let model = TestFixtures.makeModel(repository: repository)
        await model.loadActivities()
        XCTAssertEqual(model.activities, [])
        XCTAssertNotNil(model.activitiesStatus.failureMessage)
        XCTAssertTrue(model.isShowingCurrentWeek)
        XCTAssertEqual(model.visibleWeekOccurrences, [])
        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "The sample schedule could not be stored. Nothing changed.")
        await repository.setFailReads(false)
        await model.loadActivities()
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertEqual(model.activities, [])
    }

    func testFailedWriteIsReportedAndLeavesStateUnchanged() async throws {
        let seededSample = try XCTUnwrap(SampleActivities.make(weekContaining: TestFixtures.fridayNoon, timeZone: TestFixtures.pacific, destination: TestFixtures.demoDestination).first)
        let repository = ScriptedActivityRepository(initial: [seededSample])
        let model = TestFixtures.makeModel(repository: repository)
        await model.loadActivities()
        XCTAssertEqual(model.activities, [seededSample])
        await repository.setFailWrites(true)

        do {
            try await model.saveActivity(TestFixtures.activity(start: monday9))
            XCTFail("Expected a storage error")
        } catch let error as ActivityStorageError {
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertEqual(model.activities, [seededSample])
        XCTAssertNotNil(model.activitiesStatus.failureMessage)

        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "The sample schedule could not be stored. Nothing changed.")
        await model.clearSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "Sample activities could not be removed. Nothing changed.")
        XCTAssertEqual(model.activities, [seededSample])

        do {
            try await model.deleteActivity(id: seededSample.id)
            XCTFail("Expected a storage error")
        } catch is ActivityStorageError {
            // expected
        }
        let writes = await repository.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(model.isUpdatingActivities)

        await repository.setFailWrites(false)
        await model.clearSampleActivities()
        XCTAssertEqual(model.activities, [])
        XCTAssertEqual(model.activitiesStatus, .ready)
    }

    func testSampleActionsRecordFeedbackForTheSettingsTab() async {
        let model = TestFixtures.makeModel()
        XCTAssertNil(model.sampleActivitiesMessage)
        await model.clearSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "There are no sample activities to remove.")
        await model.loadSampleActivities()
        XCTAssertEqual(model.sampleActivitiesMessage, "Added 2 sample activities to the calendar.")
        XCTAssertEqual(CountPhrase.make(1, singular: "activity", plural: "activities"), "1 activity")
        XCTAssertEqual(CountPhrase.make(0, singular: "activity", plural: "activities"), "0 activities")
    }
}
