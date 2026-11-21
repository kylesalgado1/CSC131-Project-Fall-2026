import CoreGraphics
import Foundation

/// Everything one day column draws, computed purely from the occurrences that touch the day.
///
/// Blocks cover the activity itself, start to end, clipped to the day. The ideal arrival is a
/// separate marker at the arrival instant with a leader line down to the block; it never
/// stretches the block. When only the arrival falls on this day (an activity that starts just
/// after midnight), the day shows the marker alone with a leader to the day's end.
public struct DaySchedule: Hashable, Sendable {
    public struct Block: Identifiable, Hashable, Sendable {
        public let occurrence: ActivityOccurrence
        public let frame: DayTimelineLayout.BlockFrame
        public let placement: OverlapPlacement

        public var id: OccurrenceID { occurrence.id }
    }

    public struct ArrivalMarker: Identifiable, Hashable, Sendable {
        public let occurrence: ActivityOccurrence
        /// Vertical offset of the arrival instant.
        public let offset: CGFloat
        /// Where the leader line ends: the top of the block, or the bottom of the day when the
        /// activity itself starts on a later day.
        public let leaderEndOffset: CGFloat
        /// True when the activity starts after this day ends.
        public let isForLaterDay: Bool
        public let placement: OverlapPlacement

        public var id: OccurrenceID { occurrence.id }
    }

    public let day: Range<Date>
    public let layout: DayTimelineLayout
    /// Every occurrence whose planned time, arrival through end, touches the day; sorted.
    public let occurrences: [ActivityOccurrence]
    public let blocks: [Block]
    public let arrivalMarkers: [ArrivalMarker]

    public static func make(day: Range<Date>, occurrences: [ActivityOccurrence], layout: DayTimelineLayout) -> DaySchedule {
        let touching = occurrences.filter { $0.intersects(day) }.sorted(by: OccurrenceExpander.isOrderedBefore)
        let withFrames: [(ActivityOccurrence, DayTimelineLayout.BlockFrame)] = touching.compactMap { occurrence in
            layout.frame(for: occurrence.activityInterval).map { (occurrence, $0) }
        }
        let placements = OverlapLayout.placements(for: withFrames.map { occurrence, frame in
            OverlapLayout.Item(id: occurrence.id, interval: frame.visibleInterval)
        })
        let blocks = withFrames.map { occurrence, frame in
            Block(occurrence: occurrence, frame: frame, placement: placements[occurrence.id] ?? .solo)
        }
        let blocksByID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let markers: [ArrivalMarker] = touching.compactMap { occurrence in
            guard occurrence.idealArrival < occurrence.start, day.contains(occurrence.idealArrival) else { return nil }
            let offset = layout.offset(for: occurrence.idealArrival)
            if let block = blocksByID[occurrence.id] {
                return ArrivalMarker(
                    occurrence: occurrence,
                    offset: offset,
                    leaderEndOffset: max(offset, block.frame.minY),
                    isForLaterDay: false,
                    placement: block.placement
                )
            }
            return ArrivalMarker(
                occurrence: occurrence,
                offset: offset,
                leaderEndOffset: layout.height,
                isForLaterDay: true,
                placement: .solo
            )
        }
        return DaySchedule(day: day, layout: layout, occurrences: touching, blocks: blocks, arrivalMarkers: markers)
    }

    public var isEmpty: Bool {
        blocks.isEmpty && arrivalMarkers.isEmpty
    }

    /// Markers whose activity starts on a later day, shown without a block.
    public var arrivalOnlyMarkers: [ArrivalMarker] {
        arrivalMarkers.filter(\.isForLaterDay)
    }

    /// Hour row to scroll to when the day is first shown: an hour before the current time
    /// when `currentTime` falls inside the day, otherwise the first block's hour, otherwise
    /// 8 AM in elapsed hours (clamped to the column).
    public func suggestedScrollHour(currentTime: Date?) -> Int {
        if let currentTime, day.contains(currentTime) {
            return max(0, layout.hourIndex(containing: currentTime) - 1)
        }
        if let first = blocks.map(\.frame.minY).min() {
            let index = Int((first / layout.hourHeight).rounded(.down))
            return min(layout.hourCount - 1, max(0, index))
        }
        return min(layout.hourCount - 1, 8)
    }
}
