import SwiftUI

/// Settings tab. Holds the working appearance control, the explicit sample-schedule actions,
/// the prototype information area, home and campus (step 0006), leave-home reminders and
/// saved data (step 0007), and the grouped Prototype testing section: the deterministic
/// estimate scenarios (step 0006), the labeled test commute duration (step 0005), and the
/// reminder failure simulation (step 0007). Controls for features that do not exist yet are absent.
///
/// When the host supplies a live backend (stage S3) a "Data source" section follows Saved data:
/// the Live or Demo choice, the server address, where the connection stands, and what is sent.
/// In the Live data mode the reminders section shows the server's trip monitoring
/// (`MonitoringStatusView`) instead of the in-app preview, every sentence that would claim a
/// preview, "no network", or "nothing leaves this device" is worded for the backend, and
/// Prototype testing is hidden. In the Demo data mode, and without a live backend, every
/// section reads exactly as the standalone prototype.
///
/// When the host supplied a live backend the tab has the same minute tick as the Map and the
/// Calendar (`runClock`), so what it says about the server stays current while it is on
/// screen and a failed synchronization or withdrawal really is tried again automatically.
/// Without a live backend nothing here changes with time, and nothing ticks.
@MainActor
public struct SettingsScreen: View {
    let model: WaitItOutModel

    /// Public since step 0008 so the team can place this screen in its own tab bar.
    public init(model: WaitItOutModel) {
        self.model = model
    }

    @Environment(\.locale) private var locale
    /// Current instant from the injected clock, refreshed at each whole minute while the tab is
    /// on screen and the host supplied a live backend. `nil` until the first tick.
    @State private var now: Date?
    /// The place being edited in the place editor sheet, or `nil`.
    @State private var editingPlace: PlaceRole?
    /// Confirmation for "Keep a Copy and Start Over" (step 0007).
    @State private var isConfirmingStartOver = false

    /// Text being typed in the test commute field. It is validated as it changes and applied
    /// when editing ends (Done, or leaving the field or the tab), so partial input such as the
    /// "6" on the way from 60 to 45 never reaches the model. Only valid minutes are applied.
    @State private var commuteText = ""
    @State private var commuteIssue: CommuteDurationIssue?
    @FocusState private var isCommuteFieldFocused: Bool

