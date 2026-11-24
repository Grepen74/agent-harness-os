import AgentOSCore
import Foundation
import Testing

extension GH_87Tests {
    final class Fixture: Sendable {
        static let parentTicket = "GH-8700"
        static let parentID = "wn-GH-8700"
        static let firstLeafTicket = "GH-8701"
        static let firstLeafID = "wn-GH-8701"
        static let firstLeafTitle = "Store the greeting"
        static let secondLeafTicket = "GH-8702"
        static let secondLeafID = "wn-GH-8702"
        static let secondLeafTitle = "Display the greeting"

        let ledger: Ledger
        let tracker = MemoryTracker()

        init() throws {
            ledger = try Ledger()
        }

        func seed() async throws {
            let parent = NodeSpec(
                id: Self.parentID, kind: .composite, title: "Greeting feature",
                intent: "Show the total cost of proven work", acceptanceCriteria: ["Store and display a greeting"]
            )
            let first = NodeSpec(
                id: Self.firstLeafID, parent: parent.id, kind: .leaf, title: Self.firstLeafTitle,
                intent: "Store a greeting", acceptanceCriteria: ["The greeting is stored"]
            )
            let second = NodeSpec(
                id: Self.secondLeafID, parent: parent.id, kind: .leaf, title: Self.secondLeafTitle,
                intent: "Display a greeting", acceptanceCriteria: ["The greeting is displayed"]
            )
            for (spec, ticket) in [(parent, Self.parentTicket), (first, Self.firstLeafTicket),
                                   (second, Self.secondLeafTicket)] {
                await tracker.add(key: ticket, title: spec.title)
                try await record(on: spec.id, [.nodeCreated(spec: spec, ticket: ticket)])
            }
            try await record(on: parent.id, [.phaseChanged(to: .split)])
        }

        func run(
            on node: NodeID, id: RunID, role: AgentRole, credits: Double?, outcome: String = "completed"
        ) async throws {
            try await record(on: node, [.runStarted(run: id, role: role)])
            if let credits {
                try await record(on: node, [.runCostRecorded(run: id, credits: credits)])
            }
            try await record(on: node, [.runFinished(run: id, outcome: outcome)])
        }

        func recordKnownCosts() async throws {
            try await run(on: Self.parentID, id: "known-breakdown", role: .decomposer, credits: 0.75)
            try await run(on: Self.firstLeafID, id: "known-tests", role: .testAuthor, credits: 0.75)
            try await run(on: Self.firstLeafID, id: "known-build", role: .implementer, credits: 1.5)
            try await run(on: Self.firstLeafID, id: "known-zero", role: .implementer, credits: 0)
            try await run(on: Self.secondLeafID, id: "known-second", role: .implementer, credits: 1.5)
        }

        func proveParent() async throws {
            for node in [Self.firstLeafID, Self.secondLeafID] {
                try await record(on: node, [.landed(commit: "landed-\(node)"), .phaseChanged(to: .proven)])
            }
            let unused = UnusedAgents()
            let reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: UnusedWorkspace(), artifacts: UnusedArtifacts(), checks: UnusedChecks(),
                team: AgentTeam(name: "GH-87", decomposer: unused, testAuthor: unused, implementer: unused)
            )
            while true {
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                if report.isIdle { break }
            }
            try #require(await ledger.workingState().nodes[Self.parentID]?.phase == .proven,
                         "The fixture must let the reconciler prove the parent before reading its cost comment.")
        }

        func costComment() async throws -> String {
            let comments = await tracker.comments(on: Self.parentTicket)
            return try #require(comments.first { $0.contains("AI credits") && $0.contains("Total:") },
                                "A proven parent must receive its per-leaf AI credit cost comment.")
        }

        private func record(on node: NodeID, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: node, by: .reconciler, kind: $0) })
        }
    }

    actor MemoryTracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]

        func add(key: String, title: String) {
            tickets[key] = Ticket(key: key, title: title, description: "", acceptanceCriteria: [],
                                  createdBy: .human("Test owner"))
        }

        func comments(on key: String) -> [String] { tickets[key]?.comments.map(\.text) ?? [] }
        func ticket(_ key: String) async -> Ticket? { tickets[key] }
        func contextTickets() async -> [Ticket] { Array(tickets.values) }
        func pendingSignals() async -> [Signal] { [] }
        func consume(_ signal: Signal, reply: String) async { comment(on: signal.ticket, reply) }
        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) async { tickets[key]?.status = status }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-87 fixture must not create tickets.")
        }
    }

    private struct UnusedWorkspace: Workspace {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func existingComponents() -> [String] { [] }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("GH-87 fixture must not create worktrees.")
        }
        func removeWorktree(for id: NodeID) async throws {
            throw AgentFailure("GH-87 fixture must not remove worktrees.")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("GH-87 fixture must not commit.")
        }
        func head(of directory: URL) async throws -> String {
            throw AgentFailure("GH-87 fixture must not read commits.")
        }
        func changedFiles(in directory: URL) async throws -> [String] {
            throw AgentFailure("GH-87 fixture must not inspect files.")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("GH-87 fixture must not rebase.")
        }
        func abortRebase(_ directory: URL) async throws {
            throw AgentFailure("GH-87 fixture must not abort a rebase.")
        }
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("GH-87 fixture must not reset work.")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("GH-87 fixture must not land work.")
        }
        func prepareBuild(in directory: URL) async throws {
            throw AgentFailure("GH-87 fixture must not build.")
        }
    }

    private struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct UnusedAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-87 fixture must not decompose.")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-87 fixture must not author tests.")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-87 fixture must not implement.")
        }
    }

    private struct UnusedArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("GH-87 fixture must not write artifacts.")
        }
    }

    private struct UnusedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("GH-87 fixture must not invoke a check runner.")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
    }
}
