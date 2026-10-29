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
}

/// The local tracker's tickets, used when a repo has no tracker adapter (doc 03).
public protocol TicketStore: Sendable {
    func load() throws -> [Ticket]
    func save(_ tickets: [Ticket]) throws
}

/// Evidence files such as check logs. The ledger keeps only their path and checksum.
public protocol ArtifactStore: Sendable {
    func put(named name: String, contents: Data) throws -> StoredArtifact
}

public struct StoredArtifact: Sendable, Hashable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// Keeps records in memory only: for tests and throwaway runs.
public final class InMemoryLedgerStore: LedgerStore {
    private let records = Mutex<[RecordedEvent]>([])

    public init() {}

    public func loadAll() -> [RecordedEvent] { records.withLock { $0 } }
    public func append(_ new: [RecordedEvent]) { records.withLock { $0 += new } }
}
