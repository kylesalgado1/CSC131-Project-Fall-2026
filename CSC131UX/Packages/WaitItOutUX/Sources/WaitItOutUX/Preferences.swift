import Foundation
import SwiftUI

/// User-selected appearance. `system` follows the device setting.
public enum AppearancePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Value for `preferredColorScheme`; `nil` means follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Where leave-home times come from when the host supplies a live backend.
public enum DataMode: String, Codable, Sendable, CaseIterable {
    /// The team backend decides every leave-home time.
    case live
    /// The explicit, clearly labeled demo: the simulated test provider and in-app reminder previews.
    case demo
}

/// Everything the Settings tab can change about the app itself.
public struct UserPreferences: Codable, Equatable, Sendable {
    public var appearance: AppearancePreference
    /// Simulated door-to-door commute the test provider reports (Settings, labeled TEST DATA).
    /// A prototype input, not measured traffic. Initially 60 minutes.
    public var testCommuteDuration: CommuteDuration
    /// Deterministic estimate scenario of the test provider (step 0006). Initially Normal.
    public var testCommuteScenario: TestCommuteProvider.Scenario
    /// Home and campus (step 0006). Every trip goes from home to campus. Initially the
    /// labeled sample locations.
    public var places: CommutePlaces
    /// Whether the user wants leave-home reminders (step 0007). This is the desired setting
    /// only; whether a reminder actually exists is the adapter's delivery state, which is
    /// never stored. Initially off.
    public var leaveHomeRemindersEnabled: Bool
    /// Prototype testing (step 0007): while on, the in-app reminder preview adapter fails every
    /// update deterministically, so the failure message and Try Again can be tried. Initially off.
    public var simulatesReminderFailure: Bool
    /// Live backend or the explicit demo. Only matters when the host supplies a live backend;
    /// without one the app always runs on its injected provider. Initially live.
    public var dataMode: DataMode
    /// The server address typed in Settings, or `nil` to use the host's default address.
    public var backendAddress: String?

    public init(
        appearance: AppearancePreference = .system,
        testCommuteDuration: CommuteDuration = .testDefault,
        testCommuteScenario: TestCommuteProvider.Scenario = .normal,
        places: CommutePlaces = .sample,
        leaveHomeRemindersEnabled: Bool = false,
        simulatesReminderFailure: Bool = false,
        dataMode: DataMode = .live,
        backendAddress: String? = nil
    ) {
        self.appearance = appearance
        self.testCommuteDuration = testCommuteDuration
        self.testCommuteScenario = testCommuteScenario
        self.places = places
        self.leaveHomeRemindersEnabled = leaveHomeRemindersEnabled
        self.simulatesReminderFailure = simulatesReminderFailure
        self.dataMode = dataMode
        self.backendAddress = backendAddress
    }

    public static let `default` = UserPreferences()

    private enum CodingKeys: String, CodingKey {
        case appearance
        case testCommuteDuration
        case testCommuteScenario
        case places
        case leaveHomeRemindersEnabled
        case simulatesReminderFailure
        case dataMode
        case backendAddress
    }

    /// Missing values decode as their defaults. An unknown appearance falls back to System, an
    /// invalid stored commute (zero, negative, nonfinite, or too long) to 60 minutes, an unknown
    /// scenario to Normal, an unusable home or campus to its sample value, an unreadable
    /// reminder flag to off, an unknown data mode to live, and an unreadable server address to
    /// none, instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? container.decodeIfPresent(AppearancePreference.self, forKey: .appearance)) ?? .system
        testCommuteDuration = (try? container.decodeIfPresent(CommuteDuration.self, forKey: .testCommuteDuration)) ?? .testDefault
        testCommuteScenario = (try? container.decodeIfPresent(TestCommuteProvider.Scenario.self, forKey: .testCommuteScenario)) ?? .normal
        places = (try? container.decodeIfPresent(CommutePlaces.self, forKey: .places)) ?? .sample
        leaveHomeRemindersEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .leaveHomeRemindersEnabled)) ?? false
        simulatesReminderFailure = (try? container.decodeIfPresent(Bool.self, forKey: .simulatesReminderFailure)) ?? false
        dataMode = (try? container.decodeIfPresent(DataMode.self, forKey: .dataMode)) ?? .live
        backendAddress = (try? container.decodeIfPresent(String.self, forKey: .backendAddress)) ?? nil
    }

    /// The two backend fields are written only when they differ from their defaults, so a
    /// settings file that never used them keeps exactly the keys it always had.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(testCommuteDuration, forKey: .testCommuteDuration)
        try container.encode(testCommuteScenario, forKey: .testCommuteScenario)
        try container.encode(places, forKey: .places)
        try container.encode(leaveHomeRemindersEnabled, forKey: .leaveHomeRemindersEnabled)
        try container.encode(simulatesReminderFailure, forKey: .simulatesReminderFailure)
        if dataMode == .demo {
            try container.encode(dataMode, forKey: .dataMode)
        }
        try container.encodeIfPresent(backendAddress, forKey: .backendAddress)
    }
}

/// Storage boundary for user preferences.
///
/// Implementations may do file I/O, so both operations are asynchronous and must never be
/// assumed to run on the main actor. Returning `nil` from `loadPreferences()` means that
/// nothing has been saved yet, which is distinct from a failure.
public protocol PreferencesStoring: Sendable {
    /// One sentence, shown in Settings, saying where preferences are kept.
    var persistenceDescription: String { get }
    func loadPreferences() async throws -> UserPreferences?
    func savePreferences(_ preferences: UserPreferences) async throws
    /// Explicit recovery after a failed read (step 0007): moves the unreadable data aside under
    /// a new name, never deleting it. Returns the backup's file name, or `nil` when the data is
    /// readable and nothing was moved.
    func setAsideUnreadableData() async throws -> String?
}

public extension PreferencesStoring {
    /// Stores that cannot become unreadable, such as the in-memory one, have nothing to set aside.
    func setAsideUnreadableData() async throws -> String? {
        nil
    }
}

/// Session-only store. Preferences live as long as the process; nothing is written to disk.
public actor InMemoryPreferencesStore: PreferencesStoring {
    private var stored: UserPreferences?

    public init(initial: UserPreferences? = nil) {
        stored = initial
    }

    public nonisolated var persistenceDescription: String {
        "Kept in memory for this app session only. Nothing is written to disk."
    }

    public func loadPreferences() async throws -> UserPreferences? {
        stored
    }

    public func savePreferences(_ preferences: UserPreferences) async throws {
        stored = preferences
    }
}
