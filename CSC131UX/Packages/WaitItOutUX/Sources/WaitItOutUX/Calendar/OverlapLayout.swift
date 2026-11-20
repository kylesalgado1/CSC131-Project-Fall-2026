import CoreGraphics
import Foundation

/// Column assignment for one item in a group of overlapping intervals: the item occupies
/// column `column` of `columnCount` equal-width columns.
public struct OverlapPlacement: Hashable, Sendable {
    public let column: Int
    public let columnCount: Int

    public init(column: Int, columnCount: Int) {
        self.column = column
        self.columnCount = max(1, columnCount)
    }

    /// Full width: the only item in its cluster.
    public static let solo = OverlapPlacement(column: 0, columnCount: 1)

    /// Leading edge as a fraction of the available width, in 0..<1.
    public var leadingFraction: CGFloat {
        CGFloat(column) / CGFloat(columnCount)
    }

    /// Width as a fraction of the available width.
    public var widthFraction: CGFloat {
        1 / CGFloat(columnCount)
    }
}

/// Pure side-by-side layout for overlapping intervals. Every item receives a placement, so
/// nothing is ever hidden behind another block; overlapping items share the width of their
/// cluster, and a later item reuses the first column that has already ended.
public enum OverlapLayout {
    public struct Item<ID: Hashable>: Hashable {
        public let id: ID
        public let interval: Range<Date>

        public init(id: ID, interval: Range<Date>) {
            self.id = id
            self.interval = interval
        }
    }

    /// Placements keyed by item id. Items with the same id keep the last placement computed.
    /// A touching pair, where one ends exactly when the next starts, does not overlap. An empty
    /// interval is treated as one second long so a zero-length item still gets a column.
    public static func placements<ID: Hashable>(for items: [Item<ID>]) -> [ID: OverlapPlacement] {
        // A labeled tuple, not a local struct: Swift 5.9 and 5.10 reject types nested in a
        // generic function.
        let entries = items.enumerated().map { order, item -> (order: Int, id: ID, start: Date, end: Date) in
            let start = item.interval.lowerBound
            let end = item.interval.isEmpty ? start.addingTimeInterval(1) : item.interval.upperBound
            return (order: order, id: item.id, start: start, end: end)
        }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.order < rhs.order
        }

        var result: [ID: OverlapPlacement] = [:]
        var clusterMembers: [(id: ID, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let count = columnEnds.count
            for member in clusterMembers {
                result[member.id] = OverlapPlacement(column: member.column, columnCount: count)
            }
            clusterMembers.removeAll()
            columnEnds.removeAll()
        }

        for entry in entries {
            if !clusterMembers.isEmpty, entry.start >= clusterEnd {
                closeCluster()
            }
            let column: Int
            if let free = columnEnds.firstIndex(where: { $0 <= entry.start }) {
                column = free
                columnEnds[free] = entry.end
            } else {
                column = columnEnds.count
                columnEnds.append(entry.end)
            }
            clusterMembers.append((id: entry.id, column: column))
            clusterEnd = max(clusterEnd, entry.end)
        }
        closeCluster()
        return result
    }
}
