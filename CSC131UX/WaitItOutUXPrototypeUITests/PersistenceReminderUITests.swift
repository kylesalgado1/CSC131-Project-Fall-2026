import XCTest

/// Step 0007: saved data and leave-home reminder previews. The sample schedule and the
/// reminder setting survive a relaunch that reuses the test's storage folder; the reminder
/// preview is labeled as in-app only and is recreated after the relaunch; and the Prototype
/// testing failure simulation offers Try Again until it is turned off.
///
/// Identifier strings mirror `AccessibilityID` in the WaitItOutUX package because a UI test
/// cannot import it. Every test names its own storage folder through
/// `WAIT_IT_OUT_STORAGE_FOLDER`, so it starts from empty storage, and `relaunch()` opens the
/// app again on that same folder, the way a user reopens it. Which sample occurrence gets the
/// next reminder depends on the day the test runs, so the tests only check that one is shown.
final class PersistenceReminderUITests: XCTestCase {
    private static let storageFolderKey = "WAIT_IT_OUT_STORAGE_FOLDER"
    private static let previewOnlyDisclosure = "Preview only - no system notification will be sent."

    private var app: XCUIApplication = XCUIApplication()
    /// This test's storage folder: a fresh name per test, reused by `relaunch()`.
    private var storageFolder = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        // A fresh storage folder per test, so each test starts from empty storage.
        storageFolder = "UITest-" + UUID().uuidString
        app = makeApplication()
        app.launch()
    }

    func testSampleScheduleSurvivesRelaunch() throws {
        loadSampleSchedule()

        relaunch()
        openTab("Settings")
        waitForBothSamples()

        openTab("Calendar")
        let monday = app.buttons["calendar.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 10))
        monday.tap()
        let blocks = app.descendants(matching: .any).matching(identifier: "calendar.occurrenceBlock")
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 10), "Monday shows the saved sample schedule after the relaunch")
        let mondayClass = blocks.matching(NSPredicate(format: "label CONTAINS %@", "Sample morning class"))
        XCTAssertGreaterThanOrEqual(mondayClass.count, 1, "The Mon, Wed, Fri sample class was read back")
    }

    func testEnablingRemindersShowsPreviewOnly() throws {
        loadSampleSchedule()
        let toggle = revealSettingsElement(switchElement("settings.remindersToggle"))
        XCTAssertFalse(isOn(toggle), "Reminders start off in empty storage")
        enableReminders()

        let disclosure = revealSettingsElement(element("reminders.disclosure"))
        let previewOnly = element("reminders.disclosure", where: NSPredicate(format: "label == %@", Self.previewOnlyDisclosure))
        XCTAssertTrue(previewOnly.waitForExistence(timeout: 5), "The preview says no system notification is sent: \(disclosure.label)")
        let systemClaim = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "scheduled with iOS")).firstMatch
        XCTAssertFalse(systemClaim.exists, "Nothing claims a reminder was scheduled with iOS")

        relaunch()
        openTab("Settings")
        let restored = revealSettingsElement(switchElement("settings.remindersToggle"))
        XCTAssertTrue(waitForSwitch(restored, isOn: true), "The reminder setting was saved and read back")
        let recreated = revealSettingsElement(element("reminders.time"), waitingUpTo: 10)
        XCTAssertTrue(recreated.exists, "The reminder preview is recreated after the relaunch")
    }

    func testReminderFailureSimulationOffersTryAgain() throws {
        loadSampleSchedule()
        enableReminders()

        let failure = revealSettingsElement(switchElement("settings.reminderFailureToggle"))
        setSwitch(failure, on: true)
        let retryButton = app.buttons.matching(identifier: "reminders.retry").firstMatch
        let retry = revealSettingsElement(retryButton, first: .earlier, waitingUpTo: 10)
        XCTAssertTrue(retry.exists, "A failed reminder update offers Try Again")
        let couldNot = NSPredicate(format: "label CONTAINS[c] %@", "could not")
        let status = revealSettingsElement(element("reminders.status", where: couldNot), first: .earlier, waitingUpTo: 10)
        XCTAssertTrue(status.exists, "The reminder status says the update could not be made")

        let failureAgain = revealSettingsElement(switchElement("settings.reminderFailureToggle"))
        setSwitch(failureAgain, on: false)
        let time = revealSettingsElement(element("reminders.time"), first: .earlier, waitingUpTo: 10)
        XCTAssertTrue(time.exists, "Turning the simulation off recreates the preview without Try Again")
    }

    // MARK: - Launching

    /// The app with the same locale, time zone, and storage folder on every launch.
    private func makeApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        application.launchEnvironment["TZ"] = "America/Los_Angeles"
        application.launchEnvironment[Self.storageFolderKey] = storageFolder
        // The standalone demo composition: no backend, so every result is deterministic.
        application.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "demo"
        return application
    }

    /// Ends the app and opens it again on the same storage folder, the way a user reopens it.
    private func relaunch() {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The app ended before the relaunch")
        app = makeApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "The app is running again")
    }

    // MARK: - Navigation and samples

    private func openTab(_ name: String) {
        let tab = app.tabBars.firstMatch.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "The \(name) tab is shown")
        tab.tap()
    }

    private func loadSampleSchedule() {
        openTab("Settings")
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.tap()
        waitForBothSamples()
    }

    /// Waits until Settings counts both samples, as in "2 sample activities, 0 of your own".
    private func waitForBothSamples() {
        let status = app.staticTexts["settings.sampleStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Settings shows what is loaded")
        let both = NSPredicate(format: "label CONTAINS %@", "2 sample activities")
        wait(for: [expectation(for: both, evaluatedWith: status)], timeout: 10)
    }

    /// Turns on leave-home reminders and waits for the next reminder preview.
    private func enableReminders() {
        let toggle = revealSettingsElement(switchElement("settings.remindersToggle"))
        setSwitch(toggle, on: true)
        let time = revealSettingsElement(element("reminders.time"), waitingUpTo: 10)
        XCTAssertTrue(time.exists, "Turning reminders on shows the next reminder preview")
    }

    // MARK: - Elements

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(_ identifier: String, where predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).matching(predicate).firstMatch
    }

    /// A Settings toggle. `firstMatch` because iOS can expose the switch inside a SwiftUI
    /// Toggle's row with the same identifier.
    private func switchElement(_ identifier: String) -> XCUIElement {
        app.switches.matching(identifier: identifier).firstMatch
    }

    // MARK: - Switches

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    /// Whether `toggle` reports `wantsOn` within `timeout`. Switches report "1" when on.
    private func waitForSwitch(_ toggle: XCUIElement, isOn wantsOn: Bool, timeout: TimeInterval = 10) -> Bool {
        let expected: String = wantsOn ? "1" : "0"
        let state = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: state, object: toggle)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Sets a toggle the way `ActivityEditingUITests` does: taps the inner switch when iOS
    /// exposes one and the row otherwise, then the switch end of the row if the value has not
    /// changed. Waiting before that last tap keeps a slow update from being flipped back.
    private func setSwitch(_ toggle: XCUIElement, on wantsOn: Bool) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "\(toggle) is shown")
        guard isOn(toggle) != wantsOn else { return }
        let control = toggle.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            toggle.tap()
        }
        if waitForSwitch(toggle, isOn: wantsOn, timeout: 3) == false {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let state = wantsOn ? "on" : "off"
        XCTAssertTrue(waitForSwitch(toggle, isOn: wantsOn), "\(toggle) is \(state)")
    }

    // MARK: - Scrolling Settings

    /// Which way `revealSettingsElement` scrolls first.
    private enum Direction {
        /// Swipe up, toward the later sections.
        case later
        /// Swipe down, toward the earlier sections.
        case earlier

        var opposite: Direction {
            switch self {
            case .later:
                return .earlier
            case .earlier:
                return .later
            }
        }
    }

    /// Scrolls Settings until `target` is on screen: first toward `direction`, then back the
    /// other way past the starting point, because the reminder rows sit between the earlier
    /// sections and Prototype testing. Rows that update asynchronously get `patience` seconds
    /// to appear before any scrolling; Form rows exist only near the screen, so an off-screen
    /// row is found by scrolling.
    private func revealSettingsElement(_ target: XCUIElement, first direction: Direction = .later, waitingUpTo patience: TimeInterval = 0) -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        if patience > 0 {
            _ = target.waitForExistence(timeout: patience)
        }
        for (pass, limit) in [(direction, 8), (direction.opposite, 16)] {
            var swipes = 0
            while !isOnScreen(target), swipes < limit {
                swipe(pass)
                swipes += 1
            }
        }
        XCTAssertTrue(target.exists, "Settings shows \(target)")
        return target
    }

    private func isOnScreen(_ target: XCUIElement) -> Bool {
        target.exists && target.isHittable
    }

    private func swipe(_ direction: Direction) {
        switch direction {
        case .later:
            app.swipeUp()
        case .earlier:
            app.swipeDown()
        }
    }
}
