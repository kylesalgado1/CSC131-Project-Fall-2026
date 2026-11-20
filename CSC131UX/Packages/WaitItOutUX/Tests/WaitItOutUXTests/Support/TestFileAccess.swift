import Foundation
import WaitItOutUX

/// In-memory stand-in for the file system behind the step 0007 JSON stores.
///
/// Reads, writes, and moves can each be made to fail on demand and then throw `TestStoreError`.
/// Like `LocalFileAccess`, a failed write or move changes nothing: the previous bytes stay in
/// place, and a move never replaces an existing file. Successful atomic writes and moves are
/// counted and logged so tests can prove that a refused or failed operation stored nothing.
final class InMemoryFileAccess: FileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data] = [:]
    private var failReads = false
    private var failWrites = false
    private var failMoves = false
    private var writeLog: [URL] = []
    private var moveLog: [URL] = []

    init() {}

    // MARK: Failure switches

    func setFailReads(_ value: Bool) {
        lock.lock()
        failReads = value
        lock.unlock()
    }

    func setFailWrites(_ value: Bool) {
        lock.lock()
        failWrites = value
        lock.unlock()
    }

    func setFailMoves(_ value: Bool) {
        lock.lock()
        failMoves = value
        lock.unlock()
    }

    // MARK: Direct access for arranging and inspecting files

    /// Places `data` at `url` without counting a write, or removes the file when `data` is nil.
    func setContents(_ data: Data?, at url: URL) {
        lock.lock()
        storage[Self.key(url)] = data
        lock.unlock()
    }

    /// The bytes stored at `url`, or nil when there is no file. Ignores `failReads`.
    func data(at url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.key(url)]
    }

    /// Number of successful `writeAtomically` calls.
    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeLog.count
    }

    /// Destinations of the successful `writeAtomically` calls, in order.
    var writtenURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return writeLog
    }

    /// Number of successful `moveItem` calls.
    var moveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return moveLog.count
    }

    /// Destinations of the successful `moveItem` calls, in order.
    var movedToURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return moveLog
    }

    /// File names of every stored file, sorted.
    var storedFileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.map(\.lastPathComponent).sorted()
    }

    // MARK: FileAccessing

    func contents(of url: URL) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failReads { throw TestStoreError() }
        return storage[Self.key(url)]
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw TestStoreError() }
        storage[Self.key(url)] = data
        writeLog.append(url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let from = Self.key(source)
        let to = Self.key(destination)
        if failMoves { throw TestStoreError() }
        guard let data = storage[from], storage[to] == nil else { throw TestStoreError() }
        storage[to] = data
        storage.removeValue(forKey: from)
        moveLog.append(destination)
    }

    /// One spelling per path, so URLs built in different ways name the same file.
    private static func key(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path(percentEncoded: false), directoryHint: .notDirectory)
    }
}
