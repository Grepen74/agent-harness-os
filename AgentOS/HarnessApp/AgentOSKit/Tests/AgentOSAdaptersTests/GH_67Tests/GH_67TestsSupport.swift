import AgentOSAdapters
import AgentOSCore
import Foundation
import Synchronization
import Testing

extension GH_67Tests {
    enum HistoricalDamage: CaseIterable, Sendable {
        case sameSizeEdit, missingMiddle, reordered, partialTruncation, removedTail, removedAll, replaced
    }

    enum TailDamage: CaseIterable, Sendable {
        case content, position, firstPredecessor, laterPredecessor
    }

    enum CompatibilityDamage: CaseIterable, Sendable {
        case changed, missing, reordered, truncated, replaced, forged
    }

    struct Files {
        let directory: URL
        var url: URL { directory.appending(path: "ledger.jsonl") }
        var store: FileLedgerStore { FileLedgerStore(fileURL: url) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-67-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ records: [RecordedEvent]) throws {
            var data = Data()
            for record in records {
                data.append(Hashing.canonicalJSON(record))
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    func event(_ summary: String) -> LedgerEvent {
        LedgerEvent(node: nil, by: .reconciler, kind: .attemptFailed(summary: summary))
    }

    func history(prefix: String = "original") async throws -> [RecordedEvent] {
        try await Ledger().append((0..<4).map { event("\(prefix)-\($0)") })
    }

    func changedContent(_ record: RecordedEvent) throws -> RecordedEvent {
        var object = try #require(
            JSONSerialization.jsonObject(with: Hashing.canonicalJSON(record)) as? [String: Any])
        var event = try #require(object["event"] as? [String: Any])
        event["kind"] = ["attemptFailed": ["summary": "tampered"]]
        object["event"] = event
        return try Hashing.decoder().decode(
            RecordedEvent.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func rehashed(_ record: RecordedEvent, position: Int, previousHash: String) throws -> RecordedEvent {
        var payload: [String: Any] = [
            "event": try JSONSerialization.jsonObject(with: Hashing.canonicalJSON(record.event)),
            "position": position,
            "previousHash": previousHash,
        ]
        let canonical = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        payload["hash"] = Hashing.sha256(canonical)
        return try Hashing.decoder().decode(
            RecordedEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    func damageFile(_ damage: HistoricalDamage, original: [RecordedEvent], files: Files) async throws {
        var records = original
        switch damage {
        case .sameSizeEdit:
            let bytes = try Data(contentsOf: files.url)
            let edited = Data(String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "original-1", with: "tampered-1").utf8)
            try #require(edited.count == bytes.count)
            try edited.write(to: files.url)
            return
        case .missingMiddle: records.remove(at: 1)
        case .reordered: records.swapAt(1, 2)
        case .partialTruncation:
            let bytes = try Data(contentsOf: files.url)
            try Data(bytes.dropLast(17)).write(to: files.url)
            return
        case .removedTail: records.removeLast(2)
        case .removedAll: records.removeAll()
        case .replaced: records = try await history(prefix: "replaced")
        }
        try files.write(records)
    }

    func expectSafeStop(_ harness: Harness, matching failure: ChainReport) async throws {
        let problem = try #require(failure.problem)
        let expected = "Ledger integrity check failed at #\(problem.position): \(problem.reason). " +
            "Safe stop: nothing will happen until a human investigates."
        let round = await harness.reconciler.runRound(waitForAgents: true)
        #expect(round.safeStop == expected)
        #expect(round.actions.isEmpty)
        #expect(await harness.workspace.preparations == 0)
        #expect(await harness.tracker.signalReads == 0)
        #expect(await harness.tracker.consumed == 0)
    }

    final class CompatibilityStore: LedgerStore {
        struct State {
            var records: [RecordedEvent]
            var failNext = false
            var reads = 0
        }
        private let state: Mutex<State>
        init(_ records: [RecordedEvent]) { state = Mutex(State(records: records)) }
        var readCount: Int { state.withLock { $0.reads } }
        func replace(_ records: [RecordedEvent]) { state.withLock { $0.records = records } }
        func failNextRead() { state.withLock { $0.failNext = true } }
        func append(_ records: [RecordedEvent]) throws { state.withLock { $0.records += records } }
        func loadAll() throws -> [RecordedEvent] {
            try state.withLock {
                $0.reads += 1
                if $0.failNext {
                    $0.failNext = false
                    throw AgentFailure("transient ledger read failure")
                }
                return $0.records
            }
        }
    }

    struct Harness {
        let workspace = ObservedWorkspace()
        let tracker = ObservedTracker()
        let reconciler: Reconciler
        init(ledger: Ledger) {
            let agents = UnusedAgents()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: NoArtifacts(), checks: NoChecks(),
                team: AgentTeam(name: "GH-67", decomposer: agents, testAuthor: agents, implementer: agents))
        }
    }

    actor ObservedTracker: TrackerAdapter {
        var signalReads = 0
        var consumed = 0
        func pendingSignals() async -> [Signal] {
            signalReads += 1
            return []
        }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async { consumed += 1 }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("Unexpected ticket creation")
        }
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
    }

    actor ObservedWorkspace: Workspace {
        var preparations = 0
        func prepare() async throws { preparations += 1 }
        nonisolated func branch(for id: NodeID) -> String { "test/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { URL(filePath: "/unused-GH-67/\(id)") }
        func createWorktree(for id: NodeID) async throws -> URL { throw AgentFailure("Unexpected worktree") }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit")
        }
        func head(of directory: URL) async throws -> String { throw AgentFailure("Unexpected head read") }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Unexpected rebase")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Unexpected landing") }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct UnusedAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("Unexpected decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected implementation")
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
    struct NoArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact write")
        }
    }
    struct NoChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("No checks should run for these ledgers.")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
    }

    // Persisted historical data: hashes are literals, independent of current genesis/hash implementations.
    static let historicalJSONL = """
    {"event":{"at":"2020-01-01T00:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000001","kind":{"attemptFailed":{"summary":"original"}}},"hash":"f01dc673d73d03c3c5b32d8c241886dcad5ca0af1729c5dd65931cc89f648287","position":0,"previousHash":"0000000000000000000000000000000000000000000000000000000000000000"}
    {"event":{"at":"2020-01-01T00:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000002","kind":{"attemptsReset":{}}},"hash":"4520feeaa59d18d6798cd04ca67ae9b446425adcc292f870485b9f33944728f1","position":1,"previousHash":"f01dc673d73d03c3c5b32d8c241886dcad5ca0af1729c5dd65931cc89f648287"}

    """
}
