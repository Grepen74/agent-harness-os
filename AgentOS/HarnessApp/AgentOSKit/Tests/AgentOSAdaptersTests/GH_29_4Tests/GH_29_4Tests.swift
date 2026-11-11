// API contract: harness:retest is a configurable human signal handled by Reconciler; it replaces an
// eligible leaf's worktree from the latest landing branch and passes subsequent ticket comments to TestAuthor.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_29_4Tests {
    @Test
    func enabledRetestIsOfferedAndAcceptedForEscalatedOrWaitingNodes() async throws {
        #expect(HarnessCommand.allCases.contains(.retest))
        #expect(HarnessSettings().offeredSignals.contains(.retest))

        for flag in [Flag.escalated, .needsInput] {
            let fixture = try await Fixture(flag: flag)
            _ = await fixture.reconciler.runRound()

            let reply = try #require(await fixture.tracker.replies().last)
            #expect(reply.contains("✅ harness:retest"))
            let node = try #require(await fixture.node())
            #expect(node.flags[flag] == nil)
            #expect(node.phase == .ready)
            fixture.cleanup()
        }
    }

    @Test
    func acceptedRetestPreservesTheNodeAndAttemptsWhileReplacingItsTestsFromLatestLanding() async throws {
        let fixture = try await Fixture(flag: .escalated)
        let before = try #require(await fixture.node())

        _ = await fixture.reconciler.runRound()

        let after = try #require(await fixture.node())
        #expect(after.spec == before.spec)
        #expect(after.ticket == before.ticket)
        #expect(after.failedAttempts == before.failedAttempts)
        #expect(after.testsDigest != before.testsDigest)
        #expect(fixture.workspace.operations() == [.removed, .created])

        let observation = try #require(await fixture.testAuthor.observations().first)
        #expect(observation.landingMarker == "latest landing branch")
        #expect(!observation.oldAcceptanceTestsWerePresent)
        fixture.cleanup()
    }

    @Test
    func commentsSinceTheLastHumanInputRequestAreFeedbackForTheNewTestAuthorRun() async throws {
        let fixture = try await Fixture(
            flag: .needsInput,
            feedback: ["Keep the public API synchronous.", "Cover the empty result as well."]
        )

        _ = await fixture.reconciler.runRound()

        let task = try #require(await fixture.testAuthor.tasks().first)
        let feedback = try #require(task.clarifications.last?.answer)
        #expect(feedback.contains("Keep the public API synchronous."))
        #expect(feedback.contains("Cover the empty result as well."))
        fixture.cleanup()
    }

    @Test
    func acceptedAndLandedRejectedRetestsAreAuditedAndExplainedOnTheTicket() async throws {
        let accepted = try await Fixture(flag: .escalated)
        _ = await accepted.reconciler.runRound()

        let acceptedEvents = await accepted.eventKinds()
        #expect(acceptedEvents.contains {
            if case .signalAccepted(_, .retest, _) = $0 { true } else { false }
        })
        #expect(acceptedEvents.contains {
            if case .phaseChanged(to: .specified) = $0 { true } else { false }
        })
        #expect(await accepted.tracker.replies().contains {
            $0.contains("✅ harness:retest") && $0.lowercased().contains("test author")
        })
        accepted.cleanup()

        let landed = try await Fixture(flag: nil, landed: true)
        _ = await landed.reconciler.runRound()

        let rejectedEvents = await landed.eventKinds()
        #expect(rejectedEvents.contains {
            if case .signalRejected(_, .retest, let reason) = $0 {
                reason.lowercased().contains("landed")
            } else {
                false
            }
        })
        #expect(await landed.tracker.replies().contains {
            $0.contains("❌ harness:retest") && $0.lowercased().contains("landed")
        })
        #expect(landed.workspace.operations().isEmpty)
        landed.cleanup()
    }

    @Test
    func repositorySignalConfigurationCanDisableRetest() async throws {
        let repo = RepoConfig(
            test: .init(command: "swift test"),
            signals: .init(disable: ["retest"])
        )
        let effective = EffectivePolicy.resolve(
            harness: HarnessSettings(),
            repo: repo,
            defaultBranch: "main"
        )
        #expect(!effective.policy.allowedSignals.contains(.retest))

        let fixture = try await Fixture(flag: .escalated, allowedSignals: effective.policy.allowedSignals)
        _ = await fixture.reconciler.runRound()

        #expect(await fixture.tracker.replies().contains {
            $0.contains("❌ harness:retest") && $0.contains("isn't enabled")
        })
        #expect(fixture.workspace.operations().isEmpty)
        fixture.cleanup()
    }
}

private struct TestAuthorObservation: Sendable {
    let landingMarker: String?
    let oldAcceptanceTestsWerePresent: Bool
}

private actor RecordingTestAuthor: TestAuthor {
    private var recordedTasks: [AgentTask] = []
    private var recordedObservations: [TestAuthorObservation] = []

    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
        recordedTasks.append(task)
        let marker = try? String(
            contentsOf: task.directory.appending(path: "landing-marker.txt"),
            encoding: .utf8
        )
        let oldTests = FileManager.default.fileExists(
            atPath: task.directory.appending(path: task.testFolder).appending(path: "OldTests.swift").path
        )
        recordedObservations.append(.init(
            landingMarker: marker,
            oldAcceptanceTestsWerePresent: oldTests
        ))
        let testFolder = task.directory.appending(path: task.testFolder)
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        try "import Testing\n@Test func recoveredTest() {}\n".write(
            to: testFolder.appending(path: "RecoveredTests.swift"),
            atomically: true,
            encoding: .utf8
        )
        return AgentReport()
    }

    func tasks() -> [AgentTask] {
        recordedTasks
    }

    func observations() -> [TestAuthorObservation] {
        recordedObservations
    }
}

