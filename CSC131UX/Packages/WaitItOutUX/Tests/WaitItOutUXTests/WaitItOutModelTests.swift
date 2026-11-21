import XCTest
@testable import WaitItOutUX

@MainActor
final class WaitItOutModelTests: XCTestCase {
    func testStartsOnMapTabWithCurrentWeekAndDefaultPreferences() {
        let model = TestFixtures.makeModel()
        XCTAssertEqual(model.selectedTab, .map)
        XCTAssertEqual(PrototypeTab.displayOrder, [.map, .calendar, .settings])
        XCTAssertTrue(model.isShowingCurrentWeek)
        XCTAssertEqual(model.visibleWeek, TestFixtures.pacificCalculator().week(containing: TestFixtures.fridayNoon))
        XCTAssertEqual(model.preferences, .default)
        XCTAssertEqual(model.preferencesStatus, .notLoaded)
    }

    func testSelectedTabIsRetainedAcrossSwitches() {
        let model = TestFixtures.makeModel()
        model.selectedTab = .calendar
        model.showNextWeek()
        model.selectedTab = .settings
        model.selectedTab = .calendar
        XCTAssertEqual(model.selectedTab, .calendar)
        XCTAssertFalse(model.isShowingCurrentWeek, "Week navigation state must survive tab switches")
    }

    func testWeekNavigationAndToday() {
        let model = TestFixtures.makeModel()
        let current = model.visibleWeek
        model.showNextWeek()
        XCTAssertEqual(model.visibleWeek.start, current.end)
        XCTAssertFalse(model.isShowingCurrentWeek)
        model.showPreviousWeek()
        model.showPreviousWeek()
        XCTAssertEqual(model.visibleWeek.end, current.start)
        model.showCurrentWeek()
        XCTAssertEqual(model.visibleWeek, current)
        XCTAssertTrue(model.isShowingCurrentWeek)
    }

    func testTodayFollowsInjectedClockWhenTimePasses() {
        let clock = ManualWallClock(TestFixtures.fridayNoon)
        let model = TestFixtures.makeModel(clock: clock)
        let originalWeek = model.visibleWeek
        clock.advance(by: 3 * 86_400) // Monday 2026-11-02 11:00 PST
        XCTAssertFalse(model.isShowingCurrentWeek)
        XCTAssertEqual(model.visibleWeek, originalWeek, "Visible week does not jump on its own")
        model.showCurrentWeek()
        XCTAssertEqual(model.visibleWeek.start, originalWeek.end)
        XCTAssertEqual(model.currentDate(), clock.now())
    }

    func testLoadPreferencesUsesStoredValues() async {
        let store = InMemoryPreferencesStore(initial: UserPreferences(appearance: .dark))
        let model = TestFixtures.makeModel(store: store)
        await model.loadPreferences()
        XCTAssertEqual(model.preferences.appearance, .dark)
        XCTAssertEqual(model.preferencesStatus, .ready)
    }

    func testLoadPreferencesWithEmptyStoreKeepsDefaults() async {
        let model = TestFixtures.makeModel(store: InMemoryPreferencesStore())
        await model.loadPreferences()
        XCTAssertEqual(model.preferences, .default)
        XCTAssertEqual(model.preferencesStatus, .ready)
    }

    func testSetAppearancePersistsAndSkipsNoOps() async {
        let store = RecordingPreferencesStore()
        let model = TestFixtures.makeModel(store: store)
        model.setAppearance(.system) // same as default: nothing to save
        await model.flushPendingSaves()
        var saved = await store.saved
        XCTAssertTrue(saved.isEmpty)

        model.setAppearance(.light)
        XCTAssertEqual(model.preferences.appearance, .light, "Applies immediately")
        await model.flushPendingSaves()
        saved = await store.saved
        XCTAssertEqual(saved, [UserPreferences(appearance: .light)])
        XCTAssertEqual(model.preferencesStatus, .ready)
    }

    func testFailedLoadKeepsAppUsableAndReportsMessage() async {
        let model = TestFixtures.makeModel(store: FailingPreferencesStore())
        await model.loadPreferences()
        XCTAssertEqual(model.preferences, .default)
        XCTAssertNotNil(model.preferencesStatus.failureMessage)
        XCTAssertTrue(model.isShowingCurrentWeek)
    }

    func testFailedSaveStillAppliesAppearanceAndReportsMessage() async {
        let model = TestFixtures.makeModel(store: FailingPreferencesStore())
        model.setAppearance(.dark)
        await model.flushPendingSaves()
        XCTAssertEqual(model.preferences.appearance, .dark)
        XCTAssertNotNil(model.preferencesStatus.failureMessage)
        XCTAssertEqual(model.preferencesPersistenceDescription, "Failing test store")
    }

    func testAppearanceColorSchemeMapping() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    func testPreferencesRoundTripThroughCodable() throws {
        let original = UserPreferences(appearance: .dark)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
