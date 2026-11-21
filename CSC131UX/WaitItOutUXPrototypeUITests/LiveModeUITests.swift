import XCTest

/// Stage S3: the app as it normally runs, composed with the team backend, driven through the
/// real host. No server runs during these tests. The app is pointed at a loopback port where
/// nothing listens, so every request is refused at once and nothing leaves this machine. The
/// tests check what must hold while the backend cannot be reached: the screens say so, no
/// simulated time stands in for the missing answer, and the simulation returns only when the
/// user chooses the Demo data mode in Settings.
///
/// Leave-home reminders stay off here, so the app never asks for notification permission and
/// never registers with the push service.
///
/// Identifier strings mirror `AccessibilityID` in the WaitItOutUX package because a UI test
/// cannot import it. What the next sample trip shows depends on when the test runs, so the
/// trip card is checked for every honest outcome: the failed request (the trip is close enough
/// to be asked about), the note that the traffic forecast does not reach that far yet, or the
/// statement that the trip's ideal arrival has already passed (the 45 minutes between a sample
/// activity's ideal arrival and its start). None of them is a leave-home time.
final class LiveModeUITests: XCTestCase {
    /// Loopback, on the "discard" port: nothing listens there, so a connection is refused at once.
    private static let unreachableBackend = "http://127.0.0.1:9"
    private static let unreachableHost = "127.0.0.1:9"

    private var app: XCUIApplication = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // A fresh storage folder per test, so each test starts from empty storage.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = "UITest-" + UUID().uuidString
        // The live composition, which is also what a launch without this variable gets.
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "live"
        app.launchEnvironment["WAIT_IT_OUT_BACKEND_URL"] = Self.unreachableBackend
        app.launch()
    }

    func testAnUnreachableBackendIsShownHonestlyAndNeverReplacedBySimulatedTimes() throws {
        let sourceLabel = element("map.liveDataLabel")
        XCTAssertTrue(sourceLabel.waitForExistence(timeout: 10), "The Map names the team backend as its data source")
        XCTAssertTrue(sourceLabel.label.hasPrefix("Team backend"), "The label names the source, whatever it answers with: \(sourceLabel.label)")
        XCTAssertFalse(sourceLabel.label.contains("Live data"), "Nothing is called live data while no answer has arrived: \(sourceLabel.label)")
        XCTAssertFalse(element("map.demoEstimateLabel").exists, "Nothing is labeled a demo estimate in Live mode")

        let routeFailed = NSPredicate(format: "label CONTAINS %@", "The driving route could not be loaded")
        XCTAssertTrue(
            element("map.demoStatus", where: routeFailed).waitForExistence(timeout: 15),
            "The Map says the route request failed"
        )
        let schematic = NSPredicate(format: "label CONTAINS %@", "not a driving route")
        XCTAssertTrue(element("map.schematicNote", where: schematic).exists, "The line stays labeled as schematic")

        loadSampleSchedule()
        openTab("Map")
        assertTheNextTripHasNoLeaveHomeTime()

        openTab("Settings")
        _ = revealSettingsElement(element("settings.dataMode"))
        let names = NSPredicate(format: "label CONTAINS %@", Self.unreachableHost)
        let status = revealSettingsElement(element("settings.backendStatus", where: names), waitingUpTo: 5)
        XCTAssertFalse(status.label.contains("Connected"), "A server that never answered is not called connected: \(status.label)")
    }

    func testChoosingDemoBringsBackTheLabeledSimulationAndLiveRemovesItAgain() throws {
        XCTAssertTrue(element("map.liveDataLabel").waitForExistence(timeout: 10), "The app starts in Live mode")
        loadSampleSchedule()

        chooseDataMode("Demo (simulated)")
        openTab("Map")
        XCTAssertTrue(element("map.demoEstimateLabel").waitForExistence(timeout: 10), "The demo is labeled on the Map")
        XCTAssertFalse(element("map.liveDataLabel").exists, "Nothing names the team backend as the source in the Demo data mode")
        let simulated = NSPredicate(format: "label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "Simulated test data", "7:15", "10:15")
        XCTAssertTrue(
            element("map.nextTripDeparture.leaveHome", where: simulated).waitForExistence(timeout: 15),
            "The demo shows its simulated leave-home time, labeled as simulated"
        )

        chooseDataMode("Live (team backend)")
        openTab("Map")
        XCTAssertTrue(element("map.liveDataLabel").waitForExistence(timeout: 10), "Live mode is labeled again")
        XCTAssertFalse(element("map.demoEstimateLabel").exists, "The demo label is gone")
        assertTheNextTripHasNoLeaveHomeTime()
    }

    // MARK: - Checks

    /// With no backend to answer, the next trip shows one of the three honest messages and
    /// never a leave-home time, simulated or otherwise. Which one depends on the time of day:
    /// the request failed, the trip lies beyond the traffic forecast, or its ideal arrival has
    /// already passed. Try Again is offered only for the failed request.
    private func assertTheNextTripHasNoLeaveHomeTime() {
        let honest = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "The backend could not be reached",
            "The traffic forecast reaches about",
            "The ideal arrival time has passed"
        )
        let message = element("map.nextTripDeparture.message", where: honest)
        XCTAssertTrue(message.waitForExistence(timeout: 15), "The next trip says why it has no leave-home time")
        XCTAssertFalse(element("map.nextTripDeparture.leaveHome").exists, "No leave-home time is shown without an answer")
        XCTAssertFalse(element("map.nextTripSimulation").exists, "Nothing is described as simulated in Live mode")
        let retry = app.buttons.matching(identifier: "map.nextTripDeparture.retry").firstMatch
        if message.label.contains("could not be reached") {
            XCTAssertTrue(retry.exists, "A failed request offers Try Again")
        } else {
            XCTAssertFalse(retry.exists, "Nothing failed, so there is nothing to try again: \(message.label)")
        }
    }

    // MARK: - Navigation

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
        let status = app.staticTexts["settings.sampleStatus"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)
    }

    /// Picks an entry of the "Traffic data" menu under Settings, Data source.
    private func chooseDataMode(_ title: String) {
        openTab("Settings")
        let picker = revealSettingsElement(element("settings.dataMode"))
        picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "The menu offers \(title)")
        choice.tap()
        let chosen = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)
        XCTAssertTrue(
            element("settings.dataMode", where: chosen).waitForExistence(timeout: 10),
            "The picker shows \(title)"
        )
    }

    // MARK: - Elements

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(_ identifier: String, where predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).matching(predicate).firstMatch
    }

    /// Scrolls Settings toward the later sections, then back toward the earlier ones, until
    /// `target` is on screen. Form rows exist only near the screen, so an off-screen row is
    /// found by scrolling.
    private func revealSettingsElement(_ target: XCUIElement, waitingUpTo patience: TimeInterval = 0) -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        if patience > 0 {
            _ = target.waitForExistence(timeout: patience)
        }
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        swipes = 0
        while !(target.exists && target.isHittable), swipes < 16 {
            app.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(target.exists, "Settings shows \(target)")
        return target
    }
}

