import Foundation

/// Where the pending draft is being worked on.
public enum ActivityEditMode: Hashable, Sendable {
    /// The full editor sheet with every field and picker.
    case editor
    /// On the calendar grid after pressing and holding a block: drag to move, drag the
    /// handles to resize, then Save or Cancel in the bar below the grid.
    case calendar
}

/// Progress of committing the pending draft.
public enum DraftCommitState: Equatable, Sendable {
    case editing
    case saving
    case deleting
    case failed(message: String)
}

/// The one pending creation or edit. It lives in `WaitItOutModel` so the calendar preview,
/// the editor sheet, and every tab see the same draft; nothing is stored until it is saved.
public struct ActivityEditSession: Identifiable, Equatable, Sendable {
    /// Token for this session. A save that finishes after the session ended never touches a newer one.
    public let id: UUID
    public var draft: ActivityDraft
    public var mode: ActivityEditMode
    /// Set by the first Save. From then on an empty title is flagged too; time, arrival, and
    /// repeat problems show as soon as they exist because only the user's changes cause them.
    public var hasAttemptedSave: Bool
    public var commitState: DraftCommitState

    public init(draft: ActivityDraft, mode: ActivityEditMode, id: UUID = UUID()) {
        self.id = id
        self.draft = draft
        self.mode = mode
        hasAttemptedSave = false
        commitState = .editing
    }

    /// True while a save or delete is running; controls are disabled meanwhile.
    public var isBusy: Bool {
        switch commitState {
        case .saving, .deleting:
            return true
        case .editing, .failed:
            return false
        }
    }

    public var failureMessage: String? {
        if case .failed(let message) = commitState { return message }
        return nil
    }

    /// Issues the editor shows inline right now.
    public var visibleIssues: [ActivityValidationIssue] {
        let issues = draft.issues
        return hasAttemptedSave ? issues : issues.filter { $0.field != .title }
    }

    public func visibleIssues(for field: ActivityField) -> [ActivityValidationIssue] {
        visibleIssues.filter { $0.field == field }
    }
}
