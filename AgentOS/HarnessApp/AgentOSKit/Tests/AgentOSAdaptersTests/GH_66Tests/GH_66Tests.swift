// Expected API: the existing public Reconciler initializer, runRound overloads,
// waitForAgents overloads, recoverAfterRestart(), and shutdown(reason:).
// These are compatibility tests, not proof of the split: file sizes, responsibility
// boundaries, access levels, move-only edits, and scheduling the refactor require review.
import Foundation
import Testing
import AgentOSCore

@Suite struct GH_66Tests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func bothRoundModesPreserveHumanGatesChecksLandingAndStatus(waiting: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }

        await fixture.tracker.request(.breakdown)
        let ready = try await fixture.until(waiting: waiting) {
            $0.node(forTicket: "GH-66")?.phase == .ready
        }
        let leaf = try #require(ready.node(forTicket: "GH-66"))
        #expect(leaf.testsDigest != nil)
        #expect(!ready.hasGate(.build, at: leaf.id))
        #expect(await fixture.agents.implementations == 0)
        #expect(await fixture.workspace.landed.isEmpty)
        // A nonwaiting round may project status before its agents finish; publish the drained state.
        let readyProjection = await fixture.reconciler.runRound(waitForAgents: true)
        try #require(readyProjection.safeStop == nil)
        #expect(await fixture.tracker.status == ready.status(of: leaf))

        await fixture.tracker.request(.build)
        let final = try await fixture.until(waiting: waiting) {
            $0.node(forTicket: "GH-66")?.phase == .proven
        }
        let proven = try #require(final.nodes[leaf.id])
        let submission = try #require(proven.lastSubmission)
        #expect(await fixture.agents.authored == 1)
        #expect(await fixture.agents.implementations == 1)
        #expect(await fixture.workspace.landed == [leaf.id])
        #expect(proven.landedCommit == "landed-\(leaf.id)")
        #expect(proven.evidence.contains {
            $0.passed && $0.check == "own acceptance tests on branch"
        })
        #expect(proven.evidence.contains {
            $0.passed && $0.check == "all tests on latest main (landing)"
        })
        #expect(proven.evidence.allSatisfy {
            $0.builtBy == submission.run && $0.checkedBy != submission.run
                && $0.specHash == proven.spec.specHash
        })
        let finalProjection = await fixture.reconciler.runRound(waitForAgents: true)
        try #require(finalProjection.safeStop == nil)
        #expect(await fixture.tracker.status == final.status(of: proven))
        #expect(await fixture.tracker.comments.contains { $0.contains("Landed on main") })
        #expect(await fixture.reconciler.busyNodes.isEmpty)
        #expect(await fixture.ledger.verifyChain().isIntact)
    }

    @Test(.timeLimit(.minutes(1)))
    func previewRemainsUnadoptedAndItsStoredProposalIsReused() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }

        await fixture.tracker.request(.preview)
        let report = await fixture.reconciler.runRound(waitForAgents: true)
        try #require(report.safeStop == nil)
        let previewState = await fixture.ledger.workingState()
        let preview = try #require(previewState.previews["GH-66"])
        #expect(previewState.nodes.isEmpty)
        #expect(await fixture.agents.authored == 0)
        #expect(await fixture.agents.implementations == 0)

        await fixture.tracker.request(.breakdown)
        let adopted = try await fixture.until {
            $0.node(forTicket: "GH-66")?.phase == .ready
        }
        let node = try #require(adopted.node(forTicket: "GH-66"))
        let proposed = try #require(preview.proposal.first)
        #expect(node.spec.title == proposed.title)
        #expect(node.spec.acceptanceCriteria == proposed.acceptanceCriteria)
        #expect(node.spec.touches == proposed.touches)
        #expect(await fixture.agents.proposals == 1)
        #expect(!adopted.hasGate(.build, at: node.id))
    }

    @Test(.timeLimit(.minutes(1)))
    func restartRecoveryReclaimsAnOrphanAndPreservesAuthoredTests() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }

        await fixture.tracker.request(.breakdown)
        let ready = try await fixture.until {
            $0.node(forTicket: "GH-66")?.phase == .ready
        }
        let leaf = try #require(ready.node(forTicket: "GH-66"))
        try await fixture.ledger.append([
            LedgerEvent(node: leaf.id, by: .human("Reviewer"), kind: .gateOpened(.build)),
            LedgerEvent(node: leaf.id, by: .reconciler,
                        kind: .runStarted(run: "orphan-GH-66", role: .implementer)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .building)),
        ])

        let notes = await fixture.reconciler.recoverAfterRestart()
        let recovered = await fixture.ledger.workingState()
        #expect(notes.contains { $0.contains("orphan-GH-66") })
        #expect(recovered.nodes[leaf.id]?.activeRun == nil)
        #expect(recovered.nodes[leaf.id]?.phase == .ready)
        #expect(recovered.nodes[leaf.id]?.testsDigest == leaf.testsDigest)

        let final = try await fixture.until { $0.nodes[leaf.id]?.phase == .proven }
        #expect(final.nodes[leaf.id]?.lastSubmission?.run != "orphan-GH-66")
        #expect(await fixture.agents.authored == 1)
        #expect(await fixture.ledger.verifyChain().isIntact)
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownPreventsNewWorkInEitherRoundMode() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }

        await fixture.reconciler.shutdown(reason: "Harness closed")
        await fixture.tracker.request(.go)
        let asynchronous = await fixture.reconciler.runRound()
        let synchronous = await fixture.reconciler.runRound(waitForAgents: true)
        await fixture.reconciler.waitForAgents()
        await fixture.reconciler.waitForAgents(for: ["wn-GH-66"])

        #expect(asynchronous.safeStop == nil)
        #expect(synchronous.safeStop == nil)
        #expect(asynchronous.isIdle)
        #expect(synchronous.isIdle)
        #expect(await fixture.reconciler.busyNodes.isEmpty)
        #expect(await fixture.ledger.allRecords().isEmpty)
        #expect(await fixture.agents.proposals == 0)
        #expect(await fixture.agents.authored == 0)
        #expect(await fixture.agents.implementations == 0)
    }
}

