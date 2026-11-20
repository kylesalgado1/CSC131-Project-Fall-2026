import Foundation

/// Accessibility identifiers used by UI tests. Labels stay human-readable; identifiers are
/// stable machine names. The UI test target repeats these strings because it does not
/// link the package.
public enum AccessibilityID {
    public static let mapView = "map.mapView"
    public static let mapDemoStatus = "map.demoStatus"
    public static let mapRecenterButton = "map.recenterButton"
    public static let mapStylePicker = "map.stylePicker"

    public static let calendarWeekTitle = "calendar.weekTitle"
    public static let calendarPreviousWeek = "calendar.previousWeek"
    public static let calendarNextWeek = "calendar.nextWeek"
    public static let calendarToday = "calendar.today"
    public static let calendarEmptyState = "calendar.emptyState"
    public static let calendarOpenSettings = "calendar.openSettings"
    public static let calendarStorageNotice = "calendar.storageNotice"
    /// Prefix of the seven day-strip buttons: `calendar.day.0` (Sunday) to `calendar.day.6`.
    public static let calendarDayPrefix = "calendar.day."
    public static let calendarSelectedDayTitle = "calendar.selectedDayTitle"
    public static let calendarTimeGrid = "calendar.timeGrid"
    /// Shared by every activity block; UI tests count matches rather than address one block.
    public static let calendarOccurrenceBlock = "calendar.occurrenceBlock"
    /// Shared by every ideal-arrival marker on the time grid.
    public static let calendarArrivalMarker = "calendar.arrivalMarker"
    public static let calendarCurrentTimeLine = "calendar.currentTimeLine"
    public static let calendarDayEmptyNote = "calendar.dayEmptyNote"
    public static let calendarDetailSheet = "calendar.detailSheet"
    public static let calendarDetailDone = "calendar.detailDone"

    public static func calendarDay(_ index: Int) -> String {
        calendarDayPrefix + String(index)
    }

    // Step 0004: creating, adjusting, and editing activities.
    public static let calendarAddActivity = "calendar.addActivity"
    public static let calendarEmptyAddActivity = "calendar.emptyAddActivity"
    public static let calendarCreationPreview = "calendar.creationPreview"
    public static let calendarDraftBar = "calendar.draftBar"
    public static let calendarDraftSummary = "calendar.draftSummary"
    public static let calendarDraftCancel = "calendar.draftCancel"
    public static let calendarDraftEdit = "calendar.draftEdit"
    public static let calendarDraftSave = "calendar.draftSave"
    public static let calendarResizeStartHandle = "calendar.resizeStartHandle"
    public static let calendarResizeEndHandle = "calendar.resizeEndHandle"
    public static let calendarNotice = "calendar.notice"
    public static let calendarDetailEdit = "calendar.detailEdit"
    public static let calendarDetailDelete = "calendar.detailDelete"
    public static let calendarDetailError = "calendar.detailError"

    public static let editorSheet = "editor.sheet"
    public static let editorTitle = "editor.title"
    public static let editorDestination = "editor.destination"
    public static let editorStart = "editor.start"
    public static let editorEnd = "editor.end"
    public static let editorDuration = "editor.duration"
    public static let editorEndNote = "editor.endNote"
    public static let editorArrival = "editor.arrival"
    public static let editorLead = "editor.lead"
    public static let editorArrivalNote = "editor.arrivalNote"
    public static let editorRepeatToggle = "editor.repeatToggle"
    /// Prefix of the seven repeat-day buttons: `editor.repeatDay.0` (Sunday) to `editor.repeatDay.6`.
    public static let editorRepeatDayPrefix = "editor.repeatDay."
    public static let editorSeriesNote = "editor.seriesNote"
    /// Shared by every inline validation message.
    public static let editorIssue = "editor.issue"
    public static let editorFailure = "editor.failure"
    public static let editorSave = "editor.save"
    public static let editorCancel = "editor.cancel"
    public static let editorDelete = "editor.delete"

    public static func editorRepeatDay(_ weekday: Weekday) -> String {
        editorRepeatDayPrefix + String(weekday.sundayFirstIndex)
    }

    // Step 0005: calculated leave-home times. The detail sheet, the editor, and the Map card
    // use the same suffixes under their own prefix, such as `calendar.detailDeparture.leaveHome`.
    public static let calendarDetailDeparture = "calendar.detailDeparture"
    public static let editorDeparture = "editor.departure"
    /// The editor's note that its leave-home preview is for the series' next occurrence.
    public static let editorDepartureOccurrence = "editor.departure.occurrence"
    public static let mapNextTrip = "map.nextTrip"
    public static let mapNextTripTitle = "map.nextTripTitle"
    public static let mapNextTripDeparture = "map.nextTripDeparture"
    public static let mapNextTripAddActivity = "map.nextTripAddActivity"
    public static let mapNextTripOpenCalendar = "map.nextTripOpenCalendar"
    public static let settingsTestCommuteField = "settings.testCommuteField"
    public static let settingsTestCommuteStepper = "settings.testCommuteStepper"
    public static let settingsTestCommuteIssue = "settings.testCommuteIssue"

    /// `<prefix>.leaveHome`, `<prefix>.status`, `<prefix>.message`, `<prefix>.source`, `<prefix>.retry`,
    /// and for a backend recommendation `<prefix>.reason`, `<prefix>.confidence`, `<prefix>.notes`.
    public static func departure(_ prefix: String, _ part: DeparturePart) -> String {
        prefix + "." + part.rawValue
    }

