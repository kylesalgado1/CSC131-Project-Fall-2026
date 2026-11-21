import CoreGraphics
import Foundation

/// Pure vertical geometry of one calendar day: how many hour rows it has, where an instant
/// sits in points, and how an interval is clipped to the day.
///
/// Positions are proportional to elapsed time inside the day, so a block's height always
/// reflects its duration. A 25-hour day (clocks fell back) gets 25 hour rows and a 23-hour
/// day gets 23; each row is labeled with the wall clock at its own first instant, so the
/// fall-back day shows the 1 AM row twice and the spring-forward day has no 2 AM row. Hour
/// rows are elapsed hours from the real local midnight, never `Calendar.date(from:)` guesses.
public struct DayTimelineLayout: Hashable, Sendable {
    /// One hour row: its index, the instant at its top edge, and that edge's offset.
    public struct HourMark: Hashable, Sendable {
        public let index: Int
        public let instant: Date
        public let offset: CGFloat
    }

    /// Where a clipped interval lands inside the day column.
    public struct BlockFrame: Hashable, Sendable {
        public let minY: CGFloat
        public let height: CGFloat
        /// The interval started before this day, so the block's top edge is the day boundary.
        public let isClippedAtStart: Bool
        /// The interval ends after this day, so the block's bottom edge is the day boundary.
        public let isClippedAtEnd: Bool
        /// The part of the interval that lies inside the day.
        public let visibleInterval: Range<Date>

        public var maxY: CGFloat { minY + height }
    }

    public let day: Range<Date>
    public let hourHeight: CGFloat
    /// Smallest height any block is given so short activities stay readable and tappable.
    public let minimumBlockHeight: CGFloat
    /// Number of hour rows: the day's length rounded to whole hours, at least one.
    public let hourCount: Int

    public init(day: Range<Date>, hourHeight: CGFloat, minimumBlockHeight: CGFloat = 44) {
        let normalizedDay = day.lowerBound < day.upperBound ? day : day.lowerBound..<day.lowerBound.addingTimeInterval(3_600)
        self.day = normalizedDay
        self.hourHeight = max(1, hourHeight.isFinite ? hourHeight : 1)
        self.minimumBlockHeight = max(0, minimumBlockHeight.isFinite ? minimumBlockHeight : 0)
        // Real days are 23 to 25 hours long; the clamp only guards against nonsensical ranges.
        let hours = (normalizedDay.upperBound.timeIntervalSince(normalizedDay.lowerBound) / 3_600).rounded()
        hourCount = hours.isFinite ? Int(min(48, max(1, hours))) : 24
    }

    /// Length of the day in seconds: 86 400 except on daylight-saving transition days.
    public var dayLength: TimeInterval {
        day.upperBound.timeIntervalSince(day.lowerBound)
    }

    /// Total height of the day column.
    public var height: CGFloat {
        CGFloat(hourCount) * hourHeight
    }

    /// Vertical offset of an instant, clamped to the column. Instants before the day map to
    /// the top edge and instants at or after its end map to the bottom edge.
    public func offset(for date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(day.lowerBound)
        guard elapsed.isFinite, dayLength > 0 else { return 0 }
        let fraction = elapsed / dayLength
        return min(height, max(0, CGFloat(fraction) * height))
    }

    /// Inverse of `offset(for:)`: the instant at a vertical offset, clamped to the day.
    public func date(atOffset offset: CGFloat) -> Date {
        guard height > 0, offset.isFinite else { return day.lowerBound }
        let fraction = min(1, max(0, offset / height))
        return day.lowerBound.addingTimeInterval(TimeInterval(fraction) * dayLength)
    }

    /// The layout whose rows label a gutter shared by several day columns: the first ordinary
    /// 24-hour day, so a 23- or 25-hour transition day never shifts the labels of the other six
    /// columns; otherwise the first layout. `nil` when there are no layouts.
    public static func sharedGutter(for layouts: [DayTimelineLayout]) -> DayTimelineLayout? {
        layouts.first { $0.hourCount == 24 } ?? layouts.first
    }

    /// True when this day has a different number of hour rows than `gutter`. A shared gutter
    /// would then mislabel this day's rows below the transition, so the column labels its own.
    public func rowsDiffer(from gutter: DayTimelineLayout) -> Bool {
        hourCount != gutter.hourCount
    }

    /// The hour rows from the top of the day to the bottom.
    public var hourMarks: [HourMark] {
        (0..<hourCount).map { index in
            let instant = day.lowerBound.addingTimeInterval(TimeInterval(index) * 3_600)
            return HourMark(index: index, instant: instant, offset: CGFloat(index) * hourHeight)
        }
    }

    /// Index of the hour row that contains `date`, clamped to the column.
    public func hourIndex(containing date: Date) -> Int {
        guard hourHeight > 0 else { return 0 }
        let index = Int((offset(for: date) / hourHeight).rounded(.down))
        return min(hourCount - 1, max(0, index))
    }

    /// Clips `interval` to the day and returns its frame, or `nil` when the two do not
    /// overlap. The frame is at least `minimumBlockHeight` tall; when that would push it past
    /// the bottom of the column the frame is shifted up instead so it stays fully visible.
    public func frame(for interval: Range<Date>) -> BlockFrame? {
        guard !interval.isEmpty, interval.overlaps(day) else { return nil }
        let visibleStart = max(interval.lowerBound, day.lowerBound)
        let visibleEnd = min(interval.upperBound, day.upperBound)
        guard visibleStart < visibleEnd else { return nil }
        let top = offset(for: visibleStart)
        let bottom = offset(for: visibleEnd)
        var minY = top
        var blockHeight = max(bottom - top, min(minimumBlockHeight, height))
        if minY + blockHeight > height {
            minY = max(0, height - blockHeight)
            blockHeight = min(blockHeight, height)
        }
        return BlockFrame(
            minY: minY,
            height: blockHeight,
            isClippedAtStart: interval.lowerBound < day.lowerBound,
            isClippedAtEnd: interval.upperBound > day.upperBound,
            visibleInterval: visibleStart..<visibleEnd
        )
    }
}
