import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

extension GH_78Tests {
    enum Release: CaseIterable, Sendable {
        case landed, escalated, needsInput, replanned, ticketClosed
    }

    struct Hold: Equatable {
        let waitingFor: NodeID
        let paths: [String]
        let components: [String]
    }

    @MainActor
    static func withFixture(
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let repository = (0..<7).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
            url.deletingLastPathComponent()
        }
        let root = repository.appending(path: ".agentos/scratch/run-dadbee/GH78-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture: Fixture
        do {
            fixture = try Fixture(root: root)
        } catch {
            try FileManager.default.removeItem(at: root)
            throw error
        }
        let result: Result<Void, any Error>
        do {
            try await body(fixture)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await fixture.shutdown()
        try FileManager.default.removeItem(at: root)
        try result.get()
    }

    @MainActor
    final class Fixture {
        let leaf = "GH-78.2"
        let blocker = "GH-78.1"
        let ledgerURL: URL
        let ledger: Ledger
        let tracker = MemoryTracker()
        let workspace: MemoryWorkspace
        let implementation = ObservedImplementation()
        lazy var reconciler = makeReconciler(ledger: ledger)
        private var reconcilers: [Reconciler] = []

        init(root: URL) throws {
            ledgerURL = root.appending(path: "ledger.jsonl")
            ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerURL))
            workspace = MemoryWorkspace(root: root)
        }

        func nodeID(_ ticket: String) -> NodeID { "wn-\(ticket)" }

