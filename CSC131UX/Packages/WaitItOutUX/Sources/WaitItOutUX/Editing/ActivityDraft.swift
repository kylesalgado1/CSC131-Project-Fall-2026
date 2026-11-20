import Foundation

/// The editable copy of one activity while it is created or changed.
///
/// A draft never touches storage. Editor controls and calendar gestures change the draft;
/// `WaitItOutModel.saveDraft()` validates it through `ActivityValidator` and writes it once.
/// Cancelling drops the draft, so the stored activity stays exactly as it was.
///
/// Rules every change follows:
/// - Changing the start keeps the duration and the arrival lead, so the end and the ideal
///   arrival move with it. Only an explicit arrival change alters the lead.
/// - The end and the arrival are explicit instants with their own dates, so an activity can
///   cross midnight and the arrival can fall on the previous day.
/// - Times are whole minutes.
/// - There is no departure or leave-home field; a later step derives it from `idealArrival`.
public struct ActivityDraft: Equatable, Sendable {
    /// Length of a new activity.
    public static let defaultDuration: TimeInterval = 3_600
    /// How long before the start a new activity's ideal arrival is.
    public static let defaultArrivalLead: TimeInterval = 30 * 60
    /// Start of a new activity on a day other than today.
    public static let defaultStartTime: WallTime = WallTime(hour: 9, minute: 0) ?? .midnight

    /// The stored activity being edited, or `nil` for a new activity.
    public let original: Activity?
    public let id: UUID
    public var title: String
    public private(set) var start: Date
    public private(set) var end: Date
    public private(set) var idealArrival: Date
    public var destination: Destination
    public let timeZoneIdentifier: String
    public private(set) var repeatWeekdays: Set<Weekday>?
    public let source: ActivitySource

    /// A draft of a stored activity. Saving it replaces that activity; its id, source, zone,
    /// and destination carry over unchanged.
    public init(editing activity: Activity) {
        original = activity
        id = activity.id
        title = activity.title
        start = activity.start
        end = activity.end
        idealArrival = activity.idealArrival
        destination = activity.destination
        timeZoneIdentifier = activity.timeZoneIdentifier
        repeatWeekdays = activity.repeatWeekdays
        source = activity.source
    }

    /// A new, one-time user activity from `start` to `end` whose ideal arrival is
    /// `arrivalLead` before the start.
    public init(
        id: UUID = UUID(),
        title: String = "",
        start: Date,
        end: Date,
        arrivalLead: TimeInterval = ActivityDraft.defaultArrivalLead,
        destination: Destination,
        timeZone: TimeZone
    ) {
        let wholeStart = Self.wholeMinute(start)
        original = nil
        self.id = id
        self.title = title
        self.start = wholeStart
        self.end = Self.wholeMinute(end)
        idealArrival = wholeStart.addingTimeInterval(-max(0, arrivalLead))
        self.destination = destination
        timeZoneIdentifier = timeZone.identifier
        repeatWeekdays = nil
        source = .user
    }

    /// The Add Activity default: on `day` in `zone`, starting at the next whole hour when
    /// `day` is today (11:00 PM late at night), otherwise at 9:00 AM; one hour long, with the
    /// ideal arrival 30 minutes before the start.
    public static func newActivity(
        on day: LocalDate,
        now: Date,
        timeZone zone: TimeZone,
        destination: Destination,
        id: UUID = UUID()
    ) -> ActivityDraft {
        let start = suggestedStart(on: day, now: now, timeZone: zone)
        return ActivityDraft(id: id, start: start, end: start.addingTimeInterval(defaultDuration), destination: destination, timeZone: zone)
    }

    /// Start time the Add Activity action proposes for `day`. Pure: `now` is passed in.
    public static func suggestedStart(on day: LocalDate, now: Date, timeZone zone: TimeZone) -> Date {
        let current = LocalDateTime.of(now, in: zone)
        guard current.date == day else {
            return LocalTimeResolver.instant(of: defaultStartTime, on: day, in: zone)
        }
        let hour = min(23, current.time.hour + 1)
        let time = WallTime(hour: hour, minute: 0) ?? defaultStartTime
        return LocalTimeResolver.instant(of: time, on: day, in: zone)
    }

    // MARK: Derived values

    /// The activity this draft would store.
    public var activity: Activity {
        Activity(
            id: id,
            title: title,
            start: start,
            end: end,
            idealArrival: idealArrival,
            destination: destination,
            timeZoneIdentifier: timeZoneIdentifier,
            repeatWeekdays: repeatWeekdays,
            source: source
        )
    }

    public var isNew: Bool { original == nil }

    /// True for every new draft, and for an edit that differs from the stored activity.
    public var hasChanges: Bool {
        original.map { $0 != activity } ?? true
    }

    /// True when the start, end, arrival, or repeat days differ from the stored activity.
    public var changesSchedule: Bool {
        guard let original else { return true }
        return original.start != start || original.end != end
            || original.idealArrival != idealArrival || original.repeatWeekdays != repeatWeekdays
    }

    /// Every validation issue, from the shared `ActivityValidator`.
    public var issues: [ActivityValidationIssue] {
        ActivityValidator.issues(in: activity)
    }