private final class FreshLandingWorkspace: Workspace, @unchecked Sendable {
    enum Operation: Equatable {
        case removed
        case created
    }

    let directory: URL
    private let lock = NSLock()
    private var recordedOperations: [Operation] = []

    init(directory: URL) {
        self.directory = directory
    }

    func prepare() async throws {}
    func branch(for id: NodeID) -> String { "agentos/\(id)" }
    func worktree(for id: NodeID) -> URL { directory }

    func createWorktree(for id: NodeID) async throws -> URL {
        record(.created)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "latest landing branch".write(
            to: directory.appending(path: "landing-marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    func removeWorktree(for id: NodeID) async throws {
        record(.removed)
        let oldTest = directory.appending(path: testFolder(for: Fixture.spec)).appending(path: "OldTests.swift")
        if FileManager.default.fileExists(atPath: oldTest.path) {
            try FileManager.default.removeItem(at: oldTest)
        }
    }

    func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
        "fresh-tests-commit"
    }

    func head(of directory: URL) async throws -> String { "fresh-tests-commit" }
    func changedFiles(in directory: URL) async throws -> [String] {
        ["Tests/AgentOSAdaptersTests/GH_29_4Tests/RecoveredTests.swift"]
    }

    var testArea: String { "Tests/AgentOSAdaptersTests/" }
    func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_29_4Tests" }
    var agentContext: String { "" }
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
    func abortRebase(_ directory: URL) async throws {}
    func resetForRework(_ directory: URL) async throws {}
    func landOnMain(_ id: NodeID) async throws -> String { "landed" }
    func existingComponents() -> [String] { [] }
    func prepareBuild(in directory: URL) async throws {}

    private func record(_ operation: Operation) {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append(operation)
    }

    func operations() -> [Operation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }
}

private actor RetestTracker: TrackerAdapter {
    private let signal: Signal
    private var storedTicket: Ticket
    private var consumedReplies: [String] = []

    init(ticket: Ticket) {
        self.storedTicket = ticket
        self.signal = Signal(ticket: ticket.key, command: .retest, setBy: .human("Alice"))
    }

    func pendingSignals() -> [Signal] { [signal] }
    func ticket(_ key: String) -> Ticket? { key == storedTicket.key ? storedTicket : nil }

    func consume(_ signal: Signal, reply: String) {
        consumedReplies.append(reply)
    }

    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unused" }

    func comment(on key: String, _ text: String) {
        storedTicket.comments.append(Comment(author: .reconciler, text: text))
    }

    func setStatus(of key: String, to status: String) {
        storedTicket.status = status
    }

    func replies() -> [String] {
        consumedReplies
    }
}

private struct Fixture {
    static let spec = NodeSpec(
        id: "wn-GH-29.4",
        parent: nil,
        kind: .leaf,
        title: "Recover acceptance tests",
        intent: "Restart test authoring from fresh landing code",
        acceptanceCriteria: ["A human can request a retest"]
    )

    let directory: URL
    let ledger: Ledger
    let tracker: RetestTracker
    let workspace: FreshLandingWorkspace
    let testAuthor: RecordingTestAuthor
    let reconciler: Reconciler

    init(
        flag: Flag?,
        landed: Bool = false,
        feedback: [String] = ["Please rewrite these tests against the current landing branch."],
        allowedSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases)
    ) async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-29-4-\(UUID().uuidString)")
        let testFolder = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_29_4Tests")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        try "old tests".write(
            to: testFolder.appending(path: "OldTests.swift"),
            atomically: true,
            encoding: .utf8
        )

        var ticket = Ticket(
            key: "GH-29.4",
            title: Self.spec.title,
            description: Self.spec.intent,
            acceptanceCriteria: Self.spec.acceptanceCriteria,
            createdBy: .human("Alice")
        )
        ticket.comments = [
            Comment(author: .reconciler, text: "❓ Needs input: acceptance tests need human attention."),
        ] + feedback.map { Comment(author: .human("Alice"), text: $0) }

        let ledger = try Ledger()
        var events = [
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: ticket.key)),
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: testFolder))),
            LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            LedgerEvent(node: Self.spec.id, by: .agent(run: "old-builder", role: .implementer),
                        kind: .attemptFailed(summary: "Existing implementation failure")),
        ]
        if let flag {
            events.append(LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .flagSet(flag, reason: "Needs attention")))
        }
        if landed {
            events.append(LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .landed(commit: "landed-commit")))
            events.append(LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .proven)))
        }
        try await ledger.append(events)

        let tracker = RetestTracker(ticket: ticket)
        let workspace = FreshLandingWorkspace(directory: directory)
        let testAuthor = RecordingTestAuthor()
        self.ledger = ledger
        self.tracker = tracker
        self.workspace = workspace
        self.testAuthor = testAuthor
        self.reconciler = Reconciler(
            ledger: ledger,
            tracker: tracker,
            external: NoExternalDependencies(),
            workspace: workspace,
            artifacts: MemoryArtifacts(),
            checks: PassingChecks(),
            team: AgentTeam(
                name: "acceptance",
                decomposer: NoopDecomposer(),
                testAuthor: testAuthor,
                implementer: NoopImplementer()
            ),
            policy: Policy(allowedSignals: allowedSignals, guesswork: .autonomous)
        )
    }

    func node() async -> NodeState? {
        await ledger.workingState().nodes[Self.spec.id]
    }

    func eventKinds() async -> [EventKind] {
        await ledger.allRecords().map(\.event.kind)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct PassingChecks: CheckRunner {
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        CheckOutput(passed: true, summary: "Passed", log: "Passed")
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

private struct NoopImplementer: Implementer {
    func implement(_ task: AgentTask) async throws {}
}
