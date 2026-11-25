import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_88Tests {
    /// The round binds leaves to their requirement branch before it waits for running steps. A breakdown that
    /// finishes during that wait turns its ticket into a leaf, which must still start on its requirement branch.
    @Test
    func aLeafFromABreakdownThatFinishesMidRoundStartsOnItsRequirementBranch() async throws {
        let f = try LateLeafFixture()
        defer { f.cleanUp() }
        try await f.start()

        _ = await f.reconciler.runRound(waitForAgents: false)
        try await f.decomposer.asked.wait(for: "The breakdown starting")
        let report = await f.reconciler.runRound(waitForAgents: true)

        #expect(report.safeStop == nil, "\(report.safeStop ?? "")")
        let node = try #require(await f.ledger.workingState().nodes[LateLeafFixture.ticket.id])
        #expect(node.spec.kind == .leaf)
        #expect(node.flags[.escalated] == nil, "\(node.flags)")
        #expect(await f.workspace.operations.contains(.init(action: .start, node: node.id, branch: "agentos/GH-130")))
        #expect(await f.workspace.creations.map(\.branch) == ["agentos/GH-130"])
    }

    struct LateLeafFixture {
        static let ticket = NodeSpec(id: "wn-GH-130", parent: nil, kind: .composite, title: "Late leaf",
                                     intent: "One leaf", acceptanceCriteria: ["Starts on its requirement branch"])
        let root: URL
        let ledger: Ledger
        let workspace: RecordingWorkspace
        let decomposer = HeldDecomposer()
        let reconciler: Reconciler

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-88-late-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = RecordingWorkspace(root: root, allowsBreakdowns: true)
            var policy = Policy(maxParallelAgents: 4, guesswork: .autonomous)
            policy.avoidOverlappingWork = false
            reconciler = Reconciler(
                ledger: ledger, tracker: RecordingTracker(), external: External(), workspace: workspace,
                artifacts: Artifacts(), checks: RecordingChecks(workspace: workspace, diagnose: false),
                team: AgentTeam(name: "GH-88", decomposer: decomposer, testAuthor: Agents(), implementer: Agents()),
                policy: policy, requirementBranches: ReleasingRepository(release: decomposer.release)
            )
        }

        func start() async throws {
            try await ledger.append([
                LedgerEvent(node: Self.ticket.id, by: .human("Developer"), kind: .nodeCreated(spec: Self.ticket, ticket: "GH-130")),
                LedgerEvent(node: Self.ticket.id, by: .human("Developer"), kind: .gateOpened(.breakdown)),
                LedgerEvent(node: Self.ticket.id, by: .human("Developer"), kind: .gateOpened(.build)),
            ])
        }

        func cleanUp() {
            do { try FixtureFolder.remove(root) }
            catch { Issue.record("Could not remove the GH-88 fixture: \(error)") }
        }
    }

    /// Proposes the ticket itself as its only child (built as one leaf), once the test lets it finish.
    final class HeldDecomposer: Decomposer {
        let asked = TestGate()
        let release = TestGate()
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            asked.open()
            try await release.wait(for: "The round letting the breakdown finish")
            return Breakdown(children: [ChildProposal(title: request.spec.title,
                                                      acceptanceCriteria: request.spec.acceptanceCriteria)])
        }
    }

    /// Reading the default branch happens after the round bound leaves to requirement branches, and before it waits
    /// for running steps: the breakdown finishes in between.
    struct ReleasingRepository: RequirementBranchRepository {
        let release: TestGate
        var defaultBranch: String { "main" }
        func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
        func tip(of branch: String) async throws -> String? {
            guard branch == defaultBranch else { return nil }
            release.open()
            return "main-0"
        }
        func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool { true }
        func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult { .clean }
        func changedFiles(in commit: String) async throws -> [String] { [] }
    }
}
