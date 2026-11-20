import Foundation

/// Creating, editing, and deleting activities (step 0004). Every change is a draft held in
/// `editSession` until `saveDraft()` validates it through `ActivityValidator` and writes it
/// to the repository once. `cancelDraft()` drops it, so the stored activity is untouched.
/// Every path that changes or ends the draft calls `syncDraftDeparture()` (step 0005), which
/// keeps the editor's read-only leave-home preview current and cancels stale requests.
extension WaitItOutModel {
    /// Stored activities with the pending draft drawn in place of its original, or added when
    /// it is new, so the Calendar previews every change before it is saved. Map and Settings
    /// read `activities`, which only ever holds what storage returned.
    public var calendarActivities: [Activity] {
        guard let draft = editSession?.draft else { return activities }
        return activities.filter { $0.id != draft.id } + [draft.activity]
    }

    /// Add Activity: a new draft on the selected day with default times, shown in the editor.
    /// Returns `false`, changing nothing, while another change is pending.
    @discardableResult
    public func beginNewActivity() -> Bool {
        guard editSession == nil else { return false }
        let day = LocalDate.of(selectedDay, in: weekCalculator.timeZone)
        let draft = ActivityDraft.newActivity(
            on: day,
            now: currentDate(),
            timeZone: campusTimeZone,
            destination: campusDestination
        )
        editSession = ActivityEditSession(draft: draft, mode: .editor)
        syncDraftDeparture()
        return true
    }

    /// Drag creation: a new draft covering `interval`, already snapped by `GridDrag`, shown in
    /// the editor so the user adds the title, the ideal arrival, and any repeat days.
    @discardableResult
    public func beginNewActivity(spanning interval: Range<Date>) -> Bool {
        guard editSession == nil,
              !interval.isEmpty,
              interval.lowerBound.timeIntervalSinceReferenceDate.isFinite,
              interval.upperBound.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        let draft = ActivityDraft(
            start: interval.lowerBound,
            end: interval.upperBound,
            destination: campusDestination,
            timeZone: campusTimeZone
        )
        editSession = ActivityEditSession(draft: draft, mode: .editor)
        syncDraftDeparture()
        return true
    }

    /// Opens the editor for a stored activity, or for the pending draft of that activity.
    /// For a weekly series the edit applies to the whole series. Returns `false` when the
    /// activity is unknown or a different change is pending.
    @discardableResult
    public func beginEditing(activityID: UUID) -> Bool {
        if let session = editSession {
            guard session.draft.id == activityID, !session.isBusy else { return false }
            editSession?.mode = .editor
            return true
        }
        guard let stored = activities.first(where: { $0.id == activityID }) else { return false }
        editSession = ActivityEditSession(draft: ActivityDraft(editing: stored), mode: .editor)
        syncDraftDeparture()
        return true
    }

    /// Press and hold on a block: adjust that activity on the calendar. Returns the draft to
    /// drag from, or `nil` when the activity is unknown or another change is pending.
    @discardableResult
    public func beginAdjusting(activityID: UUID) -> ActivityDraft? {
        if let session = editSession {
            guard session.draft.id == activityID, session.mode == .calendar, !session.isBusy else { return nil }
            return session.draft
        }
        guard let stored = activities.first(where: { $0.id == activityID }) else { return nil }
        let session = ActivityEditSession(draft: ActivityDraft(editing: stored), mode: .calendar)
        editSession = session
        syncDraftDeparture()
        return session.draft
    }

    /// Applies an editor control change to the pending draft. Ignored while saving or deleting.
    /// A change clears the message of an earlier failed save; the next Save tries again.
    public func updateDraft(_ change: (inout ActivityDraft) -> Void) {
        guard var session = editSession, !session.isBusy else { return }
        change(&session.draft)
        if session.failureMessage != nil {
            session.commitState = .editing
        }
        editSession = session
        syncDraftDeparture()
    }

    /// Replaces the pending draft with a gesture result computed from it by `GridDrag`.
    /// Ignored when the draft belongs to another activity or a commit is running.
    public func replaceDraft(_ draft: ActivityDraft) {
        guard var session = editSession, !session.isBusy, session.draft.id == draft.id, session.draft != draft else { return }
        session.draft = draft
        if session.failureMessage != nil {
            session.commitState = .editing
        }
        editSession = session
        syncDraftDeparture()
    }

    /// Moves a calendar draft into the editor sheet, keeping every change made so far.
    public func showDraftInEditor() {
        guard var session = editSession, !session.isBusy else { return }
        session.mode = .editor
        editSession = session
    }

    /// Drops the pending draft. Nothing was stored, so the original stays exactly as it was.
    public func cancelDraft() {
        guard let session = editSession, !session.isBusy else { return }
        editSession = nil
        syncDraftDeparture()
    }

    /// Validates the pending draft and stores it with a single repository write. Returns
    /// `true` when the draft was stored (or was an edit without changes) and the session ended.
    /// Returns `false`, writing nothing, when the draft is invalid, when no session exists, or
    /// while a save is already running, so a repeated tap never commits twice. A storage
    /// failure keeps the draft and records a message so the user can retry or cancel.
    @discardableResult
    public func saveDraft() async -> Bool {
        guard var session = editSession, !session.isBusy else { return false }
        session.hasAttemptedSave = true
        let candidate = session.draft.activity
        guard ActivityValidator.isValid(candidate) else {
            session.commitState = .editing
            editSession = session
            return false
        }
        if let original = session.draft.original, original == candidate {
            editSession = nil
            syncDraftDeparture()
            return true
        }
        session.commitState = .saving
        editSession = session
        let token = session.id
        do {
            try await saveActivity(candidate)
            if editSession?.id == token {
                editSession = nil
            }
            syncDraftDeparture()
            return true
        } catch {
            if var current = editSession, current.id == token {
                current.commitState = .failed(message: "The activity could not be saved. Your changes are still here, so you can try Save again or cancel.")
                editSession = current
            }
            return false
        }
    }

    /// Deletes the stored activity the pending draft edits: the whole series for a repeating
    /// activity. The editor asks for confirmation first. On failure the draft stays and a
    /// message is recorded.
    @discardableResult
    public func deleteDraftActivity() async -> Bool {
        guard var session = editSession, !session.isBusy, let original = session.draft.original else { return false }
        session.commitState = .deleting
        editSession = session
        let token = session.id
        do {
            try await deleteActivity(id: original.id)
            if editSession?.id == token {
                editSession = nil
            }
            syncDraftDeparture()
            return true
        } catch {
            if var current = editSession, current.id == token {
                current.commitState = .failed(message: "The activity could not be deleted. Nothing changed.")
                editSession = current
            }
            return false
        }
    }

    public func dismissCalendarNotice() {
        calendarNotice = nil
    }

    /// Called after every reload. When the activity a draft edits disappeared from storage,
    /// for example because Settings cleared the sample schedule, the draft is dropped instead
    /// of silently recreating the activity on Save.
    func reconcileEditSession() {
        guard let session = editSession,
              let original = session.draft.original,
              session.commitState != .deleting,
              !activities.contains(where: { $0.id == original.id }) else {
            return
        }
        editSession = nil
        calendarNotice = "\u{201C}\(original.title)\u{201D} was removed, so its unsaved changes were discarded."
        syncDraftDeparture()
    }
}
