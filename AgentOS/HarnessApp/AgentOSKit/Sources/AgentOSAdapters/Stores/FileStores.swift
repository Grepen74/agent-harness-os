import AgentOSCore
import Foundation

/// The ledger as a JSON-lines file: one canonical JSON record per line, append only.
public struct FileLedgerStore: LedgerStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadAll() throws -> [RecordedEvent] {
        try readForVerification(after: nil).records
    }

    public func readForVerification(after checkpoint: LedgerStorageCheckpoint?) throws -> LedgerStorageRead {
        let bytes: Data
        if FileManager.default.fileExists(atPath: fileURL.path) {
            bytes = try Data(contentsOf: fileURL)
        } else {
            bytes = Data()
        }
        try checkpoint?.validatePrefix(in: bytes)
        let offset = checkpoint?.byteCount ?? 0
        let start = checkpoint?.recordCount ?? 0
        // A valid final record need not end in a newline, but any later record must be separated.
        if offset > 0, bytes.count > offset,
           bytes[offset - 1] != 0x0A, bytes[offset] != 0x0A {
            throw LedgerError.unreadable("line \(start + 1): missing newline after verified storage prefix")
        }
        let decoder = Hashing.decoder()
        let records = try bytes.dropFirst(offset).split(separator: 0x0A).enumerated().map { index, line in
            do { return try decoder.decode(RecordedEvent.self, from: Data(line)) } catch {
                throw LedgerError.unreadable("line \(start + index + 1): \(error)")
            }
        }
        return LedgerStorageRead(
            records: records, startPosition: start,
            checkpoint: LedgerStorageCheckpoint(recordCount: start + records.count, bytes: bytes),
            decodedRecords: records.count)
    }

    public func append(_ records: [RecordedEvent]) throws {
        guard !records.isEmpty else { return }
        var lines = Data()
        for record in records {
            lines.append(Hashing.canonicalJSON(record))
            lines.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            guard let lastByte, lastByte.count == 1 else {
                throw LedgerError.unreadable("could not read the final byte before appending")
            }
            if lastByte.first != 0x0A { lines.insert(0x0A, at: 0) }
        }
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

    public func liveFile(named name: String) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}
