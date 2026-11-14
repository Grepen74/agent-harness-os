// Expected API: the existing public Reconciler initializer, runRound(waitForAgents:),
// waitForAgents(), and recoverAfterRestart(), observed through Ledger and protocol adapters.
// File layout, access levels, and move-only diffs require implementation review, not runtime tests.
import Foundation
import Testing
import AgentOSCore

@Suite struct GH_62Tests {
    @Test(.timeLimit(.minutes(1)))
    func noSignalCreatesNoWorkAndAnAgentCannotOpenHumanGates() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }

        let idle = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(idle.isIdle)
        #expect(await fixture.ledger.allRecords().isEmpty)

        await fixture.tracker.request(.go, by: .agent(run: "rogue", role: .implementer))
        let rejected = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(rejected.safeStop == nil)
        #expect(await fixture.ledger.workingState().nodes.isEmpty)
        #expect(await fixture.tracker.comments.contains {
            $0.text.contains("harness:go") && $0.text.contains("Only humans")
        })
        #expect(await fixture.author.calls == 0)
        #expect(await fixture.builder.calls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func previewCreatesNoNodesAndBreakdownReusesItsProposalWithoutAnotherDecomposerRun() async throws {
        let fixture = try Fixture(children: [
            ChildProposal(title: "Store a greeting", acceptanceCriteria: ["Greeting is stored"], touches: ["Storage"]),
            ChildProposal(title: "Show a greeting", acceptanceCriteria: ["Greeting is visible"], touches: ["Display"]),
        ])
        defer { fixture.removeFiles() }

        await fixture.tracker.request(.preview)
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        let previewState = await fixture.ledger.workingState()
        let preview = try #require(previewState.previews["GH-62"])
        #expect(previewState.nodes.isEmpty)
        #expect(await fixture.tracker.childCount == 0)
        #expect(await fixture.author.calls == 0)

        await fixture.tracker.request(.breakdown)
        let state = try await fixture.until { state in
            guard let root = state.node(forTicket: "GH-62") else { return false }
            return root.phase == .split && root.children.count == 2
        }
        let root = try #require(state.node(forTicket: "GH-62"))
        let children = root.children.compactMap { state.nodes[$0] }
        let normalize = { (specs: [NodeSpec]) in
            Set(specs.map { spec in
                var result = spec
                result.id = ""
                return result
            })
        }
        #expect(normalize(children.map(\.spec)) == normalize(preview.proposal))
        #expect(await fixture.decomposer.calls == 1)
        #expect(await fixture.tracker.childCount == 2)
        #expect(!state.hasGate(.build, at: root.id))
        #expect(await fixture.builder.calls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func authoredTestsWaitForHumanBuildThenIndependentChecksAndLandingProveTheLeaf() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.breakdown)
        let readyState = try await fixture.until {
            $0.node(forTicket: "GH-62")?.phase == .ready
        }
        let ready = try #require(readyState.node(forTicket: "GH-62"))
        #expect(ready.testsDigest != nil)
        #expect(ready.lastSubmission == nil)
        #expect(await fixture.author.calls == 1)
        #expect(await fixture.builder.calls == 0)
        #expect(await fixture.workspace.landed.isEmpty)
        #expect(await fixture.tracker.status("GH-62") == readyState.status(of: ready))

        await fixture.tracker.request(.build)
        let final = try await fixture.until {
            $0.node(forTicket: "GH-62")?.phase == .proven
        }
        let leaf = try #require(final.node(forTicket: "GH-62"))
        let submission = try #require(leaf.lastSubmission)
        #expect(leaf.landedCommit == "landed-\(leaf.id)")
        #expect(await fixture.workspace.landed == [leaf.id])
        #expect(await fixture.checks.targets.contains { $0 == leaf.spec.testTarget })
        #expect(await fixture.checks.targets.contains { $0 == nil })
        #expect(leaf.evidence.contains { $0.passed && $0.check == "own acceptance tests on branch" })
        #expect(leaf.evidence.contains { $0.passed && $0.check == "all tests on latest main (landing)" })
        #expect(leaf.evidence.allSatisfy {
            $0.builtBy == submission.run && $0.checkedBy != submission.run && $0.specHash == leaf.spec.specHash
        })
        #expect(await fixture.tracker.status("GH-62") == final.status(of: leaf))
        #expect(await fixture.tracker.comments.contains { $0.text.contains("Landed on main") })
        #expect(await fixture.ledger.verifyChain().isIntact)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReportedOwnBrokenTestReturnsToItsAuthorAndCanThenBeBuiltAndLanded() async throws {
        let fixture = try Fixture(brokenTest: BrokenTestReport(
            testName: "GH_62Tests.greeting", reason: "The expected greeting is contradictory."
        ))
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.go)
        let state = try await fixture.until { $0.node(forTicket: "GH-62")?.phase == .proven }
        let leaf = try #require(state.node(forTicket: "GH-62"))

        #expect(await fixture.author.calls == 2)
        #expect(await fixture.builder.calls == 2)
        #expect(await fixture.author.feedback.contains {
            $0?.contains("The expected greeting is contradictory.") == true
        })
        #expect(leaf.brokenTestReports.contains { $0.testName == "GH_62Tests.greeting" })
        #expect(leaf.flags[.needsInput] == nil)
        #expect(await fixture.tracker.comments.contains { $0.text.contains("sent back to the test author") })
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherSuitesBrokenTestWaitsForAPersonInsteadOfBeingRewritten() async throws {
        let fixture = try Fixture(brokenTest: BrokenTestReport(
            testName: "OtherTests.greeting", reason: "An existing requirement disagrees."
        ))
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.go)
        let state = try await fixture.until { $0.node(forTicket: "GH-62")?.flags[.needsInput] != nil }
        let leaf = try #require(state.node(forTicket: "GH-62"))

        #expect(leaf.phase == .ready)
        #expect(leaf.flags[.needsInput]?.contains("OtherTests.greeting") == true)
        #expect(leaf.flags[.needsInput]?.contains("harness:retry") == true)
        #expect(await fixture.author.calls == 1)
        #expect(await fixture.workspace.landed.isEmpty)
        #expect(await fixture.tracker.comments.contains {
            $0.text.contains("neither the implementer nor the test author may change it")
        })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedChecksOrChangedAcceptanceTestsCannotReachMain(changesTests: Bool) async throws {
        let fixture = try Fixture(changesTests: changesTests, checksPass: changesTests,
                                  policy: Policy(maxAttempts: 1))
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.go)
        let state = try await fixture.until { $0.node(forTicket: "GH-62")?.flags[.escalated] != nil }
        let leaf = try #require(state.node(forTicket: "GH-62"))
        let failure = try #require(leaf.evidence.last)

        #expect(leaf.phase == .ready)
        #expect(leaf.landedCommit == nil)
        #expect(leaf.failedAttempts == 1)
        #expect(!failure.passed)
        #expect(failure.builtBy != failure.checkedBy)
        #expect(failure.failureClassification == .ownMistake)
        #expect(await fixture.workspace.landed.isEmpty)
        if changesTests {
            #expect(failure.summary.contains("Acceptance tests were changed"))
            #expect(await fixture.checks.targets.isEmpty)
        } else {
            #expect(failure.summary.contains("fixture check failure"))
            #expect(await fixture.checks.targets.contains { $0 == leaf.spec.testTarget })
        }
        #expect(await fixture.tracker.status("GH-62") == state.status(of: leaf))
    }

    @Test(.timeLimit(.minutes(1)))
    func aLandingConflictReworksImplementationWithoutRewritingTestsOrCountingAFailedAttempt() async throws {
        let fixture = try Fixture(conflictOnce: true)
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.go)
        let state = try await fixture.until { $0.node(forTicket: "GH-62")?.phase == .proven }
        let leaf = try #require(state.node(forTicket: "GH-62"))

        #expect(leaf.reworks == 1)
        #expect(leaf.failedAttempts == 0)
        #expect(await fixture.author.calls == 1)
        #expect(await fixture.builder.calls == 2)
        #expect(await fixture.workspace.landed == [leaf.id])
        #expect(await fixture.tracker.comments.contains {
            $0.text.contains("Sources/Greeting.swift") && $0.text.contains("tests are kept")
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func restartRecoveryExpiresAnOrphanedClaimAndAllowsItsWorkToFinish() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.tracker.request(.breakdown)
        let ready = try await fixture.until { $0.node(forTicket: "GH-62")?.phase == .ready }
        let leaf = try #require(ready.node(forTicket: "GH-62"))
        try await fixture.ledger.append([
            LedgerEvent(node: leaf.id, by: .human("Alice"), kind: .gateOpened(.build)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .runStarted(run: "orphan", role: .implementer)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .building)),
        ])

        let recovered = await fixture.reconciler.recoverAfterRestart()
        let state = await fixture.ledger.workingState()
        #expect(recovered.contains { $0.contains("orphan") })
        #expect(state.nodes[leaf.id]?.activeRun == nil)
        #expect(state.nodes[leaf.id]?.phase == .ready)
        let final = try await fixture.until { $0.nodes[leaf.id]?.phase == .proven }
        #expect(final.nodes[leaf.id]?.lastSubmission?.run != "orphan")
        #expect(await fixture.ledger.verifyChain().isIntact)
    }
}

