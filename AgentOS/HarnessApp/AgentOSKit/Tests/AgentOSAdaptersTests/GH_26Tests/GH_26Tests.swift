// API contract: Reconciler.runRound(waitForAgents: true) diagnoses other proven tickets' landing failures by checking
// Workspace.createSnapshot() (latest landing main, without the change) and rechecking the candidate.
// CheckRunner supplies named failures in CheckOutput.log; tracker comments expose both rerun summaries.

import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_26Tests {
    @Test
    func otherProvenTicketsTestsAreCheckedOnLatestMainBeforeAConflictIsDeclared() async throws {
        let fixture = try await Fixture(mainPasses: true, candidatePasses: false)
        defer { fixture.cleanUp() }

        let round = await fixture.reconciler.runRound(waitForAgents: true)

        #expect(round.safeStop == nil)
        let calls = await fixture.checks.calls
        let baseline = calls.filter { $0.directory == fixture.workspace.snapshot }
        #expect(!baseline.isEmpty, "A failure in another proven ticket is not itself proof of a conflict")
        for owner in Fixture.owners {
            #expect(baseline.contains {
                $0.selection == nil || $0.selection?.contains(owner.testTarget) == true
            }, "Rerun the failing tests of \(owner.testTarget) without the candidate")
        }
        for call in baseline {
            #expect(call.commit == Fixture.latestMain)
            #expect(call.commit != Fixture.previousMain)
        }
        for call in calls.dropFirst() {
            #expect(!call.alreadyEscalated, "Diagnose before recording a requirements conflict")
            #expect(call.failedAttempts == 0, "Diagnostic runs must precede attempt attribution")
        }
        #expect(await fixture.workspace.preparedDirectories.contains(fixture.workspace.snapshot))
    }

    @Test(arguments: [false, true])
    func failuresAlsoPresentOnMainAreReportedWithoutARequirementsConflictOrFailedAttempt(
        candidatePasses: Bool
    ) async throws {
        let fixture = try await Fixture(mainPasses: false, candidatePasses: candidatePasses)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 0)
        #expect(node.flags[.escalated]?.lowercased().contains("requirements conflict") != true)
        let comments = await fixture.tracker.comments(on: Fixture.ticket)
        let report = comments.joined(separator: "\n")
        #expect(report.contains("agentos/main"))
        #expect(!report.lowercased().contains("requirements conflict:"))
        for name in Fixture.failedTests {
            #expect(report.contains(name), "Name the failing test, not just its owning ticket")
        }
        for owner in Fixture.owners {
            let otherComments = await fixture.tracker.comments(on: String(owner.id.dropFirst(3)))
            #expect(!otherComments.contains { $0.contains("contradicts this ticket") })
        }
    }

    @Test
    func passingMainAndARepeatedCandidateFailureEscalateAsARequirementsConflict() async throws {
        let fixture = try await Fixture(mainPasses: true, candidatePasses: false)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let calls = await fixture.checks.calls
        #expect(calls.contains { $0.directory == fixture.workspace.snapshot })
        #expect(calls.filter { $0.directory == fixture.workspace.candidate }.count >= 2)
        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.escalated])
        #expect(reason.lowercased().contains("requirements conflict"))
        #expect(node.phase != .proven)
        #expect(await fixture.workspace.landedNodes.isEmpty)
        for owner in Fixture.owners {
            #expect(reason.contains(String(owner.id.dropFirst(3))))
        }
    }

    @Test
    func passingBothRerunsReportsAnUnreliableTestAndLandsWithoutCountingAFailure() async throws {
        let fixture = try await Fixture(mainPasses: true, candidatePasses: true)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.phase == .proven)
        #expect(node.landedCommit == Fixture.candidateCommit)
        #expect(node.flags[.escalated] == nil)
        #expect(node.failedAttempts == 0)
        #expect(await fixture.workspace.landedNodes == [Fixture.spec.id])
        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        #expect(report.lowercased().contains("unreliable") || report.lowercased().contains("flaky"))
        for name in Fixture.failedTests {
            #expect(report.contains(name))
        }
        let state = await fixture.ledger.workingState()
        for owner in Fixture.owners {
            #expect(state.nodes[owner.id]?.phase == .proven)
            #expect(state.nodes[owner.id]?.landedCommit == Fixture.previousMain)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func everyDiagnosticReportNamesTheTestsAndBothRerunOutcomes(
        mainPasses: Bool, candidatePasses: Bool
    ) async throws {
        let fixture = try await Fixture(
            mainPasses: mainPasses,
            candidatePasses: candidatePasses
        )
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        for name in Fixture.failedTests {
            #expect(report.contains(name))
        }
        #expect(report.contains(fixture.mainRerun.summary))
        #expect(report.contains(fixture.candidateRerun.summary))
        let calls = await fixture.checks.calls
        #expect(calls.contains { $0.directory == fixture.workspace.snapshot })
        #expect(calls.filter { $0.directory == fixture.workspace.candidate }.count >= 2)
    }
}

