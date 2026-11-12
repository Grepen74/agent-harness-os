import AgentOSAdapters
@testable import AgentOSCore
import AgentOSSimulation
import Dispatch
import Foundation
import Synchronization
import Testing

extension GH_49Tests {
    struct Timeout: Error {}

    final class ResultCell<Value: Sendable>: Sendable {
        struct State {
            var result: Result<Value, any Error>?
            var waiters: [CheckedContinuation<Value, any Error>] = []
        }
        let state = Mutex(State())
        var isResolved: Bool { state.withLock { $0.result != nil } }

        func resolve(_ result: Result<Value, any Error>) {
            let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
                guard state.result == nil else { return [] }
                state.result = result
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume(with: result) }
        }

        func value() async throws -> Value {
            let timeout = DispatchWorkItem { self.resolve(.failure(Timeout())) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    if let result = state.result { return result }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }
    }

    final class Signal: Sendable {
        let cell = ResultCell<Void>()
        var isOpen: Bool { cell.isResolved }
        func open() { cell.resolve(.success(())) }
        func wait() async throws { try await cell.value() }
    }

    final class Barrier: Sendable {
        let entered = Signal()
        let release = Signal()
        func wait() async throws {
            entered.open()
            try await release.wait()
        }
    }

    static func start<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> ResultCell<T> {
        let cell = ResultCell<T>()
        Task {
            do { cell.resolve(.success(try await operation())) }
            catch { cell.resolve(.failure(error)) }
        }
        return cell
    }

