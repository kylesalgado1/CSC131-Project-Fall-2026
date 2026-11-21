import Foundation

/// Where leave-home times come from. When the host supplies a `LiveBackend`, the team backend
/// is the normal flow and the simulated test provider stays available only as the explicit,
/// clearly labeled Demo data mode. Without one, the model runs on its injected provider exactly
/// as the standalone prototype does, and nothing in this file changes anything.
///
/// A failed live request is never replaced by a simulated value: the two sources are never
/// mixed. Switching the mode or the server address cancels every running request and clears
/// every result before asking again, so a value from one source is never shown under the other.
extension WaitItOutModel {
    /// True when the host supplied a live backend, so Settings can offer the data source.
    public var hasLiveBackend: Bool {
        liveBackend != nil
    }

    /// True when leave-home times come from the team backend: a live backend exists and the
    /// data mode is Live.
    public var usesLiveBackend: Bool {
        liveBackend != nil && preferences.dataMode == .live
    }

    /// Live or Demo, as stored. Only meaningful when `hasLiveBackend`.
    public var dataMode: DataMode {
        preferences.dataMode
    }

    /// The provider requests go to now: the live backend's in Live mode, the injected one
    /// otherwise. Every request starts from here, so the two are never called for each other.
    var activeCommuteEstimator: any CommuteEstimating {
        if usesLiveBackend, let liveBackend {
            return liveBackend.commuteEstimator
        }
        return commuteEstimator
    }

    /// Settings "Data source": switches between the team backend and the demo, stores the
    /// choice, and starts every leave-home time again from loading under the new source. Does
    /// nothing when the mode is unchanged or the host supplied no live backend. A switch to
    /// Live also reads the notification permission and, with reminders on, registers with the
    /// push service, as launch and the return to the foreground do: the Demo data mode never
    /// asks about notifications, so without this the screens would show "not allowed yet" for
    /// a permission that was never read. It never prompts.
    public func setDataMode(_ mode: DataMode) {
        guard hasLiveBackend, preferences.dataMode != mode else { return }
        preferences.dataMode = mode
        monitoringTracking.hasExplicitChoice = true
        persistPreferences()
        applyTestCommuteSettings()
        dataSourceDidChange()
        refreshPushRegistration()
    }

    /// The server address as stored for the Settings field; empty while the host's default applies.
    public var backendAddressText: String {
        preferences.backendAddress ?? ""
    }

    /// The address requests go to now, or `nil` when none is configured or there is no live backend.
    public var backendBaseURL: URL? {
        liveBackend?.configuration.baseURL
    }

    /// Settings "Server address": validates the typed text, stores it, and hands it to the
    /// backend client. Empty text returns to the host's default address. Returns the issue and
    /// changes nothing when the text is not a usable address. When the address in use changes
    /// while live, every result is cleared and asked again from the new server, and the server
    /// left behind is told to forget this installation's trips.
    @discardableResult
    public func applyBackendAddress(_ text: String) -> BackendAddressIssue? {
        guard let liveBackend else { return nil }
        let url: URL?
        switch BackendConfiguration.parse(text) {
        case .success(let parsed):
            url = parsed
        case .failure(let issue):
            return issue
        }
        let stored = url?.absoluteString
        let addressBefore = liveBackend.configuration.baseURL
        if preferences.backendAddress != stored {
            preferences.backendAddress = stored
            monitoringTracking.hasExplicitChoice = true
            persistPreferences()
        }
        liveBackend.configuration.setOverride(url)
        let addressAfter = liveBackend.configuration.baseURL
        if addressAfter != addressBefore {
            // A server that may still hold this installation's trips is remembered, so it is
            // told to forget them before anything is sent to the new one.
            monitoringAddressDidChange(from: addressBefore, to: addressAfter)
            if usesLiveBackend {
                dataSourceDidChange()
            } else {
                monitoringSourceDidChange()
                reconcileMonitoring(force: true)
            }
        }
        return nil
    }

    /// Hands the stored server address to the backend client after preferences load. Stored
    /// text that is no longer a usable address counts as none, so the host's default applies.
    func applyStoredBackendAddress() {
        guard let liveBackend else { return }
        var url: URL?
        if let stored = preferences.backendAddress, case .success(let parsed) = BackendConfiguration.parse(stored) {
            url = parsed
        }
        liveBackend.configuration.setOverride(url)
    }

    /// The source of leave-home times changed (data mode or server address). Cancels every
    /// running request and clears every result, so nothing from the other source lingers and
    /// every trip starts again from loading, never from an out-of-date value. Then asks again,
    /// reconciles reminders and trip monitoring (which withdraws the trips from the server when
    /// the Demo data mode was chosen), and brings the Map's route in line.
    func dataSourceDidChange() {
        monitoringSourceDidChange()
        for task in departureTasks.values {
            task.cancel()
        }
        departureTasks = [:]
        draftDepartureTask?.cancel()
        draftDepartureTask = nil
        if !departures.isEmpty {
            departures = [:]
        }
        if draftDeparture != nil {
            draftDeparture = nil
        }
        commuteRevision &+= 1
        refreshDepartures()
        syncDraftDeparture()
        reconcileReminders(force: true)
        restartRoute()
    }
}
