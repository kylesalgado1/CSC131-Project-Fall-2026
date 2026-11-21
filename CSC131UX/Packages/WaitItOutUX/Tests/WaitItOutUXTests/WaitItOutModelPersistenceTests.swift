import XCTest
@testable import WaitItOutUX

/// Step 0007 persistence through real JSON files in a fresh temporary folder per test: the
/// schedule and settings survive a relaunch (a second model on the same folder), empty storage
/// is not a failure, damaged or newer files are reported and never overwritten, Try Again and
/// Keep a Copy and Start Over recover, and departures are never stored. The failed-write test
/// keeps the same JSON files in `InMemoryFileAccess`, which can refuse writes, and checks that
/// the last saved data survives a relaunch.
///
/// Fixture clock: Fri 2026-10-30 12:00 PDT. The next sample trip is the class on Mon 2026-11-02
/// (arrival 8:15 AM PST, leave home 7:15 AM with the 60-minute test commute).
@MainActor
final class WaitItOutModelPersistenceTests: XCTestCase {
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestFixtures.date(year, month, day, hour, minute)
    }

    private var mondayClass: OccurrenceID {
        OccurrenceID(activityID: SampleActivities.morningClassID, date: LocalDate.of(pacific(2026, 11, 2, 12), in: TestFixtures.pacific))
    }

    private let damagedBytes = Data("This is not a WAIT IT OUT file".utf8)

    /// A unique empty folder, removed when the test ends.
    private func makeLocation() throws -> PrototypeStorageLocation {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WaitItOutUXPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PrototypeStorageLocation(directory: directory)
    }

    /// A model over the JSON files in `location`, as the host composes it, before anything loads.
    /// `files` is the real disk unless a test injects `InMemoryFileAccess` to make writes fail.
    private func makeModel(
        on location: PrototypeStorageLocation,
        files: any FileAccessing = LocalFileAccess(),
        clock: any WallClock = FixedWallClock(TestFixtures.fridayNoon),
        reminderScheduler: (any ReminderScheduling)? = nil
    ) -> WaitItOutModel {
        WaitItOutModel(
            clock: clock,
            preferencesStore: FilePreferencesStore(fileURL: location.preferencesFile, files: files, clock: clock),
            activityRepository: FileActivityRepository(fileURL: location.activitiesFile, files: files, clock: clock),
            commuteEstimator: nil,
            reminderScheduler: reminderScheduler,
            weekCalculator: WeekCalculator(timeZone: TestFixtures.pacific, locale: TestFixtures.enUS),
            sampleCampus: .demoCampus,
            prototypeInfo: PrototypeInfo(appName: "Test", version: "1", build: "1")
        )
    }

    /// A launch: settings first, then the schedule, then every estimate and reminder settles.
    private func launch(_ location: PrototypeStorageLocation, files: any FileAccessing = LocalFileAccess()) async -> WaitItOutModel {
        let model = makeModel(on: location, files: files)
        await model.loadPreferences()
        await model.loadActivities()
        await settle(model)
        return model
    }

    private func settle(_ model: WaitItOutModel) async {
        await model.waitForDepartures()
        await model.waitForReminders()
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func backupName(for fileBase: String) -> String {
        "\(fileBase).unreadable-\(Int(TestFixtures.fridayNoon.timeIntervalSince1970)).json"
    }

    private func assertSaveRefused(
        _ model: WaitItOutModel,
        _ activity: Activity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await model.saveActivity(activity)
            XCTFail("Saving must be refused while stored activities cannot be read", file: file, line: line)
        } catch let error as ActivityStorageError {
            XCTAssertFalse(error.message.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: Relaunch

    func testSampleScheduleSurvivesRelaunch() async throws {
        let location = try makeLocation()
        let first = await launch(location)
        await first.loadSampleActivities()
        XCTAssertEqual(first.activities.count, 2)
        let saved = first.activities

        let second = await launch(location)

        XCTAssertEqual(second.activitiesStatus, .ready)
        XCTAssertNil(second.activityStorageIssue)
        XCTAssertEqual(second.activities, saved, "Same ids, times, repeat days, zones, and destinations")
        XCTAssertEqual(second.activities.map(\.id), saved.map(\.id))
        XCTAssertTrue(second.allSamplesLoaded)
        let morningClass = try XCTUnwrap(second.activities.first { $0.id == SampleActivities.morningClassID })
        XCTAssertEqual(morningClass.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertEqual(morningClass.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(morningClass.destination.id, SampleLocation.demoCampus.destinationID)
        XCTAssertEqual(morningClass.source, .sample)
        let lab = try XCTUnwrap(second.activities.first { $0.id == SampleActivities.afternoonLabID })
        XCTAssertEqual(lab.repeatWeekdays, [.tuesday, .thursday])

        let trip = try XCTUnwrap(second.nextTrip(at: TestFixtures.fridayNoon))
        XCTAssertEqual(trip.occurrence.id, mondayClass)
        XCTAssertEqual(trip.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15), "State is \(trip.state)")

        await second.loadSampleActivities()
        XCTAssertEqual(second.activities, saved, "Loading the samples again after a relaunch adds nothing")
    }

    func testUserActivityAddEditAndDeleteSurviveRelaunch() async throws {
        let location = try makeLocation()
        let first = await launch(location)
        let lecture = TestFixtures.activity(
            title: "Persisted lecture",
            start: pacific(2026, 11, 2, 13),
            repeatWeekdays: [.monday, .wednesday]
        )
        let doomed = TestFixtures.activity(title: "Removed seminar", start: pacific(2026, 11, 3, 15))
        try await first.saveActivity(lecture)
        try await first.saveActivity(doomed)
        var edited = lecture
        edited.title = "Edited lecture"
        edited.idealArrival = lecture.start.addingTimeInterval(-30 * 60)
        try await first.saveActivity(edited)
        try await first.deleteActivity(id: doomed.id)
        XCTAssertEqual(first.activities, [edited])

        let second = await launch(location)

        XCTAssertNil(second.activityStorageIssue)
        XCTAssertEqual(second.activities, [edited])
        let restored = try XCTUnwrap(second.activities.first)
        XCTAssertEqual(restored.id, lecture.id)
        XCTAssertEqual(restored.title, "Edited lecture")
        XCTAssertEqual(restored.idealArrival, pacific(2026, 11, 2, 12, 30))
        XCTAssertEqual(restored.repeatWeekdays, [.monday, .wednesday])
        XCTAssertEqual(restored.source, .user)
    }

    func testSettingsSurviveRelaunch() async throws {
        let location = try makeLocation()
        let first = await launch(location)
        first.setAppearance(.dark)
        XCTAssertNil(first.applyTestCommuteMinutes("45"))
        first.setTestCommuteScenario(.slow)
        let homeIssues = first.applyPlaceInput(PlaceInput(name: "Test apartment", latitude: "38.6", longitude: "-121.5"), for: .home)
        XCTAssertEqual(homeIssues, [])
        let campus = try CommutePlace(name: "Test campus annex", coordinate: GeoCoordinate(latitude: 38.55, longitude: -121.42))
        first.setPlace(campus, for: .campus)
        first.setRemindersEnabled(true)
        first.setSimulatesReminderFailure(true)
        await first.flushPendingSaves()
        let expected = first.preferences
        XCTAssertEqual(first.preferencesStatus, .ready)

        let second = makeModel(on: location)
        await second.loadPreferences()

        XCTAssertNil(second.preferencesStorageIssue)
        XCTAssertEqual(second.preferencesStatus, .ready)
        XCTAssertEqual(second.preferences, expected)
        XCTAssertEqual(second.preferences.appearance, .dark)
        XCTAssertEqual(second.testCommuteDuration, try CommuteDuration.minutes(45))
        XCTAssertEqual(second.testCommuteScenario, .slow)
        XCTAssertEqual(second.places.home.name, "Test apartment")
        XCTAssertEqual(second.places.home.coordinate, GeoCoordinate(latitude: 38.6, longitude: -121.5))
        XCTAssertEqual(second.places.campus, campus)
        XCTAssertEqual(second.campusDestination.name, "Test campus annex")
        XCTAssertTrue(second.remindersEnabled)
        XCTAssertTrue(second.simulatesReminderFailure)
        XCTAssertEqual(second.testCommuteProvider?.configuration.duration, try CommuteDuration.minutes(45))
        XCTAssertEqual(second.testCommuteProvider?.configuration.scenario, .slow)
        XCTAssertEqual(second.previewReminderScheduler?.simulatesFailure, true)
    }

    func testEmptyStorageLaunchesReadyWithoutAnIssue() async throws {
        let location = try makeLocation()
        let model = await launch(location)

        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertEqual(model.preferencesStatus, .ready)
        XCTAssertNil(model.activityStorageIssue)
        XCTAssertNil(model.preferencesStorageIssue)
        XCTAssertNil(model.storageRecoveryMessage)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertEqual(model.preferences.appearance, .system)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertEqual(model.testCommuteDuration, .testDefault)
        XCTAssertEqual(model.testCommuteScenario, .normal)
    }

    // MARK: Unreadable activities

    func testDamagedActivitiesFileIsReportedAndNeverOverwritten() async throws {
        let location = try makeLocation()
        try damagedBytes.write(to: location.activitiesFile)

        let model = await launch(location)

        let issue = try XCTUnwrap(model.activityStorageIssue)
        XCTAssertEqual(issue.area, .activities)
        XCTAssertEqual(issue.error, .damaged)
        XCTAssertNotNil(model.activitiesStatus.failureMessage)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertEqual(model.reminderSync, .paused)
        XCTAssertNil(model.preferencesStorageIssue, "Settings are a separate file and still load")

        await assertSaveRefused(model, TestFixtures.activity(title: "Refused lecture", start: pacific(2026, 11, 2, 13)))
        await model.loadSampleActivities()
        XCTAssertTrue(model.activities.isEmpty, "The samples are not stored over an unreadable file")
        XCTAssertNotNil(model.activitiesStatus.failureMessage)
        XCTAssertEqual(try Data(contentsOf: location.activitiesFile), damagedBytes)
    }

    func testTryAgainReadsTheActivitiesFileOnceItIsReadable() async throws {
        let location = try makeLocation()
        try damagedBytes.write(to: location.activitiesFile)
        let model = await launch(location)
        XCTAssertNotNil(model.activityStorageIssue)

        await model.retryLoadingStorage()
        XCTAssertNotNil(model.activityStorageIssue)
        XCTAssertEqual(model.storageRecoveryMessage, "Saved data still could not be read. Nothing was overwritten.")
        XCTAssertEqual(try Data(contentsOf: location.activitiesFile), damagedBytes)

        let elsewhere = try makeLocation()
        let lecture = TestFixtures.activity(title: "Recovered lecture", start: pacific(2026, 11, 2, 13))
        let writer = FileActivityRepository(fileURL: elsewhere.activitiesFile)
        try await writer.upsert([lecture])
        let validBytes = try Data(contentsOf: elsewhere.activitiesFile)
        try validBytes.write(to: location.activitiesFile, options: .atomic)

        await model.retryLoadingStorage()
        await settle(model)

        XCTAssertNil(model.activityStorageIssue)
        XCTAssertFalse(model.isRecoveringStorage)
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertEqual(model.activities, [lecture])
        XCTAssertEqual(model.storageRecoveryMessage, "Saved data was read successfully.")
        XCTAssertNotEqual(model.reminderSync, .paused)
    }

    func testKeepACopyAndStartOverSetsTheDamagedFileAsideAndSavesAgain() async throws {
        let location = try makeLocation()
        try damagedBytes.write(to: location.activitiesFile)
        let model = await launch(location)
        XCTAssertNotNil(model.activityStorageIssue)

        await model.setAsideUnreadableStorage()
        await settle(model)

        XCTAssertNil(model.activityStorageIssue)
        XCTAssertFalse(model.isRecoveringStorage)
        XCTAssertEqual(model.activitiesStatus, .ready)
        XCTAssertTrue(model.activities.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: location.directory.path(percentEncoded: false))
        let backups = names.filter { $0.hasPrefix("activities.unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups, [backupName(for: "activities")])
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: location.directory.appending(path: backup, directoryHint: .notDirectory)), damagedBytes)
        XCTAssertFalse(fileExists(location.activitiesFile))
        XCTAssertEqual(model.storageRecoveryMessage?.contains(backup), true)

        let lecture = TestFixtures.activity(title: "Fresh start lecture", start: pacific(2026, 11, 2, 13))
        try await model.saveActivity(lecture)
        XCTAssertEqual(model.activities, [lecture])
        XCTAssertTrue(fileExists(location.activitiesFile))

        let relaunched = await launch(location)
        XCTAssertNil(relaunched.activityStorageIssue)
        XCTAssertEqual(relaunched.activities, [lecture])
    }

    func testNewerStorageFormatIsReportedAndNeverOverwritten() async throws {
        let location = try makeLocation()
        let newer = Data(#"{"kind": "activities", "payload": "from a later version", "schemaVersion": 7}"#.utf8)
        try newer.write(to: location.activitiesFile)

        let model = await launch(location)

        XCTAssertEqual(model.activityStorageIssue?.error, .unsupportedVersion(found: 7, supported: 1))
        XCTAssertEqual(model.activityStorageIssue?.message.contains("format 7"), true)
        XCTAssertNotNil(model.activitiesStatus.failureMessage)
        await assertSaveRefused(model, TestFixtures.activity(title: "Refused lecture", start: pacific(2026, 11, 2, 13)))
        XCTAssertEqual(try Data(contentsOf: location.activitiesFile), newer)
    }

    // MARK: Unreadable settings

    func testDamagedSettingsFileKeepsDefaultsAndIsNotOverwrittenUntilSetAside() async throws {
        let location = try makeLocation()
        try damagedBytes.write(to: location.preferencesFile)

        let model = await launch(location)

        let issue = try XCTUnwrap(model.preferencesStorageIssue)
        XCTAssertEqual(issue.area, .settings)
        XCTAssertEqual(issue.error, .damaged)
        XCTAssertNotNil(model.preferencesStatus.failureMessage)
        XCTAssertNil(model.activityStorageIssue, "Activities are a separate file and still load")
        XCTAssertEqual(model.preferences.appearance, .system)
        XCTAssertEqual(model.testCommuteDuration, .testDefault)
        XCTAssertEqual(model.testCommuteScenario, .normal)
        XCTAssertFalse(model.remindersEnabled)

        model.setAppearance(.dark)
        await model.flushPendingSaves()
        XCTAssertEqual(model.preferences.appearance, .dark, "The change applies now")
        XCTAssertNotNil(model.preferencesStatus.failureMessage, "but is not saved")
        XCTAssertEqual(try Data(contentsOf: location.preferencesFile), damagedBytes)

        await model.setAsideUnreadableStorage()
        await model.flushPendingSaves()

        XCTAssertNil(model.preferencesStorageIssue)
        XCTAssertEqual(model.preferencesStatus, .ready)
        XCTAssertEqual(model.preferences.appearance, .dark, "The settings in effect are kept")
        let backupURL = location.directory.appending(path: backupName(for: "preferences"), directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: backupURL), damagedBytes)

        let relaunched = makeModel(on: location)
        await relaunched.loadPreferences()
        XCTAssertNil(relaunched.preferencesStorageIssue)
        XCTAssertEqual(relaunched.preferences.appearance, .dark, "The current settings were saved after setting the file aside")
    }

    // MARK: Departures are derived

    func testDeparturesAndRemindersAreNeverStored() async throws {
        let location = try makeLocation()
        let first = await launch(location)
        await first.loadSampleActivities()
        first.setRemindersEnabled(true)
        await settle(first)
        await first.flushPendingSaves()
        XCTAssertEqual(first.departures[mondayClass]?.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15))
        XCTAssertFalse(first.reminderPreviews.isEmpty)

        let activitiesText = try String(contentsOf: location.activitiesFile, encoding: .utf8)
        for key in ["leaveHome", "travelTime", "estimatedAt", "departure", "fireDate"] {
            XCTAssertFalse(activitiesText.contains(key), "activities.json must not contain \(key)")
        }
        let preferencesText = try String(contentsOf: location.preferencesFile, encoding: .utf8)
        for key in ["\"leaveHome\"", "travelTime", "estimatedAt", "departure", "fireDate"] {
            XCTAssertFalse(preferencesText.contains(key), "preferences.json must not contain \(key)")
        }

        let second = makeModel(on: location)
        await second.loadPreferences()
        await second.loadActivities()
        XCTAssertFalse(second.departures.isEmpty)
        XCTAssertTrue(second.departures.values.allSatisfy { $0.state == .loading }, "Recalculated after launch, never restored")
        await settle(second)
        XCTAssertEqual(second.departures[mondayClass]?.state.calculation?.leaveHome, pacific(2026, 11, 2, 7, 15))
        XCTAssertEqual(second.reminderPreviews.map(\.fireDate), first.reminderPreviews.map(\.fireDate))
    }

    // MARK: Failed writes

    /// Writes start failing (a full or read-only disk) after the samples, the reminder wish, and
    /// the settings were saved. Every change is refused with a message and nothing on disk
    /// changes; the schedule and its reminders stay on the last saved data, and a relaunch reads
    /// exactly that data. Once writing works again, the next save is stored.
    func testFailedWritesKeepTheLastSavedDataThroughARelaunch() async throws {
        let files = InMemoryFileAccess()
        let location = PrototypeStorageLocation(directory: URL(filePath: "/WaitItOutUXTests/FailedWrites", directoryHint: .isDirectory))
        let first = await launch(location, files: files)
        await first.loadSampleActivities()
        first.setRemindersEnabled(true)
        await settle(first)
        await first.flushPendingSaves()
        let saved = first.activities
        let previews = first.reminderPreviews
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(previews.first?.id, mondayClass)
        XCTAssertEqual(previews.count, 5)
        let savedSchedule = try XCTUnwrap(files.data(at: location.activitiesFile))
        let savedSettings = try XCTUnwrap(files.data(at: location.preferencesFile))
        let writesBefore = files.writeCount

        files.setFailWrites(true)
        let lecture = TestFixtures.activity(title: "Afternoon lecture", start: pacific(2026, 11, 2, 13))
        let notStored = "The change could not be stored. The calendar shows the last schedule that was read successfully."
        do {
            try await first.saveActivity(lecture)
            XCTFail("Saving must fail while the file cannot be written")
        } catch let error as ActivityStorageError {
            XCTAssertEqual(error.message, notStored)
        }
        do {
            try await first.deleteActivity(id: SampleActivities.morningClassID)
            XCTFail("Deleting must fail while the file cannot be written")
        } catch let error as ActivityStorageError {
            XCTAssertEqual(error.message, notStored)
        }
        first.setAppearance(.dark)
        await first.flushPendingSaves()
        await settle(first)

        XCTAssertEqual(first.activities, saved, "The calendar keeps the last saved schedule")
        XCTAssertEqual(first.activitiesStatus.failureMessage, notStored)
        XCTAssertNil(first.activityStorageIssue, "A failed write is not an unreadable file, so nothing is paused")
        XCTAssertFalse(first.isUpdatingActivities)
        XCTAssertEqual(first.reminderPreviews, previews, "Reminders still follow the saved schedule")
        XCTAssertEqual(first.reminderSync, .synced)
        XCTAssertEqual(first.preferences.appearance, .dark, "The setting applies now")
        XCTAssertEqual(first.preferencesStatus.failureMessage, "Your settings apply now but could not be saved.")
        XCTAssertNil(first.preferencesStorageIssue)
        XCTAssertEqual(files.data(at: location.activitiesFile), savedSchedule, "The previous files are unchanged")
        XCTAssertEqual(files.data(at: location.preferencesFile), savedSettings)
        XCTAssertEqual(files.writeCount, writesBefore)

        let relaunched = await launch(location, files: files)
        XCTAssertNil(relaunched.activityStorageIssue)
        XCTAssertNil(relaunched.preferencesStorageIssue)
        XCTAssertEqual(relaunched.activities, saved, "A relaunch reads the last saved schedule")
        XCTAssertEqual(relaunched.preferences.appearance, .system, "and the last saved settings")
        XCTAssertTrue(relaunched.remindersEnabled)
        XCTAssertEqual(relaunched.reminderPreviews, previews, "The previews are recreated from the saved schedule")

        files.setFailWrites(false)
        try await first.saveActivity(lecture)
        XCTAssertEqual(first.activitiesStatus, .ready)
        XCTAssertEqual(files.writeCount, writesBefore + 1)
        let afterRecovery = await launch(location, files: files)
        XCTAssertEqual(Set(afterRecovery.activities), Set(saved + [lecture]))
    }
}
