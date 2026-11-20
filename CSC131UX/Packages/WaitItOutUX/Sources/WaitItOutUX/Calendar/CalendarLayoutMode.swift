import CoreGraphics
import Foundation

/// Which calendar body fits the available width. Seven readable day columns need a wide
/// screen; everything narrower, and every accessibility text size, shows the selected day's
/// timeline on its own while the day strip above keeps the whole week reachable.
public enum CalendarLayoutMode: Equatable, Sendable {
    case selectedDay
    case fullWeek

    /// Width of the hour-label gutter on the left of every time grid.
    public static let timeGutterWidth: CGFloat = 52
    /// Narrowest day column that still fits a title and a time range.
    public static let minimumDayColumnWidth: CGFloat = 88
    /// Smallest total width at which seven columns are shown.
    public static var fullWeekMinimumWidth: CGFloat {
        timeGutterWidth + 7 * minimumDayColumnWidth
    }

    public static func resolve(availableWidth: CGFloat, isAccessibilitySize: Bool) -> CalendarLayoutMode {
        guard !isAccessibilitySize, availableWidth.isFinite, availableWidth >= fullWeekMinimumWidth else {
            return .selectedDay
        }
        return .fullWeek
    }
}

/// How much text a block can show at a given height. Pure so tests can pin the thresholds.
public enum BlockDetail: Equatable, Sendable {
    /// Title only, one line.
    case compact
    /// Title plus the time range.
    case titleAndTime
    /// Title, time range, and the ideal arrival line.
    case full

    public static func resolve(height: CGFloat) -> BlockDetail {
        if height < 40 { return .compact }
        if height < 72 { return .titleAndTime }
        return .full
    }
}
