import Foundation
import Testing
import AgentOSCore

extension GH_84Tests {
    final class Fixture: Sendable {
        let root: URL
        let role: AgentRole
        let spec: NodeSpec
        let ledger: Ledger
        let agents: Agents
        let workspace: MemoryWorkspace
        let reconciler: Reconciler

        init(role: AgentRole, credits: [Double], fails: Bool) throws {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<7 { repository.deleteLastPathComponent() }
            root = repository.appending(path: ".agentos/scratch/run-7f2e99/GH-84-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.role = role
            spec = GH_84Tests.spec("cost-node", kind: role == .decomposer ? .composite : .leaf)
            ledger = try Ledger()
            workspace = MemoryWorkspace(root: root)
            agents = Agents(ledger: ledger, node: spec.id, credits: credits, fails: fails)
            var team = AgentTeam(name: "GH-84", decomposer: agents, testAuthor: agents, implementer: agents)
            if role == .diagnoser { team.diagnoser = agents }
            reconciler = Reconciler(
                ledger: ledger, tracker: Tracker(), external: NoExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: Checks(), team: team
            )
        }

        func seed() async throws {
            let directory = try await workspace.createWorktree(for: spec.id)
            let folder = directory.appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// Fixture acceptance test\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            try await ledger.append([
                GH_84Tests.event(spec.id, .nodeCreated(spec: spec, ticket: "GH-84")),
                LedgerEvent(node: spec.id, by: .human("Test operator"), kind: .gateOpened(.breakdown)),
            ])
            if role == .implementer {
                try await ledger.append([
                    GH_84Tests.event(spec.id, .testsFixed(digest: Hashing.digest(of: folder))),
                    GH_84Tests.event(spec.id, .phaseChanged(to: .ready)),
                    LedgerEvent(node: spec.id, by: .human("Test operator"), kind: .gateOpened(.build)),
                ])
            }
            if role == .diagnoser {
                try await ledger.append([
                    GH_84Tests.event(spec.id, .flagSet(.escalated, reason: "Fixture requests diagnosis")),
                ])
            }
        }

        func run() async throws {
            let report = await reconciler.runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH-84 fixture: \(error)") }
        }
    }

    actor Agents: Decomposer, TestAuthor, Implementer, Diagnoser {
        let ledger: Ledger
        let node: NodeID
        let credits: [Double]
        let fails: Bool
        private(set) var calls = 0

        init(ledger: Ledger, node: NodeID, credits: [Double], fails: Bool) {
            self.ledger = ledger
            self.node = node
            self.credits = credits
            self.fails = fails
        }

        private func reportUsage() async throws {
            calls += 1
            let recording = try #require(AgentRunRecording.current, "The harness must install the reporting context.")
            let run = try #require(await ledger.workingState().nodes[node]?.activeRun?.run)
            for credit in credits { recording.record(credits: credit) }
            let duringRun = await ledger.records(for: node)
            #expect(!duringRun.contains {
                if case .agentCreditsRecorded(let recordedRun, _) = $0.event.kind { return recordedRun == run }
                return false
            }, "Reports are combined into a cost event when the run ends, not appended separately while it runs.")
            if fails { throw AgentFailure("GH-84 reported failure") }
        }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            try await reportUsage()
            return Breakdown(children: [])
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            try await reportUsage()
            return AgentReport()
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            try await reportUsage()
            return AgentReport()
        }
        func diagnose(_ request: DiagnosisRequest) async throws -> Diagnosis {
            try await reportUsage()
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

    struct Tracker: TrackerAdapter {
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-84 fixture does not create child tickets")
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

    static func legacyRecords() throws -> [RecordedEvent] {
        let oldSpec: (String, String, String?) -> [String: Any] = { id, kind, parent in
            var result: [String: Any] = [
                "id": id, "kind": kind, "title": id, "intent": "Legacy work",
                "acceptanceCriteria": ["Legacy acceptance"], "touches": ["Engine"],
                "dependsOn": [], "profile": "simple-app",
            ]
            if let parent { result["parent"] = parent }
            return result
        }
        let entries: [(String, [String: Any])] = [
            ("old-parent", ["nodeCreated": ["spec": oldSpec("old-parent", "composite", nil), "ticket": "OLD-1"]]),
            ("old-leaf", ["nodeCreated": ["spec": oldSpec("old-leaf", "leaf", "old-parent"), "ticket": "OLD-2"]]),
            ("old-parent", ["runStarted": ["run": "old-breakdown", "role": "decomposer"]]),
            ("old-parent", ["runFinished": ["run": "old-breakdown", "outcome": "split"]]),
            ("old-leaf", ["runStarted": ["run": "old-author", "role": "testAuthor"]]),
            ("old-leaf", ["runFinished": ["run": "old-author", "outcome": "failed"]]),
            ("old-leaf", ["runStarted": ["run": "old-check", "role": "verifier"]]),
            ("old-leaf", ["runFinished": ["run": "old-check", "outcome": "passed"]]),
            ("old-leaf", ["runStarted": ["run": "old-active", "role": "implementer"]]),
        ]
        var previousHash = RecordedEvent.genesisHash
        return try entries.enumerated().map { position, entry in
            let event: [String: Any] = [
                "id": String(format: "00000000-0000-0000-0000-%012d", position + 1),
                "node": entry.0, "by": ["reconciler": [:]],
                "at": "2025-01-01T00:00:00Z", "kind": entry.1,
            ]
            var record: [String: Any] = ["position": position, "previousHash": previousHash, "event": event]
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
            previousHash = Hashing.sha256(bytes)
            record["hash"] = previousHash
            return try Hashing.decoder().decode(RecordedEvent.self, from: JSONSerialization.data(withJSONObject: record))
        }
    }
}