/// End to end against the fixture server: the real app over real HTTP, talking to the team
/// backend's real routes and decision code with simulated traffic and a recording push
/// sender. This class is opt-in. Start the server first (in the repository's `backend` folder:
/// `npm run serve:fixture`, which listens on 127.0.0.1:3100); every test here is skipped while
/// that server does not answer, so the ordinary UI test run never needs it and never touches a
/// network beyond this machine.
///
/// These two tests are the documented exception to two rules the other UI tests follow (see
/// AGENTS.md, "Host rules"):
/// - They turn leave-home alerts on, because registering with the server and sending the trips
///   is what they check. Allowing notifications makes the app register with the system's push
///   service, as it would for any user; nothing is ever sent through that service by a test.
///   The alert of the closed-app test is put on the simulator from outside with
///   `xcrun simctl push`.
/// - The closed-app test relaunches the app without a launch environment, in the app's default
///   storage, because a launch by the system (tapping a notification) carries no environment:
///   the trip has to exist where that launch looks for it. It puts the default storage back as
///   it found a fresh install (alerts off, no samples, no typed server address) when it ends.
///
/// The fixture reports its traffic source as a fixture, so the app must label every time it
/// shows as test fixture traffic and never as live traffic.
final class FixtureBackendEndToEndUITests: XCTestCase {
    private static let fixtureBackend = "http://127.0.0.1:3100"

