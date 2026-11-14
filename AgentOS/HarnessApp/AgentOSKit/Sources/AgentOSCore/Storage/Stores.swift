import Foundation
import Synchronization

/// Where the ledger's records live (doc 04 §7). The `Ledger` actor decides what may be written
/// (validation, compare-and-swap on node versions, hash chaining); a store only keeps the records.
///
/// File adapter: `FileLedgerStore` (AgentOSAdapters). Later: SQLite, or a database with append-only
/// permissions and the last hash anchored outside it.
public protocol LedgerStore: Sendable {
    /// Every stored record, oldest first, exactly as stored (so the chain can be re-checked).
    func loadAll() throws -> [RecordedEvent]
    /// Appends all records or none.
    func append(_ records: [RecordedEvent]) throws
    /// Rechecks the prefix digest and returns only unverified records when supported.
    func readForVerification(after checkpoint: LedgerStorageCheckpoint?) throws -> LedgerStorageRead
}

/// The local tracker's tickets, used when a repo has no tracker adapter (doc 03).
public protocol TicketStore: Sendable {
    func load() throws -> [Ticket]
    func save(_ tickets: [Ticket]) throws
}

/// Evidence files such as check logs. The ledger keeps only their path and checksum.
public protocol ArtifactStore: Sendable {
    func put(named name: String, contents: Data) throws -> StoredArtifact
    /// Where to write a file that grows over time, such as an agent's log while it runs. Nil: not kept.
    func liveFile(named name: String) throws -> URL?
}

extension ArtifactStore {
    public func liveFile(named name: String) throws -> URL? { nil }
}

public struct StoredArtifact: Codable, Sendable, Hashable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// Keeps records in memory only: for tests and throwaway runs.
public final class InMemoryLedgerStore: LedgerStore {
    private struct Storage {
        var records: [RecordedEvent] = []
        var bytes = Data()
    }
    private let storage = Mutex(Storage())

    public init() {}

    public func loadAll() -> [RecordedEvent] { storage.withLock { $0.records } }
    public func append(_ new: [RecordedEvent]) {
        storage.withLock {
            $0.records += new
            $0.bytes.append(LedgerStorageRead.bytes(for: new))
        }
    }

    public func readForVerification(after checkpoint: LedgerStorageCheckpoint?) throws -> LedgerStorageRead {
        try storage.withLock {
            try checkpoint?.validatePrefix(in: $0.bytes)
            let start = checkpoint?.recordCount ?? 0
            return LedgerStorageRead(
                records: Array($0.records.dropFirst(start)), startPosition: start,
                checkpoint: LedgerStorageCheckpoint(recordCount: $0.records.count, bytes: $0.bytes),
                decodedRecords: 0)
        }
    }
}
