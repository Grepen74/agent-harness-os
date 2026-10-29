import AgentOSCore
import Foundation

/// The ledger as a JSON-lines file: one canonical JSON record per line, append only.
public struct FileLedgerStore: LedgerStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadAll() throws -> [RecordedEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = Hashing.decoder()
        return try text.split(separator: "\n").enumerated().map { index, line in
            do { return try decoder.decode(RecordedEvent.self, from: Data(line.utf8)) } catch {
                throw LedgerError.unreadable("line \(index + 1): \(error)")
            }
        }
    }

    public func append(_ records: [RecordedEvent]) throws {
        var lines = Data()
        for record in records {
            lines.append(Hashing.canonicalJSON(record))
            lines.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines)
        // Production: fsync + database transaction, so a crash can't leave half a write.
    }
}

/// The local tracker's tickets as one JSON file.
public struct FileTicketStore: TicketStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [Ticket] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try Hashing.decoder().decode([Ticket].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ tickets: [Ticket]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Hashing.canonicalJSON(tickets).write(to: fileURL, options: .atomic)
    }
}

/// Artifacts as files in one folder.
/// Production: object storage with a retention lock (doc 04 §7).
public struct FileArtifactStore: ArtifactStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func put(named name: String, contents: Data) throws -> StoredArtifact {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try contents.write(to: url, options: .atomic)
        return StoredArtifact(path: url.path, sha256: Hashing.sha256(contents))
    }
}
