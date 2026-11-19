import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_91Tests {
    static func roundFixture(enabled: Bool = true, finalChecksPass: Bool = true) async throws -> RoundFixture {
        let base = try await Self.fixture(enabled: enabled, lastLeafProven: false)
        try await base.ledger.append([
            LedgerEvent(node: base.root.id, by: .reconciler,
                        kind: .requirementBranchCreated(branch: base.branch, from: Self.oldCommit)),
            LedgerEvent(node: base.root.id, by: .reconciler, kind: .requirementBranchObserved(
                branch: base.branch, tip: Self.tip, main: Self.oldCommit, containedInMain: false)),
        ])
        let directory = FileManager.default.temporaryDirectory.appending(path: "GH-91-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkout = directory.appending(path: "requirement")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let config = RepoConfig(
            test: .init(command: "printf 'full checkout tests passed\\n'", only: "--only {suite}"),
            checks: [.init(name: "application check", command: finalChecksPass
                ? "printf 'application check passed\\n'"
                : "printf 'CheckoutTests.rejectsMissingAddress FAILED\\n'; exit 1")])
        return RoundFixture(
            base: base, directory: directory,
            workspace: RoundWorkspace(root: directory, checkout: checkout),
            checks: RoundChecks(runner: CommandCheckRunner(config: config)),
            publisher: PublicationRecorder(ledger: base.ledger, forwarding: base.publisher())
        )
    }

    static func verifyPublisherRecorder(_ fixture: RoundFixture) async throws {
        let probe = PublicationProbe()
        let recorder = PublicationRecorder(ledger: fixture.base.ledger, forwarding: probe)
        try await recorder.publish(requirement: fixture.identity, branch: fixture.base.branch, commit: Self.tip)
        try #require(await recorder.calls.count == 1)
        try #require(await probe.called, "The spy must forward calls before its absence assertions can be trusted.")
        #expect(await fixture.publisher.calls.isEmpty, "The probe must not exercise the production publisher.")
    }

    struct RoundFixture: Sendable {
        let base: Fixture
        let directory: URL
        let workspace: RoundWorkspace
        let checks: RoundChecks
        let publisher: PublicationRecorder
        let agents = RoundAgents()
        var identity: NodeIdentity { NodeIdentity(ticketKey: "GH-91", nodeID: base.root.id) }

        func makeReconciler(ledger replacement: Ledger? = nil) -> Reconciler {
            let ledger = replacement ?? base.ledger
            let recorder = replacement == nil ? publisher
                : PublicationRecorder(ledger: ledger, forwarding: base.publisher(ledger: ledger))
            return Reconciler(
                ledger: ledger, tracker: base.tracker, external: RoundExternal(),
                workspace: workspace, artifacts: FileArtifactStore(directory: directory.appending(path: "artifacts")),
                checks: checks,
                team: AgentTeam(name: "GH-91 no agent rework", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: GH_91Tests.policy(enabled: base.enabled).policy, publisher: recorder
            )
        }

        func settle(using alternative: Reconciler? = nil) async throws {
            let reconciler = alternative ?? makeReconciler()
            try await withHangGuard("GH-91 reconciler becoming idle") {
                while true {
                    try Task.checkCancellation()
                    let report = await reconciler.runRound(waitForAgents: true)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    if report.isIdle { return }
                }
            }
        }

        func proveLastLeaf() async throws {
            let leaf = try #require(base.leaves.last)
            try await base.ledger.append([
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .landed(commit: GH_91Tests.tip)),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            ])
        }

        func expectFinalVerification(passed: Bool) async throws -> Evidence {
            let call = try #require(GH_91Tests.single(await checks.calls))
            #expect(call.directory == workspace.checkout)
            #expect(call.suite == nil, "The reconciler must run the full configured checks.")
            let state = await base.ledger.workingState()
            let evidence = try #require(state.nodes[identity.nodeID]?.requirementVerification)
            #expect(evidence.passed == passed)
            #expect(evidence.commit == GH_91Tests.tip)
            let contents = try Data(contentsOf: URL(fileURLWithPath: evidence.artifactPath))
            #expect(Hashing.sha256(contents) == evidence.artifactSHA256)
            let log = String(decoding: contents, as: UTF8.self)
            #expect(log.contains("full checkout tests passed"))
            #expect(log.contains(passed ? "application check passed" : "CheckoutTests.rejectsMissingAddress FAILED"))
            return evidence
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-91 fixture files: \(error)") }
        }
    }

    actor PublicationRecorder: RequirementPublisher {
        struct Call: Sendable {
            let requirement: NodeIdentity
            let branch: String
            let commit: String
            let verification: Evidence?
            let allLeavesProven: Bool
        }
        let ledger: Ledger
        let forwarding: any RequirementPublisher
        private(set) var calls: [Call] = []
        init(ledger: Ledger, forwarding: any RequirementPublisher) {
            self.ledger = ledger
            self.forwarding = forwarding
        }
        func publish(requirement: NodeIdentity, branch: String, commit: String) async throws {
            let state = await ledger.workingState()
            let leaves = state.requirementLeaves(for: requirement.nodeID)
            calls.append(Call(
                requirement: requirement, branch: branch, commit: commit,
                verification: state.nodes[requirement.nodeID]?.requirementVerification,
                allLeavesProven: !leaves.isEmpty && leaves.allSatisfy { $0.phase == .proven }
            ))
            try await forwarding.publish(requirement: requirement, branch: branch, commit: commit)
        }
    }

    actor PublicationProbe: RequirementPublisher {
        private(set) var called = false
        func publish(requirement: NodeIdentity, branch: String, commit: String) async throws { called = true }
    }

    actor RoundChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let suite: String?
        }
        let runner: CommandCheckRunner
        nonisolated let started = TestGate()
        nonisolated let release = TestGate()
        private(set) var calls: [Call] = []
        init(runner: CommandCheckRunner) { self.runner = runner }
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            calls.append(Call(directory: directory, suite: suite))
            started.open()
            do { try await release.wait() }
            catch { return CheckOutput(passed: false, summary: "Check gate cancelled", log: "\(error)") }
            return await runner.runChecks(in: directory, only: suite)
        }
    }

    struct RoundWorkspace: Workspace {
        let root: URL
        let checkout: URL
        func prepare() async throws {}
        func requirementWorktree(for requirement: NodeIdentity) async throws -> URL { checkout }
        func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool { false }
        func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: "leaves/\(id)") }
        func head(of directory: URL) async throws -> String {
            directory == checkout ? GH_91Tests.tip : GH_91Tests.oldCommit
        }
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func prepareBuild(in directory: URL) async throws {}
        func existingComponents() -> [String] { [] }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func removeWorktree(for id: NodeID) async throws {}
        func abortRebase(_ directory: URL) async throws {}
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("Publication must not create another leaf worktree")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Publication must not write new implementation")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Publication must not rework proven leaves")
        }
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("Publication must not reset proven leaves")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("Publication must not land or merge work")
        }
    }

    actor RoundAgents: Decomposer, TestAuthor, Implementer {
        private(set) var calls: [AgentRole] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls.append(.decomposer)
            throw AgentFailure("Publication must not start decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.testAuthor)
            throw AgentFailure("Publication must not restart acceptance tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.implementer)
            throw AgentFailure("Publication must not start agent rework")
        }
    }

    struct RoundExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
