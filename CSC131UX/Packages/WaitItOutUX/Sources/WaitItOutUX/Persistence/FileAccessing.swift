import Foundation

/// File operations the JSON stores need (step 0007). Injected so tests can simulate missing,
/// unreadable, and unwritable files without touching the disk. The stores call these from
/// their own actors, never from the main actor.
public protocol FileAccessing: Sendable {
    /// The file's bytes, or `nil` when no file exists at `url`.
    func contents(of url: URL) throws -> Data?
    /// Replaces the file in one step, creating its folder when needed. A failed write leaves
    /// the previous file untouched.
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Moves a file to a new name. Fails when `destination` already exists.
    func moveItem(at source: URL, to destination: URL) throws
}

/// `FileManager`-backed file access. Writes use `Data.WritingOptions.atomic`: the bytes go to
/// a temporary file that is then renamed over the original, so a reader sees either the whole
/// old document or the whole new one, never a partial write.
public struct LocalFileAccess: FileAccessing {
    public init() {}

    public func contents(of url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

/// Where the prototype keeps its JSON files: one folder in Application Support with
/// `activities.json` and `preferences.json`.
public struct PrototypeStorageLocation: Equatable, Sendable {
    public static let defaultFolderName = "WaitItOutUX"
    public static let activitiesFileName = "activities.json"
    public static let preferencesFileName = "preferences.json"
    /// Launch-environment key that names another folder. UI tests set a fresh name per test so
    /// every test starts from empty storage and a relaunch test can reuse the same folder.
    public static let folderEnvironmentKey = "WAIT_IT_OUT_STORAGE_FOLDER"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var activitiesFile: URL {
        directory.appending(path: Self.activitiesFileName, directoryHint: .notDirectory)
    }

    public var preferencesFile: URL {
        directory.appending(path: Self.preferencesFileName, directoryHint: .notDirectory)
    }

    /// `Application Support/<folder>` inside the app's container. Only computes the path; the
    /// folder is created by the first write, off the main actor.
    public static func applicationSupport(folderName: String? = nil) -> PrototypeStorageLocation {
        PrototypeStorageLocation(
            directory: URL.applicationSupportDirectory.appending(path: validatedFolderName(folderName), directoryHint: .isDirectory)
        )
    }

    /// `name` when it is 1 to 64 ASCII letters, digits, hyphens, or underscores; otherwise the
    /// default folder, so a stray value can never point outside Application Support.
    public static func validatedFolderName(_ name: String?) -> String {
        guard let name, (1...64).contains(name.count) else { return defaultFolderName }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
        return allowed ? name : defaultFolderName
    }
}
