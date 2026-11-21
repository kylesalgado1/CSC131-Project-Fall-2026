import XCTest

/// Step 0008: the demo at an accessibility text size. The three tabs in product order, the
/// labeled demo estimate and leave-home time on the Map, and the non-gesture path through the
/// Calendar: Add Activity opens the editor, whose start, end, and ideal arrival are accessible
/// time controls and whose leave-home line is read-only. There is no Calculate button.
///
/// Identifier strings mirror `AccessibilityID` in the WaitItOutUX package because a UI test
/// cannot import it. Which sample is the next trip depends on the day the test runs, so the Map
/// assertion accepts either sample's leave-home time.
final class DemoAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // A fresh storage folder per test, so each test starts from empty storage.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = "UITest-" + UUID().uuidString
        // The standalone demo composition: no backend, so every result is deterministic.
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "demo"
        app.launch()
    }

    func testLargeTextDemoKeepsTabsLabelsAndAccessibleTimeControls() throws {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        XCTAssertEqual(tabs.buttons.count, 3, "Exactly three tabs")
        XCTAssertEqual(tabs.buttons.element(boundBy: 0).label, "Map")
        XCTAssertEqual(tabs.buttons.element(boundBy: 1).label, "Calendar")
        XCTAssertEqual(tabs.buttons.element(boundBy: 2).label, "Settings")

        loadSampleSchedule()

        tabs.buttons["Map"].tap()
        XCTAssertTrue(element("map.demoEstimateLabel").waitForExistence(timeout: 10), "Simulated estimates are labeled")
        let leaveHome = element("map.nextTripDeparture.leaveHome")
        XCTAssertTrue(reveal(leaveHome), "The next trip's leave-home time is reachable at large text")
        XCTAssertTrue(
            leaveHome.label.contains("7:15") || leaveHome.label.contains("10:15"),
            "Ideal arrival 8:15 or 11:15 minus the 60-minute test commute: \(leaveHome.label)"
        )
        XCTAssertFalse(app.buttons["Calculate"].exists, "Nothing has to be calculated by hand")

        tabs.buttons["Calendar"].tap()
        let add = app.buttons["calendar.addActivity"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add Activity is the alternative to drag creation")
        add.tap()
        XCTAssertTrue(element("editor.sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(element("editor.start")), "The start is an accessible time control")
        XCTAssertTrue(reveal(element("editor.end")), "The end is an accessible time control")
        XCTAssertTrue(reveal(element("editor.arrival")), "The ideal arrival is an accessible time control")
        let line = element("editor.departure.leaveHome")
        XCTAssertTrue(reveal(line), "The editor shows the calculated leave-home time")
        XCTAssertTrue(line.label.contains("Leave home at"), line.label)
        XCTAssertFalse(app.datePickers["Leave home"].exists, "Leave home is never an input")
        XCTAssertFalse(app.buttons["Calculate"].exists)

        let cancel = app.buttons["editor.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element("editor.sheet"))], timeout: 10)
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func loadSampleSchedule() {
        app.tabBars.firstMatch.buttons["Settings"].tap()
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(reveal(load))
        load.tap()
        let status = app.staticTexts["settings.sampleStatus"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)
    }

    /// Large text pushes rows below the fold, and lazy forms create them only when scrolled
    /// to, so swipe up until the element is on screen.
    private func reveal(_ target: XCUIElement) -> Bool {
        if target.waitForExistence(timeout: 5), target.isHittable { return true }
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        return target.exists
    }
}
