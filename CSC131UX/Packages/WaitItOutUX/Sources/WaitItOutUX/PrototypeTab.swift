import Foundation

/// The three bottom tabs, in display order.
public enum PrototypeTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case map
    case calendar
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .map: return "Map"
        case .calendar: return "Calendar"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .map: return "map"
        case .calendar: return "calendar"
        case .settings: return "gearshape"
        }
    }

    /// Display order required by the product contract: Map, Calendar, Settings.
    public static let displayOrder: [PrototypeTab] = [.map, .calendar, .settings]
}
