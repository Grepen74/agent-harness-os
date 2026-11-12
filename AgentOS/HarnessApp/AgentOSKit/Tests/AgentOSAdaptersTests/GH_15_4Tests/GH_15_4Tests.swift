// API contract: failed check evidence exposes a failureClassification, and ordinary failures are .ownMistake.

import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite
struct GH_15_4Tests {
    @Test
    func ordinaryFailuresAgainstUnchangedMainAreReportedAsOwnMistakes() async throws {
        let cases = [
            FailureCase(summary: "Tests failed: expected greeting", failingTargets: ["GH_15_4Tests"]),
            FailureCase(summary: "Compile failed: cannot find type Greeting"),
            FailureCase(summary: "Lint failed: forbidden API"),
            FailureCase(
                summary: "Changed protected files (not allowed): AGENTS.md",
                changedFiles: ["AGENTS.md"],
                protectedPaths: ["AGENTS.md"]
            ),
        ]

        for failure in cases {
            let fixture = try await Fixture(failure: failure, phase: .checking)

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let comment = try #require(await fixture.tracker.comments().last)
            #expect(comment.lowercased().contains("agent's own mistake"), "Comment for '\(failure.summary)': \(comment)")
            let evidence = try #require(await fixture.failedEvidence().last)
            #expect(evidence.failureClassification == .ownMistake)
            #expect(evidence.summary == failure.summary)
        }
    }

    @Test
    func ownMistakePreCheckAndLandingFailuresEachCountExactlyOnce() async throws {
        for phase in [Phase.checking, .landing] {
            let fixture = try await Fixture(
                failure: FailureCase(summary: "Tests failed", failingTargets: ["GH_15_4Tests"]),
                phase: phase
            )

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let node = try #require(await fixture.node())
            #expect(node.failedAttempts == 1, "\(phase.rawValue) failure counted \(node.failedAttempts) times")
            #expect(await fixture.failedEvidence().count == 1)
            #expect(await fixture.failedEvidence().first?.failureClassification == .ownMistake)
        }
    }

    @Test
    func ownMistakeFailuresStillEscalateAtTheAttemptLimit() async throws {
        for phase in [Phase.checking, .landing] {
            let fixture = try await Fixture(
                failure: FailureCase(summary: "Compile failed: missing symbol"),
                phase: phase,
                maxAttempts: 1
            )

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let node = try #require(await fixture.node())
            #expect(node.failedAttempts == 1)
            #expect(node.flags[.escalated]?.contains("Failed 1 times (limit 1)") == true)
            #expect(await fixture.tracker.comments().contains {
                $0.contains("Needs a human") && $0.contains("harness:retry")
            })
        }
    }
}

private struct FailureCase: Sendable {
    let summary: String
    var failingTargets: Set<String> = []
    var changedFiles: [String] = []
    var protectedPaths: [String] = []

    var output: CheckOutput {
        CheckOutput(passed: false, summary: summary, log: summary, failingTargets: failingTargets)
    }
}

private struct Fixture {
    static let spec = NodeSpec(
        id: "wn-GH-15.4",
        parent: nil,
        kind: .leaf,
        title: "Classify failures",
        intent: "Count only the agent's own mistakes",
        acceptanceCriteria: ["Ordinary failures are classified"]
    )

    let ledger: Ledger
    let tracker: RecordingTracker
    let reconciler: Reconciler

    init(failure: FailureCase, phase: Phase, maxAttempts: Int = 3) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-15-4-\(UUID().uuidString)")
        let testFolder = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_15_4Tests")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        try "fixed acceptance test".write(
            to: testFolder.appending(path: "acceptance.txt"),
            atomically: true,
            encoding: .utf8
        )

        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-15.4")),
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: testFolder))),
            LedgerEvent(
                node: Self.spec.id,
                by: .agent(run: "builder", role: .implementer),
                kind: .changeSubmitted(run: "builder", commit: "candidate")
            ),
            LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: phase)),
        ])

        let tracker = RecordingTracker()
        self.ledger = ledger
        self.tracker = tracker
        self.reconciler = Reconciler(
            ledger: ledger,
            tracker: tracker,
            external: NoExternalDependencies(),
            workspace: StubWorkspace(directory: directory, changedFiles: failure.changedFiles),
            artifacts: MemoryArtifacts(),
            checks: StubChecks(output: failure.output),
            team: .init(
                name: "unused",
                decomposer: NoopDecomposer(),
                testAuthor: NoopTestAuthor(),
                implementer: NoopImplementer()
            ),
            policy: Policy(maxAttempts: maxAttempts, protectedPaths: failure.protectedPaths)
        )
    }

    func node() async -> NodeState? {
        await ledger.workingState().nodes[Self.spec.id]
    }

    func failedEvidence() async -> [Evidence] {
        await ledger.allRecords().compactMap { record in
            guard case .evidenceRecorded(let evidence) = record.event.kind, !evidence.passed else { return nil }
            return evidence
        }
    }
}

private actor RecordingTracker: TrackerAdapter {
    private var recordedComments: [String] = []

    func pendingSignals() -> [Signal] { [] }

    func ticket(_ key: String) -> Ticket? {
        Ticket(
            key: key,
            title: "Classify failures",
            description: "Count only the agent's own mistakes",
            acceptanceCriteria: ["Ordinary failures are classified"],
            createdBy: .human("Alice")
        )
    }

    func consume(_ signal: Signal, reply: String) {}

    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
        "unused"
    }

    func comment(on key: String, _ text: String) {
        recordedComments.append(text)
    }

    func setStatus(of key: String, to status: String) {}

    func comments() -> [String] {
        recordedComments
    }
}

private struct StubWorkspace: Workspace {
    let directory: URL
    let changedFilesResult: [String]

    init(directory: URL, changedFiles: [String]) {
        self.directory = directory
        self.changedFilesResult = changedFiles
    }

    func prepare() async throws {}
    func branch(for id: NodeID) -> String { "agentos/\(id)" }
    func worktree(for id: NodeID) -> URL { directory }
    func createWorktree(for id: NodeID) async throws -> URL { directory }
    func removeWorktree(for id: NodeID) async throws {}
    func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
    func head(of directory: URL) async throws -> String { "candidate" }
    func changedFiles(in directory: URL) async throws -> [String] { changedFilesResult }
    var testArea: String { "Tests/AgentOSAdaptersTests/" }
    func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_15_4Tests" }
    var agentContext: String { "" }
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
    func abortRebase(_ directory: URL) async throws {}
    func resetForRework(_ directory: URL) async throws {}
    func landOnMain(_ id: NodeID) async throws -> String { "landed" }
    func existingComponents() -> [String] { [] }
    func prepareBuild(in directory: URL) async throws {}
}

private struct StubChecks: CheckRunner {
    let output: CheckOutput

    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        output
    }
}

private struct MemoryArtifacts: ArtifactStore {
    func put(named name: String, contents: Data) throws -> StoredArtifact {
        StoredArtifact(path: name, sha256: Hashing.sha256(contents))
    }
}

private struct NoExternalDependencies: ExternalDependencySource {
    func deliveredKeys() async -> Set<String> { [] }
}

private struct NoopDecomposer: Decomposer {
    func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
        Breakdown(children: [])
    }
}

private struct NoopTestAuthor: TestAuthor {
    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
        AgentReport()
    }
}

private struct NoopImplementer: Implementer {
    func implement(_ task: AgentTask) async throws {}
}
