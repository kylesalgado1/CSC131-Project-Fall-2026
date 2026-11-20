import Foundation

/// Words of the Settings sections that depend on where the data comes from: the "Data source"
/// section itself, and the sentences elsewhere in Settings that would otherwise claim "nothing
/// leaves this device", "no network", or an in-app preview while the team backend is in use.
/// Pure, so both wordings are tested; the demo wording is the prototype's original text,
/// unchanged.
public enum DataSourceWording {
    public static let sectionTitle = "Data source"
    public static let pickerTitle = "Traffic data"
    public static let pickerHint = "Chooses between the team backend's recommendations and the simulated demo"
    public static let addressTitle = "Server address"
    /// The address field's placeholder when the host has no default address.
    public static let exampleAddress = "https://your-backend.example"

    /// "Live (team backend)" and "Demo (simulated)".
    public static func title(for mode: DataMode) -> String {
        switch mode {
        case .live:
            return "Live (team backend)"
        case .demo:
            return "Demo (simulated)"
        }
    }

    /// The host's default address, which an empty field uses, or an example.
    public static func addressPlaceholder(defaultAddress: URL?) -> String {
        defaultAddress?.absoluteString ?? exampleAddress
    }

    /// The inline text under the address field for text that is not a usable address, with
    /// what stays in effect: "Use https for this address. Still using https://backend.example."
    public static func addressIssueText(_ issue: BackendAddressIssue, addressInUse: URL?) -> String {
        guard let addressInUse else {
            return "\(issue.message) No server address is in use."
        }
        return "\(issue.message) Still using \(addressInUse.absoluteString)."
    }

    /// What the "Data source" section says is sent. With the live backend: the request fields,
    /// the monitored trips and the push details while leave-home alerts are on, and that there
    /// is no account. In the Demo data mode: that nothing is sent for the simulated values.
    /// `monitorsTrips` is false when the host composed no monitoring service.
    public static func footer(usesLiveBackend: Bool, remindersEnabled: Bool, monitorsTrips: Bool, hasDefaultAddress: Bool) -> String {
        let address = hasDefaultAddress
            ? "Leave the server address empty to use this app's built-in address."
            : "This build has no built-in server address, so live data needs one here."
        guard usesLiveBackend else {
            return "In the Demo data mode leave-home times are simulated on this device and reminders are in-app previews, so no trip is sent to the team backend. Choose Live to get the backend's traffic-based recommendations. \(address)"
        }
        let alertsOn = remindersEnabled && monitorsTrips
        var text = MonitoringText.dataSentFooter(remindersEnabled: alertsOn)
        text += " The Map's driving route is requested with the same two coordinates."
        if alertsOn {
            text += " The push token is how the server reaches this device; the server is also told whether notifications are allowed, and the installation's credential is kept in this device's Keychain."
        }
        return "\(text) \(address)"
    }

    /// The closing sentences of the "Saved data" footer, after the two storage descriptions.
    /// "Nothing leaves this device." is said only in the demo.
    public static func savedDataNote(usesLiveBackend: Bool) -> String {
        guard usesLiveBackend else {
            return "Each save replaces the file in one step, so a failed save keeps the previous copy. Leave-home times and commute estimates are never saved; they are recalculated after every launch. Nothing leaves this device."
        }
        return "Each save replaces the file in one step, so a failed save keeps the previous copy. Leave-home times and recommendations are never saved; the team backend is asked again after every launch. These files stay on this device; what the app sends to the team backend is listed under Data source."
    }

    /// VoiceOver hint of the leave-home reminders toggle.
    public static func remindersToggleHint(usesLiveBackend: Bool) -> String {
        usesLiveBackend
            ? "Asks the team backend to watch your upcoming trips and to try to alert you when it is time to leave"
            : "Shows a preview of the reminder due at each calculated leave-home time"
    }

    /// Footer of the "Leave-home reminders" section. The demo describes its in-app previews;
    /// with the live backend the server's monitoring is described in the server's own numbers
    /// (`MonitoringText.remindersFooter`), or, when the host composed no monitoring service,
    /// that no alert is sent at all.
    public static func remindersFooter(usesLiveBackend: Bool, monitorsTrips: Bool, limits: MonitoringLimits) -> String {
        guard usesLiveBackend else {
            return "Each reminder is due at the calculated leave-home time of a saved trip in the next \(DepartureHorizon.lookaheadDays) days and follows every change to activities, estimates, and settings. This prototype shows reminders only as previews inside the app: it asks for no notification permission and delivers nothing in the background. The team's notification service will be integrated later."
        }
        guard monitorsTrips else {
            return "With live data the app schedules no reminder of its own, and this build has no trip-monitoring service, so no leave-home alert is sent. The Demo data mode under Data source shows the in-app previews."
        }
        return MonitoringText.remindersFooter(limits: limits)
    }

    /// The sentences of the "Home and campus" footer about how coordinates are entered and
    /// what a change does. With the live backend the coordinates do leave the device.
    public static func placesNote(usesLiveBackend: Bool) -> String {
        guard usesLiveBackend else {
            return "Coordinates are typed in decimal degrees; no location permission, address search, or network lookup is used. A change recalculates every leave-home time."
        }
        return "Coordinates are typed in decimal degrees; no location permission or address search is used. Both coordinates are sent to the team backend to plan each trip, and a change asks it for every leave-home time again."
    }

    /// The closing sentence of the place editor's coordinates footer.
    public static func coordinateEntryNote(usesLiveBackend: Bool) -> String {
        usesLiveBackend
            ? "No location permission or address search is used. With live data the coordinates are sent to the team backend to plan your trips."
            : "No location permission, address search, or network lookup is used."
    }
}
