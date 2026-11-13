import AgentOSAdapters
import Foundation
import Synchronization
import Testing
@testable import AgentOSCore

extension GH_68Tests {
    static let other: NodeID = "wn-GH-68-other"
    static let spec = NodeSpec(
        id: "wn-GH-68", parent: nil, kind: .leaf, title: "Indexed history",
        intent: "Retain complete node history", acceptanceCriteria: ["History stays complete"])

    static func event(_ kind: EventKind, node: NodeID? = spec.id, by: Participant = .reconciler) -> LedgerEvent {
        LedgerEvent(node: node, by: by, kind: kind)
    }

    static func creation(_ id: NodeID = spec.id) -> LedgerEvent {
        var node = spec
        node.id = id
        return event(.nodeCreated(spec: node, ticket: String(id.dropFirst(3))), node: id, by: .human("Alice"))
    }

    static func noise(count: Int = 211) -> [LedgerEvent] {
        (0..<count).map {
            event(.externalDependencyResolved(ref: "unrelated-\($0)"), node: $0.isMultiple(of: 2) ? other : nil)
        }
    }

    static func reviewRecord(
        _ finding: String, stage: ReviewStage = .change, followUps: [String]? = nil
    ) -> ReviewRecord {
        ReviewRecord(stage: stage, result: .init(passed: false, findings: [finding], followUps: followUps),
                     commit: "candidate", uiEvidence: nil)
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-68-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Couldn't remove GH-68 fixture \(directory.path): \(error)")
        }
    }

    enum StorageFailure: Error { case refused }

    final class FailingStore: LedgerStore {
        private struct State {
            var records: [RecordedEvent] = []
            var failNext = false
        }
        private let state = Mutex(State())

        func failNextAppend() { state.withLock { $0.failNext = true } }
        func loadAll() throws -> [RecordedEvent] { state.withLock { $0.records } }
        func append(_ records: [RecordedEvent]) throws {
            try state.withLock {
                if $0.failNext {
                    $0.failNext = false
                    throw StorageFailure.refused
                }
                $0.records += records
            }
        }
    }

    enum BrokenReportReset: CaseIterable, Equatable, Sendable {
        case none, attempts, answer, retry, retest

        var kind: EventKind? {
            switch self {
            case .none: nil
            case .attempts: .attemptsReset
            case .answer: .questionsAnswered(.init(questions: ["How should it work?"], answer: "Use the corrected contract."))
            case .retry: .signalAccepted(ticket: "GH-68", command: .retry, reply: "retry accepted")
            case .retest: .signalAccepted(ticket: "GH-68", command: .retest, reply: "retest accepted")
            }
        }
    }

    struct Fixture: Sendable {
        static let context = ReviewContext(
            baseBranch: "agentos/main", commit: "candidate", fullDiff: "feature change",
            changedFiles: ["Sources/Feature.swift"], recentChanges: [], uiEvidence: nil)

        let directory: URL
        let ledger: Ledger
        let tracker: RecordingTracker
        let reviewer: RecordingReviewer
        let reconciler: Reconciler

        init(history: [LedgerEvent], reviewResult: ReviewResult = .init(passed: true, findings: [])) async throws {
            directory = try GH_68Tests.temporaryDirectory()
            let store = InMemoryLedgerStore()
            let writer = try Ledger(store: store)
            try await writer.append([GH_68Tests.creation(), GH_68Tests.creation(GH_68Tests.other)] + history)
            ledger = try Ledger(store: store)
            tracker = RecordingTracker()
            reviewer = RecordingReviewer(result: reviewResult)
            let agents = NoopAgents()
            var team = AgentTeam(name: "GH-68", decomposer: agents, testAuthor: agents, implementer: agents)
            team.reviewer = reviewer
            var policy = Policy(maxAttempts: 2)
            policy.review.level = .none
            policy.review.maxRounds = 2
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: StubWorkspace(directory: directory), artifacts: MemoryArtifacts(),
                checks: PassingChecks(), team: team, policy: policy,
                acceptanceTestPreflight: FailingPreflight())
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[GH_68Tests.spec.id])
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var messages: [String] = []
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("This fixture must not create child tickets.")
        }
        func comment(on key: String, _ text: String) { messages.append(text) }
        func setStatus(of key: String, to status: String) {}
        func comments() -> [String] { messages }
    }

    actor RecordingReviewer: Reviewer {
        private let result: ReviewResult
        private var requests: [[[String]]] = []
        init(result: ReviewResult) { self.result = result }
        func review(_ request: ReviewRequest) -> ReviewResult {
            requests.append(request.earlierFindings)
            return result
        }
        func earlierFindings() -> [[[String]]] { requests }
    }

    struct NoopAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown { Breakdown(children: []) }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
        func implement(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
    }

    struct FailingPreflight: AcceptanceTestPreflight {
        func compileTests(in directory: URL, testFolder: String, expectedAPI: [String]) async -> AcceptanceTestPreflightResult {
            .diagnostics([CompilerDiagnostic(
                file: testFolder + "/Contract.swift", line: 1, message: "invalid test fixture",
                classification: .testAuthorMistake)], fullLog: "invalid test fixture")
        }
    }

    struct StubWorkspace: Workspace {
        let directory: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
        func head(of directory: URL) async throws -> String { "candidate" }
        func changedFiles(in directory: URL) async throws -> [String] { [testArea + "GH_68Tests/Contract.swift"] }
        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext { Fixture.context }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { testArea + "GH_68Tests" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "passed", log: "passed")
        }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
