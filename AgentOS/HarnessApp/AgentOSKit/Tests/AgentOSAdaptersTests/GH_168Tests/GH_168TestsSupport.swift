import Foundation
import Testing
@testable import AgentOSCore

extension GH_168Tests {
    static var ticket: Ticket {
        Ticket(key: "GH-168", title: "Record workflow", description: "Store, display and audit records.",
               acceptanceCriteria: ["Stored records can be displayed and audited."],
               createdBy: .human("Reviewer"))
    }

    static func child(_ title: String, integration: Bool = false) -> ChildProposal {
        var proposal = ChildProposal(
            title: title, acceptanceCriteria: ["\(title) returns the expected record."],
            touches: [title], predictedPaths: ["Sources/\(title.replacingOccurrences(of: " ", with: ""))/"])
        proposal.integration = integration
        return proposal
    }

    final class Fixture: Sendable {
        let ledger: Ledger
        let tracker = RecordingTracker()
        let reconciler: Reconciler

        init() throws {
            ledger = try Ledger()
            let services = BreakdownOnlyServices()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "GH-168", decomposer: services, testAuthor: services, implementer: services))
        }

        func start(_ proposals: [ChildProposal]) async throws {
            let spec = Planner.rootSpec(for: GH_168Tests.ticket)
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Reviewer"),
                            kind: .nodeCreated(spec: spec, ticket: GH_168Tests.ticket.key))
            ])
            try await applyApproved(proposals)
            let state = await ledger.workingState()
            let parent = try #require(state.nodes[spec.id])
            for id in parent.children {
                let child = try #require(state.nodes[id])
                let files = ["Tests/\(child.spec.testTarget)/\(child.spec.testTarget).swift"]
                let review = ReviewRecord(
                    stage: .acceptanceTests, result: ReviewResult(passed: true, findings: []),
                    commit: "test-commit-\(id)", uiEvidence: nil)
                try await ledger.append([
                    LedgerEvent(node: id, by: .agent(run: "test-author-\(id)", role: .testAuthor),
                                kind: .testsRecorded(files: files, suite: child.spec.testTarget)),
                    LedgerEvent(node: id, by: .reconciler, kind: .testsFixed(digest: "test-digest-\(id)")),
                    LedgerEvent(node: id, by: .reconciler, kind: .reviewRecorded(review)),
                    LedgerEvent(node: id, by: .human("Reviewer"), kind: .gateOpened(.build)),
                    LedgerEvent(node: id, by: .human("Reviewer"),
                                kind: .testUpdatesApproved(files: ["Tests/ExistingRecordTests.swift"])),
                    LedgerEvent(node: id, by: .reconciler, kind: .phaseChanged(to: .ready))
                ])
            }
        }

        func replan(_ proposals: [ChildProposal]) async throws {
            let ticket = await tracker.editRoot(criteria: proposals.flatMap(\.acceptanceCriteria))
            let state = await ledger.workingState()
            let node = try #require(state.node(forTicket: ticket.key))
            _ = try await reconciler.replan(node, ticket: ticket, by: "Reviewer")
            try await applyApproved(proposals)
        }

        private func applyApproved(_ proposals: [ChildProposal]) async throws {
            let state = await ledger.workingState()
            let node = try #require(state.node(forTicket: GH_168Tests.ticket.key))
            let specs = Planner.childSpecs(parent: node.spec, proposals: proposals)
            try await ledger.append([
                LedgerEvent(node: nil, by: .reconciler,
                            kind: .previewRecorded(ticket: node.ticket, number: 1,
                                                   specHash: node.spec.specHash, proposal: specs)),
                LedgerEvent(node: node.id, by: .human("Reviewer"), kind: .gateOpened(.breakdown))
            ])
            let approved = await ledger.workingState()
            let parent = try #require(approved.nodes[node.id])
            _ = try await reconciler.breakDown(parent, in: approved)
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var root = GH_168Tests.ticket
        private(set) var created: [NodeSpec] = []
        private(set) var closed: Set<String> = []
        private(set) var statuses: [String: String] = [:]
        private(set) var comments: [String: [String]] = [:]

        func editRoot(criteria: [String]) -> Ticket {
            root = Ticket(key: root.key, title: root.title, description: root.description,
                          acceptanceCriteria: criteria, createdBy: root.createdBy)
            return root
        }
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { key == root.key ? root : nil }
        func consume(_ signal: Signal, reply: String) { comments[signal.ticket, default: []].append(reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            created.append(spec)
            return "GH-168-child-\(created.count)"
        }
        func comment(on key: String, _ text: String) { comments[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) { statuses[key] = status }
        func close(_ key: String, saying text: String) async {
            closed.insert(key)
            comments[key, default: []].append(text)
            statuses[key] = "Superseded"
        }
        func isClosed(_ key: String) async -> Bool { closed.contains(key) }
    }

    struct BreakdownOnlyServices: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner,
                                  Decomposer, TestAuthor, Implementer {
        private func unexpected(_ operation: String) -> AgentFailure {
            Issue.record("A preview-adoption fixture unexpectedly attempted \(operation).")
            return AgentFailure("GH-168 unexpected \(operation)")
        }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL { throw unexpected("worktree creation") }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw unexpected("commit")
        }
        func head(of directory: URL) async throws -> String { throw unexpected("HEAD read") }
        func changedFiles(in directory: URL) async throws -> [String] { throw unexpected("changed-file read") }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { throw unexpected("rebase") }
        func abortRebase(_ directory: URL) async throws { throw unexpected("rebase abort") }
        func resetForRework(_ directory: URL) async throws { throw unexpected("rework") }
        func landOnMain(_ id: NodeID) async throws -> String { throw unexpected("landing") }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws { throw unexpected("build") }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact { throw unexpected("artifact write") }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("A preview-adoption fixture must not run checks.")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw unexpected("decomposition of an already approved preview")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { throw unexpected("test author") }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw unexpected("implementer") }
    }
}
