// Expected API: Reconciler.runRound(waitForAgents: false) schedules a round without awaiting
// running agents; Reconciler.waitForAgents() awaits their completed ledger/tracker effects.
// The explicit overload leaves existing parameterless runRound() callers' waiting contract alone.
import Foundation
import Testing
import AgentOSCore

@Suite struct GH_51Tests {
    @Test(.timeLimit(.minutes(1)))
    func agentsStartedInDifferentRoundsBothEscalateAndIdentifyTheOverlappingTicket() async throws {
        try await Self.withFixture { fixture in
            try await fixture.start(.first)
            try await fixture.start(.second)
            try await fixture.expectRunning([.first, .second])

            await fixture.fingerprint.change()
            await fixture.control(.first).release.open()
            await fixture.control(.second).release.open()
            await fixture.reconciler.waitForAgents()

            try await fixture.expectEscalated(.first, alongside: [.second])
            try await fixture.expectEscalated(.second, alongside: [.first])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [TicketID.first, .second])
    func aFinishedOverlappingTicketRemainsInTheLaterDiagnostic(_ finishesFirst: TicketID) async throws {
        try await Self.withFixture { fixture in
            try await fixture.start(.first)
            try await fixture.start(.second)
            await fixture.fingerprint.change()

            let finishesLater: TicketID = finishesFirst == .first ? .second : .first
            await fixture.control(finishesFirst).release.open()
            // This reply is posted after the first watch has ended and its runFinished is durable.
            try await fixture.control(finishesFirst).diagnostic.wait()
            try await fixture.expectEscalated(finishesFirst, alongside: [finishesLater])
            try await fixture.expectRunning([finishesLater])

            await fixture.control(finishesLater).release.open()
            await fixture.reconciler.waitForAgents()
            try await fixture.expectEscalated(finishesLater, alongside: [finishesFirst])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aWatchThatEndedBeforeEitherAffectedAgentStartedIsNotNamed() async throws {
        try await Self.withFixture { fixture in
            try await fixture.start(.earlier)
            await fixture.control(.earlier).release.open()
            await fixture.reconciler.waitForAgents()
            try await fixture.expectSubmittedWithoutEscalation(.earlier)

            try await fixture.start(.first)
            try await fixture.start(.second)
            await fixture.fingerprint.change()
            await fixture.control(.first).release.open()
            await fixture.control(.second).release.open()
            await fixture.reconciler.waitForAgents()

            try await fixture.expectEscalated(.first, alongside: [.second], excluding: [.earlier])
            try await fixture.expectEscalated(.second, alongside: [.first], excluding: [.earlier])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func laterRoundsPreserveLiveAndFinishedSpansChangedStateDetailsAndRetryGuidance() async throws {
        try await Self.withFixture { fixture in
            try await fixture.start(.first)
            try await fixture.start(.second)
            for _ in 0..<3 { try await fixture.round() }
            try await fixture.expectRunning([.first, .second])
            await fixture.fingerprint.change()

            await fixture.control(.second).release.open()
            try await fixture.control(.second).diagnostic.wait()
            try await fixture.expectEscalated(.second, alongside: [.first])

            // Another round must retain the finished span while the first watch still needs it.
            try await fixture.round()
            try await fixture.expectRunning([.first])
            await fixture.control(.first).release.open()
            await fixture.reconciler.waitForAgents()
            try await fixture.expectEscalated(.first, alongside: [.second])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangeAfterOneCompletionAffectsOnlyTheStillWatchedAgent() async throws {
        try await Self.withFixture { fixture in
            try await fixture.start(.first)
            try await fixture.start(.second)

            await fixture.control(.first).release.open()
            // Committing follows the final fingerprint comparison, so the first watch is over.
            try await fixture.control(.first).submitted.wait()
            await fixture.fingerprint.change()
            await fixture.control(.second).release.open()
            await fixture.reconciler.waitForAgents()

            try await fixture.expectSubmittedWithoutEscalation(.first)
            try await fixture.expectEscalated(.second, alongside: [.first])
        }
    }

    enum TicketID: String, CaseIterable, Sendable {
        case first = "GH-5101"
        case second = "GH-5102"
        case earlier = "GH-5100"

        var node: NodeID { "wn-\(rawValue)" }
    }

    private struct Control: Sendable {
        let started = Barrier()
        let release = Barrier()
        let diagnostic = Barrier()
        let submitted = Barrier()
    }

    private static func withFixture(_ exercise: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do {
            try await exercise(fixture)
        } catch {
            try await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    private struct Fixture: Sendable {
        let directory: URL
        let ledger: Ledger
        let reconciler: Reconciler
        let tracker: RecordingTracker
        let fingerprint: Fingerprint
        let controls: [TicketID: Control]
        let workspace: FakeWorkspace

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-51-\(UUID())")
            ledger = try Ledger()
            controls = Dictionary(uniqueKeysWithValues: TicketID.allCases.map { ($0, Control()) })
            fingerprint = Fingerprint()
            workspace = FakeWorkspace(directory: directory, fingerprint: fingerprint, controls: controls)
            tracker = RecordingTracker(controls: controls)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: workspace, artifacts: MemoryArtifacts(), checks: PassingChecks(),
                team: AgentTeam(name: "GH-51 controlled agents", decomposer: UnusedDecomposer(),
                                testAuthor: UnusedTestAuthor(), implementer: ControlledImplementer(controls: controls)),
                policy: Policy(maxParallelAgents: 2)
            )
        }

        func control(_ ticket: TicketID) -> Control { controls[ticket]! }

        func start(_ ticket: TicketID) async throws {
            let spec = NodeSpec(id: ticket.node, parent: nil, kind: .leaf, title: "Work on \(ticket.rawValue)",
                                intent: "Preserve attribution across rounds",
                                acceptanceCriteria: ["Do not change user git state"], touches: ["Product"])
            let folder = workspace.worktree(for: spec.id).appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixed acceptance fixture".utf8).write(to: folder.appending(path: "fixture.txt"))
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .nodeCreated(spec: spec, ticket: ticket.rawValue)),
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .gateOpened(.build)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: folder))),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            ])
            try await round()
            // Reaching the agent proves its initial fingerprint was taken before we mutate it.
            try await control(ticket).started.wait()
            try await expectRunning([ticket])
        }

        func round() async throws {
            let report = await reconciler.runRound(waitForAgents: false)
            #expect(report.safeStop == nil)
            try #require(report.safeStop == nil, "The fixture must reach agent scheduling.")
        }

        func expectRunning(_ tickets: [TicketID]) async throws {
            let state = await ledger.workingState()
            for ticket in tickets {
                let node = try #require(state.nodes[ticket.node])
                #expect(node.activeRun?.role == .implementer)
                #expect(node.flags[.escalated] == nil)
            }
        }

        func expectEscalated(_ ticket: TicketID, alongside others: [TicketID],
                             excluding excluded: [TicketID] = []) async throws {
            let node = try #require(await ledger.workingState().nodes[ticket.node])
            #expect(node.activeRun == nil)
            let reason = try #require(node.flags[.escalated])
            let comments = await tracker.comments(on: ticket)
            let diagnostic = try #require(comments.first { $0.contains("harness:retry") })
            #expect(reason.contains("outside agentos/"))
            #expect(diagnostic.contains("outside agentos/"))
            // The tracker reply's destination identifies the affected ticket; its body names the others.
            for other in others {
                #expect(reason.contains(other.rawValue))
                #expect(diagnostic.contains(other.rawValue))
            }
            for other in excluded {
                #expect(!reason.contains(other.rawValue))
                #expect(!diagnostic.contains(other.rawValue))
            }
            for changedName in Fingerprint.changedNames {
                #expect(reason.contains(changedName))
                #expect(diagnostic.contains(changedName))
            }
            #expect(diagnostic.contains("harness:retry"))
            #expect(diagnostic.contains("git reflog"))
            #expect(diagnostic.contains("git config --list"))
        }

        func expectSubmittedWithoutEscalation(_ ticket: TicketID) async throws {
            let node = try #require(await ledger.workingState().nodes[ticket.node])
            #expect(node.activeRun == nil)
            #expect(node.flags[.escalated] == nil)
            #expect(node.lastSubmission != nil)
            #expect(await tracker.comments(on: ticket).allSatisfy { !$0.contains("outside agentos/") })
        }

        func cleanup() async throws {
            for control in controls.values { await control.release.open() }
            await reconciler.waitForAgents()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// A one-shot, cancellation-aware barrier; ordering never depends on sleeps or task yields.
    private actor Barrier {
        private var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

        func wait() async throws {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if isOpen {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func open() {
            isOpen = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    private actor Fingerprint {
        static let changedNames = ["refs/heads/personal-work", "config", "hooks/pre-commit"]
        private var value = [
            "old-ref refs/heads/personal-work",
            "old-config config",
            "old-hook hooks/pre-commit",
        ]

        func read() -> [String] { value }
        func change() {
            value = [
                "new-ref refs/heads/personal-work",
                "new-config config",
                "new-hook hooks/pre-commit",
            ]
        }
    }

    private struct ControlledImplementer: Implementer {
        let controls: [TicketID: Control]

        func implement(_ task: AgentTask) async throws -> AgentReport {
            let ticket = try #require(TicketID(rawValue: task.identity.ticketKey))
            let control = try #require(controls[ticket])
            await control.started.open()
            try await control.release.wait()
            return AgentReport()
        }
    }

    private struct FakeWorkspace: Workspace {
        let directory: URL
        let fingerprint: Fingerprint
        let controls: [TicketID: Control]

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let control = try #require(controls.first { $0.key.node == directory.lastPathComponent }?.value)
            await control.submitted.open()
            return "candidate-\(directory.lastPathComponent)"
        }
        func head(of directory: URL) async throws -> String { "candidate-\(directory.lastPathComponent)" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed-\(id)" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func userGitState() async throws -> [String] { await fingerprint.read() }
    }

    private actor RecordingTracker: TrackerAdapter {
        let controls: [TicketID: Control]
        private var posted: [TicketID: [String]] = [:]

        init(controls: [TicketID: Control]) { self.controls = controls }
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: "Work on \(key)", description: "Preserve attribution across rounds",
                   acceptanceCriteria: ["Do not change user git state"], createdBy: .human("Morgan"))
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("GH-51 fixtures must not create child tickets")
        }
        func comment(on key: String, _ text: String) async {
            guard let ticket = TicketID(rawValue: key), let control = controls[ticket] else {
                Issue.record("Unexpected ticket \(key)")
                return
            }
            posted[ticket, default: []].append(text)
            if text.contains("harness:retry") { await control.diagnostic.open() }
        }
        func setStatus(of key: String, to status: String) {}
        func comments(on ticket: TicketID) -> [String] { posted[ticket, default: []] }
    }

    private struct UnusedDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-51 fixtures must start at implementation")
        }
    }

    private struct UnusedTestAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-51 fixtures already have fixed acceptance tests")
        }
    }

    private struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Passed", log: "Passed")
        }
    }
}
