// API contract: CheckOutput distinguishes a runner crash from reported failures, and Reconciler retries
// that check once before recording non-attempt-counting runner-crash evidence and waiting for harness:retry.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_15_1Tests {
    @Test
    func preCheckAndLandingRunnerCrashesAreRerunExactlyOnce() async throws {
        for phase in [Phase.checking, .landing] {
            let crash = ScriptedChecks.Result.crash(signal: phase == .checking ? nil : 9)
            let fixture = try await Fixture(phase: phase, phaseResults: [crash, crash])

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            #expect(await fixture.checks.callCount(for: phase) == 2)
            #expect(await fixture.checks.callCount(for: phase == .checking ? .landing : .checking) == 0)
        }
    }

    @Test
    func passingRerunContinuesWithoutIncreasingFailedAttempts() async throws {
        for phase in [Phase.checking, .landing] {
            let fixture = try await Fixture(phase: phase, phaseResults: [.crash(), .pass])

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let node = try #require(await fixture.node())
            #expect(node.failedAttempts == 0)
            #expect(node.phase == .proven)
            #expect(node.landedCommit == "landed-commit")
            #expect(await fixture.checks.callCount(for: phase) == 2)
        }
    }

    @Test
    func repeatedCrashWaitsForAPersonAndDirectsThemToRetry() async throws {
        for phase in [Phase.checking, .landing] {
            let fixture = try await Fixture(phase: phase, phaseResults: [.crash(), .crash()])

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let node = try #require(await fixture.node())
            #expect(node.flags[.escalated]?.lowercased().contains("runner crash") == true)
            #expect(await fixture.tracker.status() == "Needs human")
            #expect(await fixture.tracker.comments().contains {
                $0.lowercased().contains("runner crash") && $0.contains("harness:retry")
            })
        }
    }

    @Test
    func repeatedCrashCommentIncludesLogTailInDetailsAndFullArtifactPath() async throws {
        let fixture = try await Fixture(phase: .checking, phaseResults: [.crash(), .crash()])

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let comment = try #require(await fixture.tracker.comments().last {
            $0.lowercased().contains("runner crash")
        })
        let details = try #require(Self.detailsBody(in: comment))
        let shownLogLines = details.split(separator: "\n").filter { $0.hasPrefix("runner log line ") }
        #expect((55...65).contains(shownLogLines.count))
        #expect(details.contains("runner log line 80"))
        #expect(!details.contains("runner log line 1\n"))

        let evidence = try #require(await fixture.crashEvidence().last)
        #expect(comment.contains(evidence.artifactPath))
        #expect(comment.contains("<details>"))
        #expect(comment.contains("</details>"))
    }

    @Test
    func repeatedCrashLedgerEvidencePreservesArtifactWithoutCountingAnAttempt() async throws {
        for phase in [Phase.checking, .landing] {
            let fixture = try await Fixture(phase: phase, phaseResults: [.crash(), .crash()])

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let node = try #require(await fixture.node())
            let evidence = try #require(await fixture.crashEvidence().last)
            #expect(evidence.failureClassification == .runnerCrash)
            #expect(evidence.artifactPath.hasPrefix("/app-storage/artifacts/"))
            #expect(!evidence.artifactSHA256.isEmpty)
            #expect(node.failedAttempts == 0)
            #expect(node.recentFailures.isEmpty)
        }
    }
}

private extension GH_15_1Tests {
    static func detailsBody(in comment: String) -> String? {
        guard let start = comment.range(of: "<details>"),
              let end = comment.range(of: "</details>", range: start.upperBound..<comment.endIndex)
        else {
            return nil
        }
        return String(comment[start.upperBound..<end.lowerBound])
    }

    struct Fixture {
        static let spec = NodeSpec(
            id: "wn-GH-15.1",
            parent: nil,
            kind: .leaf,
            title: "Retry runner crashes",
            intent: "Count only the agent's own mistakes as failed attempts",
            acceptanceCriteria: ["Runner crashes are retried once"]
        )

        let ledger: Ledger
        let tracker: RecordingTracker
        let checks: ScriptedChecks
        let reconciler: Reconciler

        init(phase: Phase, phaseResults: [ScriptedChecks.Result]) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-15-1-\(UUID().uuidString)")
            let testFolder = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_15_1Tests")
            try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
            try "fixed acceptance test".write(
                to: testFolder.appending(path: "acceptance.txt"),
                atomically: true,
                encoding: .utf8
            )