    static func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await start(operation).value()
    }

    // The marker and call execute on the reconciler's executor, with no intervening actor hop.
    static func observeWait(on reconciler: isolated Reconciler, entered: Signal, returned: Signal) async {
        entered.open()
        await reconciler.waitForAgents()
        returned.open()
    }

    final class BeforeClaim: Sendable {
        struct State { var hold = false; var entries: [NodeID] = [] }
        let state = Mutex(State())
        let entered = Signal()
        let release = Signal()
        var hold: Bool {
            get { state.withLock { $0.hold } }
            set { state.withLock { $0.hold = newValue } }
        }
        var entries: [NodeID] { state.withLock { $0.entries } }
        func call(_ id: NodeID) async {
            let held = state.withLock { state in
                state.entries.append(id)
                return state.hold
            }
            if held {
                entered.open()
                do { try await release.wait() }
                catch { Issue.record("Pre-claim barrier timed out: \(error)") }
            }
        }
    }

    final class Agents: Decomposer, TestAuthor, AgentOSCore.Implementer, Sendable {
        struct State {
            var starts: [NodeID] = []
            var started: [NodeID: Signal] = [:]
            var releases: [NodeID: Signal] = [:]
            var releasedAll = false
        }
        let state = Mutex(State())
        let twoStarted = Signal()
        var starts: [NodeID] { state.withLock { $0.starts } }
        func started(_ id: NodeID) -> Signal {
            state.withLock {
                if let signal = $0.started[id] { return signal }
                let signal = Signal()
                $0.started[id] = signal
                return signal
            }
        }
        func release(_ id: NodeID) -> Signal {
            state.withLock {
                if let signal = $0.releases[id] { return signal }
                let signal = Signal()
                $0.releases[id] = signal
                if $0.releasedAll { signal.open() }
                return signal
            }
        }
        func releaseAll() {
            let releases = state.withLock { state in
                state.releasedAll = true
                return Array(state.releases.values)
            }
            for release in releases { release.open() }
        }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            let count = state.withLock { $0.starts.append(request.spec.id); return $0.starts.count }
            let release = release(request.spec.id)
            started(request.spec.id).open()
            if count >= 2 { twoStarted.open() }
            try await release.wait()
            return Breakdown(children: [], report: AgentReport(questions: [
                AgentQuestion(question: "Clarify \(request.spec.id)")
            ]))
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test-author step for \(task.spec.id)")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected implementer step for \(task.spec.id)")
        }
        var team: AgentTeam {
            AgentTeam(name: "GH-49 controlled", decomposer: self, testAuthor: self, implementer: self)
        }
    }

    actor WorkspaceFake: Workspace {
        var prepareBarrier: Barrier?
        var cleanupBarrier: Barrier?
        var barriers: [Barrier] = []
        func holdNextPrepare(_ barrier: Barrier) { prepareBarrier = barrier; barriers.append(barrier) }
        func holdSnapshotCleanup(_ barrier: Barrier) { cleanupBarrier = barrier; barriers.append(barrier) }
        func releaseAll() {
            for barrier in barriers { barrier.release.open() }
        }
        func prepare() async throws {
            if let barrier = prepareBarrier {
                prepareBarrier = nil
                try await barrier.wait()
            }
        }
        func createSnapshot() async throws -> URL? { URL(filePath: "/gh-49-fake/snapshot") }
        func removeSnapshot(_ directory: URL) async {
            if let barrier = cleanupBarrier {
                do { try await barrier.wait() }
                catch { Issue.record("Snapshot cleanup barrier timed out: \(error)") }
            }
        }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { URL(filePath: "/gh-49-fake/\(id)") }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }
        func createWorktree(for id: NodeID) async throws -> URL { throw unexpected() }
        func removeWorktree(for id: NodeID) async throws { throw unexpected() }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { throw unexpected() }
        func head(of directory: URL) async throws -> String { throw unexpected() }
        func changedFiles(in directory: URL) async throws -> [String] { throw unexpected() }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { throw unexpected() }
        func abortRebase(_ directory: URL) async throws { throw unexpected() }
        func resetForRework(_ directory: URL) async throws { throw unexpected() }
        func landOnMain(_ id: NodeID) async throws -> String { throw unexpected() }
        func prepareBuild(in directory: URL) async throws { throw unexpected() }
        private func unexpected() -> AgentFailure { AgentFailure("Unexpected workspace mutation") }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "fake checks", log: "fake checks")
        }
    }

    final class Fixture: Sendable {
        let ledger: Ledger
        let agents = Agents()
        let workspace = WorkspaceFake()
        let beforeClaim = BeforeClaim()
        let reconciler: Reconciler
        init(limit: Int) throws {
            ledger = try Ledger()
            let beforeClaim = self.beforeClaim
            reconciler = Reconciler(
                ledger: ledger, tracker: LocalTrackerAdapter(tracker: LocalTracker(store: nil)),
                external: External(), workspace: workspace, artifacts: Artifacts(), checks: Checks(),
                team: agents.team, policy: Policy(maxParallelAgents: limit),
                beforeStep: { await beforeClaim.call($0) })
        }
        func add(_ id: NodeID) async throws { try await GH_49Tests.seed(id, ledger: ledger) }
        func claimCount(_ id: NodeID) async -> Int {
            await ledger.allRecords().filter {
                if case .runStarted = $0.event.kind { return $0.event.node == id }
                return false
            }.count
        }
        func cleanup() async throws {
            beforeClaim.release.open()
            agents.releaseAll()
            await workspace.releaseAll()
            await reconciler.shutdown(reason: "GH-49 test cleanup")
        }
    }

    static func seed(_ id: NodeID, ledger: Ledger) async throws {
        let spec = NodeSpec(id: id, kind: .composite, title: id, intent: "Controlled scheduling",
                            acceptanceCriteria: ["First criterion", "Second criterion"])
        try await ledger.append([
            LedgerEvent(node: id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: id)),
            LedgerEvent(node: id, by: .human("Alice"), kind: .gateOpened(.breakdown))
        ])
    }

    static func withFixture(limit: Int = 1, _ body: @Sendable (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(limit: limit)
        do { try await body(fixture) }
        catch {
            try await bounded { try await fixture.cleanup() }
            throw error
        }
        try await bounded { try await fixture.cleanup() }
    }
}
