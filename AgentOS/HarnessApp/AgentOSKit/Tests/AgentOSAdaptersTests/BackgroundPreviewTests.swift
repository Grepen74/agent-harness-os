// harness:preview runs its decomposer in the background, in one of the agent slots: the label is acknowledged at
// once, rounds go on meanwhile, the run is listed as running, can be stopped, and its result follows on the ticket.
import Foundation
import Testing
import AgentOSCore

@Suite struct BackgroundPreviewTests {
    @Test(.timeLimit(.minutes(1)))
    func aPreviewIsAcknowledgedAtOnceAndItsResultFollowsWhenDone() async throws {
        let fixture = try Fixture(slots: 2)
        await fixture.tracker.request(.preview, on: "GH-1")

        let report = await fixture.reconciler.runRound()
        #expect(report.hasRunningAgents)
        let acknowledgement = try #require(await fixture.tracker.comments(on: "GH-1").first)
        #expect(acknowledgement.hasPrefix("✅ harness:preview: previewing with test-model, reasoning effort xhigh (run-"))
        let running = try await fixture.eventually { $0.runningPreviews["GH-1"] }
        #expect(running.node == "wn-GH-1")
        #expect(running.settings == AgentRunSettings(model: "test-model", effort: "xhigh"))
        #expect(await fixture.ledger.workingState().previews["GH-1"] == nil)

        await fixture.agents.release()
        await fixture.reconciler.waitForAgents()
        let state = await fixture.ledger.workingState()
        #expect(state.previews["GH-1"]?.number == 1)
        #expect(state.runningPreviews.isEmpty)
        let comments = await fixture.tracker.comments(on: "GH-1")
        #expect(comments.first == acknowledgement)
        #expect(comments.last?.contains("🔍 Preview #1. Nothing has been created.") == true)
        #expect(comments.last?.contains("Proposed by test-model, reasoning effort xhigh (\(running.run))") == true)
        #expect(await fixture.reconciler.runRound().actions.contains("GH-1: preview → preview #1 posted"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPreviewTakesAnAgentSlotAndAnotherWaitsForIt() async throws {
        let fixture = try Fixture(slots: 1)
        await fixture.tracker.request(.preview, on: "GH-1")
        _ = await fixture.reconciler.runRound()
        _ = try await fixture.eventually { $0.runningPreviews["GH-1"] }

        await fixture.tracker.request(.preview, on: "GH-2")
        let waiting = await fixture.reconciler.runRound()
        #expect(waiting.actions.contains("GH-2: harness:preview waits for a free agent slot"))
        #expect(await fixture.tracker.isPending(.preview, on: "GH-2"))
        #expect(await fixture.tracker.comments(on: "GH-2").isEmpty)

        await fixture.agents.release()
        await fixture.reconciler.waitForAgents()
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(!(await fixture.tracker.isPending(.preview, on: "GH-2")))
        #expect(await fixture.ledger.workingState().previews["GH-2"]?.number == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondPreviewOfTheSameTicketIsRefusedWhileTheFirstRuns() async throws {
        let fixture = try Fixture(slots: 2)
        await fixture.tracker.request(.preview, on: "GH-1")
        _ = await fixture.reconciler.runRound()
        let running = try await fixture.eventually { $0.runningPreviews["GH-1"] }

        await fixture.tracker.request(.preview, on: "GH-1")
        _ = await fixture.reconciler.runRound()
        let refusal = try #require(await fixture.tracker.comments(on: "GH-1").last)
        #expect(refusal.hasPrefix("❌ harness:preview: A preview of this ticket is already running (\(running.run))."))
        #expect(await fixture.agents.proposals == 1)

        await fixture.agents.release()
        await fixture.reconciler.waitForAgents()
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingAPreviewTellsTheTicketAndFreesItsSlot() async throws {
        let fixture = try Fixture(slots: 1)
        await fixture.tracker.request(.preview, on: "GH-1")
        _ = await fixture.reconciler.runRound()
        let running = try await fixture.eventually { $0.runningPreviews["GH-1"] }
        _ = try await fixture.eventually { _ in await fixture.agents.proposals == 1 ? true : nil }

        try await fixture.reconciler.stopRun(running.run, by: "Reviewer")

        let state = await fixture.ledger.workingState()
        #expect(state.runningPreviews.isEmpty)
        #expect(state.previews["GH-1"] == nil)
        let notice = try #require(await fixture.tracker.comments(on: "GH-1").last)
        #expect(notice.hasPrefix("⏹ harness:preview (\(running.run)) stopped by Reviewer. Nothing has been created."))
        #expect(!(await fixture.reconciler.runRound().hasRunningAgents))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPreviewCutOffByARestartIsReclaimedAndItsTicketTold() async throws {
        let fixture = try Fixture(slots: 1)
        try await fixture.ledger.append([LedgerEvent(node: nil, by: .reconciler,
                                                     kind: .previewStarted(ticket: "GH-1", node: "wn-GH-1", run: "run-old"))])

        let report = await fixture.reconciler.runRound()

        #expect(report.actions.contains("GH-1: preview → abandoned: harness restarted"))
        #expect(await fixture.ledger.workingState().runningPreviews.isEmpty)
        let notice = try #require(await fixture.tracker.comments(on: "GH-1").last)
        #expect(notice.hasPrefix("⚠️ harness:preview (run-old) was interrupted: the harness restarted."))
    }
}

private extension BackgroundPreviewTests {
    struct Fixture {
        let ledger: Ledger
        let tracker = Tracker()
        let agents = Agents()
        let reconciler: Reconciler