    public var isValid: Bool { issues.isEmpty }

    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneIdentifier) }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// How long before the start the user wants to be on campus.
    public var arrivalLead: TimeInterval { start.timeIntervalSince(idealArrival) }

    public var isRecurring: Bool { repeatWeekdays != nil }

    /// True when the stored activity is a weekly series, so saving or deleting affects every occurrence.
    public var editsSeries: Bool { original?.isRecurring ?? false }

    /// True when a stored series is being turned into a one-time activity: only the first
    /// occurrence remains after saving.
    public var removesRepeats: Bool { editsSeries && repeatWeekdays == nil }

    /// Calendar day of the start in the activity's zone.
    public var startDate: LocalDate? { timeZone.map { LocalDate.of(start, in: $0) } }

    public var startWeekday: Weekday? { startDate?.weekday }

    /// True when the activity ends on a later day than it starts. Ending exactly at midnight
    /// still counts as the start day.
    public var endsOnLaterDay: Bool {
        guard let zone = timeZone, end > start else { return false }
        return LocalDate.of(end.addingTimeInterval(-1), in: zone) > LocalDate.of(start, in: zone)
    }

    /// True when the ideal arrival is on an earlier day than the start.
    public var arrivalOnEarlierDay: Bool {
        guard let zone = timeZone else { return false }
        return LocalDate.of(idealArrival, in: zone) < LocalDate.of(start, in: zone)
    }

    // MARK: Editor controls

    /// Moves the start; the end and the ideal arrival follow so duration and lead are kept.
    public mutating func setStart(_ instant: Date) {
        guard instant.timeIntervalSinceReferenceDate.isFinite else { return }
        let keptDuration = duration
        let keptLead = arrivalLead
        let newStart = Self.wholeMinute(instant)
        start = newStart
        end = newStart.addingTimeInterval(keptDuration)
        idealArrival = newStart.addingTimeInterval(-keptLead)
    }

    /// Sets the end only. An end on the next day makes an overnight activity.
    public mutating func setEnd(_ instant: Date) {
        guard instant.timeIntervalSinceReferenceDate.isFinite else { return }
        end = Self.wholeMinute(instant)
    }

    /// Sets the ideal arrival only. This is the one change that alters the arrival lead.
    public mutating func setArrival(_ instant: Date) {
        guard instant.timeIntervalSinceReferenceDate.isFinite else { return }
        idealArrival = Self.wholeMinute(instant)
    }

    /// Turns weekly repeat on, starting with the start's weekday, or off.
    public mutating func setRepeats(_ isOn: Bool) {
        if isOn {
            guard repeatWeekdays == nil else { return }
            repeatWeekdays = Set(startWeekday.map { [$0] } ?? [])
        } else {
            repeatWeekdays = nil
        }
    }

    /// Adds or removes one repeat day. Removing the start's weekday is allowed; validation
    /// then asks for it back, because the stored start must be the first occurrence.
    public mutating func setRepeat(_ weekday: Weekday, isOn: Bool) {
        var days = repeatWeekdays ?? Set(startWeekday.map { [$0] } ?? [])
        if isOn {
            days.insert(weekday)
        } else {
            days.remove(weekday)
        }
        repeatWeekdays = days
    }

    // MARK: Calendar gestures

    /// Moves the whole activity so that `occurrence`, one of its occurrences, starts at
    /// `newStart`. Duration and arrival lead are kept. For a weekly series the new wall-clock
    /// time applies to every occurrence. A move that would change the occurrence's day is
    /// ignored; the editor's date controls change days.
    public func movingOccurrence(_ occurrence: ActivityOccurrence, toStart newStart: Date) -> ActivityDraft {
        retimed(occurrence, start: newStart, duration: occurrence.end.timeIntervalSince(occurrence.start))
    }

    /// Changes when `occurrence` starts while its end stays put. The arrival keeps its lead.
    public func resizingOccurrence(_ occurrence: ActivityOccurrence, toStart newStart: Date) -> ActivityDraft {
        retimed(occurrence, start: newStart, duration: occurrence.end.timeIntervalSince(newStart))
    }

    /// Changes when `occurrence` ends. The start and the arrival stay put.
    public func resizingOccurrence(_ occurrence: ActivityOccurrence, toEnd newEnd: Date) -> ActivityDraft {
        retimed(occurrence, start: occurrence.start, duration: newEnd.timeIntervalSince(occurrence.start))
    }

    /// Applies a start and duration chosen on one occurrence to the stored first occurrence.
    private func retimed(_ occurrence: ActivityOccurrence, start newStart: Date, duration newDuration: TimeInterval) -> ActivityDraft {
        guard occurrence.activity.id == id,
              let zone = timeZone,
              newStart.timeIntervalSinceReferenceDate.isFinite,
              newDuration.isFinite,
              newDuration > 0 else {
            return self
        }
        let target = LocalDateTime.of(newStart, in: zone)
        guard target.date == occurrence.id.date else { return self }
        let anchorDate = LocalDate.of(start, in: zone)
        let anchorStart: Date
        if anchorDate == occurrence.id.date {
            anchorStart = Self.wholeMinute(newStart)
        } else if newStart == occurrence.start,
                  LocalTimeResolver.instant(of: WallTime.of(start, in: zone), on: occurrence.id.date, in: zone) == occurrence.start {
            // The start did not move (an end resize or a too-short drag) and this occurrence
            // still follows the draft's own first start. Keep that start: re-reading this
            // occurrence's clock time would shift the series when a daylight-saving gap or
            // repeated hour changed the time shown on this day.
            anchorStart = start
        } else {
            anchorStart = Self.wholeMinute(LocalTimeResolver.instant(of: target.time, on: anchorDate, in: zone))
        }
        let keptLead = arrivalLead
        var copy = self
        copy.start = anchorStart
        copy.end = Self.wholeMinute(anchorStart.addingTimeInterval(newDuration))
        copy.idealArrival = anchorStart.addingTimeInterval(-keptLead)
        return copy
    }

    /// `date` rounded down to a whole minute. Zone offsets are whole minutes, so this is a
    /// whole minute on every wall clock too.
    static func wholeMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { return date }
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
    }
}