    /// Text being typed in the Data source server address field. Like the commute field it is
    /// applied when editing ends (Return, Done, or leaving the field or the tab), so half an
    /// address never reaches the backend client. Only a usable address is applied; anything
    /// else shows its issue under the field and keeps the address in use.
    @State private var addressText = ""
    @State private var addressIssue: BackendAddressIssue?
    @FocusState private var isAddressFieldFocused: Bool

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { model.preferences.appearance },
            set: { model.setAppearance($0) }
        )
    }

    public var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                sampleScheduleSection
                prototypeInfoSection
                // New sections go below, so the sections above keep their positions from
                // earlier steps (the launch UI tests read them without scrolling).
                PlacesSettingsSection(model: model) { role in
                    editingPlace = role
                }
                remindersSection
                savedDataSection
                if model.hasLiveBackend {
                    dataSourceSection
                }
                if model.usesTestCommute {
                    prototypeTestingSection
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $editingPlace) { role in
                PlaceEditorView(model: model, role: role)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isCommuteFieldFocused = false
                        isAddressFieldFocused = false
                    }
                }
            }
            .onAppear {
                commuteText = String(model.testCommuteDuration.wholeMinutes)
                commuteIssue = nil
                addressText = model.backendAddressText
                addressIssue = nil
            }
            .onDisappear {
                commitCommuteText()
                commitAddressText()
            }
            .task {
                await runClock()
            }
            .onChange(of: model.testCommuteDuration) { _, duration in
                // Stored preferences loaded, or the stepper moved: show the value in effect.
                if !isCommuteFieldFocused {
                    commuteText = String(duration.wholeMinutes)
                    commuteIssue = nil
                }
            }
            .onChange(of: model.backendAddressText) { _, address in
                // Stored preferences loaded: show the address in effect.
                if !isAddressFieldFocused {
                    addressText = address
                    addressIssue = nil
                }
            }
        }
    }

    /// Refreshes `now` at each whole minute and re-plans leave-home times, which is also what
    /// retries a failed synchronization or withdrawal and reads the server's state again, as
    /// the Map's and the Calendar's ticks do. Runs only in a host with a live backend, in
    /// either data mode (a withdrawal can be pending in the Demo data mode too). Cancelled
    /// when the tab is hidden, so nothing ticks in the background.
    @MainActor
    private func runClock() async {
        guard model.hasLiveBackend else { return }
        while !Task.isCancelled {
            let instant = model.currentDate()
            now = instant
            model.refreshDepartures()
            let second = model.weekCalculator.calendar.component(.second, from: instant)
            do {
                try await Task.sleep(for: .seconds(max(1, 60 - second)))
            } catch {
                return
            }
        }
    }

    /// Applies the field's text when it is valid; otherwise keeps the issue on screen and the
    /// last valid duration in effect.
    private func commitCommuteText() {
        commuteIssue = model.applyTestCommuteMinutes(commuteText)
    }

    /// Applies the typed server address when it is usable and shows it as stored (trimmed,
    /// without a trailing slash); otherwise keeps the issue on screen and the address in use.
    /// Text that equals the stored address changes nothing.
    private func commitAddressText() {
        guard model.hasLiveBackend else { return }
        guard addressText.trimmingCharacters(in: .whitespacesAndNewlines) != model.backendAddressText else {
            addressText = model.backendAddressText
            addressIssue = nil
            return
        }
        addressIssue = model.applyBackendAddress(addressText)
        if addressIssue == nil {
            addressText = model.backendAddressText
        }
    }

    private var dataModeBinding: Binding<DataMode> {
        Binding(
            get: { model.dataMode },
            set: { model.setDataMode($0) }
        )
    }

    /// Data source (stage S3), shown only when the host supplied a live backend: the Live or
    /// Demo choice, the server address, where the connection stands, and what is sent. A
    /// server that is still being told to forget this installation, or could not be told, is
    /// named here in the Demo data mode; in the Live mode the reminders section says it.
    private var dataSourceSection: some View {
        let formatter = OccurrenceFormatter(calculator: model.weekCalculator, locale: locale)
        let connection = model.backendConnection
        return Section {
            Picker(DataSourceWording.pickerTitle, selection: dataModeBinding) {
                ForEach(DataMode.allCases, id: \.self) { mode in
                    Text(DataSourceWording.title(for: mode)).tag(mode)
                }
            }
            .accessibilityIdentifier(AccessibilityID.settingsDataMode)
            .accessibilityHint(DataSourceWording.pickerHint)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(DataSourceWording.addressTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    DataSourceWording.addressTitle,
                    text: $addressText,
                    prompt: Text(DataSourceWording.addressPlaceholder(defaultAddress: model.defaultBackendURL))
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isAddressFieldFocused)
                .onChange(of: addressText) { _, text in
                    // Half an address is never an address, so nothing is flagged while typing:
                    // an issue appears when editing ends and goes as soon as the text is usable.
                    if case .success = BackendConfiguration.parse(text) {
                        addressIssue = nil
                    }
                }
                .onChange(of: isAddressFieldFocused) { _, isFocused in
                    if !isFocused {
                        commitAddressText()
                    }
                }
                .onSubmit {
                    commitAddressText()
                }
                .accessibilityLabel(DataSourceWording.addressTitle)
                .accessibilityIdentifier(AccessibilityID.settingsBackendAddress)
            }
            if let addressIssue {
                Label(DataSourceWording.addressIssueText(addressIssue, addressInUse: model.backendBaseURL), systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityID.settingsBackendAddressIssue)
            }
            Label(formatter.backendStatusText(for: connection, at: now ?? model.currentDate()), systemImage: Self.symbol(for: connection))
                .font(.footnote)
                .foregroundStyle(Self.isProblem(connection) ? .primary : .secondary)
                .accessibilityIdentifier(AccessibilityID.settingsBackendStatus)
            if !model.usesLiveBackend, let withdrawal = MonitoringText.withdrawalSentence(model.monitoringWithdrawal) {
                Label(withdrawal, systemImage: model.monitoringWithdrawal == .pending ? "hourglass" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(model.monitoringWithdrawal == .pending ? .secondary : .primary)
                    .accessibilityIdentifier(AccessibilityID.settingsBackendNotice)
            }
            if model.previousServerMayStillAlert {
                Label(MonitoringText.previousServerWarning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.settingsBackendNotice)
            }
        } header: {
            Text(DataSourceWording.sectionTitle)
        } footer: {
            Text(DataSourceWording.footer(
                usesLiveBackend: model.usesLiveBackend,
                remindersEnabled: model.remindersEnabled,
                monitorsTrips: model.usesTripMonitoring,
                hasDefaultAddress: model.defaultBackendURL != nil
            ))
        }
    }

    private static func symbol(for connection: BackendConnection) -> String {
        switch connection {
        case .demo:
            return "testtube.2"
        case .notConfigured, .failing:
            return "exclamationmark.triangle"
        case .unanswered:
            return "hourglass"
        case .connected:
            return "checkmark.circle"
        }
    }

    private static func isProblem(_ connection: BackendConnection) -> Bool {
        switch connection {
        case .notConfigured, .failing:
            return true
        case .demo, .unanswered, .connected:
            return false
        }
    }

    private var remindersBinding: Binding<Bool> {
        Binding(
            get: { model.remindersEnabled },
            set: { model.setRemindersEnabled($0) }
        )
    }

    private var reminderFailureBinding: Binding<Bool> {
        Binding(
            get: { model.simulatesReminderFailure },
            set: { model.setSimulatesReminderFailure($0) }
        )
    }

    /// Leave-home reminders (step 0007): the user's wish, and the preview of what the adapter
    /// holds. The wish is stored; the preview is recreated after every relaunch. In the Live
    /// data mode (stage S3) the same wish asks the server to monitor the trips: the PREVIEW
    /// badge goes, the body is the server's status, and the footer describes the server's
    /// alerts in the server's own numbers.
    private var remindersSection: some View {
        Section {
            Toggle("Remind me when it is time to leave", isOn: remindersBinding)
                .accessibilityIdentifier(AccessibilityID.settingsRemindersToggle)
                .accessibilityHint(DataSourceWording.remindersToggleHint(usesLiveBackend: model.usesLiveBackend))
            if model.usesLiveBackend {
                MonitoringStatusView(model: model, identifierPrefix: AccessibilityID.settingsMonitoring, now: now)
            } else {
                ReminderPreviewView(model: model, identifierPrefix: AccessibilityID.settingsReminderPreview)
            }
        } header: {
            if model.usesLiveBackend {
                Text("Leave-home reminders")
            } else {
                HStack(spacing: Spacing.sm) {
                    Text("Leave-home reminders")
                    DemoBadge(text: "PREVIEW")
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            Text(DataSourceWording.remindersFooter(
                usesLiveBackend: model.usesLiveBackend,
                monitorsTrips: model.usesTripMonitoring,
                limits: model.monitoringLimits
            ))
        }
    }

    /// Saved data (step 0007): where activities and settings live, and recovery when stored
    /// data cannot be read. Recovery controls appear only while there is something to recover.
    private var savedDataSection: some View {
        Section {
            LabeledContent("Activities", value: model.activityStorageIssue == nil ? storageStateText(model.activitiesStatus) : "Could not be read")
            LabeledContent("Settings", value: model.preferencesStorageIssue == nil ? storageStateText(model.preferencesStatus) : "Could not be read")
            ForEach(storageIssues, id: \.area) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(PrototypeColor.demo)
                    .accessibilityIdentifier(AccessibilityID.settingsStorageIssue)
            }
            if !storageIssues.isEmpty {
                Button {
                    Task { await model.retryLoadingStorage() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRecoveringStorage)
                .accessibilityIdentifier(AccessibilityID.settingsStorageRetry)
                .accessibilityHint("Reads the saved data again")
                Button(role: .destructive) {
                    isConfirmingStartOver = true
                } label: {
                    Label("Keep a Copy and Start Over", systemImage: "doc.on.doc")
                }
                .disabled(model.isRecoveringStorage)
                .accessibilityIdentifier(AccessibilityID.settingsStorageStartOver)
                .accessibilityHint("Renames the unreadable file, keeps it, and starts with empty saved data")
            }
            if let message = model.storageRecoveryMessage {
                Text(message)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.settingsStorageMessage)
            }
        } header: {
            Text("Saved data")
        } footer: {
            Text("\(model.activitiesPersistenceDescription) \(model.preferencesPersistenceDescription) \(DataSourceWording.savedDataNote(usesLiveBackend: model.usesLiveBackend))")
                .accessibilityIdentifier(AccessibilityID.settingsStorageLocation)
        }
        .confirmationDialog("Keep a copy and start over?", isPresented: $isConfirmingStartOver, titleVisibility: .visible) {
            Button("Keep a Copy and Start Over", role: .destructive) {
                Task { await model.setAsideUnreadableStorage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The unreadable file is renamed and kept next to the saved data; nothing is deleted. Unreadable activities are replaced by an empty schedule, and unreadable settings by the settings in effect now.")
        }
    }

    private var storageIssues: [StorageIssue] {
        [model.activityStorageIssue, model.preferencesStorageIssue].compactMap { $0 }
    }

    private func storageStateText(_ status: StorageStatus) -> String {
        switch status {
        case .notLoaded:
            return "Loading"
        case .ready:
            return "Saved"
        case .failed:
            return "Last save failed"
        }
    }

    private var commuteStepperBinding: Binding<Int> {
        Binding(
            get: { model.testCommuteDuration.wholeMinutes },
            set: { minutes in
                guard let duration = try? CommuteDuration.minutes(minutes) else { return }
                model.setTestCommuteDuration(duration)
                commuteText = String(minutes)
                commuteIssue = nil
            }
        )
    }

    private var prototypeTestingSection: some View {
        Section {
            ForEach(TestCommuteProvider.Scenario.allCases) { scenario in
                scenarioRow(scenario)
            }
            Text("Now simulating: \(OccurrenceFormatter(calculator: model.weekCalculator, locale: locale).simulationText(scenario: model.testCommuteScenario, testDuration: model.testCommuteDuration, travelTime: model.simulatedTravelTime)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.settingsTestScenarioDescription)
            LabeledContent("Test commute duration") {
                HStack(spacing: Spacing.xs) {
                    TextField("Minutes", text: $commuteText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 56, maxWidth: 96)
                        .focused($isCommuteFieldFocused)
                        .onChange(of: commuteText) { _, text in
                            if case .failure(let issue) = CommuteDuration.parseMinutes(text) {
                                commuteIssue = issue
                            } else {
                                commuteIssue = nil
                            }
                        }
                        .onChange(of: isCommuteFieldFocused) { _, isFocused in
                            if !isFocused {
                                commitCommuteText()
                            }
                        }
                        .onSubmit {
                            commitCommuteText()
                        }
                        .accessibilityLabel("Test commute duration, minutes")
                        .accessibilityIdentifier(AccessibilityID.settingsTestCommuteField)
                    Text("min")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let commuteIssue {
                Label("\(commuteIssue.message) Still using \(model.testCommuteDuration.wholeMinutes) minutes.", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityID.settingsTestCommuteIssue)
            }
            Stepper(value: commuteStepperBinding, in: 1...CommuteDuration.maximumMinutes, step: 5) {
                Text("Adjust by 5 minutes")
            }
            .accessibilityValue("\(model.testCommuteDuration.wholeMinutes) minutes")
            .accessibilityIdentifier(AccessibilityID.settingsTestCommuteStepper)
            Button {
                model.resetPrototypeTesting()
                commuteText = String(model.testCommuteDuration.wholeMinutes)
                commuteIssue = nil
            } label: {
                Label("Reset to Normal, 60 Minutes", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isPrototypeTestingAtDefaults)
            .accessibilityIdentifier(AccessibilityID.settingsResetTesting)
            .accessibilityHint("Chooses the Normal scenario and the 60-minute test commute, and turns off the reminder failure simulation")
            if model.usesPreviewReminders {
                Toggle(isOn: reminderFailureBinding) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Simulate reminder failure")
                        Text("The in-app reminder preview fails every update while this is on; Try Again keeps failing until you turn it off.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.settingsReminderFailureToggle)
            }
        } header: {
            HStack(spacing: Spacing.sm) {
                Text("Prototype testing")
                DemoBadge(text: "TEST DATA")
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text("Simulations for trying the UX, not measured traffic. Every scenario is deterministic: the same settings always give the same answer. Each leave-home time is the ideal arrival minus the simulated travel time; nothing else is subtracted. Changing the scenario or the duration (tap Done after typing; whole minutes from 1 to \(CommuteDuration.maximumMinutes), initially 60) recalculates every leave-home time automatically, and an earlier time stays visible, marked out of date, until the new estimate arrives. Only failures offer Try Again. The reminder failure simulation affects only the in-app preview; reset turns it off. \(model.preferencesPersistenceDescription)")
        }
    }

    private func scenarioRow(_ scenario: TestCommuteProvider.Scenario) -> some View {
        let isSelected = model.testCommuteScenario == scenario
        return Button {
            model.setTestCommuteScenario(scenario)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(scenario.title)
                        .foregroundStyle(.primary)
                    Text(scenario.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel("\(scenario.title) scenario. \(scenario.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.settingsTestScenario(scenario))
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: appearanceBinding) {
                ForEach(AppearancePreference.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.settingsAppearancePicker)
        } header: {
            Text("Appearance")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("System follows the device setting. \(model.preferencesPersistenceDescription)")
                if let failure = model.preferencesStatus.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PrototypeColor.demo)
                }
            }
        }
    }

    private var sampleScheduleSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("Loaded")
                Spacer()
                Text(loadedSummary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(AccessibilityID.settingsSampleStatus)
            }

            Button {
                Task { await model.loadSampleActivities() }
            } label: {
                Label("Load sample activities", systemImage: "tray.and.arrow.down")
            }
            .disabled(model.isUpdatingActivities || model.allSamplesLoaded)
            .accessibilityIdentifier(AccessibilityID.settingsLoadSamplesButton)
            .accessibilityHint("Adds the two labeled sample classes to the calendar")

            Button(role: .destructive) {
                Task { await model.clearSampleActivities() }
            } label: {
                Label("Clear sample activities", systemImage: "trash")
            }
            .disabled(model.isUpdatingActivities || model.sampleActivities.isEmpty)
            .accessibilityIdentifier(AccessibilityID.settingsClearSamplesButton)
            .accessibilityHint("Removes only the sample activities")

            if let message = model.sampleActivitiesMessage {
                Text(message)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.settingsSampleMessage)
            }
            if let failure = model.activitiesStatus.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(PrototypeColor.demo)
            }
        } header: {
            HStack(spacing: Spacing.sm) {
                Text("Sample schedule")
                DemoBadge()
            }
        } footer: {
            Text(sampleFooter)
        }
    }

    /// Where leave-home times come from, in a few words.
    private var commuteSourceSummary: String {
        if model.usesLiveBackend {
            return "Team backend"
        }
        return model.usesTestCommute ? "Test provider, \(model.testCommuteScenario.title) scenario" : "Injected provider"
    }

    private var prototypeInfoSection: some View {
        Section {
            LabeledContent("App", value: model.prototypeInfo.appName)
            LabeledContent("Version", value: "\(model.prototypeInfo.version) (\(model.prototypeInfo.build))")
            LabeledContent("Feature package", value: model.prototypeInfo.packageName)
            LabeledContent("Home and campus", value: model.usesSamplePlaces ? "Sample locations" : "Set in Settings")
            LabeledContent("Campus time zone", value: model.campusTimeZone.identifier)
            LabeledContent("Commute estimates", value: commuteSourceSummary)
            Text(model.prototypeInfo.stepDescription(usesLiveBackend: model.usesLiveBackend))
                .font(.footnote)
            HStack(alignment: .top, spacing: Spacing.sm) {
                // The badge marks demo content; with live data the disclosure stands alone.
                if !model.usesLiveBackend {
                    DemoBadge()
                }
                Text(model.prototypeInfo.dataDisclosure(usesLiveBackend: model.usesLiveBackend))
                    .font(.footnote)
            }
        } header: {
            Text("Prototype information")
        } footer: {
            Text("The reusable screens and state live in the \(model.prototypeInfo.packageName) package. The app target is a thin host that wires dependencies.")
        }
        .accessibilityIdentifier(AccessibilityID.settingsPrototypeInfo)
    }

    private var loadedSummary: String {
        let samples = CountPhrase.make(model.sampleActivities.count, singular: "sample activity", plural: "sample activities")
        return "\(samples), \(model.userActivities.count) of your own"
    }

    private var sampleFooter: String {
        "Sample activities are demo content for trying the calendar: a Mon, Wed, Fri class from 9:00 to 9:50 AM with ideal arrival 8:15 AM, and a Tue, Thu lab from 12:00 to 5:15 PM with ideal arrival 11:15 AM, scheduled in the sample campus time zone (\(model.campusTimeZone.identifier)). They are marked SAMPLE wherever they appear and never load on their own. Loading again adds nothing. Clearing removes only sample activities; anything you add yourself stays. \(model.activitiesPersistenceDescription)"
    }
}

#Preview("Settings") {
    SettingsScreen(model: .preview(initialTab: .settings))
}

#Preview("Settings - samples loaded") {
    SettingsScreen(model: .preview(initialTab: .settings, activities: WaitItOutModel.previewSampleActivities()))
}

#Preview("Settings - live data, alerts on") {
    SettingsScreen(model: .previewLive())
}

#Preview("Settings - live data, notifications not asked yet") {
    SettingsScreen(model: .previewLive(permission: .notDetermined))
}
