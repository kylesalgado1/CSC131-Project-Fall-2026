import Foundation

/// Source of the current wall-clock time.
///
/// Every date calculation in the package takes a `Date` as input and stays pure; the
/// clock is only consulted at the edges (feature state, "Today" controls) so tests and
/// previews can pin time.
public protocol WallClock: Sendable {
    func now() -> Date
}

/// Production clock backed by `Date()`.
public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

/// Clock that always reports the same instant. Used by previews and tests.
public struct FixedWallClock: WallClock {
    public let instant: Date

    public init(_ instant: Date) {
        self.instant = instant
    }

    public func now() -> Date {
        instant
    }
}
