// API contract: runRound() returns while node steps remain running, but still consumes signals,
// serializes landing and projects WorkingState.status(of:). Reconciler.init additionally accepts
// beforeNodeStep: (@Sendable (NodeID) async -> Void)? = nil, awaited AFTER reserving a non-landing
// node step and BEFORE executing it or writing runStarted. This optional scheduling seam lets tests
// exercise the otherwise unobservable reservation-before-claim interval without scheduler races.

import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_50Tests {
    @Test
    func aLaterRoundAcceptsRetryOnAnotherTicketWhileAnAgentRemainsHeld() async throws {
        try await withFixture { f in
            try await f.seed("slow", authoring: true)
            try await f.seed("retry", phase: .ready)
            try await f.record("retry", [
                .attemptFailed(summary: "Earlier failure"),
                .flagSet(.escalated, reason: "Needs a human"),
            ])
            try await f.startHeldAuthor()
            await f.tracker.send(.retry, to: "retry")

            let report = try await f.roundReturningWhileHeld()

            let node = try #require(await f.node("retry"))
            #expect(node.flags[.escalated] == nil)
            #expect(node.failedAttempts == 0)
            #expect(await f.signalCount("retry", command: .retry, accepted: true) == 1)
            #expect(await f.signalCount("retry", command: .retry, accepted: false) == 0)
            #expect(await f.tracker.pendingSignals().isEmpty)
            #expect(await f.tracker.replies("retry").contains { $0.contains("harness:retry") })
            #expect(report.actions.contains { $0.contains("retry") && $0.contains("accepted") })
            #expect(await f.authorGate.isReleased == false)
            #expect(await f.node("slow")?.activeRun != nil)
        }
    }

    @Test
    func anInapplicableSignalIsRejectedOnceWithoutInterruptingOrDuplicatingTheStep() async throws {
        try await withFixture { f in
            try await f.seed("slow", authoring: true)
            try await f.startHeldAuthor()
            let originalRun = try #require(await f.node("slow")?.activeRun?.run)
            await f.tracker.send(.retry, to: "slow")

            _ = try await f.roundReturningWhileHeld()
            _ = try await f.roundReturningWhileHeld()

            #expect(await f.signalCount("slow", command: .retry, accepted: false) == 1)
            #expect(await f.signalCount("slow", command: .retry, accepted: true) == 0)
            #expect(await f.tracker.pendingSignals().isEmpty)
            let replies = await f.tracker.replies("slow")
            #expect(replies.count == 1)
            #expect(replies.first?.contains("What you can do now:") == true)
            #expect(replies.first?.contains("Nothing for now") == true)
            #expect(replies.first?.contains("test author") == true)
            #expect(await f.node("slow")?.activeRun?.run == originalRun)
            #expect(await f.node("slow")?.flags[.escalated] == nil)
            #expect(await f.author.calls(for: "slow") == 1)
            #expect(await f.runStarts("slow") == 1)
            #expect(await f.authorGate.isReleased == false)

            await f.authorGate.release()
            try await f.waitForReady("slow")
            #expect(await f.author.calls(for: "slow") == 1)
            #expect(await f.node("slow")?.testsDigest != nil)
            #expect(await f.node("slow")?.flags[.escalated] == nil)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func replanCannotReplaceARunningNodeOrDescendantBeforeOrAfterClaim(
        reserved: Bool, descendant: Bool
    ) async throws {
        try await withFixture(reserve: reserved ? "slow" : nil) { f in
            if descendant {
                try await f.seed("parent", kind: .composite, phase: .split)
            }
            try await f.seed("slow", parent: descendant ? "parent" : nil, authoring: true)
            if reserved {
                _ = try await f.roundReturningWhileHeld()
                try #require(try await Self.eventually { await f.reservationGate.hasEntered })
                #expect(await f.node("slow")?.activeRun == nil)
            } else {
                try await f.startHeldAuthor()
            }
            let target = descendant ? "parent" : "slow"
            let before = try #require(await f.node(target))
            let removals = await f.workspace.removals()
            await f.tracker.send(.replan, to: target)

            _ = try await f.roundReturningWhileHeld()
            _ = try await f.roundReturningWhileHeld()

            let after = try #require(await f.node(target))
            #expect(after.spec == before.spec)
            #expect(after.phase == before.phase)
            #expect(after.gates == before.gates)
            #expect(after.children == before.children)
            #expect(await f.signalCount(target, command: .replan, accepted: false) == 1)
            #expect(await f.signalCount(target, command: .replan, accepted: true) == 0)
            #expect(await f.workspace.removals() == removals)
            #expect(FileManager.default.fileExists(atPath: f.workspace.worktree(for: "slow").path))
            #expect(await f.tracker.replies(target).first?.contains("What you can do now:") == true)
            #expect(await f.runStarts("slow") == (reserved ? 0 : 1))
            #expect(await f.author.calls(for: "slow") == (reserved ? 0 : 1))
            #expect(await f.authorGate.isReleased == false)
        }
    }

    @Test(arguments: [false, true])
    func retestCannotDiscardTheRunningNodesWorktree(reserved: Bool) async throws {
        try await withFixture(reserve: reserved ? "slow" : nil) { f in
            try await f.seed("slow", authoring: true)
            if reserved {
                _ = try await f.roundReturningWhileHeld()
                try #require(try await Self.eventually { await f.reservationGate.hasEntered })
            } else {
                try await f.startHeldAuthor()
            }
            // Make retest applicable apart from the reservation/claim guard.
            try await f.record("slow", [.flagSet(.escalated, reason: "Human intervention requested")])
            let before = try #require(await f.node("slow"))
            await f.tracker.send(.retest, to: "slow")

            _ = try await f.roundReturningWhileHeld()

            #expect(await f.signalCount("slow", command: .retest, accepted: false) == 1)
            #expect(await f.signalCount("slow", command: .retest, accepted: true) == 0)
            #expect(await f.workspace.removals().isEmpty)
            #expect(FileManager.default.fileExists(atPath: f.workspace.worktree(for: "slow").path))
            #expect(await f.node("slow")?.activeRun?.run == before.activeRun?.run)
            #expect(await f.node("slow")?.flags[.escalated] == before.flags[.escalated])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func correctingSuggestedAnswersCannotReplaceRunningWork(
        reserved: Bool, descendant: Bool
    ) async throws {
        try await withFixture(reserve: reserved ? "slow" : nil) { f in
            let target = descendant ? "parent" : "slow"
            if descendant {
                try await f.seed("parent", kind: .composite, phase: .split)
            }
            try await f.seed("slow", parent: descendant ? "parent" : nil, authoring: true)
            try await f.record(target, [
                .suggestionsReported(
                    role: descendant ? .decomposer : .testAuthor,
                    questions: [AgentQuestion(question: "Which layout?", suggestion: "Compact rows")]
                ),
            ])
            if reserved {
                _ = try await f.roundReturningWhileHeld()
                try #require(try await Self.eventually { await f.reservationGate.hasEntered })
            } else {
                try await f.startHeldAuthor()
            }
            await f.tracker.humanComment(on: target, "1: Spacious rows")
            await f.tracker.send(.retry, to: target)
            let before = try #require(await f.node(target))

            _ = try await f.roundReturningWhileHeld()
            _ = try await f.roundReturningWhileHeld()

            let after = try #require(await f.node(target))
            #expect(await f.signalCount(target, command: .retry, accepted: false) == 1)
            #expect(await f.signalCount(target, command: .retry, accepted: true) == 0)
            #expect(after.spec == before.spec)
            #expect(after.children == before.children)
            #expect(after.clarifications == before.clarifications)
            #expect(after.phase == before.phase)
            #expect(await f.workspace.removals().isEmpty)
            #expect(FileManager.default.fileExists(atPath: f.workspace.worktree(for: "slow").path))
            #expect(await f.author.calls(for: "slow") == (reserved ? 0 : 1))
            #expect(await f.authorGate.isReleased == false)
        }
    }

    @Test
    func aPreviouslyQueuedChangeLandsAndProjectsItsStatusBeforeTheUnrelatedAgentIsReleased() async throws {
        try await withFixture { f in
            try await f.seed("slow", authoring: true)
            try await f.startHeldAuthor()
            try await f.seed("queued", phase: .landing)
            #expect(await f.ledger.workingState().landingQueue.map(\.id).contains("queued"))

            _ = try await f.roundReturningWhileHeld()

            let state = await f.ledger.workingState()
            let landed = try #require(state.nodes["queued"])
            #expect(landed.phase == .proven)
            #expect(landed.landedCommit == "landed-queued")
            #expect(landed.activeRun == nil)
            #expect(landed.evidence.contains { $0.passed && $0.builtBy != $0.checkedBy })
            #expect(await f.workspace.landed() == ["queued"])
            #expect(await f.tracker.ticket("queued")?.status == state.status(of: landed))
            #expect(await f.tracker.ticket("queued")?.comments.contains {
                $0.text.contains("Landed") && $0.text.contains("landed-q")
            } == true)
            let records = await f.ledger.allRecords()
            #expect(records.filter {
                guard $0.event.node == "queued", case .landed = $0.event.kind else { return false }
                return true
            }.count == 1)
            #expect(await f.authorGate.isReleased == false)
            #expect(state.nodes["slow"]?.activeRun != nil)
        }
    }

    @Test
    func landingTransactionsNeverOverlapEvenWhenRoundsAreRequestedConcurrently() async throws {
        try await withFixture(holdLanding: true) { f in
            try await f.seed("first", phase: .landing)
            try await f.seed("second", phase: .landing)
            let first = Task { await f.reconciler.runRound() }
            try #require(try await Self.eventually { await f.landingGate.hasEntered })
            let second = Task { await f.reconciler.runRound() }
            // The first transaction is suspended inside rebase. A reentrant round must not enter
            // another transaction, even though neither task is doing CPU work.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await f.workspace.maximumConcurrentLandings() == 1)
            await f.landingGate.release()
            let reports = await (first.value, second.value)
            #expect(reports.0.safeStop == nil)
            #expect(reports.1.safeStop == nil)
            _ = await f.reconciler.runRound()

            #expect(await f.workspace.maximumConcurrentLandings() == 1)
            #expect(await f.workspace.landed() == ["first", "second"])
            #expect(await f.node("first")?.phase == .proven)
            #expect(await f.node("second")?.phase == .proven)
            #expect(await f.workspace.landingOperations() == [
                "rebase:first", "prepare:first", "check:first", "land:first", "remove:first",
                "rebase:second", "prepare:second", "check:second", "land:second", "remove:second",
            ])
        }
    }

    @Test
    func aReservedNodeInTheLandingQueueWaitsUntilItsStepCompletes() async throws {
        try await withFixture(reserve: "queued") { f in
            try await f.seed("queued", phase: .landing)

            _ = try await f.roundReturningWhileHeld()
            try #require(try await Self.eventually { await f.reservationGate.hasEntered })
            _ = try await f.roundReturningWhileHeld()

            #expect(await f.node("queued")?.activeRun == nil)
            #expect(await f.node("queued")?.phase == .landing)
            #expect(await f.workspace.landingOperations().isEmpty)
            await f.reservationGate.release()
            try #require(try await Self.eventually {
                _ = await f.reconciler.runRound()
                return await f.node("queued")?.phase == .proven
            })
            #expect(await f.workspace.landed() == ["queued"])
        }
    }

    @Test
    func anActiveClaimInTheLandingPhaseIsNotLandedUntilTheClaimFinishes() async throws {
        try await withFixture { f in
            try await f.seed("queued", phase: .landing)
            try await f.record("queued", [.runStarted(run: "held-check", role: .verifier)])

            _ = try await f.roundReturningWhileHeld()
            _ = try await f.roundReturningWhileHeld()

            #expect(await f.workspace.landingOperations().isEmpty)
            #expect(await f.node("queued")?.activeRun?.run == "held-check")
            try await f.record("queued", [.runFinished(run: "held-check", outcome: "completed")])
            _ = try await f.roundReturningWhileHeld()
            #expect(await f.workspace.landed() == ["queued"])
            #expect(await f.node("queued")?.phase == .proven)
        }
    }

    @Test
    func returningRoundsRefreshEveryTrackerStatusFromWorkingStateWhileAnAgentIsRunning() async throws {
        try await withFixture { f in
            try await f.seed("slow", authoring: true)
            try await f.startHeldAuthor()
            try await f.seed("ready", phase: .ready)
            try await f.seed("escalated", phase: .ready)
            try await f.record("escalated", [.flagSet(.escalated, reason: "Needs a person")])
            try await f.seed("input", phase: .ready)
            try await f.record("input", [.flagSet(.needsInput, reason: "Needs an answer")])
            try await f.seed("blocked", phase: .ready)
            try await f.record("blocked", [.flagSet(.blocked, reason: "Waiting for another system")])
            await f.tracker.staleStatuses()

            _ = try await f.roundReturningWhileHeld()

            let state = await f.ledger.workingState()
            for node in state.nodes.values {
                #expect(await f.tracker.ticket(node.ticket)?.status == state.status(of: node))
            }
            #expect(await f.authorGate.isReleased == false)
            #expect(state.nodes["slow"]?.activeRun != nil)
            await f.tracker.send(.retry, to: "escalated")
            _ = try await f.roundReturningWhileHeld()
            let updated = await f.ledger.workingState()
            let retried = try #require(updated.nodes["escalated"])
            #expect(retried.flags[.escalated] == nil)
            #expect(await f.tracker.ticket("escalated")?.status == updated.status(of: retried))
        }
    }

    @Test
    func renderedAppDocumentationExplainsCrossRoundSchedulingAndTheRemainingRoundBlockers() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for relativePath in ["README.md", "docs/real-repo-mode.md"] {
            let markdown = try String(contentsOf: app.appending(path: relativePath), encoding: .utf8)
            let rendered = try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            let paragraphs = String(rendered.characters).lowercased()
                .components(separatedBy: "\n\n")
            // This inspects reader-visible documentation, not Swift implementation source.
            #expect(paragraphs.contains { paragraph in
                paragraph.contains("round") && paragraph.contains("agent")
                    && ["across", "later", "earlier", "previous", "background", "between"].contains {
                        paragraph.contains($0)
                    }
            }, "Document agents continuing across rounds in \(relativePath)")
            for subject in ["preview", "landing"] {
                #expect(paragraphs.contains { paragraph in
                    paragraph.contains(subject) && paragraph.contains("round")
                        && ["hold", "wait", "block", "synchronous"].contains { paragraph.contains($0) }
                }, "Document that \(subject) processing can still hold its own round open in \(relativePath)")
            }
        }
    }

    private static func eventually(
        _ predicate: @Sendable () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        return false
    }

    private func withFixture(
        reserve: NodeID? = nil, holdLanding: Bool = false,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let f = try Fixture(reserve: reserve, holdLanding: holdLanding)
        do {
            try await body(f)
        } catch {
            await f.cleanup()
            throw error
        }
        await f.cleanup()
    }

    private final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let tracker = Tracker()
        let authorGate = GateLatch()
        let reservationGate = GateLatch()
        let landingGate = GateLatch()
        let workspace: InstrumentedWorkspace
        let author: HeldAuthor
        let reconciler: Reconciler

        init(reserve: NodeID?, holdLanding: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-50-\(UUID().uuidString)")
            ledger = try Ledger()
            workspace = InstrumentedWorkspace(root: root, gate: holdLanding ? landingGate : nil)
            author = HeldAuthor(gate: authorGate)
            let reservationGate = reservationGate
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: Checks(workspace: workspace),
                team: AgentTeam(name: "GH-50", decomposer: NoDecomposer(),
                                testAuthor: author, implementer: NoImplementer()),
                policy: Policy(maxParallelAgents: 4),
                beforeNodeStep: { id in
                    if id == reserve { await reservationGate.enter() }
                }
            )
        }

        func seed(
            _ id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf,
            phase: Phase = .specified, authoring: Bool = false
        ) async throws {
            let spec = NodeSpec(id: id, parent: parent, kind: kind, title: id, intent: "GH-50 fixture",
                                acceptanceCriteria: ["Observable \(id) behaviour"], touches: ["Feature"])
            let directory = workspace.worktree(for: id)
            let tests = directory.appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
            try "Acceptance fixture for \(id)".write(
                to: tests.appending(path: "acceptance.txt"), atomically: true, encoding: .utf8
            )
            await tracker.add(Ticket(key: id, title: spec.title, description: spec.intent,
                                     acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Alice")))
            var events: [EventKind] = [
                .nodeCreated(spec: spec, ticket: id), .phaseChanged(to: phase),
            ]
            if authoring { events.append(.gateOpened(.breakdown)) }
            if phase == .landing {
                events += [
                    .testsFixed(digest: Hashing.digest(of: tests)),
                    .changeSubmitted(run: "builder-\(id)", commit: "candidate-\(id)"),
                ]
            }
            try await record(id, events)
        }

        func record(_ id: NodeID, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: .human("Alice"), kind: $0) })
        }

        func node(_ id: NodeID) async -> NodeState? { await ledger.workingState().nodes[id] }

        func startHeldAuthor() async throws {
            _ = try await roundReturningWhileHeld()
            try #require(try await GH_50Tests.eventually { await self.authorGate.hasEntered })
        }

        func roundReturningWhileHeld() async throws -> RoundReport {
            let result = RoundResult()
            let task = Task {
                let report = await self.reconciler.runRound()
                await result.set(report)
                return report
            }
            let returned = try await GH_50Tests.eventually { await result.report != nil }
            if !returned {
                // Release barriers before awaiting the failed round so the old synchronous scheduler
                // fails an assertion instead of hanging the test process and hiding later failures.
                await releaseAll()
            }
            let report = await task.value
            try #require(returned, "runRound() waited for a held node step")
            #expect(report.safeStop == nil)
            return report
        }

        func waitForReady(_ id: NodeID) async throws {
            try #require(try await GH_50Tests.eventually {
                _ = await self.reconciler.runRound()
                let node = await self.node(id)
                return node?.phase == .ready && node?.activeRun == nil
            })
        }

        func runStarts(_ id: NodeID) async -> Int {
            await ledger.allRecords().filter {
                guard $0.event.node == id, case .runStarted = $0.event.kind else { return false }
                return true
            }.count
        }

        func signalCount(_ id: NodeID, command: HarnessCommand, accepted: Bool) async -> Int {
            await ledger.allRecords().filter {
                switch $0.event.kind {
                case .signalAccepted(let ticket, let found, _):
                    return accepted && ticket == id && found == command
                case .signalRejected(let ticket, let found, _):
                    return !accepted && ticket == id && found == command
                default: return false
                }
            }.count
        }

        func releaseAll() async {
            await authorGate.release()
            await reservationGate.release()
            await landingGate.release()
        }

        func cleanup() async {
            await releaseAll()
            await reconciler.shutdown(reason: "GH-50 test cleanup")
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                Issue.record("Couldn't remove GH-50 temporary workspace: \(error)")
            }
        }
    }

    private actor GateLatch {
        private(set) var hasEntered = false
        private(set) var isReleased = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            hasEntered = true
            guard !isReleased else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            isReleased = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor RoundResult {
        private(set) var report: RoundReport?
        func set(_ report: RoundReport) { self.report = report }
    }

    private actor HeldAuthor: TestAuthor {
        let gate: GateLatch
        private var received: [NodeID] = []
        init(gate: GateLatch) { self.gate = gate }
        func calls(for id: NodeID) -> Int { received.filter { $0 == id }.count }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            received.append(task.spec.id)
            await gate.enter()
            try Task.checkCancellation()
            try "New acceptance tests".write(
                to: task.directory.appending(path: task.testFolder).appending(path: "acceptance.txt"),
                atomically: true, encoding: .utf8
            )
            return AgentReport()
        }
    }

    private actor Tracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var signals: [Signal] = []
        private var consumed: [String: [String]] = [:]
        func add(_ ticket: Ticket) { tickets[ticket.key] = ticket }
        func send(_ command: HarnessCommand, to key: String) {
            signals.append(Signal(ticket: key, command: command, setBy: .human("Alice")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func replies(_ key: String) -> [String] { consumed[key] ?? [] }
        func consume(_ signal: Signal, reply: String) {
            if let index = signals.firstIndex(where: {
                $0.ticket == signal.ticket && $0.command == signal.command
            }) { signals.remove(at: index) }
            consumed[signal.ticket, default: []].append(reply)
            comment(on: signal.ticket, reply)
        }
        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func humanComment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .human("Alice"), text: text))
        }
        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }
        func staleStatuses() {
            for key in Array(tickets.keys) { tickets[key]?.status = "stale projection" }
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("No GH-50 test expects child creation")
        }
    }

    private actor InstrumentedWorkspace: Workspace {
        nonisolated let root: URL
        let gate: GateLatch?
        private var removed: [NodeID] = []
        private var merged: [NodeID] = []
        private var operations: [String] = []
        private var transactions = 0
        private var maximumTransactions = 0
        init(root: URL, gate: GateLatch?) { self.root = root; self.gate = gate }
        func removals() -> [NodeID] { removed }
        func landed() -> [NodeID] { merged }
        func landingOperations() -> [String] { operations }
        func maximumConcurrentLandings() -> Int { maximumTransactions }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.id)" }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {
            removed.append(id)
            if merged.contains(id) {
                operations.append("remove:\(id)")
                transactions -= 1
            }
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "commit-\(author)"
        }
        func head(of directory: URL) async throws -> String { "candidate-\(directory.lastPathComponent)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/\(directory.lastPathComponent)/acceptance.txt"]
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            transactions += 1
            maximumTransactions = max(maximumTransactions, transactions)
            operations.append("rebase:\(directory.lastPathComponent)")
            if let gate { await gate.enter() }
            return .clean
        }
        func prepareBuild(in directory: URL) async throws {
            operations.append("prepare:\(directory.lastPathComponent)")
        }
        func recordCheck(_ directory: URL) { operations.append("check:\(directory.lastPathComponent)") }
        func landOnMain(_ id: NodeID) async throws -> String {
            operations.append("land:\(id)")
            merged.append(id)
            return "landed-\(id)"
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("No GH-50 fixture should require rework")
        }
        nonisolated func existingComponents() -> [String] { ["Feature"] }
    }

    private struct Checks: CheckRunner {
        let workspace: InstrumentedWorkspace
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            await workspace.recordCheck(directory)
            return CheckOutput(passed: true, summary: "Passed", log: "Passed")
        }
    }

    private struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct NoDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("No GH-50 test expects decomposition")
        }
    }

    private struct NoImplementer: Implementer {
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("No GH-50 test expects implementation")
        }
    }
}