        func makeReconciler(ledger: Ledger) -> Reconciler {
            let unused = UnusedPlanningAgents()
            let reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: MemoryArtifacts(), checks: PassingChecks(),
                team: AgentTeam(name: "GH-78", decomposer: unused, testAuthor: unused,
                                implementer: implementation),
                policy: Policy(maxParallelAgents: 4))
            reconcilers.append(reconciler)
            return reconciler
        }

        func shutdown() async {
            for reconciler in reconcilers {
                await reconciler.shutdown(reason: "GH-78 test finished")
            }
        }

        func spec(_ ticket: String, paths: [String], touches: [String]) -> NodeSpec {
            var value = NodeSpec(id: nodeID(ticket), kind: .leaf, title: "Work on \(ticket)",
                                 intent: "Exercise observable overlap reporting",
                                 acceptanceCriteria: ["Report a hold"], touches: touches)
            value.predictedPaths = paths
            return value
        }

        func seedPair(paths: [String], touches: [String] = ["Engine"]) async throws {
            try await seedReview(blocker, paths: paths, touches: touches)
            try await seedReady(paths: paths, touches: touches)
        }

        func seedReview(_ ticket: String, paths: [String], touches: [String] = ["Engine"]) async throws {
            let value = spec(ticket, paths: paths, touches: touches)
            await tracker.add(ticket)
            await workspace.setFiles(paths, for: ticket)
            try await record(ticket, [
                .nodeCreated(spec: value, ticket: ticket),
                .changeSubmitted(run: "builder-\(ticket)", commit: "candidate-\(ticket)"),
                .phaseChanged(to: .landing),
                .humanReviewRequested(commit: "candidate-\(ticket)"),
            ])
        }

        func seedReady(paths: [String], touches: [String] = ["Engine"]) async throws {
            await tracker.add(leaf)
            let value = spec(leaf, paths: paths, touches: touches)
            let tests = workspace.worktree(for: value.id).appending(path: workspace.testFolder(for: value))
            try await record(leaf, [
                .nodeCreated(spec: value, ticket: leaf),
                .testsFixed(digest: Hashing.digest(of: tests)),
                .phaseChanged(to: .ready),
            ])
            try await ledger.append([
                LedgerEvent(node: nodeID(leaf), by: .human("Test owner"), kind: .gateOpened(.build)),
            ])
        }

        func record(_ ticket: String, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: nodeID(ticket), by: .reconciler, kind: $0) })
        }

        func settle(waitForAgents: Bool = true, using runner: Reconciler? = nil) async throws {
            let runner = runner ?? reconciler
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            repeat {
                let report = await runner.runRound(waitForAgents: waitForAgents)
                try #require(report.safeStop == nil, "Fixture must not safe-stop: \(report.safeStop ?? "")")
                if !waitForAgents { await runner.waitForAgents() }
                if report.isIdle { return }
            } while ContinuousClock.now < deadline
            throw AgentFailure("GH-78 reconciliation did not settle within 20 seconds")
        }

        func startedHolds(in source: Ledger? = nil) async -> [Hold] {
            await (source ?? ledger).records(for: nodeID(leaf)).compactMap { record in
                guard case .overlapHoldStarted(let waitingFor, let paths, let components) = record.event.kind else {
                    return nil
                }
                return Hold(waitingFor: waitingFor, paths: paths, components: components)
            }
        }

        func endedHolds() async -> [Hold] {
            await ledger.records(for: nodeID(leaf)).compactMap { record in
                guard case .overlapHoldEnded(let waitingFor, let paths, let components) = record.event.kind else {
                    return nil
                }
                return Hold(waitingFor: waitingFor, paths: paths, components: components)
            }
        }

        func releaseBlocker(_ release: Release) async throws {
            switch release {
            case .landed:
                try await record(blocker, [.landed(commit: "landed"), .phaseChanged(to: .proven)])
            case .escalated:
                try await record(blocker, [.flagSet(.escalated, reason: "Needs a human")])
            case .needsInput:
                try await record(blocker, [.flagSet(.needsInput, reason: "Waiting for an answer")])
            case .replanned:
                let node = try #require(await ledger.workingState().nodes[nodeID(blocker)])
                try await record(blocker, [.replanned(spec: node.spec)])
            case .ticketClosed:
                await tracker.setClosed(blocker)
            }
        }
    }

    actor MemoryTracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var closed: Set<String> = []

        func add(_ key: String) {
            tickets[key] = Ticket(key: key, title: key, description: "", acceptanceCriteria: [],
                                  createdBy: .human("Test owner"))
        }
        func comments(on key: String) -> [String] { tickets[key]?.comments.map(\.text) ?? [] }
        func status(of key: String) -> String? { tickets[key]?.status }
        func setClosed(_ key: String) { closed.insert(key) }
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { tickets[key] }
        func contextTickets() async -> [Ticket] { Array(tickets.values) }
        func consume(_ signal: Signal, reply: String) async { comment(on: signal.ticket, reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-78 fixture must not create child tickets")
        }
        func comment(on key: String, _ text: String) { tickets[key]?.comments.append(Comment(author: .reconciler, text: text)) }
        func setStatus(of key: String, to status: String) async { tickets[key]?.status = status }
        func isClosed(_ key: String) async -> Bool { closed.contains(key) }
    }

    actor MemoryWorkspace: Workspace {
        nonisolated let root: URL
        private var files: [NodeID: [String]] = [:]
        init(root: URL) { self.root = root }
        func setFiles(_ paths: [String], for ticket: String) { files["wn-\(ticket)"] = paths }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "commit-\(directory.lastPathComponent)"
        }
        func head(of directory: URL) async throws -> String { "commit-\(directory.lastPathComponent)" }
        func changedFiles(in directory: URL) async throws -> [String] { files[directory.lastPathComponent] ?? [] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed-\(id)" }
        nonisolated func existingComponents() -> [String] { ["Engine", "Storage"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor ObservedImplementation: Implementer {
        private(set) var calls: [NodeID] = []
        private var barrier: BuildBarrier?
        func pauseNextCall(using barrier: BuildBarrier) { self.barrier = barrier }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append(task.spec.id)
            if let barrier {
                self.barrier = nil
                try await barrier.enterAndWait()
            }
            return AgentReport()
        }
    }

    final class BuildBarrier: Sendable {
        private let entered: AsyncStream<Void>
        private let enteredSignal: AsyncStream<Void>.Continuation
        private let released: AsyncStream<Void>
        private let releasedSignal: AsyncStream<Void>.Continuation

        init() {
            (entered, enteredSignal) = AsyncStream<Void>.makeStream()
            (released, releasedSignal) = AsyncStream<Void>.makeStream()
        }

        func enterAndWait() async throws {
            enteredSignal.yield(())
            enteredSignal.finish()
            try await Self.wait(for: released, signal: releasedSignal, reason: "release the implementer")
        }

        func waitForEntry() async throws {
            try await Self.wait(for: entered, signal: enteredSignal, reason: "start the implementer")
        }

        func release() {
            releasedSignal.yield(())
            releasedSignal.finish()
        }

        private static func wait(
            for stream: AsyncStream<Void>, signal: AsyncStream<Void>.Continuation, reason: String
        ) async throws {
            let timeout = DispatchWorkItem { signal.finish() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            defer { timeout.cancel() }
            for await _ in stream { return }
            try Task.checkCancellation()
            throw AgentFailure("GH-78 timed out waiting to \(reason)")
        }
    }

    struct UnusedPlanningAgents: Decomposer, TestAuthor {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-78 fixture must not decompose")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-78 fixture must not author tests")
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture checks passed", log: "")
        }
    }
}
