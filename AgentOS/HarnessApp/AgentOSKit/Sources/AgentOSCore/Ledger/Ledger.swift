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
    private var recordsByNode: [NodeID: [RecordedEvent]] = [:]
    private var knownIDs: Set<UUID> = []
    private var state = WorkingState()
    private var subscribers: [UUID: AsyncStream<RecordedEvent>.Continuation] = [:]
    private var verification = LedgerVerification()

    public init(store: any LedgerStore = InMemoryLedgerStore()) throws {
        self.store = store
        let stored = try store.readForVerification(after: nil)
        for record in stored.records {
            records.append(record)
            if let node = record.event.node { recordsByNode[node, default: []].append(record) }
            knownIDs.insert(record.event.id)
            state.apply(record)
        }
        _ = verification.check(stored, expectedCount: records.count)
    }

    // MARK: Reading

    public func workingState() -> WorkingState { state }

    public func allRecords() -> [RecordedEvent] { records }

    /// Complete history for one node, in ledger order (not timestamp order).
    public func records(for node: NodeID) -> [RecordedEvent] { recordsByNode[node] ?? [] }

    /// Captures complete legacy and indexed history at the same ledger position.
    public func historySnapshot() -> LedgerHistorySnapshot {
        LedgerHistorySnapshot(records: records, recordsByNode: recordsByNode)
    }

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
        var seen: Set<UUID> = []
        let fresh = events.filter { !knownIDs.contains($0.id) && seen.insert($0.id).inserted }
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
            if let node = record.event.node { recordsByNode[node, default: []].append(record) }
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
        case .evidenceRecorded(let evidence), .landingReworkNeeded(let evidence):
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

    /// Records a baseline run on the default branch.
    public func record(_ baseline: Baseline, by participant: Participant = .adapter("Baseline check")) throws {
        try append([LedgerEvent(node: nil, by: participant, kind: .baselineChecked(baseline))])
    }

    /// Runs `body` while nothing else can append, for maintenance outside the normal flow (e.g. restoring
    /// storage from a backup). Reload the ledger afterwards if storage changed.
    public func exclusively<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T { try body() }

    // MARK: Auditing

    /// Re-reads every stored record and checks that each matches its hash and links to the one before.
    /// Production: also compare the last hash with an anchor stored outside the ledger (doc: `isIntact` discussion).
    public func verifyChain() -> ChainReport {
        do {
            return verification.check(try store.readForVerification(after: nil), expectedCount: records.count)
        } catch {
            return verification.fail(reason: "\(error)")
        }
    }

    public func verifyIncrementally() -> ChainReport {
        if let failure = verification.failure { return failure }
        do {
            return verification.check(
                try store.readForVerification(after: verification.checkpoint), expectedCount: records.count)
        } catch {
            return verification.fail(reason: "\(error)")
        }
    }

    public func verificationStatistics() -> LedgerVerificationStatistics {
        LedgerVerificationStatistics(
            decodedRecords: verification.decodedRecords, hashedRecords: verification.hashedRecords)
    }
}
