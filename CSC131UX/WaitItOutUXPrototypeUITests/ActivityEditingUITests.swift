import XCTest

/// Step 0004 editing flows: inline validation and Cancel, creating repeating activities through
/// the compact pickers, press-and-hold drag creation, series edit and delete, and the
/// unsaved-change bar. Identifier strings mirror `AccessibilityID` in the WaitItOutUX package
/// because a UI test cannot import it. The app launches with an en_US locale so the time
/// wheels are hour, minute, and AM/PM; labels are matched on digits only because iOS 17 puts a
/// narrow no-break space before AM and PM.
final class ActivityEditingUITests: XCTestCase {
    private var app: XCUIApplication = XCUIApplication()
    private let editorTitles = ["New Activity", "Edit Activity", "Edit Series"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // The editor sets times in the campus zone and the Calendar shows the device zone, so
        // pin the device to the campus zone for the 9:00 and 12:00 block labels checked below.
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // A fresh storage folder per test, so each test starts from empty storage.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = "UITest-" + UUID().uuidString
        // The standalone demo composition: no backend, so every result is deterministic.
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "demo"
        app.launch()
    }

    // MARK: - Validation and Cancel

    func testSaveWithEmptyTitleShowsInlineErrorAndCancelLeavesNothing() throws {
        openCalendar()
        openNewActivityEditor()
        XCTAssertTrue(app.navigationBars["New Activity"].waitForExistence(timeout: 10))

        app.buttons["editor.save"].tap()
        let titleIssue = app.descendants(matching: .any).matching(identifier: "editor.issue")
            .matching(NSPredicate(format: "label CONTAINS %@", "Enter a title.")).firstMatch
        XCTAssertTrue(titleIssue.waitForExistence(timeout: 10), "An empty title is reported inline after Save")
        XCTAssertTrue(editorSheet().exists, "The editor stays open while the draft is invalid")

        app.buttons["editor.cancel"].tap()
        assertGone(editorSheet(), "Cancel closes the editor")
        XCTAssertFalse(allBlocks().firstMatch.exists, "Cancel stores nothing")
        XCTAssertTrue(element("calendar.emptyState").exists, "The empty card is still shown")
    }

    // MARK: - Creating through the controls

    func testCreateMondayWednesdayFridayClassThroughControls() throws {
        openCalendar()
        selectDay(1)
        openNewActivityEditor()
        typeTitle("UI morning class")
        setTime("editor.start", hour: "9", minute: "00", period: "AM")
        setTime("editor.end", hour: "9", minute: "50", period: "AM")
        setTime("editor.arrival", hour: "8", minute: "15", period: "AM")
        turnOnRepeat(days: [1, 3, 5])
        saveEditor()

        selectDay(1)
        let monday = blocks(containing: ["UI morning class", "9:00", "9:50", "8:15", "Wednesday", "Friday"]).firstMatch
        XCTAssertTrue(monday.waitForExistence(timeout: 10), "Monday shows the class 9:00 to 9:50, arrive by 8:15, repeating")
        selectDay(3)
        XCTAssertTrue(blocks(containing: ["UI morning class"]).firstMatch.waitForExistence(timeout: 10), "Wednesday repeats the class")
        selectDay(5)
        XCTAssertTrue(blocks(containing: ["UI morning class"]).firstMatch.waitForExistence(timeout: 10), "Friday repeats the class")
        selectDay(2)
        XCTAssertFalse(blocks(containing: ["UI morning class"]).firstMatch.exists, "Tuesday is not a repeat day")
    }

    func testCreateTuesdayThursdayLabThroughControls() throws {
        openCalendar()
        selectDay(2)
        openNewActivityEditor()
        typeTitle("UI afternoon lab")
        setTime("editor.start", hour: "12", minute: "00", period: "PM")
        setTime("editor.end", hour: "5", minute: "15", period: "PM")
        setTime("editor.arrival", hour: "11", minute: "15", period: "AM")
        turnOnRepeat(days: [2, 4])
        saveEditor()

        selectDay(2)
        let tuesday = blocks(containing: ["UI afternoon lab", "12:00", "5:15", "11:15", "Thursday"]).firstMatch
        XCTAssertTrue(tuesday.waitForExistence(timeout: 10), "Tuesday shows the lab 12:00 to 5:15, arrive by 11:15, repeating")
        selectDay(4)
        XCTAssertTrue(blocks(containing: ["UI afternoon lab"]).firstMatch.waitForExistence(timeout: 10), "Thursday repeats the lab")
        selectDay(3)
        XCTAssertFalse(blocks(containing: ["UI afternoon lab"]).firstMatch.exists, "Wednesday is not a repeat day")
    }

    // MARK: - Drag creation