private extension GH_26Tests {
    struct Fixture {
        static let ticket = "GH-26"
        static let previousMain = "previous-proven-agentos-main"
        static let latestMain = "latest-agentos-main"
        static let candidateCommit = "change-rebased-on-latest-agentos-main"
        static let spec = NodeSpec(
            id: "wn-GH-26", parent: nil, kind: .leaf, title: "Resize Changes",
            intent: "Resize a UI window", acceptanceCriteria: ["Changes can be resized"]
        )
        static let owners = [
            NodeSpec(
                id: "wn-GH-19", parent: nil, kind: .leaf, title: "Rerun landing",
                intent: "Rerun unchanged rework", acceptanceCriteria: ["Passing rework lands"]
            ),
            NodeSpec(
                id: "wn-GH-10", parent: nil, kind: .leaf, title: "Catch up main",
                intent: "Preserve landed work", acceptanceCriteria: ["Catch-up keeps landed work"]
            ),
        ]
        static let failedTests = [
            "GH_19Tests.passingLandingRerunLandsWithoutIncreasingFailedAttempts",
            "GH_10Tests.catchUpPreservesLandedWork",
        ]

        let root: URL
        let ledger: Ledger
        let tracker: RecordingTracker
        let workspace: RecordingWorkspace
        let checks: ScriptedChecks
        let reconciler: Reconciler
        let mainRerun: CheckOutput
        let candidateRerun: CheckOutput

