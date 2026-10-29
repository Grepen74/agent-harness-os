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
/// The ledger decides what may be written; a `LedgerStore` keeps the records (a JSON-lines file to
/// start with). Production (doc 04 §7): a database with append-only permissions, the hash anchored
/// somewhere the operators can't change, big files in artifact storage, point-in-time-recovery backups.
public actor Ledger {
    private let store: any LedgerStore
    private var records: [RecordedEvent] = []
    private var knownIDs: Set<UUID> = []
    private var state = WorkingState()
    private var subscribers: [UUID: AsyncStream<RecordedEvent>.Continuation] = [:]

    public init(store: any LedgerStore = InMemoryLedgerStore()) throws {
        self.store = store
        for record in try store.loadAll() {
            records.append(record)
            knownIDs.insert(record.event.id)
            state.apply(record)
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

        try store.append(new)
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

    /// Records a readiness scan, unless it's the same as the latest one: rescanning an unchanged repo
    /// doesn't grow the ledger. Returns whether it was recorded.
    @discardableResult
    public func record(_ scan: ReadinessScan, by participant: Participant = .adapter("Readiness scan")) throws -> Bool {
        guard state.readiness != scan else { return false }
        try append([LedgerEvent(node: nil, by: participant, kind: .readinessScanned(scan))])
        return true
    }

    /// Runs `body` while nothing else can append, for maintenance outside the normal flow (e.g. restoring
    /// storage from a backup). Reload the ledger afterwards if storage changed.
    public func exclusively<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T { try body() }

    // MARK: Auditing

    /// Re-reads every stored record and checks that each matches its hash and links to the one before.
    /// Production: also compare the last hash with an anchor stored outside the ledger (doc: `isIntact` discussion).
    public func verifyChain() -> ChainReport {
        let stored: [RecordedEvent]
        do { stored = try store.loadAll() } catch {
            return ChainReport(checked: 0, problem: .init(position: -1, reason: "\(error)"))
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
}
