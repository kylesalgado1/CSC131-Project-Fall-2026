import XCTest
@testable import WaitItOutUX

/// Step 0007: activities and preferences in versioned JSON files.
///
/// A missing file is empty storage, not a failure. A damaged, foreign, or newer file is reported
/// and never overwritten: every write is refused until the file is set aside explicitly under a
/// new name. A failed write keeps the previous valid data on disk and in memory. Most tests use
/// `InMemoryFileAccess`; the last one runs `LocalFileAccess` against the real disk.
final class PersistenceStoreTests: XCTestCase {
    private let storageLocation = PrototypeStorageLocation(
        directory: URL(filePath: "/WaitItOutUXTests/Storage", directoryHint: .isDirectory)
    )
    /// Files are set aside at `fridayNoon` (1 793 386 800 seconds since 1970) unless a test
    /// passes its own clock.
    private let clock = FixedWallClock(TestFixtures.fridayNoon)
    private let activitiesBackupName = "activities.unreadable-1793386800.json"
    private let preferencesBackupName = "preferences.unreadable-1793386800.json"
    private let mondayNine = TestFixtures.mondayNine

    private func makeRepository(_ files: InMemoryFileAccess) -> FileActivityRepository {
        FileActivityRepository(fileURL: storageLocation.activitiesFile, files: files, clock: clock)
    }

    private func makeStore(_ files: InMemoryFileAccess) -> FilePreferencesStore {
        FilePreferencesStore(fileURL: storageLocation.preferencesFile, files: files, clock: clock)
    }