    private var app: XCUIApplication = XCUIApplication()
    private var storageFolder = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            Self.fixtureIsRunning(),
            "The fixture server is not running on 127.0.0.1:3100, so the end-to-end check is skipped."
        )
        storageFolder = "UITest-E2E-" + UUID().uuidString
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        // A fresh storage folder per test; its name is printed so a later launch can reuse it.
        app.launchEnvironment["WAIT_IT_OUT_STORAGE_FOLDER"] = storageFolder
        app.launchEnvironment["WAIT_IT_OUT_DATA_MODE"] = "live"
        app.launchEnvironment["WAIT_IT_OUT_BACKEND_URL"] = Self.fixtureBackend
        app.launch()
        print("E2E_STORAGE_FOLDER=" + storageFolder)
    }

    func testBackendRecommendationReachesTheMapAndTripsReachTheServer() throws {
        XCTAssertTrue(element("map.liveDataLabel").waitForExistence(timeout: 15), "The app runs composed with the backend")
        loadSampleSchedule()

        // Map: the next trip's leave-home time is the backend's answer.
        openTab("Map")
        let mapTime = element("map.nextTripDeparture.leaveHome")
        let noTimeYet = element(
            "map.nextTripDeparture.message",
            where: NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "The traffic forecast reaches about",
                "The ideal arrival time has passed"
            )
        )
        waitUntil(timeout: 40) { mapTime.exists || noTimeYet.exists }
        try XCTSkipIf(
            noTimeYet.exists && !mapTime.exists,
            "The next sample trip has no leave-home time at this hour: it is beyond the backend's forecast, or its ideal arrival has just passed. Run within about 11 hours before a sample class's ideal arrival."
        )
        XCTAssertTrue(mapTime.exists, "The Map shows a leave-home time from the backend")
        let mapLabel = mapTime.label
        print("E2E_MAP_LEAVE_HOME=" + mapLabel)
        XCTAssertNotNil(Self.firstClockTime(in: mapLabel), "The Map's leave-home label names a time: \(mapLabel)")

        let fixtureSource = element(
            "map.nextTripDeparture.source",
            where: NSPredicate(format: "label CONTAINS[c] %@", "fixture")
        )
        XCTAssertTrue(fixtureSource.waitForExistence(timeout: 5), "Fixture traffic is labeled as fixture data, never as live traffic")
        print("E2E_MAP_SOURCE=" + fixtureSource.label)
        XCTAssertFalse(element("map.nextTripSimulation").exists, "The demo simulation line is absent in Live mode")

        let route = element(
            "map.schematicNote",
            where: NSPredicate(format: "label CONTAINS %@", "Driving route from the team backend")
        )
        XCTAssertTrue(route.waitForExistence(timeout: 20), "The map draws the backend's route and says where it came from")
        print("E2E_ROUTE_NOTE=" + route.label)

        // Reminders on: the app asks for permission, registers with the server, and syncs trips.
        openTab("Settings")
        turnAlertsOnAndAllowNotifications(reporting: "E2E_PERMISSION")
        let status = revealSettingsElement(element("monitoring.status"), waitingUpTo: 20)
        // Give the registration and the first synchronization time to settle.
        waitUntil(timeout: 25) { !status.label.contains("Waiting for the server") }
        print("E2E_MONITORING_STATUS=" + status.label)
        XCTAssertFalse(status.label.contains("could not be synchronized"), "Trips reached the server: \(status.label)")
        let detail = element("monitoring.detail")
        if detail.exists {
            print("E2E_MONITORING_DETAIL=" + detail.label)
        }
    }

    /// The app is closed when an alert arrives; tapping the alert opens the trip it is about.
    /// The alert is put on the simulator from outside (`xcrun simctl push` with the payload the
    /// fixture server recorded), so this checks how the app shows and handles a visible push,
    /// not Apple's delivery. It runs only when the environment asks for it (`E2E_CLOSED_APP=1`),
    /// because someone has to send that push while the test waits: it prints
    /// `E2E_READY_FOR_PUSH` when the app is closed and then waits up to three minutes.
    func testClosedAppShowsAPushedAlertAndTappingItOpensTheTrip() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["E2E_CLOSED_APP"] == "1",
            "Runs only with E2E_CLOSED_APP=1 and someone sending the push while it waits."
        )
        // Start over the way a person would: default storage, server address typed in Settings,
        // so a launch by the system (a notification tap) finds the same data and server. This
        // is the one launch in the UI tests without a storage folder and a data mode, and the
        // teardown below puts the default storage back as a fresh install has it.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "America/Los_Angeles"
        addTeardownBlock { [self] in
            restoreDefaultStorage()
        }
        app.launch()

        openTab("Settings")
        let address = revealSettingsElement(element("settings.backendAddress"))
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        address.typeText(Self.fixtureBackend + "\n")
        let connected = element("settings.backendStatus", where: NSPredicate(format: "label CONTAINS %@", "127.0.0.1"))
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "Settings names the server typed in")

        loadSampleSchedule()
        openTab("Map")
        let mapTime = element("map.nextTripDeparture.leaveHome")
        XCTAssertTrue(mapTime.waitForExistence(timeout: 40), "The Map shows a leave-home time from the backend")
        let mapClock = try XCTUnwrap(Self.firstClockTime(in: mapTime.label))
        print("E2E_CLOSED_MAP_LEAVE_HOME=" + mapTime.label)

        openTab("Settings")
        turnAlertsOnAndAllowNotifications(reporting: nil)
        let status = revealSettingsElement(element("monitoring.status"), waitingUpTo: 20)
        waitUntil(timeout: 25) { !status.label.contains("Waiting for the server") }
        print("E2E_CLOSED_MONITORING_STATUS=" + status.label)

        // Close the app completely, then wait for the alert.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The app is closed")
        print("E2E_READY_FOR_PUSH")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Sample morning class")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 180), "The pushed alert is shown while the app is closed")
        print("E2E_ALERT_SHOWN=" + alert.label)
        attachScreenshot(named: "closed-app-alert")
        alert.tap()

        // The app opens on the trip the alert was about and shows its leave-home time.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "Tapping the alert opens the app")
        let sheet = element("calendar.detailSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "The app opens the trip's details")
        let detailTime = element("calendar.detailDeparture.leaveHome")
        XCTAssertTrue(detailTime.waitForExistence(timeout: 30), "The details show the trip's leave-home time")
        print("E2E_OPENED_DETAIL_LEAVE_HOME=" + detailTime.label)
        attachScreenshot(named: "opened-trip")
        XCTAssertEqual(Self.firstClockTime(in: detailTime.label), mapClock, "The details show the same leave-home time the Map showed")
        let monitoring = element("calendar.detailMonitoring")
        if monitoring.exists {
            print("E2E_OPENED_DETAIL_MONITORING=" + monitoring.label)
        }
    }

    // MARK: - Fixture

    /// Whether the fixture answers its health route. A plain request from the test runner to
    /// this machine's loopback address; nothing else is contacted.
    private static func fixtureIsRunning() -> Bool {
        guard let url = URL(string: fixtureBackend + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        var answered = false
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
            answered = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 4)
        return answered
    }

    /// The first clock time in a label, such as "7:45 AM", with any narrow space made plain.
    private static func firstClockTime(in label: String) -> String? {
        let plain = label.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        guard let range = plain.range(of: #"\d{1,2}:\d{2} ?[AP]M"#, options: .regularExpression) else { return nil }
        return String(plain[range]).replacingOccurrences(of: " ", with: "")
    }

    /// Keeps a picture of the whole screen with the test's results, whatever the outcome.
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Alerts

    /// Turns the leave-home alerts toggle on (when it is off) and answers the system's
    /// question with Allow when it appears. `key` names the line printed about the question.
    private func turnAlertsOnAndAllowNotifications(reporting key: String?) {
        let toggle = revealSettingsElement(app.switches["settings.remindersToggle"])
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            allow.tap()
            if let key {
                print(key + "=allowed")
            }
        } else if let key {
            print(key + "=no prompt appeared")
        }
    }

    /// Puts the app's default storage back as a fresh install has it, after the closed-app
    /// test used it: alerts off (which also takes this installation off the fixture server),
    /// no sample activities, and no typed server address. Best effort and without assertions,
    /// so it also runs after a failure; whatever it cannot reach it leaves alone.
    private func restoreDefaultStorage() {
        if app.state != .runningForeground {
            app.launch()
        }
        let done = app.buttons["calendar.detailDone"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
        }
        let settings = app.tabBars.firstMatch.buttons["Settings"]
        guard settings.waitForExistence(timeout: 10) else { return }
        settings.tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 10) else { return }

        let toggle = scrolledIntoView(app.switches["settings.remindersToggle"])
        if toggle.exists, (toggle.value as? String) == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let clear = scrolledIntoView(app.buttons["settings.clearSamplesButton"])
        if clear.exists, clear.isEnabled {
            clear.tap()
        }
        let address = scrolledIntoView(element("settings.backendAddress"))
        if address.exists, let typed = address.value as? String, typed.hasPrefix("http://127.0.0.1") {
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count) + "\n")
        }
    }

    // MARK: - Navigation

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
        let status = app.staticTexts["settings.sampleStatus"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "2 sample"), evaluatedWith: status)], timeout: 10)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(_ identifier: String, where predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).matching(predicate).firstMatch
    }

    /// Scrolls Settings toward the later sections, then back toward the earlier ones, until
    /// `target` is on screen. Never fails: the caller checks `exists`.
    private func scrolledIntoView(_ target: XCUIElement) -> XCUIElement {
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        swipes = 0
        while !(target.exists && target.isHittable), swipes < 16 {
            app.swipeDown()
            swipes += 1
        }
        return target
    }

    private func revealSettingsElement(_ target: XCUIElement, waitingUpTo patience: TimeInterval = 0) -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        if patience > 0 {
            _ = target.waitForExistence(timeout: patience)
        }
        let found = scrolledIntoView(target)
        XCTAssertTrue(found.exists, "Settings shows \(target)")
        return found
    }
}