        init(slots: Int) throws {
            ledger = try Ledger()
            var team = AgentTeam(name: "previews", decomposer: agents, testAuthor: agents, implementer: agents)
            team.runSettings = { _ in AgentRunSettings(model: "test-model", effort: "xhigh") }
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: NoWorkspace(), artifacts: Artifacts(), checks: Checks(), team: team,
                policy: Policy(maxParallelAgents: slots))
        }

        /// Polls the working state until `value` finds something: background work records its events soon after.
        func eventually<T>(_ value: (WorkingState) async -> T?) async throws -> T {
            for _ in 0..<500 {
                if let found = await value(await ledger.workingState()) { return found }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AgentFailure("Timed out waiting for the background preview")
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private var comments: [(key: String, text: String)] = []

        func request(_ command: HarnessCommand, on key: String) {
            signals.append(Signal(ticket: key, command: command, setBy: .human("Reviewer")))
        }
        func isPending(_ command: HarnessCommand, on key: String) -> Bool {
            signals.contains { $0.ticket == key && $0.command == command }
        }
        func comments(on key: String) -> [String] { comments.filter { $0.key == key }.map(\.text) }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: "Greeting \(key)", description: "Greet the user",
                   acceptanceCriteria: ["The greeting is visible"], createdBy: .human("Reviewer"))
        }
        func consume(_ signal: Signal, reply: String) {
            if let index = signals.firstIndex(where: { $0.ticket == signal.ticket && $0.command == signal.command }) {
                signals.remove(at: index)
            }
            comments.append((signal.ticket, reply))
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("Previews create no tickets")
        }
        func comment(on key: String, _ text: String) { comments.append((key, text)) }
        func setStatus(of key: String, to status: String) {}
    }

    /// A decomposer that works until released, or until its run is stopped.
    actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var proposals = 0
        private var released = false

        func release() { released = true }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            proposals += 1
            while !released { try await Task.sleep(for: .milliseconds(10)) }
            return Breakdown(children: [
                ChildProposal(title: request.spec.title, acceptanceCriteria: request.spec.acceptanceCriteria,
                              touches: ["Greeting"]),
            ])
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("not in previews") }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("not in previews") }
    }

    struct NoWorkspace: Workspace {
        let root = FileManager.default.temporaryDirectory
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL { throw AgentFailure("Previews need no working copy") }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { "" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Previews land nothing") }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "passed", log: "ok")
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