            let ledger = try Ledger()
            var events = [
                LedgerEvent(
                    node: Self.spec.id,
                    by: .human("Alice"),
                    kind: .nodeCreated(spec: Self.spec, ticket: "GH-15.1")
                ),
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
                LedgerEvent(
                    node: Self.spec.id,
                    by: .reconciler,
                    kind: .testsFixed(digest: Hashing.digest(of: testFolder))
                ),
                LedgerEvent(
                    node: Self.spec.id,
                    by: .agent(run: "builder", role: .implementer),
                    kind: .changeSubmitted(run: "builder", commit: "candidate")
                ),
            ]
            if phase == .landing {
                let evidence = Evidence(
                    check: "own acceptance tests on branch",
                    passed: true,
                    summary: "passed",
                    specHash: Self.spec.specHash,
                    builtBy: "builder",
                    checkedBy: "earlier-verifier",
                    artifactPath: "/app-storage/artifacts/pre-check.log",
                    artifactSHA256: "pre-check-sha",
                    commit: "candidate"
                )
                events.append(LedgerEvent(
                    node: Self.spec.id,
                    by: .agent(run: "earlier-verifier", role: .verifier),
                    kind: .evidenceRecorded(evidence)
                ))
            }
            events.append(LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: phase)))
            try await ledger.append(events)

            let tracker = RecordingTracker()
            let checks = ScriptedChecks(
                preCheckResults: phase == .checking ? phaseResults : [],
                landingResults: phase == .landing ? phaseResults : [.pass]
            )
            self.ledger = ledger
            self.tracker = tracker
            self.checks = checks
            self.reconciler = Reconciler(
                ledger: ledger,
                tracker: tracker,
                external: NoExternalDependencies(),
                workspace: StubWorkspace(directory: directory),
                artifacts: RecordingArtifacts(),
                checks: checks,
                team: .init(
                    name: "unused",
                    decomposer: NoopDecomposer(),
                    testAuthor: NoopTestAuthor(),
                    implementer: NoopImplementer()
                )
            )
        }

        func node() async -> NodeState? {
            await ledger.workingState().nodes[Self.spec.id]
        }

        func crashEvidence() async -> [Evidence] {
            await ledger.allRecords().compactMap { record in
                guard case .evidenceRecorded(let evidence) = record.event.kind,
                      evidence.failureClassification == .runnerCrash
                else {
                    return nil
                }
                return evidence
            }
        }
    }

    actor ScriptedChecks: CheckRunner {
        enum Result: Sendable {
            case pass
            case crash(signal: Int32? = nil)

            var output: CheckOutput {
                switch self {
                case .pass:
                    return CheckOutput(passed: true, summary: "tests passed", log: "tests passed\n")
                case .crash(let signal):
                    let termination = signal.map { "signal \($0)" } ?? "a process crash"
                    return CheckOutput(
                        passed: false,
                        summary: "test process terminated from \(termination)",
                        log: (1...80).map { "runner log line \($0)" }.joined(separator: "\n") + "\n",
                        failureKind: .runnerCrash(signal: signal)
                    )
                }
            }
        }

        private var preCheckResults: [Result]
        private var landingResults: [Result]
        private var preCheckCalls = 0
        private var landingCalls = 0

        init(preCheckResults: [Result], landingResults: [Result]) {
            self.preCheckResults = preCheckResults
            self.landingResults = landingResults
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            if testTarget == nil {
                landingCalls += 1
                return landingResults.removeFirst().output
            }
            preCheckCalls += 1
            return preCheckResults.removeFirst().output
        }

        func callCount(for phase: Phase) -> Int {
            phase == .checking ? preCheckCalls : landingCalls
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var recordedComments: [String] = []
        private var recordedStatus = ""

        func pendingSignals() -> [Signal] { [] }

        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key,
                title: "Retry runner crashes",
                description: "Count only agent mistakes",
                acceptanceCriteria: ["Runner crashes are retried once"],
                createdBy: .human("Alice")
            )
        }

        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unused" }

        func comment(on key: String, _ text: String) {
            recordedComments.append(text)
        }

        func setStatus(of key: String, to status: String) {
            recordedStatus = status
        }

        func comments() -> [String] { recordedComments }
        func status() -> String { recordedStatus }
    }

    struct StubWorkspace: Workspace {
        let directory: URL

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
        func head(of directory: URL) async throws -> String { "candidate" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_15_1Tests" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed-commit" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct RecordingArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(
                path: "/app-storage/artifacts/\(name)",
                sha256: Hashing.sha256(contents)
            )
        }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct NoopDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [])
        }
    }

    struct NoopTestAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            AgentReport()
        }
    }

    struct NoopImplementer: Implementer {
        func implement(_ task: AgentTask) async throws {}
    }
}
