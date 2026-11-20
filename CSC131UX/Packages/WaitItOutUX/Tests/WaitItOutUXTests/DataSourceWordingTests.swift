import XCTest
@testable import WaitItOutUX

/// Stage S3: the Settings words that depend on where the data comes from. The demo wording is
/// the prototype's own, pinned byte for byte; the live wording never claims a preview, "no
/// network", or "nothing leaves this device", and says what is sent.
final class DataSourceWordingTests: XCTestCase {
    private let info = PrototypeInfo(appName: "WAIT IT OUT UX", version: "1.0", build: "1")

    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    // MARK: The Data source section

    func testTheModesAreNamedForWhatTheyAre() {
        XCTAssertEqual(DataSourceWording.sectionTitle, "Data source")
        XCTAssertEqual(DataSourceWording.pickerTitle, "Traffic data")
        XCTAssertEqual(DataSourceWording.addressTitle, "Server address")
        XCTAssertEqual(DataMode.allCases.map(DataSourceWording.title(for:)), ["Live (team backend)", "Demo (simulated)"])
    }

    func testThePlaceholderIsTheDefaultAddressOrAnExample() throws {
        XCTAssertEqual(DataSourceWording.addressPlaceholder(defaultAddress: try url("http://localhost:3000")), "http://localhost:3000")
        XCTAssertEqual(DataSourceWording.addressPlaceholder(defaultAddress: nil), "https://your-backend.example")
    }

    func testAnUnusableAddressSaysWhatStaysInUse() throws {
        XCTAssertEqual(
            DataSourceWording.addressIssueText(.needsHTTPS, addressInUse: try url("https://backend.example")),
            "Use https for this address. Still using https://backend.example."
        )
        XCTAssertEqual(
            DataSourceWording.addressIssueText(.notAnAddress, addressInUse: nil),
            "Enter a server address, such as https://example.org. No server address is in use."
        )
    }

    func testTheFooterSaysWhatIsSent() {
        let recommendations = DataSourceWording.footer(usesLiveBackend: true, remindersEnabled: false, monitorsTrips: true, hasDefaultAddress: true)
        XCTAssertEqual(recommendations, "For a recommendation the app sends the home and campus coordinates and your ideal arrival to the team backend. There is no account, and your location is never read. The Map's driving route is requested with the same two coordinates. Leave the server address empty to use this app's built-in address.")

        let alerts = DataSourceWording.footer(usesLiveBackend: true, remindersEnabled: true, monitorsTrips: true, hasDefaultAddress: false)
        XCTAssertEqual(alerts, "For a recommendation the app sends the home and campus coordinates and your ideal arrival to the team backend. With leave-home alerts on it also sends, for each upcoming trip, an id the app makes up, the title, the home and destination coordinates, the ideal arrival, and the time zone, together with an anonymous installation id and this device's push token. There is no account, and your location is never read. The Map's driving route is requested with the same two coordinates. The push token is how the server reaches this device; the server is also told whether notifications are allowed, and the installation's credential is kept in this device's Keychain. This build has no built-in server address, so live data needs one here.")
        // The list names what is sent and nothing that is not: the activity's start time and
        // the destination's name stay on the device.
        XCTAssertFalse(alerts.lowercased().contains("start"), alerts)
        XCTAssertFalse(alerts.lowercased().contains("destination name"), alerts)
        XCTAssertFalse(alerts.lowercased().contains("destination's name"), alerts)

        let withoutService = DataSourceWording.footer(usesLiveBackend: true, remindersEnabled: true, monitorsTrips: false, hasDefaultAddress: true)
        XCTAssertEqual(withoutService, recommendations, "Without a monitoring service no trip and no push token is sent")
    }

    func testTheDemoFooterSaysNothingIsSent() {
        let footer = DataSourceWording.footer(usesLiveBackend: false, remindersEnabled: true, monitorsTrips: true, hasDefaultAddress: true)
        XCTAssertEqual(footer, "In the Demo data mode leave-home times are simulated on this device and reminders are in-app previews, so no trip is sent to the team backend. Choose Live to get the backend's traffic-based recommendations. Leave the server address empty to use this app's built-in address.")
    }

    // MARK: Sentences elsewhere in Settings

    func testTheDemoWordingIsUnchanged() {
        XCTAssertEqual(
            DataSourceWording.savedDataNote(usesLiveBackend: false),
            "Each save replaces the file in one step, so a failed save keeps the previous copy. Leave-home times and commute estimates are never saved; they are recalculated after every launch. Nothing leaves this device."
        )
        XCTAssertEqual(
            DataSourceWording.remindersToggleHint(usesLiveBackend: false),
            "Shows a preview of the reminder due at each calculated leave-home time"
        )
        XCTAssertEqual(
            DataSourceWording.remindersFooter(usesLiveBackend: false, monitorsTrips: true, limits: .fallback),
            "Each reminder is due at the calculated leave-home time of a saved trip in the next 7 days and follows every change to activities, estimates, and settings. This prototype shows reminders only as previews inside the app: it asks for no notification permission and delivers nothing in the background. The team's notification service will be integrated later."
        )
        XCTAssertEqual(
            DataSourceWording.placesNote(usesLiveBackend: false),
            "Coordinates are typed in decimal degrees; no location permission, address search, or network lookup is used. A change recalculates every leave-home time."
        )
        XCTAssertEqual(
            DataSourceWording.coordinateEntryNote(usesLiveBackend: false),
            "No location permission, address search, or network lookup is used."
        )
    }