        init(mainPasses: Bool, candidatePasses: Bool) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-26-\(UUID().uuidString)")
            let candidate = root.appending(path: "candidate")
            let snapshot = root.appending(path: "latest-main-without-change")
            let folder = candidate.appending(path: "Tests/AgentOSAdaptersTests/GH_26Tests")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try "// fixed acceptance tests\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            ledger = try Ledger()
            for owner in Self.owners {
                try await ledger.append([
                    LedgerEvent(node: owner.id, by: .human("Developer"), kind: .nodeCreated(
                        spec: owner, ticket: String(owner.id.dropFirst(3))
                    )),
                    LedgerEvent(node: owner.id, by: .reconciler, kind: .landed(commit: Self.previousMain)),
                    LedgerEvent(node: owner.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .nodeCreated(
                    spec: Self.spec, ticket: Self.ticket
                )),
                LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .testsFixed(
                    digest: Hashing.digest(of: folder)
                )),
                LedgerEvent(node: Self.spec.id, by: .agent(run: "builder", role: .implementer),
                            kind: .changeSubmitted(run: "builder", commit: Self.candidateCommit)),
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .landing)),
            ])
            tracker = RecordingTracker()
            workspace = RecordingWorkspace(candidate: candidate, snapshot: snapshot)
            mainRerun = Self.output(passed: mainPasses, context: "Rerun without the change on agentos/main")
            candidateRerun = Self.output(passed: candidatePasses, context: "Rerun with the change")
            checks = ScriptedChecks(
                workspace: workspace, ledger: ledger,
                initial: Self.output(passed: false, context: "Initial landing check"),
                mainRerun: mainRerun, candidateRerun: candidateRerun
            )
            let unused = UnusedAgents()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: unused, workspace: workspace,
                artifacts: MemoryArtifacts(), checks: checks,
                team: AgentTeam(name: "GH-26", decomposer: unused, testAuthor: unused, implementer: unused)
            )
        }

        static func output(passed: Bool, context: String) -> CheckOutput {
            let result = passed ? "PASS" : "FAIL"
            return CheckOutput(
                passed: passed,
                summary: "\(context): \(result)",
                log: failedTests.map { "\(result): \($0)" }.joined(separator: "\n"),
                failingTargets: passed ? [] : Set(owners.map(\.testTarget))
            )
        }

        func node() async -> NodeState? { await ledger.workingState().nodes[Self.spec.id] }

        func cleanUp() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove GH-26 fixture directory: \(error)")
            }
        }
    }

    actor ScriptedChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let selection: String?
            let commit: String
            let alreadyEscalated: Bool
            let failedAttempts: Int
        }

        let workspace: RecordingWorkspace
        let ledger: Ledger
        let initial: CheckOutput
        let mainRerun: CheckOutput
        let candidateRerun: CheckOutput
        private var candidateCalls = 0
        private(set) var calls: [Call] = []

        init(
            workspace: RecordingWorkspace, ledger: Ledger, initial: CheckOutput,
            mainRerun: CheckOutput, candidateRerun: CheckOutput
        ) {
            self.workspace = workspace
            self.ledger = ledger
            self.initial = initial
            self.mainRerun = mainRerun
            self.candidateRerun = candidateRerun
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            let node = await ledger.workingState().nodes[Fixture.spec.id]
            let commit = await workspace.head(of: directory)
            calls.append(Call(
                directory: directory, selection: testTarget, commit: commit,
                alreadyEscalated: node?.flags[.escalated] != nil,
                failedAttempts: node?.failedAttempts ?? 0
            ))
            if directory == workspace.snapshot { return mainRerun }
            guard directory == workspace.candidate else {
                Issue.record("Unexpected diagnostic checkout: \(directory)")
                return CheckOutput(passed: false, summary: "Unexpected checkout", log: directory.path)
            }
            candidateCalls += 1
            return candidateCalls == 1 ? initial : candidateRerun
        }
    }

    actor RecordingWorkspace: Workspace {
        nonisolated let candidate: URL
        nonisolated let snapshot: URL
        private(set) var preparedDirectories: [URL] = []
        private(set) var landedNodes: [NodeID] = []

        init(candidate: URL, snapshot: URL) {
            self.candidate = candidate
            self.snapshot = snapshot
        }

        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { candidate }
        func createWorktree(for id: NodeID) async throws -> URL { candidate }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            Fixture.candidateCommit
        }
        func head(of directory: URL) -> String {
            directory == snapshot ? Fixture.latestMain : Fixture.candidateCommit
        }
        func changedFiles(in directory: URL) async throws -> [String] { ["App/Changes.swift"] }
        nonisolated var testArea: String { "Tests/AgentOSAdaptersTests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            landedNodes.append(id)
            return Fixture.candidateCommit
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws { preparedDirectories.append(directory) }
        func createSnapshot() async throws -> URL? { snapshot }
        func removeSnapshot(_ directory: URL) async {}
    }

    actor RecordingTracker: TrackerAdapter {
        private var recorded: [String: [String]] = [:]
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key, title: key, description: key,
                acceptanceCriteria: ["Preserve proven behaviour"], createdBy: .human("Developer")
            )
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            Issue.record("Landing diagnostics must not create tickets")
            return "unexpected"
        }
        func comment(on key: String, _ text: String) { recorded[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) {}
        func comments(on key: String) -> [String] { recorded[key, default: []] }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct UnusedAgents: ExternalDependencySource, Decomposer, TestAuthor, AgentOSCore.Implementer {
        private enum UnexpectedRun: Error { case agentDispatched }
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw UnexpectedRun.agentDispatched
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw UnexpectedRun.agentDispatched
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw UnexpectedRun.agentDispatched
        }
    }
}
