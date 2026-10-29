import Foundation

public enum LedgerError: Error, CustomStringConvertible {
    case conflict(node: NodeID, expected: Int, current: Int)
    case notAllowed(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .conflict(let node, let expected, let current):
            "Conflict on \(node): expected version \(expected), ledger has \(current)"
        case .notAllowed(let reason): "Not allowed: \(reason)"
        case .unreadable(let reason): "Ledger unreadable: \(reason)"
        }
    }
}

public struct ChainReport: Sendable {
    public struct Problem: Sendable {
        public let position: Int
        public let reason: String
    }

    public let checked: Int
    public let problem: Problem?
    public var isIntact: Bool { problem == nil }
}

/// The harness's memory for ONE system: an append-only, hash-chained event log.
///
/// The mock stores one JSON line per event in a file. Production (doc 04 §7): a database
/// (e.g. PostgreSQL) with append-only permissions, the hash anchored somewhere the operators
/// can't change, big files in artifact storage, and point-in-time-recovery backups.
public actor Ledger {
    public nonisolated let fileURL: URL?
    private var records: [RecordedEvent] = []
    private var knownIDs: Set<UUID> = []
    private var state = WorkingState()
    private var subscribers: [UUID: AsyncStream<RecordedEvent>.Continuation] = [:]

    /// Pass nil for an in-memory ledger.
    public init(fileURL: URL?) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            for record in try Self.load(fileURL) {
                records.append(record)
                knownIDs.insert(record.event.id)
                state.apply(record)
            }
        }
    }

    // MARK: Reading

    public func workingState() -> WorkingState { state }

    public func allRecords() -> [RecordedEvent] { records }

    /// The live event stream (doc 06): views subscribe and redraw on every new event.
    public func subscribe() -> AsyncStream<RecordedEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordedEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: Writing (append only: there is deliberately no update or delete)

    /// Writes all events or none.
    /// - `expecting`: node → version the caller based its decision on. If the node changed since,
    ///   the write is refused (compare-and-swap) and the caller simply looks again next round.
    /// - Events whose id is already in the ledger are skipped (idempotent retries).
    @discardableResult
    public func append(_ events: [LedgerEvent], expecting: [NodeID: Int] = [:]) throws -> [RecordedEvent] {
        let fresh = events.filter { !knownIDs.contains($0.id) }
        guard !fresh.isEmpty else { return [] }

        for (node, expected) in expecting {
            let current = state.nodes[node]?.version ?? -1
            guard current == expected else { throw LedgerError.conflict(node: node, expected: expected, current: current) }
        }
        for event in fresh { try validate(event) }

        var new: [RecordedEvent] = []
        var previousHash = records.last?.hash ?? RecordedEvent.genesisHash
        for (offset, event) in fresh.enumerated() {
            let record = RecordedEvent(position: records.count + offset, event: event, previousHash: previousHash)
            new.append(record)
            previousHash = record.hash
        }

        try persist(new)
        for record in new {
            records.append(record)
            knownIDs.insert(record.event.id)
            state.apply(record)
            for continuation in subscribers.values { continuation.yield(record) }
        }
        return new
    }

    /// Rules the ledger enforces itself, so a bug elsewhere can't break them.
    private func validate(_ event: LedgerEvent) throws {
        switch event.kind {
        case .gateOpened:
            guard event.by.isHuman else { throw LedgerError.notAllowed("only humans can open gates") }
        case .evidenceRecorded(let evidence):
            guard case .agent(let run, .verifier) = event.by, run == evidence.checkedBy else {
                throw LedgerError.notAllowed("evidence must be recorded by the verifier run that produced it")
            }
            guard evidence.builtBy != evidence.checkedBy else {
                throw LedgerError.notAllowed("builder ≠ checker: a run can't verify its own work")
            }
        case .nodeCreated(let spec, _):
            guard state.nodes[spec.id] == nil else { throw LedgerError.notAllowed("node \(spec.id) already exists") }
        default:
            break
        }
    }

    private func persist(_ new: [RecordedEvent]) throws {
        guard let fileURL else { return }
        var lines = Data()
        for record in new {
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

    private static func load(_ url: URL) throws -> [RecordedEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = Hashing.decoder()
        return try text.split(separator: "\n").enumerated().map { index, line in
            do { return try decoder.decode(RecordedEvent.self, from: Data(line.utf8)) } catch {
                throw LedgerError.unreadable("line \(index + 1): \(error)")
            }
        }
    }

    // MARK: Auditing

    /// Re-checks every stored record (from disk, if persisted): each matches its hash and links to the one before.
    /// Production: also compare the last hash with an anchor stored outside the ledger (doc: `isIntact` discussion).
    public func verifyChain() -> ChainReport {
        let stored: [RecordedEvent]
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do { stored = try Self.load(fileURL) } catch {
                return ChainReport(checked: 0, problem: .init(position: -1, reason: "\(error)"))
            }
        } else {
            stored = records
        }

        var previous: RecordedEvent?
        for record in stored {
            if !record.isIntact {
                return ChainReport(checked: record.position, problem: .init(
                    position: record.position, reason: "record content doesn't match its hash (changed after writing)"))
            }
            if !record.follows(previous) {
                return ChainReport(checked: record.position, problem: .init(
                    position: record.position, reason: "chain broken: record doesn't follow the one before"))
            }
            previous = record
        }
        if stored.count != records.count {
            return ChainReport(checked: stored.count, problem: .init(
                position: stored.count, reason: "\(records.count - stored.count) records missing from storage"))
        }
        return ChainReport(checked: stored.count, problem: nil)
    }

    /// Demo only: back-dates one stored event, as someone editing the database directly might.
    public func tamperForDemo() throws {
        guard let fileURL else { return }
        var lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return }
        // Keep the first untouched copy, so the demo can recover (see `restoreAfterTamperDemo`).
        if let backupURL, !FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        let index = lines.count / 2
        guard var object = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any],
              var event = object["event"] as? [String: Any] else { return }
        event["at"] = "2001-01-01T00:00:00Z"
        object["event"] = event
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        lines[index] = String(decoding: data, as: UTF8.self)
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Demo only: puts back the copy saved before tampering. Returns false if there is nothing to restore.
    /// Production: a human investigates, then restores from a replica or backup whose last hash matches
    /// the anchor kept outside the ledger. The harness never repairs its own ledger.
    /// Reload the ledger afterwards (restart the harness) so memory matches the restored file.
    public func restoreAfterTamperDemo() throws -> Bool {
        guard let fileURL, let backupURL, FileManager.default.fileExists(atPath: backupURL.path) else { return false }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: backupURL)
        return true
    }

    private var backupURL: URL? { fileURL?.appendingPathExtension("before-tamper") }
}
