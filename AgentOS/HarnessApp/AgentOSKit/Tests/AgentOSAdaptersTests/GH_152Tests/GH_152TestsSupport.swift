import Foundation
import Synchronization
import Testing
import AgentOSCore
import AgentOSTestSupport

extension GH_152Tests {
    struct Options: Sendable {
        var suppliedMetadata = true
        var harnessBuild = "92fe9f3-modified"
        var agentRuntimeName = "copilot"
        var agentRuntimeVersion = "1.0.114"
        var effectivePolicyJSON: String? = #"{"limit":7,"review":{"level":"agent"}}"#
        var model = "initial-model"
        var effort = "high"
        var settingsAvailable = true
        var policy = Policy()
        var settings: AgentRunSettings { AgentRunSettings(model: model, effort: effort) }
    }

    final class BatchStore: LedgerStore {
        private let writes = Mutex<[[RecordedEvent]]>([])
        var batches: [[RecordedEvent]] { writes.withLock { $0 } }
        func loadAll() -> [RecordedEvent] { batches.flatMap { $0 } }
        func append(_ records: [RecordedEvent]) { writes.withLock { $0.append(records) } }
    }

    final class Fixture: Sendable {
        static var fallbackSettings: AgentRunSettings {
            AgentRunSettings(model: "fallback-model", effort: "low", fallback: "Initial model unavailable")
        }

        let root: URL
        let role: AgentRole
        let preview: Bool
        let options: Options
        let spec: NodeSpec
        let store: BatchStore
        let ledger: Ledger
        let agents: Agents
        let workspace: MemoryWorkspace
        let reconciler: Reconciler

        init(role: AgentRole, preview: Bool = false, fails: Bool = false, fallback: Bool = false,
             settingsProvider: Bool = true,
             id: String = "configuration-node", options: Options = Options()) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-152-\(UUID().uuidString)")
            self.role = role
            self.preview = preview
            self.options = options
            spec = NodeSpec(id: id, parent: nil, kind: role == .decomposer ? .composite : .leaf,
                            title: id, intent: "Exercise a real reconciler run",
                            acceptanceCriteria: ["Record starting configuration"], touches: ["Engine"])
            store = BatchStore()
            ledger = try Ledger(store: store)
            workspace = MemoryWorkspace(root: root)
            agents = Agents(ledger: ledger, fails: fails, fallback: fallback)
            var team = AgentTeam(name: "GH-152", decomposer: agents, testAuthor: agents, implementer: agents)
            if role == .diagnoser { team.diagnoser = agents }
            if settingsProvider {
                team.runSettings = { _ in options.settingsAvailable ? options.settings : nil }
            }
            let tracker = Tracker(preview: preview, ticketKey: spec.id)
            if options.suppliedMetadata {
                reconciler = Reconciler(
                    ledger: ledger, tracker: tracker, external: NoExternal(), workspace: workspace,
                    artifacts: Artifacts(), checks: Checks(), team: team, policy: options.policy,
                    harnessBuild: options.harnessBuild, agentRuntimeName: options.agentRuntimeName,
                    agentRuntimeVersion: options.agentRuntimeVersion, effectivePolicyJSON: options.effectivePolicyJSON)
            } else {
                reconciler = Reconciler(
                    ledger: ledger, tracker: tracker, external: NoExternal(), workspace: workspace,
                    artifacts: Artifacts(), checks: Checks(), team: team, policy: options.policy)
            }
        }

        func seedAndRun() async throws {
            let directory = try await workspace.createWorktree(for: spec.id)
            let folder = directory.appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// Existing fixture acceptance test\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8)
            if !preview {
                try await ledger.append([
                    event(.nodeCreated(spec: spec, ticket: spec.id)),
                    LedgerEvent(node: spec.id, by: .human("Test operator"), kind: .gateOpened(.breakdown)),
                ])
                if role == .implementer || role == .verifier {
                    try await ledger.append([
                        event(.testsFixed(digest: Hashing.digest(of: folder))),
                        event(.phaseChanged(to: .ready)),
                        LedgerEvent(node: spec.id, by: .human("Test operator"), kind: .gateOpened(.build)),
                    ])
                }
                if role == .verifier {
                    try await ledger.append([
                        event(.changeSubmitted(run: "fixture-builder", commit: "candidate")),
                        event(.phaseChanged(to: .checking)),
                    ])
                }
                if role == .diagnoser {
                    try await ledger.append([event(.flagSet(.escalated, reason: "Fixture requests diagnosis"))])
                }
            }
            try await withHangGuard("GH-152 reconciler run") {
                let report = await self.reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            }
        }

        private func event(_ kind: EventKind) -> LedgerEvent {
            LedgerEvent(node: spec.id, by: .reconciler, kind: kind)
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH-152 fixture: \(error)") }
        }
    }

    actor Agents: Decomposer, TestAuthor, Implementer, Diagnoser {
        let ledger: Ledger
        let fails: Bool
        let fallback: Bool
        private(set) var snapshots: [[RecordedEvent]] = []
        private(set) var calls = 0

        init(ledger: Ledger, fails: Bool, fallback: Bool) {
            self.ledger = ledger
            self.fails = fails
            self.fallback = fallback
        }

        private func observeStart() async throws {
            calls += 1
            snapshots.append(await ledger.allRecords())
            if fallback {
                let recording = try #require(AgentRunRecording.current)
                recording.record(fallback: Fixture.fallbackSettings)
            }
            if fails { throw AgentFailure("GH-152 fixture failure") }
        }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            try await observeStart()
            return Breakdown(children: [])
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            try await observeStart()
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// Authored fixture acceptance test\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8)
            return AgentReport()
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            try await observeStart()
            return AgentReport()
        }

        func diagnose(_ request: DiagnosisRequest) async throws -> Diagnosis {
            try await observeStart()
            return Diagnosis(cause: "Fixture diagnosis", nextStep: "Review the ticket")
        }
    }

    struct MemoryWorkspace: Workspace {
        let root: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
        func head(of directory: URL) async throws -> String { "candidate" }
        func changedFiles(in directory: URL) async throws -> [String] { ["Tests/Acceptance/Acceptance.swift"] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/Acceptance" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { ["Engine"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor Tracker: TrackerAdapter {
        let preview: Bool
        let ticketKey: String
        private var consumed = false
        init(preview: Bool, ticketKey: String) {
            self.preview = preview
            self.ticketKey = ticketKey
        }
        func pendingSignals() async -> [Signal] {
            preview && !consumed
                ? [Signal(ticket: ticketKey, command: .preview, setBy: .human("Test operator"))] : []
        }
        func ticket(_ key: String) async -> Ticket? {
            guard preview, key == ticketKey else { return nil }
            return Ticket(key: key, title: key, description: "Preview a configuration-recorded run",
                          acceptanceCriteria: ["Record starting configuration"], createdBy: .human("Test operator"))
        }
        func consume(_ signal: Signal, reply: String) async { consumed = true }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-152 fixture does not create child tickets")
        }
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture passed", log: "")
        }
    }
}
