import Foundation

/// Which stored file a problem concerns.
public enum StorageArea: String, Sendable {
    case activities
    case settings
}

/// Stored data that could not be read at launch or on Try Again (step 0007). While an issue is
/// open, the store refuses every write, so the unreadable file is never replaced; Settings
/// offers Try Again and the explicit "Keep a Copy and Start Over".
public struct StorageIssue: Equatable, Sendable {
    public let area: StorageArea
    public let error: PersistenceError

    public init(area: StorageArea, error: PersistenceError) {
        self.area = area
        self.error = error
    }

    /// One user-facing paragraph: what failed and what happens meanwhile.
    public var message: String {
        let subject = area == .activities ? "Saved activities" : "Saved settings"
        let reason: String
        switch error {
        case .damaged:
            reason = "\(subject) could not be read: the file is damaged or is not a WAIT IT OUT file."
        case .unsupportedVersion(let found, let supported):
            reason = "\(subject) use storage format \(found), which this version cannot read (it reads format \(supported))."
        case .readFailed, .writeFailed, .unreadableDataProtected, .setAsideFailed:
            reason = "\(subject) could not be read from this device's storage."
        }
        let meanwhile = area == .activities
            ? "Nothing was overwritten. The calendar stays empty and changes are not saved until you choose Try Again or Keep a Copy and Start Over in Settings under Saved data."
            : "Nothing was overwritten. Default settings apply for now, and changes are not saved until you choose Try Again or Keep a Copy and Start Over in Settings under Saved data."
        return "\(reason) \(meanwhile)"
    }
}
