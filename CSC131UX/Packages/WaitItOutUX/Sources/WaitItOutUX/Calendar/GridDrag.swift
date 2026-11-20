import CoreGraphics
import Foundation

/// Which part of an activity block a drag changes.
public enum GridDragKind: Hashable, Sendable {
    /// The block body: the whole activity moves and keeps its length.
    case move
    /// The top handle: the start moves, the end stays.
    case resizeStart
    /// The bottom handle: the end moves, the start stays.
    case resizeEnd
}

/// Pure conversion of vertical drags on one day column into snapped times and draft changes.
///
/// Views report offsets and translations in points. Everything else happens here: offsets
/// become instants through `DayTimelineLayout.date(atOffset:)`, instants snap to the wall
/// clock of the calendar's zone, and results are clamped so a drag never produces an activity
/// shorter than one snap interval, longer than the validator allows, or starting on another day.
public struct GridDrag: Sendable {
    /// Gesture times snap to quarter hours. The editor's pickers set any minute.
    public static let defaultSnapInterval: TimeInterval = 15 * 60
    /// Drags shorter than this many points are accidental and change nothing.
    public static let minimumDistance: CGFloat = 10

    public let layout: DayTimelineLayout
    public let timeZone: TimeZone
    public let snapInterval: TimeInterval

    public init(layout: DayTimelineLayout, timeZone: TimeZone, snapInterval: TimeInterval = GridDrag.defaultSnapInterval) {
        self.layout = layout
        self.timeZone = timeZone
        self.snapInterval = snapInterval.isFinite && snapInterval >= 60 ? snapInterval : GridDrag.defaultSnapInterval
    }

    /// True when a drag of `distance` points is long enough to count as intentional.
    public static func isIntentional(_ distance: CGFloat) -> Bool {
        distance.isFinite && abs(distance) >= minimumDistance
    }

    /// `date` rounded to the nearest snap boundary on the wall clock of `timeZone`.
    public func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { return date }
        let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
        let snapped = ((seconds + offset) / snapInterval).rounded() * snapInterval
        return Date(timeIntervalSinceReferenceDate: snapped - offset)
    }

    /// The snapped instant at a vertical offset, clamped to the day.
    public func snappedDate(atOffset offset: CGFloat) -> Date {
        min(layout.day.upperBound, max(layout.day.lowerBound, snap(layout.date(atOffset: offset))))
    }

    /// What a press-and-drag on empty grid space from `startOffset` to `endOffset` creates:
    /// both ends snapped, at least one snap interval long, inside the day. Dragging upward
    /// works too. Returns `nil` for a drag shorter than `minimumDistance`, so an accidental
    /// touch never creates anything.
    public func creationInterval(fromOffset startOffset: CGFloat, toOffset endOffset: CGFloat) -> Range<Date>? {
        guard startOffset.isFinite, endOffset.isFinite, Self.isIntentional(endOffset - startOffset) else { return nil }
        var lower = snappedDate(atOffset: min(startOffset, endOffset))
        var upper = snappedDate(atOffset: max(startOffset, endOffset))
        if upper.timeIntervalSince(lower) < snapInterval {
            upper = lower.addingTimeInterval(snapInterval)
            if upper > layout.day.upperBound {
                upper = layout.day.upperBound
                lower = max(layout.day.lowerBound, upper.addingTimeInterval(-snapInterval))
            }
        }
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// `draft` after dragging `occurrence` by `translation` points. `occurrence` is the one drawn
    /// in this column when the drag began, so every call computes from that snapshot and
    /// repeated calls during one drag never accumulate. A drag shorter than `minimumDistance`
    /// leaves the occurrence where it was when the drag began; one that cannot apply (the edge
    /// lies on another day) returns `draft` unchanged.
    public func draft(_ draft: ActivityDraft, dragging occurrence: ActivityOccurrence, kind: GridDragKind, translation: CGFloat) -> ActivityDraft {
        guard Self.isIntentional(translation) else {
            return draft.movingOccurrence(occurrence, toStart: occurrence.start)
        }
        switch kind {
        case .move:
            guard let newStart = movedStart(of: occurrence, translation: translation) else { return draft }
            return draft.movingOccurrence(occurrence, toStart: newStart)
        case .resizeStart:
            guard let newStart = resizedStart(of: occurrence, translation: translation) else { return draft }
            return draft.resizingOccurrence(occurrence, toStart: newStart)
        case .resizeEnd:
            guard let newEnd = resizedEnd(of: occurrence, translation: translation) else { return draft }
            return draft.resizingOccurrence(occurrence, toEnd: newEnd)
        }
    }

    /// Snapped start after moving `occurrence` by `translation`, kept inside the day. `nil`
    /// when the occurrence started on an earlier day, so its start is not in this column.
    public func movedStart(of occurrence: ActivityOccurrence, translation: CGFloat) -> Date? {
        guard layout.day.contains(occurrence.start) else { return nil }
        let proposed = snap(layout.date(atOffset: layout.offset(for: occurrence.start) + translation))
        let latest = layout.day.upperBound.addingTimeInterval(-snapInterval)
        return min(latest, max(layout.day.lowerBound, proposed))
    }

    /// Snapped start after dragging the top handle. Leaves at least one snap interval before
    /// the end and at most the longest permitted duration.
    public func resizedStart(of occurrence: ActivityOccurrence, translation: CGFloat) -> Date? {
        guard layout.day.contains(occurrence.start) else { return nil }
        let proposed = snappedDate(atOffset: layout.offset(for: occurrence.start) + translation)
        let earliest = max(layout.day.lowerBound, occurrence.end.addingTimeInterval(-ActivityValidator.maximumDuration))
        let latest = min(occurrence.end, layout.day.upperBound).addingTimeInterval(-snapInterval)
        guard earliest <= latest else { return nil }
        return min(latest, max(earliest, proposed))
    }

    /// Snapped end after dragging the bottom handle. Keeps at least one snap interval after
    /// the start; the end can reach midnight at the bottom of the column. `nil` when the
    /// occurrence ends on a later day, so its end is not in this column.
    public func resizedEnd(of occurrence: ActivityOccurrence, translation: CGFloat) -> Date? {
        guard occurrence.end > layout.day.lowerBound, occurrence.end <= layout.day.upperBound else { return nil }
        let proposed = snappedDate(atOffset: layout.offset(for: occurrence.end) + translation)
        let earliest = occurrence.start.addingTimeInterval(snapInterval)
        let latest = min(layout.day.upperBound, occurrence.start.addingTimeInterval(ActivityValidator.maximumDuration))
        guard earliest <= latest else { return nil }
        return min(latest, max(earliest, proposed))
    }
}

/// Outlines of the stored version of an activity while a calendar draft shows it elsewhere,
/// so the user sees what moves before saving. Pure: positions come from `DayTimelineLayout`.
public enum DraftPreview {
    /// Frames of the original activity's occurrences on `layout.day`, or none when there is
    /// no draft, the draft is new, or its schedule is unchanged.
    public static func originalFrames(for draft: ActivityDraft?, layout: DayTimelineLayout) -> [DayTimelineLayout.BlockFrame] {
        guard let draft, let original = draft.original, draft.changesSchedule else { return [] }
        return OccurrenceExpander.occurrences(of: original, in: layout.day)
            .filter { $0.activityIntersects(layout.day) }
            .compactMap { layout.frame(for: $0.activityInterval) }
    }
}