    func testDragOnEmptyGridOpensEditorAndSaves() throws {
        openCalendar()
        selectDay(1)
        let grid = timeGrid()
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55))
        let to = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.75))
        from.press(forDuration: 0.6, thenDragTo: to)

        XCTAssertTrue(editorSheet().waitForExistence(timeout: 10), "Press, hold, and drag on empty grid space opens the editor")
        XCTAssertTrue(app.navigationBars["New Activity"].waitForExistence(timeout: 10))
        typeTitle("Dragged block")
        saveEditor()
        XCTAssertTrue(blocks(containing: ["Dragged block"]).firstMatch.waitForExistence(timeout: 10), "The dragged activity is stored and drawn")
    }

    // MARK: - Series edit and delete

    func testEditCancelAndDeleteSeries() throws {
        loadSamples()
        openCalendar()
        selectDay(1)
        let morningClass = blocks(containing: ["Sample morning class"]).firstMatch
        XCTAssertTrue(morningClass.waitForExistence(timeout: 10))
        morningClass.tap()

        XCTAssertTrue(detailSheet().waitForExistence(timeout: 10))
        let edit = app.buttons["calendar.detailEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertEqual(edit.label, "Edit Series", "A repeating activity is edited as a whole series")
        edit.tap()

        XCTAssertTrue(editorSheet().waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Edit Series"].waitForExistence(timeout: 10))
        replaceTitle(with: "Renamed morning class")
        let seriesNote = element("editor.seriesNote")
        reveal(seriesNote)
        XCTAssertTrue(seriesNote.exists, "The editor says the change applies to the whole series")
        app.buttons["editor.cancel"].tap()
        assertGone(editorSheet(), "Cancel closes the editor")
        closeDetailsIfShown()

        let restored = blocks(containing: ["Sample morning class"]).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10), "Cancel restores the original title")
        XCTAssertFalse(blocks(containing: ["Renamed morning class"]).firstMatch.exists, "Nothing from the cancelled draft was stored")

        restored.tap()
        XCTAssertTrue(detailSheet().waitForExistence(timeout: 10))
        let delete = app.buttons["calendar.detailDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        XCTAssertEqual(delete.label, "Delete Series")
        delete.tap()
        confirm("Delete Series")
        closeDetailsIfShown()

        assertGone(blocks(containing: ["Sample morning class"]).firstMatch, "Monday no longer shows the deleted series")
        selectDay(3)
        XCTAssertFalse(blocks(containing: ["Sample morning class"]).firstMatch.exists, "Wednesday no longer shows the deleted series")
        selectDay(2)
        XCTAssertTrue(blocks(containing: ["Sample afternoon lab"]).firstMatch.waitForExistence(timeout: 10), "The other sample series is untouched")
    }

    // MARK: - Press and hold a block

    func testPressAndHoldBlockShowsUnsavedBarAndCancelRestores() throws {
        loadSamples()
        openCalendar()
        selectDay(1)
        let morningClass = blocks(containing: ["Sample morning class"]).firstMatch
        XCTAssertTrue(morningClass.waitForExistence(timeout: 10))
        let originalLabel = morningClass.label
        morningClass.press(forDuration: 0.8)

        let bar = element("calendar.draftBar")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Press and hold starts an unsaved adjustment")
        XCTAssertTrue(element("calendar.draftSummary").exists)
        XCTAssertTrue(app.buttons["calendar.draftSave"].exists)
        XCTAssertTrue(app.buttons["calendar.draftEdit"].exists)
        XCTAssertTrue(element("calendar.resizeStartHandle").exists, "Top resize handle")
        XCTAssertTrue(element("calendar.resizeEndHandle").exists, "Bottom resize handle")
        XCTAssertFalse(app.buttons["calendar.addActivity"].isEnabled, "Add Activity waits while a change is unsaved")
        let cancel = app.buttons["calendar.draftCancel"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()

        assertGone(bar, "Cancel closes the unsaved-change bar")
        XCTAssertTrue(app.buttons["calendar.addActivity"].isEnabled)
        let restored = blocks(containing: ["Sample morning class"]).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.label, originalLabel, "Cancel restores the original times")
    }

    // MARK: - Navigation helpers

    private func openCalendar() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Calendar"].tap()
        XCTAssertTrue(timeGrid().waitForExistence(timeout: 10), "The time grid shows even with nothing stored")
    }

    private func loadSamples() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons["Settings"].tap()
        let load = app.buttons["settings.loadSamplesButton"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.tap()
        let status = app.staticTexts["settings.sampleStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)
    }

    private func selectDay(_ index: Int) {
        let day = app.buttons["calendar.day.\(index)"]
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        day.tap()
    }

    private func openNewActivityEditor() {
        let add = app.buttons["calendar.addActivity"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(editorSheet().waitForExistence(timeout: 10), "Add Activity opens the editor")
    }

    // MARK: - Element lookups

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func editorSheet() -> XCUIElement {
        element("editor.sheet")
    }

    private func detailSheet() -> XCUIElement {
        element("calendar.detailSheet")
    }

    private func timeGrid() -> XCUIElement {
        element("calendar.timeGrid")
    }

    private func editorNavigationBar() -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier IN %@", argumentArray: [editorTitles])).firstMatch
    }

    private func allBlocks() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "calendar.occurrenceBlock")
    }

    private func blocks(containing parts: [String]) -> XCUIElementQuery {
        let predicates = parts.map { NSPredicate(format: "label CONTAINS %@", $0) }
        return allBlocks().matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    }

    // MARK: - Editor helpers

    /// Types into the empty title field, then presses Return so the keyboard does not cover
    /// the pickers below it.
    private func typeTitle(_ title: String) {
        let field = app.textFields["editor.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title + "\n")
    }

    /// Places the cursor after the current title, deletes it, and types the replacement.
    private func replaceTitle(with title: String) {
        let field = app.textFields["editor.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let current = (field.value as? String) ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
        field.typeText(deletes + title)
    }

    /// Sets the time half of a compact DatePicker: taps its time button, which is the last
    /// button the picker exposes, turns the popover's wheels, and taps the editor's navigation
    /// bar to close the popover. The bar's position is read before the popover opens because
    /// the popover can hide the rest of the sheet from the accessibility tree. Minutes turn
    /// first so an end time never passes through its start on the way to the target.
    private func setTime(_ pickerID: String, hour: String, minute: String, period: String) {
        let bar = editorNavigationBar()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The editor's navigation bar is on screen")
        let barCenter = CGVector(dx: bar.frame.midX, dy: bar.frame.midY)

        let picker = app.datePickers[pickerID]
        reveal(picker)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "\(pickerID) is on screen")
        let buttons = picker.buttons
        XCTAssertGreaterThan(buttons.count, 0, "\(pickerID) shows a date button and a time button")
        buttons.element(boundBy: max(buttons.count - 1, 0)).tap()

        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 10), "The time button opens the wheels")
        XCTAssertGreaterThanOrEqual(wheels.count, 3, "Hour, minute, and AM/PM wheels")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: minute)
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: hour)
        wheels.element(boundBy: 2).adjust(toPickerWheelValue: period)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(barCenter).tap()
        assertGone(wheels.firstMatch, "Tapping the navigation bar closes the time popover")
    }

    /// Turns on "Repeat weekly" and makes sure each listed day is selected. A day that is
    /// already on, such as the start's weekday, is left alone so it is not turned off.
    private func turnOnRepeat(days: [Int]) {
        let toggle = app.switches["editor.repeatToggle"]
        reveal(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if isOn(toggle) == false {
            let control = toggle.switches.firstMatch
            if control.exists {
                control.tap()
            } else {
                toggle.tap()
            }
        }
        if isOn(toggle) == false {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(isOn(toggle), "Repeat weekly is on")

        for index in days {
            let day = app.buttons["editor.repeatDay.\(index)"]
            reveal(day)
            XCTAssertTrue(day.waitForExistence(timeout: 10), "Repeat day \(index) is shown")
            if day.isSelected == false {
                day.tap()
            }
            XCTAssertTrue(day.isSelected, "Repeat day \(index) is on")
        }
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    private func saveEditor() {
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        if isGone(editorSheet(), timeout: 10) == false {
            let issues = app.descendants(matching: .any).matching(identifier: "editor.issue")
                .allElementsBoundByIndex.map { $0.label }
            XCTFail("The editor stayed open after Save. Visible issues: \(issues.joined(separator: " | "))")
        }
    }

    /// Form rows load lazily, so scroll the editor until the element exists.
    private func reveal(_ element: XCUIElement) {
        var drags = 0
        while element.exists == false && drags < 4 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: to)
            drags += 1
        }
    }

    // MARK: - Sheet and dialog helpers

    /// Taps the destructive button of a confirmation dialog: an action sheet on iPhone, or the
    /// last button with that label when the dialog is shown as a popover.
    private func confirm(_ label: String) {
        let sheetButton = app.sheets.buttons[label]
        if sheetButton.waitForExistence(timeout: 5) {
            sheetButton.tap()
            return
        }
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "The confirmation dialog offers \(label)")
        matches.element(boundBy: max(matches.count - 1, 0)).tap()
    }

    /// Closes the detail sheet when it is still shown after the editor or a delete finished.
    private func closeDetailsIfShown() {
        let detail = detailSheet()
        guard detail.waitForExistence(timeout: 2) else {
            return
        }
        let done = app.buttons["calendar.detailDone"]
        if done.exists {
            done.tap()
        }
        assertGone(detail, "The detail sheet closes")
    }

    private func isGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func assertGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isGone(element, timeout: 10), message, file: file, line: line)
    }
}