private extension GH_66Tests {
    final class Fixture: Sendable {
        let directory: URL
        let ledger: Ledger
        let tracker = Tracker()
        let agents = Agents()
        let workspace: MemoryWorkspace
        let reconciler: Reconciler

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-66-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = MemoryWorkspace(root: directory)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: workspace, artifacts: Artifacts(), checks: Checks(),
                team: AgentTeam(name: "GH-66", decomposer: agents, testAuthor: agents, implementer: agents)
            )
        }

        func until(waiting: Bool = true, _ predicate: (WorkingState) -> Bool) async throws -> WorkingState {
            // Bound total progress, not the number or order of rounds needed by a particular scheduler.
            for _ in 0..<100 {
                let report = waiting
                    ? await reconciler.runRound(waitForAgents: true)
                    : await reconciler.runRound()
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                await reconciler.waitForAgents()
                let state = await ledger.workingState()
                if predicate(state) { return state }
            }
            throw AgentFailure("GH-66 fixture did not reach its expected ledger outcome")
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-66 fixture: \(error)") }
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        private(set) var status: String?

        func request(_ command: HarnessCommand) {
            signals.append(Signal(ticket: "GH-66", command: command, setBy: .human("Reviewer")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: "Greeting", description: "Greet the user",
                   acceptanceCriteria: ["The greeting is visible"], createdBy: .human("Reviewer"))
        }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("This fixture expects a single leaf, not child tickets")
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) { self.status = status }
    }

    actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var proposals = 0
        private(set) var authored = 0
        private(set) var implementations = 0

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            proposals += 1
            return Breakdown(children: [
                ChildProposal(title: request.spec.title,
                              acceptanceCriteria: request.spec.acceptanceCriteria, touches: ["Greeting"]),
            ])
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            authored += 1
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// fixture acceptance tests\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            return AgentReport()
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            implementations += 1
            return AgentReport()
        }
    }

    actor MemoryWorkspace: Workspace {
        nonisolated let root: URL
        private var sequence = 0
        private var implemented: Set<URL> = []
        private(set) var landed: [NodeID] = []

        init(root: URL) { self.root = root }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            sequence += 1
            if !message.hasSuffix(": acceptance tests") { implemented.insert(directory) }
            return "commit-\(sequence)"
        }
        func head(of directory: URL) async throws -> String { "commit-\(sequence)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            let suite = directory.lastPathComponent
                .replacingOccurrences(of: "wn-", with: "")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_") + "Tests"
            return ["Tests/\(suite)/Acceptance.swift"]
                + (implemented.contains(directory) ? ["Sources/Greeting.swift"] : [])
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws { implemented.remove(directory) }
        func landOnMain(_ id: NodeID) async throws -> String {
            landed.append(id)
            return "landed-\(id)"
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture checks passed", log: "ok")
        }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
