import XCTest

/// Step 0006: the Map's demo label, home and campus pins summary, and schematic-line label;
/// switching the deterministic Prototype testing scenarios (Try Again only for Error, automatic
/// recalculation otherwise, and Reset); and editing home with inline validation and a reset to
/// the labeled samples.
///
/// Identifier strings mirror `AccessibilityID` in the WaitItOutUX package because a UI test
/// cannot import it. The app runs with an en_US locale and the sample campus time zone, so the
/// sample schedule's 8:15 AM and 11:15 AM arrivals display as such. Which sample occurrence is
/// next depends on the day the test runs, so time assertions accept either sample.
final class MapScenarioUITests: XCTestCase {
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

    func testMapShowsDemoLabelPlacesAndSchematicNote() throws {
        let label = element("map.demoEstimateLabel")
        XCTAssertTrue(label.waitForExistence(timeout: 10), "The Map always shows the demo estimate label")
        XCTAssertTrue(label.label.contains("Demo estimate"), label.label)

        XCTAssertTrue(element("map.placesCard").waitForExistence(timeout: 10))
        let home = element("map.place.home")
        let campus = element("map.place.campus")
        XCTAssertTrue(home.exists && home.label.contains("Sample home"), home.label)
        XCTAssertTrue(campus.exists && campus.label.contains("Sample campus"), campus.label)

        let note = element("map.schematicNote")
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("not a driving route"), "The line is labeled as schematic: \(note.label)")
        XCTAssertTrue(app.buttons["map.recenterButton"].exists, "The camera can be fitted to both pins")
        XCTAssertTrue(element("map.nextTrip").exists, "The trip summary does not depend on map tiles")
    }

    func testScenariosRecalculateAutomaticallyAndOnlyErrorOffersTryAgain() throws {
        loadSampleSchedule()
        let leaveHome = element("map.nextTripDeparture.leaveHome")
        let message = element("map.nextTripDeparture.message")
        let retry = app.buttons["map.nextTripDeparture.retry"]

        app.tabBars.firstMatch.buttons["Map"].tap()
        let normal = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "7:15", "10:15")
        wait(for: [expectation(for: normal, evaluatedWith: leaveHome)], timeout: 10)

        chooseScenario("error")
        app.tabBars.firstMatch.buttons["Map"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "A failed estimate offers Try Again")
        XCTAssertTrue(message.label.contains("could not be loaded"), message.label)
        XCTAssertFalse(leaveHome.exists, "No time is shown for a failed estimate")
        XCTAssertTrue(element("map.demoEstimateLabel").label.contains("Error"), "The demo label names the scenario")
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "The Error scenario keeps failing until another scenario is chosen")

        chooseScenario("unavailable")
        app.tabBars.firstMatch.buttons["Map"].tap()
        let unavailable = NSPredicate(format: "label CONTAINS %@", "no estimate")
        wait(for: [expectation(for: unavailable, evaluatedWith: message)], timeout: 10)
        XCTAssertFalse(retry.exists, "No Try Again when the provider simply has no estimate")

        chooseScenario("slow")
        app.tabBars.firstMatch.buttons["Map"].tap()
        let slow = NSPredicate(format: "(label CONTAINS %@ OR label CONTAINS %@) AND NOT (label CONTAINS %@)", "6:45", "9:45", "out of date")
        wait(for: [expectation(for: slow, evaluatedWith: leaveHome)], timeout: 15)
        XCTAssertTrue(element("map.nextTripSimulation").label.contains("Slow"))

        app.tabBars.firstMatch.buttons["Settings"].tap()
        let reset = revealSettingsElement(app.buttons["settings.resetTesting"])
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        app.tabBars.firstMatch.buttons["Map"].tap()
        wait(for: [expectation(for: normal, evaluatedWith: leaveHome)], timeout: 15)
    }

    func testHomeEditorValidatesAndResetRestoresTheSample() throws {
        app.tabBars.firstMatch.buttons["Settings"].tap()
        let homeRow = revealSettingsElement(app.buttons["settings.place.home"])
        XCTAssertTrue(homeRow.label.contains("sample data"), homeRow.label)
        homeRow.tap()
        XCTAssertTrue(element("placeEditor.sheet").waitForExistence(timeout: 10))

        let latitude = app.textFields["placeEditor.latitude"]
        XCTAssertTrue(latitude.waitForExistence(timeout: 10))
        replaceText(in: latitude, with: "91")
        let issue = app.descendants(matching: .any).matching(identifier: "placeEditor.issue")
            .matching(NSPredicate(format: "label CONTAINS %@", "between -90 and 90")).firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "An out-of-range latitude is reported inline")
        XCTAssertFalse(app.buttons["placeEditor.save"].isEnabled, "Save waits for valid input")

        replaceText(in: latitude, with: "38.5000")
        let name = app.textFields["placeEditor.name"]
        replaceText(in: name, with: "UI test home")
        XCTAssertTrue(app.buttons["placeEditor.save"].isEnabled)
        app.buttons["placeEditor.save"].tap()
        assertGone(element("placeEditor.sheet"))

        let updated = revealSettingsElement(app.buttons["settings.place.home"])
        XCTAssertTrue(updated.label.contains("UI test home"), updated.label)
        XCTAssertFalse(updated.label.contains("sample data"), "A user value is not labeled SAMPLE")

        let reset = revealSettingsElement(app.buttons["settings.resetPlaces"])
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        let restored = revealSettingsElement(app.buttons["settings.place.home"])
        let isSample = NSPredicate(format: "label CONTAINS %@", "Sample home")
        wait(for: [expectation(for: isSample, evaluatedWith: restored)], timeout: 10)
        XCTAssertFalse(reset.isEnabled, "Nothing to reset once the samples are back")
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

    private func chooseScenario(_ rawValue: String) {
        app.tabBars.firstMatch.buttons["Settings"].tap()
        let row = revealSettingsElement(app.buttons["settings.testScenario." + rawValue])
        row.tap()
        let selected = NSPredicate(format: "isSelected == true")
        wait(for: [expectation(for: selected, evaluatedWith: row)], timeout: 10)
    }

    /// The step 0006 sections sit below the earlier ones, so scroll until `target` is on screen.
    private func revealSettingsElement(_ target: XCUIElement) -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.exists, "Settings shows \(target)")
        return target
    }

    /// Taps the field's trailing edge so the cursor lands after the current text (the coordinate
    /// fields are right-aligned, and a tap left of the text would put it before), deletes the
    /// text, and types the replacement.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 1))
        field.typeText(text)
    }

    private func assertGone(_ target: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)], timeout: 10)
    }
}
