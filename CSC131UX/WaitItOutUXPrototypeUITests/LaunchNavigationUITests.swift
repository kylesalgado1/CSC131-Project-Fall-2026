import XCTest

/// Launches the host app and walks the three tabs. Identifier strings mirror
/// `AccessibilityID` in the WaitItOutUX package.
final class LaunchNavigationUITests: XCTestCase {
    private var app: XCUIApplication = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A fresh storage folder per test, so each test starts from empty storage.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = "UITest-" + UUID().uuidString
        // The standalone demo composition: no backend, so every result is deterministic.
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "demo"
        app.launch()
    }

    func testTabBarShowsMapCalendarSettingsInOrder() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        let buttons = tabBar.buttons
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(buttons.element(boundBy: 0).label, "Map")
        XCTAssertEqual(buttons.element(boundBy: 1).label, "Calendar")
        XCTAssertEqual(buttons.element(boundBy: 2).label, "Settings")
        XCTAssertTrue(buttons.element(boundBy: 0).isSelected, "Map is the initial tab")
    }

    func testEachTabShowsItsContent() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["map.demoStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["map.recenterButton"].exists)

        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendar.weekTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["calendar.previousWeek"].exists)
        XCTAssertTrue(app.buttons["calendar.nextWeek"].exists)
        XCTAssertTrue(app.buttons["calendar.day.0"].exists, "Sunday cell")
        XCTAssertTrue(app.buttons["calendar.day.6"].exists, "Saturday cell")
        XCTAssertTrue(app.descendants(matching: .any)["calendar.selectedDayTitle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar.emptyState"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["calendar.timeGrid"].exists, "The grid shows even with nothing stored")
        XCTAssertTrue(app.buttons["calendar.addActivity"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["calendar.occurrenceBlock"].exists, "No blocks before anything is loaded")

        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.appearancePicker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Feature package"].exists)
        XCTAssertTrue(app.buttons["settings.loadSamplesButton"].exists)
        XCTAssertTrue(app.buttons["settings.clearSamplesButton"].exists)
    }

    func testCalendarWeekSelectionSurvivesTabSwitch() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Calendar"].tap()

        let title = app.descendants(matching: .any)["calendar.weekTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let currentWeekTitle = title.label
        // Read before Next week, which keeps the weekday but moves the selection a week ahead.
        let dayTitle = app.descendants(matching: .any)["calendar.selectedDayTitle"]
        XCTAssertTrue(dayTitle.exists)
        let initialDayTitle = dayTitle.label
        app.buttons["calendar.nextWeek"].tap()
        let nextWeekTitle = title.label
        XCTAssertNotEqual(nextWeekTitle, currentWeekTitle)

        app.buttons["calendar.day.2"].tap()
        let tuesdayTitle = dayTitle.label
        XCTAssertTrue(tuesdayTitle.contains("Tuesday"), tuesdayTitle)

        tabBar.buttons["Settings"].tap()
        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, nextWeekTitle, "Visible week is retained across tab switches")
        XCTAssertEqual(dayTitle.label, tuesdayTitle, "Selected day is retained across tab switches")

        let today = app.buttons["calendar.today"]
        XCTAssertTrue(today.isEnabled)
        today.tap()
        XCTAssertEqual(title.label, currentWeekTitle)
        XCTAssertEqual(dayTitle.label, initialDayTitle, "Today reselects the current day")
        XCTAssertTrue(dayTitle.label.contains("today"), dayTitle.label)
    }

    func testSampleScheduleLoadsOnlyFromSettingsAndShowsOnCalendar() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        tabBar.buttons["Calendar"].tap()
        let emptyState = app.descendants(matching: .any)["calendar.emptyState"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10), "Samples never appear on their own")

        tabBar.buttons["Settings"].tap()
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        XCTAssertTrue(load.isEnabled)
        load.tap()

        let status = app.staticTexts["settings.sampleStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let loaded = expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)
        wait(for: [loaded], timeout: 10)
        XCTAssertFalse(load.isEnabled, "Loading is idempotent, so the button rests once both samples exist")

        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendar.timeGrid"].waitForExistence(timeout: 10))
        XCTAssertFalse(emptyState.exists)
        app.buttons["calendar.day.1"].tap()
        let blocks = app.descendants(matching: .any).matching(identifier: "calendar.occurrenceBlock")
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 10))
        let mondayClass = blocks.matching(NSPredicate(format: "label CONTAINS %@", "Sample morning class"))
        XCTAssertGreaterThanOrEqual(mondayClass.count, 1, "Monday shows the Mon, Wed, Fri class as a block")
        let markers = app.descendants(matching: .any).matching(identifier: "calendar.arrivalMarker")
        XCTAssertGreaterThanOrEqual(markers.count, 1, "The ideal arrival is a separate marker")
        app.buttons["calendar.day.2"].tap()
        let tuesdayLab = blocks.matching(NSPredicate(format: "label CONTAINS %@", "Sample afternoon lab"))
        XCTAssertTrue(tuesdayLab.firstMatch.waitForExistence(timeout: 10), "Tuesday shows the Tue, Thu lab as a block")

        tabBar.buttons["Settings"].tap()
        let clear = app.buttons["settings.clearSamplesButton"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        XCTAssertTrue(clear.isEnabled)
        clear.tap()

        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10), "Clearing removes the samples from the calendar")
    }

    func testTappingABlockShowsDetailsWithEditAndDelete() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Settings"].tap()
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.tap()
        let status = app.staticTexts["settings.sampleStatus"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)

        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["calendar.day.1"].waitForExistence(timeout: 10))
        app.buttons["calendar.day.1"].tap()
        let block = app.descendants(matching: .any).matching(identifier: "calendar.occurrenceBlock")
            .matching(NSPredicate(format: "label CONTAINS %@", "Sample morning class")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        block.tap()

        let sheet = app.descendants(matching: .any)["calendar.detailSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ideal arrival"].exists)
        XCTAssertTrue(app.staticTexts["Repeats"].exists)
        XCTAssertTrue(app.buttons["calendar.detailEdit"].exists, "Details offer Edit")
        XCTAssertTrue(app.buttons["calendar.detailDelete"].exists, "Details offer Delete")
        let done = app.buttons["calendar.detailDone"]
        XCTAssertTrue(done.exists)
        done.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)], timeout: 10)
        XCTAssertTrue(app.descendants(matching: .any)["calendar.timeGrid"].exists)
    }
}
