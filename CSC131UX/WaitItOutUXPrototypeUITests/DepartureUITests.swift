import XCTest

/// Step 0005: calculated leave-home times. The Map's empty-schedule setup action, the
/// read-only departure line in the editor and the detail sheet, the labeled Settings test
/// commute with validation, and the Map's next trip following a changed duration.
///
/// Identifier strings mirror `AccessibilityID` in the WaitItOutUX package because a UI test
/// cannot import it. The app runs with an en_US locale and the sample campus time zone, so the
/// sample schedule's 8:15 AM and 11:15 AM arrivals display as such. Which sample occurrence is
/// next depends on the day the test runs, so the Map assertions accept either sample.
final class DepartureUITests: XCTestCase {
    private var app: XCUIApplication = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // A fresh storage folder per test, so each test starts from empty storage.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = "UITest-" + UUID().uuidString
        // The standalone demo composition: no backend, so every result is deterministic.
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "demo"
        app.launch()
    }

    func testEmptyMapOffersAddActivityAndTheEditorShowsAReadOnlyLeaveHomeLine() throws {
        let card = element("map.nextTrip")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The Map shows a next-trip card even with nothing scheduled")
        let add = app.buttons["map.nextTripAddActivity"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "An empty schedule offers a calendar setup action")
        add.tap()

        XCTAssertTrue(app.tabBars.firstMatch.buttons["Calendar"].isSelected, "The setup action switches to the Calendar")
        XCTAssertTrue(element("editor.sheet").waitForExistence(timeout: 10), "The setup action opens the editor")
        let leaveHome = element("editor.departure.leaveHome")
        XCTAssertTrue(leaveHome.waitForExistence(timeout: 10), "The editor shows the calculated leave-home time")
        XCTAssertTrue(leaveHome.label.contains("Leave home at"), leaveHome.label)
        XCTAssertTrue(leaveHome.label.contains("Simulated test data"), "The simulated commute is labeled")
        XCTAssertFalse(app.datePickers["Leave home"].exists, "Leave home is never an input")
        XCTAssertFalse(app.textFields["Leave home"].exists, "Leave home is never an input")

        app.buttons["editor.cancel"].tap()
        let sheet = element("editor.sheet")
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)], timeout: 10)
    }

    func testSettingsTestCommuteRejectsInvalidMinutesAndKeepsTheLastValidValue() throws {
        app.tabBars.firstMatch.buttons["Settings"].tap()
        let field = revealTestCommuteField()
        XCTAssertTrue(field.exists, "Settings shows the test commute duration")
        XCTAssertEqual(field.value as? String, "60", "The test commute starts at 60 minutes")
        XCTAssertTrue(app.staticTexts["Test commute duration"].exists)

        replaceText(in: field, with: "0")
        let issue = element("settings.testCommuteIssue")
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "Zero minutes is rejected inline")
        XCTAssertTrue(issue.label.contains("Still using 60 minutes"), issue.label)

        replaceText(in: field, with: "45")
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: issue)], timeout: 10)
        XCTAssertEqual(field.value as? String, "45")
    }

    func testNextTripFollowsTheTestCommuteAndDetailsShowTheLeaveHomeSection() throws {
        loadSampleSchedule()

        app.tabBars.firstMatch.buttons["Map"].tap()
        let leaveHome = element("map.nextTripDeparture.leaveHome")
        XCTAssertTrue(leaveHome.waitForExistence(timeout: 10), "The next sample trip gets a leave-home time")
        XCTAssertTrue(
            leaveHome.label.contains("7:15") || leaveHome.label.contains("10:15"),
            "Ideal arrival 8:15 or 11:15 minus the 60-minute test commute: \(leaveHome.label)"
        )
        XCTAssertTrue(element("map.nextTripDeparture.source").exists, "The estimate source is shown")

        app.tabBars.firstMatch.buttons["Settings"].tap()
        let field = revealTestCommuteField()
        XCTAssertTrue(field.exists)
        replaceText(in: field, with: "45")
        app.buttons["Done"].firstMatch.tap()

        app.tabBars.firstMatch.buttons["Map"].tap()
        let recalculated = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "7:30", "10:30")
        wait(for: [expectation(for: recalculated, evaluatedWith: leaveHome)], timeout: 10)

        app.tabBars.firstMatch.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["calendar.day.1"].waitForExistence(timeout: 10))
        app.buttons["calendar.day.1"].tap()
        let block = app.descendants(matching: .any).matching(identifier: "calendar.occurrenceBlock")
            .matching(NSPredicate(format: "label CONTAINS %@", "Sample morning class")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        block.tap()
        XCTAssertTrue(element("calendar.detailSheet").waitForExistence(timeout: 10))
        let value = element("calendar.detailDeparture.leaveHome")
        let message = element("calendar.detailDeparture.message")
        let detailShown = NSPredicate(format: "exists == true")
        let eitherShown = XCTNSPredicateExpectation(predicate: detailShown, object: value)
        if XCTWaiter.wait(for: [eitherShown], timeout: 10) != .completed {
            XCTAssertTrue(message.exists, "Without a time, the Leave home section says why (for example, the class is already over)")
        }
        if value.exists {
            XCTAssertTrue(value.label.contains("7:30"), "8:15 arrival minus the 45-minute test commute: \(value.label)")
        }
        XCTAssertFalse(app.datePickers["Leave home"].exists, "Leave home is read-only")
        app.buttons["calendar.detailDone"].tap()
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func loadSampleSchedule() {
        app.tabBars.firstMatch.buttons["Settings"].tap()
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.tap()
        let status = app.staticTexts["settings.sampleStatus"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)
    }

    /// The test commute section is the last one in Settings, so scroll until its field is on screen.
    private func revealTestCommuteField() -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let field = app.textFields["settings.testCommuteField"]
        var swipes = 0
        while !(field.exists && field.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        return field
    }

    /// Taps the field's trailing edge so the cursor lands after the current text (the minutes
    /// field is right-aligned, and a tap left of the text would put it before), deletes the
    /// text, and types the replacement.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 1))
        field.typeText(text)
    }
}
