import Foundation
import WaitItOutUX

/// Composition root for the app. This is the only place that chooses concrete implementations
/// for the package's boundaries.
///
/// There are two compositions, chosen once per launch by `BackendLaunchOptions`:
/// - **Live (the normal flow).** The team backend answers leave-home times, supplies the Map's
///   route, and monitors trips for alerts. The simulated commute provider and the in-app
///   reminder previews are still composed, but only for the explicit Demo data mode the user
///   can choose under Settings, Data source.
/// - **Standalone demo.** With `WAIT_IT_OUT_DATA_MODE=demo` in the environment (every UI test
///   sets it) no backend is composed at all: no network client, no Keychain item, and no
///   notification code runs. This is exactly the prototype's original graph.
enum AppDependencies {
    /// What one launch composed.
    struct Graph {
        let model: WaitItOutModel
        /// The backend session that receives the device's push token. `nil` in the standalone
        /// demo composition.
        let session: BackendSession?
    }

    @MainActor
    static func makeGraph(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Graph {
        let clock = SystemWallClock()
        // Activities and settings are JSON files in Application Support/WaitItOutUX (step 0007),
        // written atomically by the stores' actors, so no file I/O happens on the main actor.
        // UI tests pass WAIT_IT_OUT_STORAGE_FOLDER to start each test from an empty folder of
        // their own; the package validates the name before using it.
        let storage = PrototypeStorageLocation.applicationSupport(
            folderName: environment[PrototypeStorageLocation.folderEnvironmentKey]
        )
        let options = BackendLaunchOptions(environment: environment, infoDictionary: infoDictionary)
        let live = options.composesLiveBackend ? makeLiveBackend(defaultBaseURL: options.defaultBaseURL, clock: clock) : nil
        let model = WaitItOutModel(
            clock: clock,
            preferencesStore: FilePreferencesStore(fileURL: storage.preferencesFile, clock: clock),
            activityRepository: FileActivityRepository(fileURL: storage.activitiesFile, clock: clock),
            // Simulated commute for the Demo data mode: every trip takes the Settings test
            // duration (60 minutes at first), shaped by the Prototype testing scenario (Normal,
            // Slow, Unavailable, Error). The pauses only make loading and refreshing visible;
            // nothing is measured. In Live mode the model never calls this provider.
            commuteEstimator: TestCommuteProvider(
                clock: clock,
                configuration: TestCommuteProvider.Configuration(
                    simulatedDelay: .milliseconds(300),
                    slowDelay: .seconds(3)
                )
            ),
            // In-app reminder previews for the Demo data mode: no notification permission, no
            // system notification, no background delivery. In Live mode the server sends the
            // alerts and the model leaves this adapter alone (docs/REMINDERS.md).
            reminderScheduler: PreviewReminderScheduler(),
            weekCalculator: WeekCalculator(calendar: .autoupdatingCurrent),
            // Labeled demo locations; Settings shows them as SAMPLE until the user edits them.
            sampleCampus: .demoCampus,
            sampleHome: .demoHome,
            prototypeInfo: PrototypeInfo(infoDictionary: infoDictionary),
            liveBackend: live?.backend
        )
        return Graph(model: model, session: live?.session)
    }

    /// The team backend's adapters around one shared client and one shared session.
    ///
    /// The session is passed twice on purpose: as the trip monitor, and as the commute
    /// provider's source of monitored answers, so the screens and the server's alerts show the
    /// same recommendation. The server credential lives in the Keychain, one per server
    /// address. `defaultBaseURL` is `nil` when the host has no usable address; the app then
    /// says so and waits for one in Settings.
    private static func makeLiveBackend(defaultBaseURL: URL?, clock: any WallClock) -> (backend: LiveBackend, session: BackendSession) {
        let configuration = BackendConfiguration(defaultBaseURL: defaultBaseURL)
        let client = BackendClient(configuration: configuration, transport: URLSessionTransport(), clock: clock)
        let session = BackendSession(
            client: client,
            credentials: KeychainCredentialStore(),
            push: SystemPushRegistrar(),
            clock: clock
        )
        let backend = LiveBackend(
            commuteEstimator: BackendCommuteProvider(client: client, clock: clock, monitoredTrips: session),
            routeProvider: BackendRouteProvider(client: client),
            tripMonitor: session,
            configuration: configuration
        )
        return (backend, session)
    }
}

/// The one model and the one backend session of this process. The app's scene and the
/// `AppDelegate` both read them here, so handling a notification or a push token never depends
/// on a scene existing or on the order in which views are built. Built on first use, once.
@MainActor
final class AppComposition {
    static let shared = AppComposition()

    let model: WaitItOutModel
    /// `nil` in the standalone demo composition, which uses no notification or push API.
    let session: BackendSession?

    private init() {
        let graph = AppDependencies.makeGraph()
        model = graph.model
        session = graph.session
    }
}
