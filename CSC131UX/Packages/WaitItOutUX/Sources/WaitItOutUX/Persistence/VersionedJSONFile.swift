import Foundation

/// Why stored data could not be read or written (step 0007).
public enum PersistenceError: Error, Equatable, Sendable {
    /// The file exists but is not a readable document: damaged, truncated, not JSON, or a
    /// different kind of document.
    case damaged
    /// Written in a newer storage format than this version reads.
    case unsupportedVersion(found: Int, supported: Int)
    /// The file system refused the read.
    case readFailed
    /// The file system refused the write. The previous file is unchanged.
    case writeFailed
    /// A write was refused because the stored file could not be read: writing would replace it.
    case unreadableDataProtected
    /// The unreadable file could not be moved aside, so nothing changed.
    case setAsideFailed
}

/// Storage format versions. Version 1 is the first stored format (steps 0001 to 0006 kept
/// everything in memory), so there is nothing to migrate yet. A later format bumps
/// `currentVersion` and converts older payloads in `VersionedJSONFile.decode` before use.
public enum StorageSchema {
    public static let currentVersion = 1
}

/// The envelope every stored file uses:
/// `{"kind": "activities", "payload": …, "schemaVersion": 1}`.
struct StoredDocument<Payload: Codable>: Codable {
    let schemaVersion: Int
    let kind: String
    let payload: Payload
}

/// Read first, before the payload, so a newer or foreign file is recognized as such.
private struct StoredDocumentHeader: Decodable {
    let schemaVersion: Int
    let kind: String
}

/// One versioned JSON document on disk. Reads check the envelope before the payload; writes
/// are atomic through `FileAccessing`. Holds no state, so each store's actor serializes access.
struct VersionedJSONFile<Payload: Codable & Sendable>: Sendable {
    let url: URL
    let kind: String
    let files: any FileAccessing

    /// The stored payload, or `nil` when no file exists yet (empty storage, not a failure).
    func read() throws -> Payload? {
        let contents: Data?
        do {
            contents = try files.contents(of: url)
        } catch {
            throw PersistenceError.readFailed
        }
        guard let data = contents else { return nil }
        return try Self.decode(data, kind: kind)
    }

    /// Encodes and replaces the file atomically. Throws `.writeFailed` and leaves the previous
    /// file in place on any failure.
    func write(_ payload: Payload) throws {
        let data: Data
        do {
            data = try Self.encode(payload, kind: kind)
            try files.writeAtomically(data, to: url)
        } catch {
            throw PersistenceError.writeFailed
        }
    }

    /// Moves the unreadable file aside as `<name>.unreadable-<seconds since 1970>.json` and
    /// returns the new location. Nothing is deleted.
    func setAside(at now: Date) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970.rounded(.down))
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent().appending(path: "\(base).unreadable-\(stamp).json", directoryHint: .notDirectory)
        do {
            try files.moveItem(at: url, to: backup)
        } catch {
            throw PersistenceError.setAsideFailed
        }
        return backup
    }

    static func encode(_ payload: Payload, kind: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates keep the default encoding (seconds since 2001-01-01 UTC as a JSON number), which
        // round-trips every instant exactly. Wall-clock meaning comes from each activity's zone.
        return try encoder.encode(StoredDocument(schemaVersion: StorageSchema.currentVersion, kind: kind, payload: payload))
    }

    static func decode(_ data: Data, kind: String) throws -> Payload {
        let decoder = JSONDecoder()
        let header: StoredDocumentHeader
        do {
            header = try decoder.decode(StoredDocumentHeader.self, from: data)
        } catch {
            throw PersistenceError.damaged
        }
        guard header.kind == kind, header.schemaVersion >= 1 else {
            throw PersistenceError.damaged
        }
        guard header.schemaVersion <= StorageSchema.currentVersion else {
            throw PersistenceError.unsupportedVersion(found: header.schemaVersion, supported: StorageSchema.currentVersion)
        }
        do {
            return try decoder.decode(StoredDocument<Payload>.self, from: data).payload
        } catch {
            throw PersistenceError.damaged
        }
    }
}
