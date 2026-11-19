@testable import AgentOSCore
import Foundation
import Testing

/// Another requirement's proven work landed only on its own requirement branch. Work that depends on it waits until
/// it's where that work starts (`main`, merged), or it would be built without it.
@Suite
struct CrossRequirementDependencyTests {
    @Test
    func workThatDependsOnAnotherRequirementWaitsUntilThatWorkIsMergedIntoMain() async throws {
        let fixture = try await Fixture()

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let waiting = try #require(await fixture.node(Fixture.dependent.id))
        #expect(waiting.flags[.blocked]?.contains("GH-5 to be merged into main") == true)
        // Only the latest landing: it has the earlier one, which on its own could conflict with a squash.
        #expect(await fixture.workspace.questions.map(\.commit) == [Fixture.landed])
        #expect(await fixture.workspace.questions.allSatisfy { $0.branch == nil })
        #expect(await fixture.agents.implemented.isEmpty)

        await fixture.workspace.merge()
        _ = await fixture.reconciler.runRound(waitForAgents: true)

        #expect(try #require(await fixture.node(Fixture.dependent.id)).flags[.blocked] == nil)
        #expect(await fixture.tracker.comments(on: "GH-7").contains { $0.contains("Unblocked") })
    }

    @Test
    func workProvenSinceTheLastCheckCountsAsNotMergedYet() async throws {
        let fixture = try await Fixture()
        let state = await fixture.ledger.workingState()
        let dependent = try #require(state.nodes[Fixture.dependent.id])

        #expect(await fixture.reconciler.unresolvedDependencies(of: dependent, in: state) == ["GH-5 to be merged into main"])
    }

    @Test
    func aDependencyWithinTheSameRequirementNeedsOnlyToBeProven() async throws {
        let fixture = try await Fixture(sameRequirement: true)

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let dependent = try #require(await fixture.node(Fixture.dependent.id))
        #expect(dependent.flags[.blocked]?.contains("merged into main") != true)
        #expect(await fixture.workspace.questions.isEmpty)
    }

    private struct Fixture {
        static let earlier = "c4"
        static let landed = "c5"
        static let requirement = NodeSpec(id: "wn-GH-1", parent: nil, kind: .composite, title: "Requirement",
                                          intent: "Both parts", acceptanceCriteria: ["Done"])
        static let dependency = NodeSpec(id: "wn-GH-5", parent: nil, kind: .composite, title: "Dependency",
                                         intent: "Land first", acceptanceCriteria: ["Exists"])
        static let parts = ["wn-GH-5.1", "wn-GH-5.2"].map {
            NodeSpec(id: $0, parent: dependency.id, kind: .leaf, title: $0, intent: "Part", acceptanceCriteria: ["Exists"])
        }
        static let dependent = NodeSpec(id: "wn-GH-7", parent: nil, kind: .leaf, title: "Dependent",
                                        intent: "Build on GH-5", acceptanceCriteria: ["Uses it"], dependsOn: ["GH-5"])

        let ledger: Ledger
        let tracker: RecordingTracker
        let workspace: MergeWorkspace
        let agents: RecordingAgents
        let reconciler: Reconciler

        init(sameRequirement: Bool = false) async throws {
            var dependency = Self.dependency
            var dependent = Self.dependent
            let ledger = try Ledger()
            if sameRequirement {
                dependency.parent = Self.requirement.id
                dependent.parent = Self.requirement.id
                try await ledger.append([
                    LedgerEvent(node: Self.requirement.id, by: .human("Alice"),
                                kind: .nodeCreated(spec: Self.requirement, ticket: "GH-1")),
                    LedgerEvent(node: Self.requirement.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
                    LedgerEvent(node: Self.requirement.id, by: .human("Alice"), kind: .gateOpened(.build)),
                ])
            }
            try await ledger.append([
                LedgerEvent(node: Self.dependency.id, by: .human("Alice"),
                            kind: .nodeCreated(spec: dependency, ticket: "GH-5")),
                LedgerEvent(node: Self.dependency.id, by: .reconciler,
                            kind: .requirementBranchCreated(branch: "agentos/GH-5", from: "m0")),
            ])
            for part in Self.parts {
                try await ledger.append([
                    LedgerEvent(node: part.id, by: .reconciler, kind: .nodeCreated(spec: part, ticket: part.id)),
                ])
            }
            // The second part landed first; the first part's landing has it.
            for (part, commit) in zip(Self.parts.reversed(), [Self.earlier, Self.landed]) {
                try await ledger.append([
                    LedgerEvent(node: part.id, by: .reconciler, kind: .landed(commit: commit)),
                    LedgerEvent(node: part.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            try await ledger.append([
                LedgerEvent(node: Self.dependency.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                LedgerEvent(node: dependent.id, by: .human("Alice"), kind: .nodeCreated(spec: dependent, ticket: "GH-7")),
                LedgerEvent(node: dependent.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
                LedgerEvent(node: dependent.id, by: .human("Alice"), kind: .gateOpened(.build)),
                LedgerEvent(node: dependent.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            ])
            let tracker = RecordingTracker()
            let workspace = MergeWorkspace()
            let agents = RecordingAgents()
            self.ledger = ledger
            self.tracker = tracker
            self.workspace = workspace
            self.agents = agents
            self.reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: agents, workspace: workspace, artifacts: MemoryArtifacts(),
                checks: PassingChecks(),
                team: AgentTeam(name: "dependencies", decomposer: agents, testAuthor: agents, implementer: agents)
            )
        }

        func node(_ id: NodeID) async -> NodeState? { await ledger.workingState().nodes[id] }
    }

    /// Has the landed commit nowhere but its own requirement branch until `merge()`.
    private actor MergeWorkspace: Workspace {
        struct Question: Sendable { let branch: String?; let commit: String }
        private var merged = false
        private(set) var questions: [Question] = []

        func merge() { merged = true }
        func branch(_ branch: String?, hasEverythingIn commit: String) -> Bool {
            questions.append(Question(branch: branch, commit: commit))
            return merged
        }

        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { FileManager.default.temporaryDirectory }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { "head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    private actor RecordingTracker: TrackerAdapter {
        private var recorded: [String: [String]] = [:]
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: key, description: key, acceptanceCriteria: ["Works"], createdBy: .human("Alice"))
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unexpected" }
        func comment(on key: String, _ text: String) { recorded[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) {}
        func comments(on key: String) -> [String] { recorded[key, default: []] }
    }

    /// Records which nodes got an implementer; every agent run then stops, which is all these tests need.
    private actor RecordingAgents: ExternalDependencySource, Decomposer, TestAuthor, AgentOSCore.Implementer {
        private struct Stopped: Error {}
        private(set) var implemented: [NodeID] = []
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown { throw Stopped() }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { throw Stopped() }
        func implement(_ task: AgentTask) async throws {
            implemented.append(task.spec.id)
            throw Stopped()
        }
    }

    private struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "PASS", log: "")
        }
    }

    private struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