private extension GH_62Tests {
    final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let tracker = Tracker()
        let workspace: MemoryWorkspace
        let decomposer: Proposer
        let author = Author()
        let builder: Builder
        let checks: Checks
        let reconciler: Reconciler

        init(children: [ChildProposal] = [], brokenTest: BrokenTestReport? = nil,
             changesTests: Bool = false, checksPass: Bool = true, conflictOnce: Bool = false,
             policy: Policy = Policy()) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-62-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = MemoryWorkspace(root: root, conflictOnce: conflictOnce)
            decomposer = Proposer(children: children)
            builder = Builder(brokenTest: brokenTest, changesTests: changesTests)
            checks = Checks(passed: checksPass)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: workspace, artifacts: Artifacts(), checks: checks,
                team: AgentTeam(name: "GH-62", decomposer: decomposer, testAuthor: author, implementer: builder),
                policy: policy
            )
        }

        func until(_ predicate: (WorkingState) -> Bool) async throws -> WorkingState {
            // A safety bound, not a required round count: stop on the ledger outcome regardless of batching.
            for _ in 0..<100 {
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                await reconciler.waitForAgents()
                let state = await ledger.workingState()
                if predicate(state) { return state }
            }
            throw AgentFailure("Expected ledger outcome was not reached within 100 reconciliation rounds")
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH-62 fixture: \(error)") }
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private var statuses: [String: String] = [:]
        private(set) var comments: [AgentOSCore.Comment] = []
        private(set) var childCount = 0

        func request(_ command: HarnessCommand, by person: Participant = .human("Alice")) {
            signals.append(Signal(ticket: "GH-62", command: command, setBy: person))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            var ticket = Ticket(key: key, title: "Greeting", description: "Greet the user",
                                acceptanceCriteria: ["The greeting is visible"], createdBy: .human("Alice"))
            ticket.comments = comments
            return ticket
        }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(AgentOSCore.Comment(author: .reconciler, text: reply))
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            childCount += 1
            return "\(parent).\(childCount)"
        }
        func comment(on key: String, _ text: String) {
            comments.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { statuses[key] = status }
        func status(_ key: String) -> String? { statuses[key] }
    }

    actor Proposer: Decomposer {
        let children: [ChildProposal]
        private(set) var calls = 0
        init(children: [ChildProposal]) { self.children = children }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls += 1
            return Breakdown(children: children)
        }
    }

    actor Author: TestAuthor {
        private(set) var calls = 0
        private(set) var feedback: [String?] = []
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls += 1
            feedback.append(task.previousFailure)
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// acceptance fixture revision \(calls)\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            return AgentReport()
        }
    }

    actor Builder: Implementer {
        private var brokenTest: BrokenTestReport?
        let changesTests: Bool
        private(set) var calls = 0
        init(brokenTest: BrokenTestReport?, changesTests: Bool) {
            self.brokenTest = brokenTest
            self.changesTests = changesTests
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls += 1
            if let report = brokenTest {
                brokenTest = nil
                return AgentReport(brokenTest: report)
            }
            if changesTests {
                try "// changed by implementer\n".write(
                    to: task.directory.appending(path: "\(task.testFolder)/Acceptance.swift"),
                    atomically: true, encoding: .utf8
                )
            }
            return AgentReport()
        }
    }

    actor MemoryWorkspace: Workspace {
        nonisolated let root: URL
        private var conflictOnce: Bool
        private var implementationDirectories: Set<URL> = []
        private var sequence = 0
        private(set) var landed: [NodeID] = []
        init(root: URL, conflictOnce: Bool) { self.root = root; self.conflictOnce = conflictOnce }
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
            if !message.hasSuffix(": acceptance tests") { implementationDirectories.insert(directory) }
            return "commit-\(sequence)"
        }
        func head(of directory: URL) async throws -> String { "commit-\(sequence)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            let suite = directory.lastPathComponent
                .replacingOccurrences(of: "wn-", with: "")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_") + "Tests"
            let own = "Tests/\(suite)/Acceptance.swift"
            return [own] + (implementationDirectories.contains(directory) ? ["Sources/Greeting.swift"] : [])
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            if conflictOnce, implementationDirectories.contains(directory) {
                conflictOnce = false
                return .conflict(files: ["Sources/Greeting.swift"])
            }
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws { implementationDirectories.remove(directory) }
        func landOnMain(_ id: NodeID) async throws -> String {
            landed.append(id)
            return "landed-\(id)"
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor Checks: CheckRunner {
        let passed: Bool
        private(set) var targets: [String?] = []
        init(passed: Bool) { self.passed = passed }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            targets.append(testTarget)
            return CheckOutput(passed: passed, summary: passed ? "passed" : "fixture check failure",
                               log: "fixture check output")
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
