import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

/// GH-151: a leaf's working copy that git couldn't set up (on a busy machine) escalated the leaf as if its agent had
/// failed, used up a turn of the run budget, and lost the test draft the run had taken over.
@Suite
struct WorkspaceProblemTests {
    static let draft = ["Tests/Leaf/Acceptance.swift"]

    @Test
    func aTestAuthorWhoseWorkingCopyCantBeSetUpKeepsItsTurnAndDraftAndIsTriedAgainByItself() async throws {
        let clock = Clock()
        let f = try await Fixture(now: { clock.now })

        _ = await f.reconciler.runRound(waitForAgents: true)

        let escalated = try #require(await f.node())
        let reason = try #require(escalated.flags[.escalated])
        #expect(reason.contains("Workspace problem: git worktree ran out of time"))
        #expect(reason.contains("tried again by itself"))
        #expect(reason.contains("harness:retry"))
        #expect(escalated.agentRunsSinceHuman == 1, "Only the earlier run counts")
        #expect(escalated.testDraft == Self.draft, "The draft the run took over is still there for the next one")
        #expect(escalated.failedAttempts == 0)
        #expect(await f.workspace.forgottenDrafts == 0)

        clock.advance(600)
        _ = await f.reconciler.runRound(waitForAgents: true)

        let comments = await f.tracker.comments(on: Fixture.ticket)
        #expect(comments.contains { $0.contains("Trying again by itself (1 of 1)") })
        #expect(!comments.contains { $0.contains("run budget") }, "The workspace problem used up no turn")
        #expect(await f.workspace.worktreeAttempts == 2)
        let again = try #require(await f.node())
        #expect(again.flags[.escalated] != nil, "Failing again waits for a person: the waits ran out")
        #expect(again.agentRunsSinceHuman == 1)
        #expect(again.testDraft == Self.draft)
    }

    @Test
    func anImplementerWhoseWorkingCopyCantBeBroughtUpToDateIsNoFailedAttempt() async throws {
        let f = try await Fixture(now: { .now }, implementing: true)

        _ = await f.reconciler.runRound(waitForAgents: true)

        let node = try #require(await f.node())
        #expect(node.flags[.escalated]?.contains("Workspace problem: git rebase ran out of time") == true)
        #expect(node.phase == .ready)
        #expect(node.failedAttempts == 0)
        #expect(node.agentRunsSinceHuman == 0)
        #expect(await f.workspace.savedUnfinishedWork == 0,
                "Saving the worktree before the unfinished work is back would replace that work")
    }

    @Test
    func testsLeftUncommittedByARunThatHitAWorkspaceProblemAreKeptByTheNextRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agentos-GH151-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await Fixture(now: { .now }, afterCommitProblem: true, root: root)
        try FileManager.default.createDirectory(at: f.workspace.worktree(for: Fixture.spec.id), withIntermediateDirectories: true)

        _ = await f.reconciler.runRound(waitForAgents: true)

        #expect(await f.workspace.savedDrafts == 1)
        #expect(await f.workspace.forgottenDrafts == 0)
        #expect(try #require(await f.node()).testDraft == Self.draft)
    }

    struct Fixture {
        static let ticket = "GH151"
        static let spec = NodeSpec(id: "wn-GH151", parent: nil, kind: .leaf, title: "Leaf", intent: "Change",
                                   acceptanceCriteria: ["Works"], touches: ["Sources/Leaf.swift"])
        let ledger: Ledger
        let tracker = GH_104Tests.TrackerFake()
        let workspace: BusyWorkspace
        let reconciler: Reconciler

        init(now: @escaping @Sendable () -> Date, implementing: Bool = false, afterCommitProblem: Bool = false,
             root: URL = BusyWorkspace.nowhere) async throws {
            ledger = try Ledger()
            workspace = BusyWorkspace(root: root)
            var policy = Policy(maxParallelAgents: 1, guesswork: .autonomous)
            policy.maxAgentRuns = 2
            policy.infrastructureRetryDelays = [600]
            let unused = GH_104Tests.NoAgents()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: GH_104Tests.NoExternal(), workspace: workspace,
                artifacts: GH_104Tests.Artifacts(), checks: NoChecks(),
                team: AgentTeam(name: "GH151", decomposer: unused, testAuthor: unused, implementer: unused),
                policy: policy, now: now)
            await tracker.seed(Self.spec)
            if implementing {
                try await ledger.append([
                    LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .nodeCreated(spec: Self.spec, ticket: Self.ticket)),
                    LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .testsFixed(digest: "tests")),
                    LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
                    LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                ])
                return
            }
            let earlier = Participant.agent(run: "run-earlier", role: .testAuthor)
            if afterCommitProblem {
                // Its tests were written, then committing them ran out of time: they are still in the worktree.
                try await ledger.append([
                    LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .nodeCreated(spec: Self.spec, ticket: Self.ticket)),
                    LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                    LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .runStarted(run: "run-earlier", role: .testAuthor)),
                    LedgerEvent(node: Self.spec.id, by: earlier, kind: .runFinished(
                        run: "run-earlier", outcome: WorkspaceProblem("git commit ran out of time (120 seconds)").outcome)),
                ])
                return
            }
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .nodeCreated(spec: Self.spec, ticket: Self.ticket)),
                LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .runStarted(run: "run-earlier", role: .testAuthor)),
                LedgerEvent(node: Self.spec.id, by: earlier, kind: .runFinished(run: "run-earlier", outcome: "failed: tests don't build")),
                LedgerEvent(node: Self.spec.id, by: earlier, kind: .testDraftKept(run: "run-earlier", files: WorkspaceProblemTests.draft)),
            ])
        }

        func node() async -> NodeState? { await ledger.workingState().nodes[Self.spec.id] }
    }

    final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    struct NoChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("No checks run while the working copy can't be set up")
            return CheckOutput(passed: false, summary: "unexpected", log: "")
        }
    }

    /// Every working copy times out, as on a machine too busy for git.
    actor BusyWorkspace: Workspace {
        private(set) var worktreeAttempts = 0
        private(set) var forgottenDrafts = 0
        private(set) var savedDrafts = 0
        private(set) var savedUnfinishedWork = 0
        static let nowhere = URL(filePath: "/nonexistent/GH151")
        nonisolated let root: URL

        init(root: URL = nowhere) {
            self.root = root
        }

        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            worktreeAttempts += 1
            throw WorkspaceProblem("git worktree ran out of time (120 seconds)")
        }
        func forgetTestDraft(for id: NodeID) async throws { forgottenDrafts += 1 }
        func saveTestDraft(_ directory: URL, for id: NodeID) async throws -> [String] {
            savedDrafts += 1
            return WorkspaceProblemTests.draft
        }
        func saveUnfinishedWork(_ directory: URL, for id: NodeID) async throws -> [String] {
            savedUnfinishedWork += 1
            return []
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { "head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/Leaf" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw WorkspaceProblem("git rebase ran out of time (120 seconds)")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("GH151 never lands") }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func createSnapshot() async throws -> URL? { nil }
        func createSnapshot(for id: NodeID) async throws -> URL? { nil }
        func removeSnapshot(_ directory: URL) async {}
    }
}
