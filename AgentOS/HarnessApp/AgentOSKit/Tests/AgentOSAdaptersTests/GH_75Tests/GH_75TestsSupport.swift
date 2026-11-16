import Foundation
import Testing
@testable import AgentOSCore

extension GH_75Tests {
    final class Fixture: Sendable {
        let ledger: Ledger
        let tracker = Tracker()
        let decomposer: Proposer
        let reconciler: Reconciler

        init(children: [ChildProposal]) throws {
            ledger = try Ledger()
            decomposer = Proposer(children)
            let services = Services()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "GH-75", decomposer: decomposer, testAuthor: services, implementer: services))
        }

        func breakDown() async throws {
            if await ledger.workingState().nodes[GH_75Tests.rootSpec.id] == nil {
                try await ledger.append([LedgerEvent(
                    node: GH_75Tests.rootSpec.id, by: .human("Reviewer"),
                    kind: .nodeCreated(spec: GH_75Tests.rootSpec, ticket: GH_75Tests.ticket.key))])
            }
            try await ledger.append([LedgerEvent(node: GH_75Tests.rootSpec.id, by: .human("Reviewer"),
                                                 kind: .gateOpened(.breakdown))])
            let state = await ledger.workingState()
            let node = try #require(state.nodes[GH_75Tests.rootSpec.id])
            _ = try await reconciler.breakDown(node, in: state)
        }

        func preview() async throws -> String {
            await tracker.requestPreview()
            let report = await reconciler.runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            return try #require(await tracker.comments.first { $0.contains("Preview #") })
        }
    }

    actor Proposer: Decomposer {
        private var children: [ChildProposal]
        private(set) var calls = 0

        init(_ children: [ChildProposal]) { self.children = children }
        func replace(_ children: [ChildProposal]) { self.children = children }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls += 1
            return Breakdown(children: children)
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        private(set) var createdChildren = 0

        func requestPreview() {
            signals.append(Signal(ticket: "GH-75", command: .preview, setBy: .human("Reviewer")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { key == "GH-75" ? GH_75Tests.ticket : nil }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            createdChildren += 1
            return "GH-75-\(createdChildren)"
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    // These tests finish at breakdown, before a working copy or a build is needed.
    struct Services: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner, TestAuthor, Implementer {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("GH-75 does not run a test author")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit in a breakdown test")
        }
        func head(of directory: URL) async throws -> String { throw AgentFailure("Unexpected HEAD read") }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Unexpected rebase")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Unexpected landing") }
        func existingComponents() -> [String] { ["Storage", "Display", "Speech"] }
        func prepareBuild(in directory: URL) async throws { throw AgentFailure("Unexpected build") }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact")
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("GH-75 must not run checks while breaking down a ticket")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("Unexpected implementer") }
    }

    static func legacyRecords() throws -> [RecordedEvent] {
        let events = """
        [
          {"id":"00000000-0000-0000-0000-000000000075","node":"wn-GH-75",
           "by":{"human":{"_0":"Reviewer"}},"at":"2025-01-01T00:00:00Z",
           "kind":{"nodeCreated":{"ticket":"GH-75","spec":{
             "id":"wn-GH-75","kind":"composite","title":"Greeting features","intent":"Greet the user",
             "acceptanceCriteria":["A greeting is stored","A greeting is visible"],
             "touches":[],"dependsOn":[],"profile":"simple-app"}}}},
          {"id":"00000000-0000-0000-0000-000000000076","node":"wn-GH-75",
           "by":{"reconciler":{}},"at":"2025-01-01T00:00:01Z",
           "kind":{"becameLeaf":{"touches":["Storage"]}}}
        ]
        """
        let objects = try #require(JSONSerialization.jsonObject(with: Data(events.utf8)) as? [[String: Any]])
        var previousHash = RecordedEvent.genesisHash
        return try objects.enumerated().map { position, event in
            var payload: [String: Any] = ["position": position, "previousHash": previousHash, "event": event]
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            previousHash = Hashing.sha256(bytes)
            payload["hash"] = previousHash
            return try Hashing.decoder().decode(RecordedEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        }
    }
}