    /// Awaits `operation` and checks that it throws exactly `expected`. `XCTAssertThrowsError`
    /// cannot await, so this is the do/catch form in one place.
    private func assertThrows<Value>(
        _ expected: PersistenceError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Value
    ) async {
        do {
            let value = try await operation()
            XCTFail("Expected \(expected), got \(value). \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PersistenceError, expected, "\(error). \(message)", file: file, line: line)
        }
    }

    /// The stored file at `url`, parsed as a JSON object.
    private func storedDocument(
        _ files: InMemoryFileAccess,
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(files.data(at: url), "No file named \(url.lastPathComponent)", file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "The file is not a JSON object", file: file, line: line)
    }

    private func backupURL(_ name: String) -> URL {
        storageLocation.directory.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: Empty storage and round trips

    func testMissingFilesAreEmptyStorageAndReadingWritesNothing() async throws {
        let files = InMemoryFileAccess()
        let repository = makeRepository(files)
        let firstRead = try await repository.fetchAll()
        let secondRead = try await repository.fetchAll()
        XCTAssertEqual(firstRead, [])
        XCTAssertEqual(secondRead, [])

        let store = makeStore(files)
        let preferences = try await store.loadPreferences()
        XCTAssertNil(preferences, "No file means nothing was saved yet, which is not a failure")

        let activitiesSetAside = try await repository.setAsideUnreadableData()
        let preferencesSetAside = try await store.setAsideUnreadableData()
        XCTAssertNil(activitiesSetAside)
        XCTAssertNil(preferencesSetAside)

        XCTAssertEqual(files.writeCount, 0, "Reading never writes")
        XCTAssertEqual(files.moveCount, 0)
        XCTAssertEqual(files.storedFileNames, [])
        XCTAssertTrue(repository.persistenceDescription.contains("Application Support"))
        XCTAssertTrue(store.persistenceDescription.contains("Application Support"))
    }

    func testActivitiesRoundTripThroughASecondRepository() async throws {
        let files = InMemoryFileAccess()
        let samples = SampleActivities.make(
            weekContaining: TestFixtures.fridayNoon,
            timeZone: TestFixtures.pacific,
            destination: TestFixtures.demoDestination
        )
        XCTAssertEqual(samples.count, 2)
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let tokyoStart = TestFixtures.date(2026, 10, 28, 18, 30, in: tokyo)
        let studyRoom = Destination(
            id: DestinationID("user-study-room"),
            name: "Study room",
            coordinate: GeoCoordinate(latitude: 35.6812, longitude: 139.7671)
        )
        let session = TestFixtures.activity(
            title: "Study group",
            start: tokyoStart,
            end: tokyoStart.addingTimeInterval(90 * 60),
            arrival: tokyoStart.addingTimeInterval(-20 * 60),
            timeZone: tokyo,
            destination: studyRoom
        )
        let schedule = samples + [session]

        try await makeRepository(files).upsert(schedule)
        XCTAssertEqual(files.writeCount, 1, "One call is one atomic write of the whole schedule")
        XCTAssertEqual(files.writtenURLs.map(\.lastPathComponent), ["activities.json"])

        let restored = try await makeRepository(files).fetchAll()
        XCTAssertEqual(restored.count, schedule.count)
        XCTAssertEqual(Set(restored), Set(schedule))

        let byID = Dictionary(restored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let morning = try XCTUnwrap(byID[SampleActivities.morningClassID])
        XCTAssertEqual(morning.repeatWeekdays, [.monday, .wednesday, .friday])
        XCTAssertEqual(morning.source, .sample)
        XCTAssertEqual(morning.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(morning.destination, TestFixtures.demoDestination)
        let lab = try XCTUnwrap(byID[SampleActivities.afternoonLabID])
        XCTAssertEqual(lab.repeatWeekdays, [.tuesday, .thursday])
        XCTAssertEqual(lab.source, .sample)

        let restoredSession = try XCTUnwrap(byID[session.id])
        XCTAssertNil(restoredSession.repeatWeekdays)
        XCTAssertEqual(restoredSession.source, .user)
        XCTAssertEqual(restoredSession.title, "Study group")
        XCTAssertEqual(restoredSession.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(restoredSession.destination.id, DestinationID("user-study-room"))
        XCTAssertEqual(restoredSession.destination.name, "Study room")
        XCTAssertEqual(restoredSession.destination.coordinate, GeoCoordinate(latitude: 35.6812, longitude: 139.7671))
        XCTAssertEqual(restoredSession.start, tokyoStart)
        XCTAssertEqual(restoredSession.end, tokyoStart.addingTimeInterval(90 * 60))
        XCTAssertEqual(restoredSession.idealArrival, tokyoStart.addingTimeInterval(-20 * 60))
        XCTAssertEqual(files.writeCount, 1, "Reading writes nothing")
    }

    func testStoredFilesUseTheVersionedEnvelope() async throws {
        let files = InMemoryFileAccess()
        let lecture = TestFixtures.activity(title: "Lecture", start: mondayNine, repeatWeekdays: [.monday])
        try await makeRepository(files).upsert(lecture)

        let activitiesDocument = try storedDocument(files, at: storageLocation.activitiesFile)
        XCTAssertEqual(Set(activitiesDocument.keys), ["schemaVersion", "kind", "payload"])
        XCTAssertEqual(StorageSchema.currentVersion, 1)
        XCTAssertEqual(activitiesDocument["schemaVersion"] as? Int, 1)
        XCTAssertEqual(activitiesDocument["kind"] as? String, "activities")
        XCTAssertEqual(FileActivityRepository.documentKind, "activities")
        let storedActivities = try XCTUnwrap(activitiesDocument["payload"] as? [[String: Any]])
        XCTAssertEqual(storedActivities.count, 1)
        let storedLecture = try XCTUnwrap(storedActivities.first)
        XCTAssertEqual(
            Set(storedLecture.keys),
            ["id", "title", "start", "end", "idealArrival", "destination", "timeZoneIdentifier", "repeatWeekdays", "source"],
            "Only the activity itself is stored: no departure, estimate, or reminder"
        )
        XCTAssertEqual(storedLecture["id"] as? String, lecture.id.uuidString)
        XCTAssertEqual(storedLecture["title"] as? String, "Lecture")
        XCTAssertEqual(storedLecture["timeZoneIdentifier"] as? String, "America/Los_Angeles")
        XCTAssertEqual(storedLecture["start"] as? Double, mondayNine.timeIntervalSinceReferenceDate)

        try await makeStore(files).savePreferences(UserPreferences(appearance: .dark))
        let preferencesDocument = try storedDocument(files, at: storageLocation.preferencesFile)
        XCTAssertEqual(Set(preferencesDocument.keys), ["schemaVersion", "kind", "payload"])
        XCTAssertEqual(preferencesDocument["schemaVersion"] as? Int, 1)
        XCTAssertEqual(preferencesDocument["kind"] as? String, "preferences")
        XCTAssertEqual(FilePreferencesStore.documentKind, "preferences")
        let payload = try XCTUnwrap(preferencesDocument["payload"] as? [String: Any])
        XCTAssertEqual(
            Set(payload.keys),
            ["appearance", "testCommuteDuration", "testCommuteScenario", "places", "leaveHomeRemindersEnabled", "simulatesReminderFailure"],
            "Settings only: no departure result is stored"
        )
        XCTAssertEqual(payload["appearance"] as? String, "dark")
        XCTAssertEqual(files.writtenURLs.map(\.lastPathComponent), ["activities.json", "preferences.json"])
    }

    func testTheSameOneTimeScheduleWritesIdenticalBytesInStartOrder() async throws {
        let early = TestFixtures.activity(title: "Early", start: mondayNine)
        let late = TestFixtures.activity(title: "Late", start: mondayNine.addingTimeInterval(3 * 3_600))
        let first = InMemoryFileAccess()
        try await makeRepository(first).upsert([late, early])
        let second = InMemoryFileAccess()
        try await makeRepository(second).upsert([early, late])

        let firstBytes = try XCTUnwrap(first.data(at: storageLocation.activitiesFile))
        XCTAssertEqual(firstBytes, second.data(at: storageLocation.activitiesFile))
        let document = try storedDocument(first, at: storageLocation.activitiesFile)
        let payload = try XCTUnwrap(document["payload"] as? [[String: Any]])
        XCTAssertEqual(payload.map { $0["title"] as? String }, ["Early", "Late"])
    }

    func testUpsertReplacesByIdAndDeleteIgnoresUnknownIds() async throws {
        let files = InMemoryFileAccess()
        let repository = makeRepository(files)
        let keep = TestFixtures.activity(title: "Keep", start: mondayNine)
        let drop = TestFixtures.activity(title: "Drop", start: mondayNine.addingTimeInterval(7_200))
        try await repository.upsert([keep, drop])

        var renamed = keep
        renamed.title = "Kept and renamed"
        try await repository.upsert(renamed)
        let afterRename = try await repository.fetchAll()
        XCTAssertEqual(afterRename.count, 2)
        XCTAssertEqual(Set(afterRename), [renamed, drop])

        try await repository.delete(ids: [drop.id, UUID()])
        try await repository.delete(id: UUID())
        let afterDelete = try await repository.fetchAll()
        XCTAssertEqual(afterDelete, [renamed])

        let reopened = try await makeRepository(files).fetchAll()
        XCTAssertEqual(reopened, [renamed])
    }

    // MARK: Unreadable files are reported and protected

    func testDamagedActivitiesFileIsReportedAndNeverOverwritten() async throws {
        let files = InMemoryFileAccess()
        let corrupt = Data("not json".utf8)
        files.setContents(corrupt, at: storageLocation.activitiesFile)
        let newActivity = TestFixtures.activity(title: "New", start: mondayNine)

        let unread = makeRepository(files)
        await assertThrows(.unreadableDataProtected, "A write before any read is refused too") {
            try await unread.upsert(newActivity)
        }

        let repository = makeRepository(files)
        await assertThrows(.damaged) { try await repository.fetchAll() }
        await assertThrows(.unreadableDataProtected) { try await repository.upsert(newActivity) }
        await assertThrows(.unreadableDataProtected) { try await repository.delete(ids: [UUID()]) }
        await assertThrows(.damaged, "Every read tries the file again") { try await repository.fetchAll() }

        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), corrupt, "The damaged bytes are unchanged")
        XCTAssertEqual(files.writeCount, 0)
        XCTAssertEqual(files.moveCount, 0)
        XCTAssertEqual(files.storedFileNames, ["activities.json"])
    }

    func testMalformedOrTruncatedEnvelopesAreDamaged() async throws {
        let seed = InMemoryFileAccess()
        try await makeRepository(seed).upsert(TestFixtures.activity(title: "Seed", start: mondayNine))
        let valid = try XCTUnwrap(seed.data(at: storageLocation.activitiesFile))
        let inputs: [(String, Data)] = [
            ("empty file", Data()),
            ("truncated file", valid.prefix(valid.count / 2)),
            ("JSON array", Data("[1, 2, 3]".utf8)),
            ("no schema version", Data(#"{"kind": "activities", "payload": []}"#.utf8)),
            ("schema version as text", Data(#"{"schemaVersion": "1", "kind": "activities", "payload": []}"#.utf8)),
            ("no kind", Data(#"{"schemaVersion": 1, "payload": []}"#.utf8)),
            ("no payload", Data(#"{"schemaVersion": 1, "kind": "activities"}"#.utf8)),
            ("payload not a list", Data(#"{"schemaVersion": 1, "kind": "activities", "payload": {}}"#.utf8)),
            ("null payload", Data(#"{"schemaVersion": 1, "kind": "activities", "payload": null}"#.utf8))
        ]
        for (label, bytes) in inputs {
            let files = InMemoryFileAccess()
            files.setContents(bytes, at: storageLocation.activitiesFile)
            let repository = makeRepository(files)
            await assertThrows(.damaged, label) { try await repository.fetchAll() }
            await assertThrows(.unreadableDataProtected, label) {
                try await repository.upsert(TestFixtures.activity(start: self.mondayNine))
            }
            XCTAssertEqual(files.data(at: storageLocation.activitiesFile), bytes, label)
            XCTAssertEqual(files.writeCount, 0, label)
        }
    }

    func testADocumentOfAnotherKindIsDamaged() async throws {
        let files = InMemoryFileAccess()
        try await makeStore(files).savePreferences(.default)
        try await makeRepository(files).upsert(TestFixtures.activity(start: mondayNine))
        let preferencesBytes = try XCTUnwrap(files.data(at: storageLocation.preferencesFile))
        let activitiesBytes = try XCTUnwrap(files.data(at: storageLocation.activitiesFile))

        let swapped = InMemoryFileAccess()
        swapped.setContents(preferencesBytes, at: storageLocation.activitiesFile)
        swapped.setContents(activitiesBytes, at: storageLocation.preferencesFile)
        let repository = makeRepository(swapped)
        await assertThrows(.damaged, "A valid settings file is not a schedule") { try await repository.fetchAll() }
        await assertThrows(.unreadableDataProtected) { try await repository.upsert(TestFixtures.activity(start: self.mondayNine)) }
        let store = makeStore(swapped)
        await assertThrows(.damaged, "A valid schedule is not a settings file") { try await store.loadPreferences() }
        await assertThrows(.unreadableDataProtected) { try await store.savePreferences(.default) }
        XCTAssertEqual(swapped.data(at: storageLocation.activitiesFile), preferencesBytes)
        XCTAssertEqual(swapped.data(at: storageLocation.preferencesFile), activitiesBytes)
        XCTAssertEqual(swapped.writeCount, 0)

        let unknownKind = InMemoryFileAccess()
        unknownKind.setContents(Data(#"{"schemaVersion": 1, "kind": "reminders", "payload": []}"#.utf8), at: storageLocation.activitiesFile)
        let other = makeRepository(unknownKind)
        await assertThrows(.damaged) { try await other.fetchAll() }
    }

    func testNewerStorageFormatIsReportedAndProtected() async throws {
        let files = InMemoryFileAccess()
        let newerSchedule = Data(#"{"schemaVersion": 99, "kind": "activities", "payload": []}"#.utf8)
        let newerSettings = Data(#"{"schemaVersion": 2, "kind": "preferences", "payload": {"theme": "midnight"}}"#.utf8)
        files.setContents(newerSchedule, at: storageLocation.activitiesFile)
        files.setContents(newerSettings, at: storageLocation.preferencesFile)

        let repository = makeRepository(files)
        await assertThrows(.unsupportedVersion(found: 99, supported: 1)) { try await repository.fetchAll() }
        await assertThrows(.unreadableDataProtected) { try await repository.upsert(TestFixtures.activity(start: self.mondayNine)) }

        let store = makeStore(files)
        await assertThrows(
            .unsupportedVersion(found: 2, supported: StorageSchema.currentVersion),
            "The version is checked before the payload"
        ) {
            try await store.loadPreferences()
        }
        await assertThrows(.unreadableDataProtected) { try await store.savePreferences(.default) }

        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), newerSchedule)
        XCTAssertEqual(files.data(at: storageLocation.preferencesFile), newerSettings)
        XCTAssertEqual(files.writeCount, 0)
    }

    func testSchemaVersionBelowOneIsDamaged() async {
        let inputs = [
            Data(#"{"schemaVersion": 0, "kind": "activities", "payload": []}"#.utf8),
            Data(#"{"schemaVersion": -1, "kind": "activities", "payload": []}"#.utf8)
        ]
        for bytes in inputs {
            let files = InMemoryFileAccess()
            files.setContents(bytes, at: storageLocation.activitiesFile)
            let repository = makeRepository(files)
            await assertThrows(.damaged) { try await repository.fetchAll() }
        }

        let settings = InMemoryFileAccess()
        settings.setContents(Data(#"{"schemaVersion": 0, "kind": "preferences", "payload": {}}"#.utf8), at: storageLocation.preferencesFile)
        let store = makeStore(settings)
        await assertThrows(.damaged) { try await store.loadPreferences() }
    }

    func testOneUndecodableActivityProtectsTheWholeFile() async throws {
        let files = InMemoryFileAccess()
        let readable = TestFixtures.activity(title: "Readable", start: mondayNine)
        try await makeRepository(files).upsert(readable)
        var document = try storedDocument(files, at: storageLocation.activitiesFile)
        var payload = try XCTUnwrap(document["payload"] as? [Any])
        let broken: [String: Any] = ["id": "not-a-uuid", "title": "Broken", "start": "yesterday"]
        payload.append(broken)
        document["payload"] = payload
        let mixed = try JSONSerialization.data(withJSONObject: document)
        files.setContents(mixed, at: storageLocation.activitiesFile)
        let writesBefore = files.writeCount

        let repository = makeRepository(files)
        await assertThrows(.damaged, "The readable activity is not returned on its own") {
            try await repository.fetchAll()
        }
        await assertThrows(.unreadableDataProtected, "Writing would drop the unreadable activity") {
            try await repository.upsert(readable)
        }
        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), mixed)
        XCTAssertEqual(files.writeCount, writesBefore)
    }

    func testReadFailureIsReportedAndTryAgainRereads() async throws {
        let files = InMemoryFileAccess()
        let stored = TestFixtures.activity(title: "Stored", start: mondayNine)
        let settings = UserPreferences(appearance: .light)
        try await makeRepository(files).upsert(stored)
        try await makeStore(files).savePreferences(settings)
        let writesBefore = files.writeCount
        files.setFailReads(true)

        let repository = makeRepository(files)
        let store = makeStore(files)
        await assertThrows(.readFailed) { try await repository.fetchAll() }
        await assertThrows(.unreadableDataProtected) { try await repository.upsert(stored) }
        await assertThrows(.readFailed) { try await store.loadPreferences() }
        await assertThrows(.unreadableDataProtected) { try await store.savePreferences(.default) }
        XCTAssertEqual(files.writeCount, writesBefore)

        files.setFailReads(false)
        let activities = try await repository.fetchAll()
        XCTAssertEqual(activities, [stored], "Try Again reads the file again")
        let preferences = try await store.loadPreferences()
        XCTAssertEqual(preferences, settings)

        let added = TestFixtures.activity(title: "Added", start: mondayNine.addingTimeInterval(3_600))
        try await repository.upsert(added)
        try await store.savePreferences(UserPreferences(appearance: .dark))
        XCTAssertEqual(files.writeCount, writesBefore + 2)
    }

    // MARK: Failed writes keep the previous data

    func testFailedWriteKeepsThePreviousSchedule() async throws {
        let files = InMemoryFileAccess()
        let repository = makeRepository(files)
        let first = TestFixtures.activity(title: "A", start: mondayNine)
        let second = TestFixtures.activity(title: "B", start: mondayNine.addingTimeInterval(3_600))
        try await repository.upsert(first)
        let savedBytes = try XCTUnwrap(files.data(at: storageLocation.activitiesFile))

        files.setFailWrites(true)
        await assertThrows(.writeFailed) { try await repository.upsert(second) }
        await assertThrows(.writeFailed) { try await repository.delete(id: first.id) }
        let inMemory = try await repository.fetchAll()
        XCTAssertEqual(inMemory, [first], "The repository keeps the last saved schedule")
        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), savedBytes)
        let onDisk = try await makeRepository(files).fetchAll()
        XCTAssertEqual(onDisk, [first])
        XCTAssertEqual(files.writeCount, 1)

        files.setFailWrites(false)
        try await repository.upsert(second)
        let afterRecovery = try await makeRepository(files).fetchAll()
        XCTAssertEqual(Set(afterRecovery), [first, second])
        XCTAssertEqual(files.writeCount, 2)
    }

    func testFailedPreferencesWriteKeepsThePreviousSettings() async throws {
        let files = InMemoryFileAccess()
        let store = makeStore(files)
        let saved = UserPreferences(appearance: .dark, testCommuteScenario: .slow)
        try await store.savePreferences(saved)
        let savedBytes = try XCTUnwrap(files.data(at: storageLocation.preferencesFile))

        files.setFailWrites(true)
        await assertThrows(.writeFailed) { try await store.savePreferences(UserPreferences(appearance: .light)) }
        XCTAssertEqual(files.data(at: storageLocation.preferencesFile), savedBytes)
        let reloaded = try await makeStore(files).loadPreferences()
        XCTAssertEqual(reloaded, saved)

        files.setFailWrites(false)
        try await store.savePreferences(UserPreferences(appearance: .light))
        let afterRecovery = try await makeStore(files).loadPreferences()
        XCTAssertEqual(afterRecovery, UserPreferences(appearance: .light))
    }

    // MARK: Setting unreadable data aside

    func testSetAsideMovesTheDamagedScheduleAndStartsEmpty() async throws {
        let files = InMemoryFileAccess()
        let corrupt = Data("not json".utf8)
        files.setContents(corrupt, at: storageLocation.activitiesFile)
        let repository = makeRepository(files)
        await assertThrows(.damaged) { try await repository.fetchAll() }

        let name = try await repository.setAsideUnreadableData()
        XCTAssertEqual(name, "activities.unreadable-1793386800.json")
        XCTAssertEqual(name, "activities.unreadable-\(Int(TestFixtures.fridayNoon.timeIntervalSince1970)).json")
        let backup = backupURL(activitiesBackupName)
        XCTAssertEqual(files.data(at: backup), corrupt, "The damaged bytes are kept under the new name")
        XCTAssertNil(files.data(at: storageLocation.activitiesFile))
        XCTAssertEqual(files.movedToURLs.map(\.lastPathComponent), [activitiesBackupName])
        XCTAssertEqual(files.writeCount, 0, "Setting aside writes nothing")

        let afterSetAside = try await repository.fetchAll()
        XCTAssertEqual(afterSetAside, [])
        let fresh = TestFixtures.activity(title: "Fresh start", start: mondayNine)
        try await repository.upsert(fresh)
        let reopened = try await makeRepository(files).fetchAll()
        XCTAssertEqual(reopened, [fresh])
        XCTAssertEqual(files.data(at: backup), corrupt, "The backup is never touched again")
        XCTAssertEqual(files.storedFileNames, ["activities.json", activitiesBackupName])
    }

    func testSetAsideLeavesReadableDataAlone() async throws {
        let files = InMemoryFileAccess()
        let stored = TestFixtures.activity(title: "Stored", start: mondayNine)
        try await makeRepository(files).upsert(stored)
        try await makeStore(files).savePreferences(UserPreferences(appearance: .dark))

        let repository = makeRepository(files)
        let activitiesName = try await repository.setAsideUnreadableData()
        XCTAssertNil(activitiesName)
        let store = makeStore(files)
        let preferencesName = try await store.setAsideUnreadableData()
        XCTAssertNil(preferencesName)
        XCTAssertEqual(files.moveCount, 0)
        XCTAssertEqual(files.storedFileNames, ["activities.json", "preferences.json"])
        let activities = try await repository.fetchAll()
        XCTAssertEqual(activities, [stored])
        let preferences = try await store.loadPreferences()
        XCTAssertEqual(preferences?.appearance, .dark)

        // A file that failed to read but is readable again is not set aside either.
        let flaky = InMemoryFileAccess()
        try await makeRepository(flaky).upsert(stored)
        flaky.setFailReads(true)
        let recovering = makeRepository(flaky)
        await assertThrows(.readFailed) { try await recovering.fetchAll() }
        flaky.setFailReads(false)
        let recoveredName = try await recovering.setAsideUnreadableData()
        XCTAssertNil(recoveredName)
        XCTAssertEqual(flaky.moveCount, 0)
        let recovered = try await recovering.fetchAll()
        XCTAssertEqual(recovered, [stored])
    }

    func testFailedSetAsideMovesNothingAndKeepsProtecting() async throws {
        let files = InMemoryFileAccess()
        let corrupt = Data("not json".utf8)
        files.setContents(corrupt, at: storageLocation.activitiesFile)
        files.setContents(corrupt, at: storageLocation.preferencesFile)
        files.setFailMoves(true)

        let repository = makeRepository(files)
        await assertThrows(.setAsideFailed) { try await repository.setAsideUnreadableData() }
        let store = makeStore(files)
        await assertThrows(.setAsideFailed) { try await store.setAsideUnreadableData() }
        XCTAssertEqual(files.moveCount, 0)
        XCTAssertEqual(files.storedFileNames, ["activities.json", "preferences.json"])
        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), corrupt)
        XCTAssertEqual(files.data(at: storageLocation.preferencesFile), corrupt)

        await assertThrows(.damaged) { try await repository.fetchAll() }
        await assertThrows(.unreadableDataProtected) { try await repository.upsert(TestFixtures.activity(start: self.mondayNine)) }
        await assertThrows(.unreadableDataProtected) { try await store.savePreferences(.default) }
        XCTAssertEqual(files.writeCount, 0)

        files.setFailMoves(false)
        let activitiesName = try await repository.setAsideUnreadableData()
        XCTAssertEqual(activitiesName, activitiesBackupName)
        let preferencesName = try await store.setAsideUnreadableData()
        XCTAssertEqual(preferencesName, preferencesBackupName)
        XCTAssertEqual(files.storedFileNames, [activitiesBackupName, preferencesBackupName])
    }

    func testSetAsideNeverReplacesAnEarlierBackup() async throws {
        let files = InMemoryFileAccess()
        let earlier = Data("earlier damage".utf8)
        let later = Data("later damage".utf8)
        files.setContents(earlier, at: backupURL(activitiesBackupName))
        files.setContents(later, at: storageLocation.activitiesFile)

        let repository = makeRepository(files)
        await assertThrows(.setAsideFailed, "Same second, same backup name: the move is refused") {
            try await repository.setAsideUnreadableData()
        }
        XCTAssertEqual(files.data(at: backupURL(activitiesBackupName)), earlier)
        XCTAssertEqual(files.data(at: storageLocation.activitiesFile), later)

        let oneSecondLater = FileActivityRepository(
            fileURL: storageLocation.activitiesFile,
            files: files,
            clock: FixedWallClock(TestFixtures.fridayNoon.addingTimeInterval(1))
        )
        let name = try await oneSecondLater.setAsideUnreadableData()
        XCTAssertEqual(name, "activities.unreadable-1793386801.json")
        XCTAssertEqual(files.data(at: backupURL(activitiesBackupName)), earlier)
        XCTAssertEqual(files.data(at: backupURL("activities.unreadable-1793386801.json")), later)
        XCTAssertEqual(files.storedFileNames, [activitiesBackupName, "activities.unreadable-1793386801.json"])
    }

    // MARK: Preferences

    func testPreferencesRoundTripEveryField() async throws {
        let files = InMemoryFileAccess()
        let home = try CommutePlace(name: "Dorm room", coordinate: GeoCoordinate(latitude: 38.5541, longitude: -121.4181))
        let campus = try CommutePlace(name: "Engineering building", coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093))
        let duration = try CommuteDuration.minutes(45)
        let preferences = UserPreferences(
            appearance: .dark,
            testCommuteDuration: duration,
            testCommuteScenario: .slow,
            places: CommutePlaces(home: home, campus: campus),
            leaveHomeRemindersEnabled: true,
            simulatesReminderFailure: true
        )
        XCTAssertNotEqual(preferences, UserPreferences.default)

        try await makeStore(files).savePreferences(preferences)
        let loaded = try await makeStore(files).loadPreferences()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.testCommuteDuration, duration)
        XCTAssertEqual(restored.testCommuteDuration.wholeMinutes, 45)
        XCTAssertEqual(restored.testCommuteScenario, .slow)
        XCTAssertEqual(restored.places.home, home)
        XCTAssertEqual(restored.places.campus.name, "Engineering building")
        XCTAssertEqual(restored.places.campus.coordinate, GeoCoordinate(latitude: -33.8688, longitude: 151.2093))
        XCTAssertTrue(restored.leaveHomeRemindersEnabled)
        XCTAssertTrue(restored.simulatesReminderFailure)
    }

    func testPreferencesDecodeToleratesUnusableFieldsInsideAValidEnvelope() async throws {
        let files = InMemoryFileAccess()
        let json = #"""
        {
          "schemaVersion": 1,
          "kind": "preferences",
          "payload": {
            "appearance": "sepia",
            "testCommuteDuration": -300,
            "testCommuteScenario": "gridlock",
            "leaveHomeRemindersEnabled": "yes",
            "simulatesReminderFailure": true,
            "places": {
              "home": {"name": "Dorm", "coordinate": {"latitude": 200, "longitude": -121.42}},
              "campus": {"name": "Library", "coordinate": {"latitude": 38.5592, "longitude": -121.4229}}
            }
          }
        }
        """#
        files.setContents(Data(json.utf8), at: storageLocation.preferencesFile)
        let loaded = try await makeStore(files).loadPreferences()
        let preferences = try XCTUnwrap(loaded)
        XCTAssertEqual(preferences.appearance, .system, "Unknown appearance falls back to System")
        XCTAssertEqual(preferences.testCommuteDuration, .testDefault, "A negative duration falls back to 60 minutes")
        XCTAssertEqual(preferences.testCommuteScenario, .normal, "Unknown scenario falls back to Normal")
        XCTAssertFalse(preferences.leaveHomeRemindersEnabled, "A flag that is not a Bool falls back to off")
        XCTAssertTrue(preferences.simulatesReminderFailure, "A valid field is kept")
        XCTAssertEqual(preferences.places.home, CommutePlaces.sample.home, "An unusable home falls back to the sample")
        XCTAssertEqual(preferences.places.campus.name, "Library", "The valid campus is kept")
        XCTAssertEqual(preferences.places.campus.coordinate, GeoCoordinate(latitude: 38.5592, longitude: -121.4229))
        XCTAssertEqual(files.writeCount, 0, "Tolerant decoding does not rewrite the file")
    }

    func testEmptyPreferencesPayloadIsDefaultsButAMissingOneIsDamaged() async throws {
        let empty = InMemoryFileAccess()
        empty.setContents(Data(#"{"schemaVersion": 1, "kind": "preferences", "payload": {}}"#.utf8), at: storageLocation.preferencesFile)
        let defaults = try await makeStore(empty).loadPreferences()
        XCTAssertEqual(defaults, UserPreferences.default, "Missing fields decode as their defaults")

        let unusable = [
            #"{"schemaVersion": 1, "kind": "preferences", "payload": 5}"#,
            #"{"schemaVersion": 1, "kind": "preferences", "payload": null}"#,
            #"{"schemaVersion": 1, "kind": "preferences"}"#
        ]
        for text in unusable {
            let files = InMemoryFileAccess()
            files.setContents(Data(text.utf8), at: storageLocation.preferencesFile)
            let store = makeStore(files)
            await assertThrows(.damaged, text) { try await store.loadPreferences() }
        }
    }

    func testDamagedPreferencesFileIsProtectedUntilSetAside() async throws {
        let files = InMemoryFileAccess()
        let damaged = Data(#"{"schemaVersion": 1, "kind": "preferences", "payload": 5}"#.utf8)
        files.setContents(damaged, at: storageLocation.preferencesFile)
        let manualClock = ManualWallClock(Date(timeIntervalSince1970: 1_793_386_800.75))
        let store = FilePreferencesStore(fileURL: storageLocation.preferencesFile, files: files, clock: manualClock)

        await assertThrows(.unreadableDataProtected, "A save before any load is refused too") {
            try await store.savePreferences(.default)
        }
        await assertThrows(.damaged) { try await store.loadPreferences() }
        await assertThrows(.unreadableDataProtected) { try await store.savePreferences(UserPreferences(appearance: .dark)) }
        XCTAssertEqual(files.data(at: storageLocation.preferencesFile), damaged, "The damaged bytes are unchanged")
        XCTAssertEqual(files.writeCount, 0)

        manualClock.advance(by: 60)
        let name = try await store.setAsideUnreadableData()
        XCTAssertEqual(name, "preferences.unreadable-1793386860.json", "Whole seconds, rounded down")
        let backup = backupURL("preferences.unreadable-1793386860.json")
        XCTAssertEqual(files.data(at: backup), damaged)
        XCTAssertNil(files.data(at: storageLocation.preferencesFile))
        let afterSetAside = try await store.loadPreferences()
        XCTAssertNil(afterSetAside)

        let chosen = UserPreferences(appearance: .dark, testCommuteScenario: .error, leaveHomeRemindersEnabled: true)
        try await store.savePreferences(chosen)
        let reloaded = try await makeStore(files).loadPreferences()
        XCTAssertEqual(reloaded, chosen)
        XCTAssertEqual(files.data(at: backup), damaged)
        XCTAssertEqual(files.storedFileNames, ["preferences.json", "preferences.unreadable-1793386860.json"])
    }

    // MARK: Storage storageLocation

    func testStorageFolderNamesAreValidated() {
        XCTAssertEqual(PrototypeStorageLocation.defaultFolderName, "WaitItOutUX")
        XCTAssertEqual(PrototypeStorageLocation.folderEnvironmentKey, "WAIT_IT_OUT_STORAGE_FOLDER")
        let rejected: [String?] = [
            nil,
            "",
            "../x",
            "a/b",
            "..",
            ".",
            "with space",
            "tab\tname",
            "~home",
            String(repeating: "a", count: 65),
            "Caf\u{E9}",
            "\u{540D}\u{524D}"
        ]
        for name in rejected {
            XCTAssertEqual(PrototypeStorageLocation.validatedFolderName(name), "WaitItOutUX", String(describing: name))
        }
        let accepted = ["UITest-1234_ab", "a", String(repeating: "b", count: 64), "WaitItOutUX"]
        for name in accepted {
            XCTAssertEqual(PrototypeStorageLocation.validatedFolderName(name), name)
        }

        let custom = PrototypeStorageLocation.applicationSupport(folderName: "UITest-1234_ab")
        XCTAssertEqual(custom.directory.lastPathComponent, "UITest-1234_ab")
        XCTAssertEqual(custom.activitiesFile.lastPathComponent, "activities.json")
        XCTAssertEqual(custom.preferencesFile.lastPathComponent, "preferences.json")
        XCTAssertEqual(custom.activitiesFile.deletingLastPathComponent().lastPathComponent, "UITest-1234_ab")
        let escaped = PrototypeStorageLocation.applicationSupport(folderName: "../Documents")
        XCTAssertEqual(escaped.directory.lastPathComponent, "WaitItOutUX")
        XCTAssertEqual(PrototypeStorageLocation.applicationSupport().directory.lastPathComponent, "WaitItOutUX")
        let supportPath = URL.applicationSupportDirectory.path(percentEncoded: false)
        XCTAssertTrue(escaped.directory.path(percentEncoded: false).hasPrefix(supportPath))
        XCTAssertTrue(custom.activitiesFile.path(percentEncoded: false).hasPrefix(supportPath))
    }

    // MARK: Real disk

    func testLocalFileAccessRoundTripsOnDisk() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "WaitItOutUXTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: root) }
        let diskLocation = PrototypeStorageLocation(directory: root.appending(path: "Nested/Storage", directoryHint: .isDirectory))
        let folderPath = diskLocation.directory.path(percentEncoded: false)
        let files = LocalFileAccess()

        XCTAssertNil(try files.contents(of: diskLocation.activitiesFile), "No file reads as nil")
        let first = FileActivityRepository(fileURL: diskLocation.activitiesFile, files: files, clock: clock)
        let empty = try await first.fetchAll()
        XCTAssertEqual(empty, [])
        XCTAssertFalse(fileManager.fileExists(atPath: folderPath), "Reading creates nothing")

        let activity = TestFixtures.activity(title: "On disk", start: mondayNine, repeatWeekdays: [.monday])
        try await first.upsert(activity)
        XCTAssertTrue(fileManager.fileExists(atPath: diskLocation.activitiesFile.path(percentEncoded: false)), "The first write creates the nested folder")
        let second = FileActivityRepository(fileURL: diskLocation.activitiesFile, files: files, clock: clock)
        let restored = try await second.fetchAll()
        XCTAssertEqual(restored, [activity])

        let settings = UserPreferences(appearance: .light, testCommuteScenario: .unavailable, leaveHomeRemindersEnabled: true)
        try await FilePreferencesStore(fileURL: diskLocation.preferencesFile, files: files, clock: clock).savePreferences(settings)
        let reloadedSettings = try await FilePreferencesStore(fileURL: diskLocation.preferencesFile, files: files, clock: clock).loadPreferences()
        XCTAssertEqual(reloadedSettings, settings)

        let corrupt = Data("not json".utf8)
        try files.writeAtomically(corrupt, to: diskLocation.activitiesFile)
        XCTAssertEqual(try files.contents(of: diskLocation.activitiesFile), corrupt, "An atomic write replaces the file")
        let third = FileActivityRepository(fileURL: diskLocation.activitiesFile, files: files, clock: clock)
        await assertThrows(.damaged) { try await third.fetchAll() }
        let name = try await third.setAsideUnreadableData()
        XCTAssertEqual(name, activitiesBackupName)
        let backup = diskLocation.directory.appending(path: activitiesBackupName, directoryHint: .notDirectory)
        XCTAssertEqual(try files.contents(of: backup), corrupt, "The file was renamed on disk")
        XCTAssertNil(try files.contents(of: diskLocation.activitiesFile))

        try await third.upsert(activity)
        let afterRecovery = try await FileActivityRepository(fileURL: diskLocation.activitiesFile, files: files, clock: clock).fetchAll()
        XCTAssertEqual(afterRecovery, [activity])
        XCTAssertThrowsError(try files.moveItem(at: diskLocation.activitiesFile, to: backup), "A move never replaces a file")
        XCTAssertEqual(try files.contents(of: backup), corrupt)

        let names = try fileManager.contentsOfDirectory(atPath: folderPath).filter { $0.hasPrefix(".") == false }.sorted()
        XCTAssertEqual(names, ["activities.json", activitiesBackupName, "preferences.json"])
    }
}