    public enum DeparturePart: String, Sendable {
        case leaveHome
        case status
        case message
        case source
        case retry
        /// The backend's reason sentence, or the time to spare once that sentence is out of date.
        case reason
        /// The backend's confidence and why.
        case confidence
        /// Shared by every note the backend attached.
        case notes
    }

    // Step 0006: the Map's places and demo label, home and campus settings, the place editor,
    // and the Prototype testing scenarios. `MapScenarioUITests` repeats these strings.
    public static let mapDemoEstimateLabel = "map.demoEstimateLabel"
    public static let mapPlacesCard = "map.placesCard"
    public static let mapSchematicNote = "map.schematicNote"
    public static let mapNextTripSimulation = "map.nextTripSimulation"
    public static let mapOpenSettings = "map.openSettings"
    public static let settingsResetPlaces = "settings.resetPlaces"
    public static let settingsTestScenarioDescription = "settings.testScenarioDescription"
    public static let settingsResetTesting = "settings.resetTesting"
    public static let placeEditorSheet = "placeEditor.sheet"
    public static let placeEditorName = "placeEditor.name"
    public static let placeEditorLatitude = "placeEditor.latitude"
    public static let placeEditorLongitude = "placeEditor.longitude"
    /// Shared by every inline place issue.
    public static let placeEditorIssue = "placeEditor.issue"
    public static let placeEditorUseSample = "placeEditor.useSample"
    public static let placeEditorCancel = "placeEditor.cancel"
    public static let placeEditorSave = "placeEditor.save"

    /// `settings.place.home` and `settings.place.campus`: the rows that open the place editor.
    public static func settingsPlace(_ role: PlaceRole) -> String {
        "settings.place." + role.rawValue
    }

    /// `map.place.home` and `map.place.campus`: the Map card's place lines.
    public static func mapPlace(_ role: PlaceRole) -> String {
        "map.place." + role.rawValue
    }

    /// `settings.testScenario.normal`, `.slow`, `.unavailable`, `.error`.
    public static func settingsTestScenario(_ scenario: TestCommuteProvider.Scenario) -> String {
        "settings.testScenario." + scenario.rawValue
    }

    // Step 0007: leave-home reminder previews and saved data. The Settings preview uses the
    // `reminders` prefix and the Map card's line the `map.reminder` prefix, each with the
    // `ReminderPart` suffixes, such as `reminders.time`. `PersistenceReminderUITests` repeats these.
    public static let settingsRemindersToggle = "settings.remindersToggle"
    public static let settingsReminderFailureToggle = "settings.reminderFailureToggle"
    public static let settingsReminderPreview = "reminders"
    public static let mapReminderPreview = "map.reminder"
    public static let settingsStorageIssue = "settings.storageIssue"
    public static let settingsStorageRetry = "settings.storageRetry"
    public static let settingsStorageStartOver = "settings.storageStartOver"
    public static let settingsStorageMessage = "settings.storageMessage"
    public static let settingsStorageLocation = "settings.storageLocation"

    /// `<prefix>.time`, `<prefix>.title`, `<prefix>.message`, `<prefix>.disclosure`,
    /// `<prefix>.status`, `<prefix>.retry`.
    public static func reminder(_ prefix: String, _ part: ReminderPart) -> String {
        prefix + "." + part.rawValue
    }

    public enum ReminderPart: String, Sendable {
        case time
        case title
        case message
        case disclosure
        case status
        case retry
    }

    // Stage S3: the data source, the live data label, and server-side trip monitoring. The
    // Settings status uses the `monitoring` prefix and the Map card's the `map.monitoring`
    // prefix, each with the `MonitoringPart` suffixes, such as `monitoring.status`.
    public static let mapLiveDataLabel = "map.liveDataLabel"
    public static let settingsDataMode = "settings.dataMode"
    public static let settingsBackendAddress = "settings.backendAddress"
    public static let settingsBackendAddressIssue = "settings.backendAddressIssue"
    public static let settingsBackendStatus = "settings.backendStatus"
    /// Shared by the notes under the status: a server that is still being told to stop, or
    /// that could not be told.
    public static let settingsBackendNotice = "settings.backendNotice"
    public static let settingsMonitoring = "monitoring"
    public static let mapMonitoring = "map.monitoring"
    /// Shared by every sentence of the detail sheet's "Leave-home alerts" section.
    public static let calendarDetailMonitoring = "calendar.detailMonitoring"
    public static let calendarDetailLeft = "calendar.detailLeft"
    public static let calendarDetailLeftStatus = "calendar.detailLeftStatus"
    public static let mapNextTripLeft = "map.nextTripLeft"
    public static let mapNextTripLeftStatus = "map.nextTripLeftStatus"

    /// `<prefix>.status`, `<prefix>.detail`, `<prefix>.retry`, `<prefix>.allow`,
    /// `<prefix>.openSettings`.
    public static func monitoring(_ prefix: String, _ part: MonitoringPart) -> String {
        prefix + "." + part.rawValue
    }

    public enum MonitoringPart: String, Sendable {
        case status
        /// Shared by every sentence under the status.
        case detail
        case retry
        case allow
        case openSettings
    }

    public static let settingsAppearancePicker = "settings.appearancePicker"
    public static let settingsPrototypeInfo = "settings.prototypeInfo"
    public static let settingsSampleStatus = "settings.sampleStatus"
    public static let settingsSampleMessage = "settings.sampleMessage"
    public static let settingsLoadSamplesButton = "settings.loadSamplesButton"
    public static let settingsClearSamplesButton = "settings.clearSamplesButton"
}