    func testTheLiveWordingNeverClaimsThatNothingLeavesTheDevice() {
        let saved = DataSourceWording.savedDataNote(usesLiveBackend: true)
        XCTAssertEqual(saved, "Each save replaces the file in one step, so a failed save keeps the previous copy. Leave-home times and recommendations are never saved; the team backend is asked again after every launch. These files stay on this device; what the app sends to the team backend is listed under Data source.")
        XCTAssertEqual(
            DataSourceWording.remindersToggleHint(usesLiveBackend: true),
            "Asks the team backend to watch your upcoming trips and to try to alert you when it is time to leave"
        )
        XCTAssertEqual(
            DataSourceWording.placesNote(usesLiveBackend: true),
            "Coordinates are typed in decimal degrees; no location permission or address search is used. Both coordinates are sent to the team backend to plan each trip, and a change asks it for every leave-home time again."
        )
        XCTAssertEqual(
            DataSourceWording.coordinateEntryNote(usesLiveBackend: true),
            "No location permission or address search is used. With live data the coordinates are sent to the team backend to plan your trips."
        )
        let live = [
            saved,
            DataSourceWording.remindersToggleHint(usesLiveBackend: true),
            DataSourceWording.placesNote(usesLiveBackend: true),
            DataSourceWording.coordinateEntryNote(usesLiveBackend: true),
            DataSourceWording.remindersFooter(usesLiveBackend: true, monitorsTrips: true, limits: .fallback),
            DataSourceWording.remindersFooter(usesLiveBackend: true, monitorsTrips: false, limits: .fallback),
            info.stepDescription(usesLiveBackend: true),
            info.dataDisclosure(usesLiveBackend: true)
        ]
        for sentence in live {
            let lowered = sentence.lowercased()
            XCTAssertFalse(lowered.contains("nothing leaves"), sentence)
            XCTAssertFalse(lowered.contains("network lookup"), sentence)
            XCTAssertFalse(lowered.contains("no network"), sentence)
            XCTAssertFalse(lowered.contains("preview only"), sentence)
            XCTAssertFalse(lowered.contains("simulated"), sentence)
        }
    }

    func testTheLiveRemindersFooterUsesTheServersNumbers() {
        let limits = MonitoringLimits(planningHorizon: 600 * 60, monitorLead: 180 * 60, headsUpLead: 45 * 60, meaningfulShift: 10 * 60, maxTrips: 10)
        let footer = DataSourceWording.remindersFooter(usesLiveBackend: true, monitorsTrips: true, limits: limits)
        XCTAssertEqual(footer, MonitoringText.remindersFooter(limits: limits))
        XCTAssertTrue(footer.contains("about 3 hours before the recommended departure"), footer)
        XCTAssertTrue(footer.contains("a heads-up about 45 minutes before"), footer)
        XCTAssertTrue(footer.contains("at least 10 minutes"), footer)
        XCTAssertTrue(footer.contains("Trips are removed from the server after they end; turning this off deletes this installation's data from the server."), footer)
        XCTAssertFalse(footer.contains("2 hours"), "No hard-coded lead")
        XCTAssertTrue(
            footer.contains("The app sends your trips for the next 7 days (at most 10) to the server each time it is opened or brought to the foreground, so alerts stop for later trips unless you open the app again."),
            "How far ahead alerts reach is said where alerts are described, with the server's own limit when it is the smaller one: \(footer)"
        )

        XCTAssertEqual(
            DataSourceWording.remindersFooter(usesLiveBackend: true, monitorsTrips: false, limits: limits),
            "With live data the app schedules no reminder of its own, and this build has no trip-monitoring service, so no leave-home alert is sent. The Demo data mode under Data source shows the in-app previews."
        )
    }

    // MARK: Prototype information

    func testThePrototypeInformationKeepsItsDemoText() {
        XCTAssertEqual(info.stepDescription(usesLiveBackend: false), info.stepDescription)
        XCTAssertEqual(info.dataDisclosure(usesLiveBackend: false), info.dataDisclosure)
        XCTAssertEqual(info.stepDescription, "Prototype step 8 of 8: the complete standalone demo, reviewed for team handoff. Activities and settings are saved on this device; leave-home times are calculated from the ideal arrival and a simulated test commute; reminders appear as in-app previews only, and no system notification is sent.")
        XCTAssertEqual(info.dataDisclosure, "Everything shown is demo content. Commute times are simulated test values, not measured traffic, and the line between home and campus is schematic, not a driving route. Reminders are previews inside the app; no notification permission is requested and no system notification is sent. No live traffic, routing, device location, accounts, or network services are used.")
    }

    func testThePrototypeInformationIsTruthfulWithLiveData() {
        let step = info.stepDescription(usesLiveBackend: true)
        XCTAssertEqual(step, "Live data mode: activities and settings are saved on this device; each leave-home time is the team backend's traffic-based recommendation for your ideal arrival; with leave-home reminders on, the server monitors your upcoming trips and tries to alert you. The Demo data mode under Data source brings back the standalone demo.")
        let disclosure = info.dataDisclosure(usesLiveBackend: true)
        XCTAssertEqual(disclosure, "Leave-home times, and the Map's driving route when the server provides one, come from the team backend over the network. Each recommendation names the traffic source the backend reported, and live traffic is claimed only when the backend had it. Home and campus are the coordinates set in Settings; no device location, address lookup, or account is used. Notification permission is asked for only when you turn leave-home reminders on or choose Allow Notifications. Sample activities and sample locations stay labeled SAMPLE.")
        for sentence in [step, disclosure] {
            XCTAssertFalse(sentence.contains("demo content"), sentence)
            XCTAssertFalse(sentence.contains("No live traffic"), sentence)
            XCTAssertFalse(sentence.contains("no notification permission"), sentence)
            XCTAssertFalse(sentence.contains("no system notification"), sentence)
        }
    }
}
