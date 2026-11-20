import XCTest
@testable import WaitItOutUX

final class InMemoryActivityRepositoryTests: XCTestCase {
    private let monday9 = TestFixtures.mondayNine

    func testEmptyRepositoryFetchesNothing() async throws {
        let repository = InMemoryActivityRepository()
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [])
        XCTAssertTrue(repository.persistenceDescription.localizedCaseInsensitiveContains("memory"))
        XCTAssertTrue(repository.persistenceDescription.localizedCaseInsensitiveContains("nothing is written"))
    }

    func testUpsertInsertsThenReplacesById() async throws {
        let repository = InMemoryActivityRepository()
        let original = TestFixtures.activity(title: "Original", start: monday9)
        try await repository.upsert(original)
        var renamed = original
        renamed.title = "Renamed"
        try await repository.upsert([renamed, TestFixtures.activity(title: "Other", start: monday9)])
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first { $0.id == original.id }?.title, "Renamed")
        try await repository.upsert([])
        let unchanged = try await repository.fetchAll()
        XCTAssertEqual(unchanged.count, 2)
    }

    func testDeleteRemovesGivenIdsAndIgnoresUnknownOnes() async throws {
        let keep = TestFixtures.activity(title: "Keep", start: monday9)
        let drop = TestFixtures.activity(title: "Drop", start: monday9)
        let repository = InMemoryActivityRepository(initial: [keep, drop])
        try await repository.delete(ids: [drop.id, UUID()])
        let afterFirstDelete = try await repository.fetchAll()
        XCTAssertEqual(afterFirstDelete, [keep])
        try await repository.delete(id: keep.id)
        try await repository.delete(ids: [])
        let afterSecondDelete = try await repository.fetchAll()
        XCTAssertEqual(afterSecondDelete, [])
    }

    func testInitialContentsAreDeduplicatedById() async throws {
        let first = TestFixtures.activity(title: "First", start: monday9)
        var second = first
        second.title = "Second"
        let repository = InMemoryActivityRepository(initial: [first, second])
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored.map(\.title), ["Second"])
    }

    func testRepositoryStoresWhatItIsGivenWithoutValidating() async throws {
        // Validation is the model's job; the store is deliberately dumb so file-backed
        // implementations of a later step stay simple.
        let repository = InMemoryActivityRepository()
        let invalid = TestFixtures.activity(title: "", start: monday9, end: monday9)
        try await repository.upsert(invalid)
        let stored = try await repository.fetchAll()
        XCTAssertEqual(stored, [invalid])
    }
}
