import AgentOSCore
import Dispatch
import Foundation
import Synchronization
import Testing

extension GH_77Tests {
    enum Mode: String, CaseIterable, Sendable { case background, waitingRound, untilIdle }
    enum Release: String, CaseIterable, Sendable { case landed, escalated, needsInput, replanned, closed }

    struct PathCase: Sendable {
        let busy: [String]
        let ready: [String]
        let overlaps: Bool
        init(_ busy: [String], _ ready: [String], overlaps: Bool) {
            self.busy = busy; self.ready = ready; self.overlaps = overlaps
        }
    }

    struct TouchCase: Sendable {
        let busyPaths: [String]?
        let busyTouches: [String]
        let readyPaths: [String]?
        let readyTouches: [String]
        let overlaps: Bool
        init(_ busyPaths: [String]?, _ busyTouches: [String],
             _ readyPaths: [String]?, _ readyTouches: [String], overlaps: Bool) {
            self.busyPaths = busyPaths; self.busyTouches = busyTouches
            self.readyPaths = readyPaths; self.readyTouches = readyTouches; self.overlaps = overlaps
        }
    }

    struct Timeout: Error { let operation: String }

    final class Cell<Value: Sendable>: Sendable {
        struct State {
            var result: Result<Value, any Error>?
            var waiters: [CheckedContinuation<Value, any Error>] = []
        }
        let state = Mutex(State())
        func resolve(_ result: Result<Value, any Error>) {
            let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
                guard state.result == nil else { return [] }
                state.result = result
                let pending = state.waiters
                state.waiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter.resume(with: result) }
        }
        func value(operation: String = "explicit scheduling signal") async throws -> Value {
            let timeout = DispatchWorkItem { self.resolve(.failure(Timeout(operation: operation))) }
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

    final class Probe: Sendable {
        let filled = Cell<Void>()
        let release = Cell<Void>()
        let entries = Mutex(Set<NodeID>())
        let expectedEntries: Int
        let hold: Bool
        init(expectedEntries: Int, hold: Bool) { self.expectedEntries = expectedEntries; self.hold = hold }
        func beforeStep(_ id: NodeID) async {
            guard id.hasPrefix("leaf-") else { return }
            let count = entries.withLock { $0.insert(id); return $0.count }
            if count >= expectedEntries { filled.resolve(.success(())) }
            if hold {
                do { try await release.value(operation: "release reserved leaf \(id)") }
                catch { Issue.record(error) }
            }
        }
    }

    final class Agents: Decomposer, TestAuthor, AgentOSCore.Implementer, Sendable {
        let entered = Cell<Void>()
        let release = Cell<Void>()
        let received = Mutex([NodeID]())
        let hold: Bool
        var starts: [NodeID] { received.withLock { $0 } }
        init(hold: Bool) { self.hold = hold }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-77 does not expect decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-77 seeds already-authored acceptance tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            received.withLock { $0.append(task.spec.id) }
            entered.resolve(.success(()))
            if hold { try await release.value(operation: "release implementer \(task.spec.id)") }
            return AgentReport(questions: [AgentQuestion(question: "Clarify \(task.spec.id)")])
        }
        var team: AgentTeam {
            AgentTeam(name: "GH-77 controlled", decomposer: self, testAuthor: self, implementer: self)
        }
    }

    final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let tracker = Tracker()
        let probe: Probe
        let agents: Agents
        let workspace: WorkspaceFake
        let reconciler: Reconciler
        let runs = Mutex([Task<Void, Never>]())
        let results = Mutex([Cell<Void>]())

        init(limit: Int, settingOn: Bool, expectedEntries: Int,
             holdBeforeClaim: Bool, holdImplementer: Bool, holdLanding: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-77-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            probe = Probe(expectedEntries: expectedEntries, hold: holdBeforeClaim)
            agents = Agents(hold: holdImplementer)
            workspace = WorkspaceFake(root: root.appending(path: "worktrees"), holdLanding: holdLanding)
            var policy = Policy(maxParallelAgents: limit)
            policy.avoidOverlappingWork = settingOn
            let probe = self.probe
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: External(), workspace: workspace,
                artifacts: Artifacts(), checks: Checks(), team: agents.team, policy: policy,
                beforeStep: { await probe.beforeStep($0) })
        }

        func record(_ id: NodeID, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: .human("Alice"), kind: $0) })
        }
        func seed(_ id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf,
                  phase: Phase, paths: [String]? = nil, touches: [String] = []) async throws {
            var spec = NodeSpec(id: id, parent: parent, kind: kind, title: id, intent: "GH-77 scheduling",
                                acceptanceCriteria: ["Observable work for \(id)"], touches: touches)
            spec.predictedPaths = paths ?? []
            let directory = workspace.worktree(for: id).appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Acceptance tests for \(id)\n".write(
                to: directory.appending(path: "acceptance.txt"), atomically: true, encoding: .utf8)
            await tracker.add(Ticket(key: id, title: id, description: spec.intent,
                                     acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Alice")))
            try await record(id, [.nodeCreated(spec: spec, ticket: id), .phaseChanged(to: phase),
                                  .testsFixed(digest: Hashing.digest(of: directory))])
        }
        func leaf(_ id: NodeID, paths: [String]?, touches: [String] = []) async throws {
            try await seed(id, phase: .ready, paths: paths, touches: touches)
            try await record(id, [.gateOpened(.build)])
        }
        func parent(_ id: NodeID) async throws { try await seed(id, kind: .composite, phase: .split) }
        func blocker(_ id: NodeID, parent: NodeID? = nil, phase: Phase = .building,
                     paths: [String]?, touches: [String] = [], humanReview: Bool = false) async throws {
            try await seed(id, parent: parent, phase: phase, paths: paths, touches: touches)
            try await record(id, humanReview
                ? [.humanReviewRequested(commit: "candidate-\(id)")]
                : [.runStarted(run: "existing-\(id)", role: phase == .building ? .implementer : .verifier)])
        }
        func queued(_ id: NodeID, paths: [String]) async throws {
            try await seed(id, phase: .landing, paths: paths)
            try await record(id, [.changeSubmitted(run: "builder-\(id)", commit: "candidate-\(id)")])
        }
        func reservedLeaves() async -> Set<NodeID> {
            await reconciler.busyNodes.filter { $0.hasPrefix("leaf-") }
        }
        func round() async throws {
            let result = Cell<RoundReport>()
            let task = Task {
                result.resolve(.success(await self.reconciler.runRound(waitForAgents: false)))
            }
            runs.withLock { $0.append(task) }
            let report = try await result.value(operation: "nonwaiting round returns")
            #expect(report.safeStop == nil)
        }
        func start(_ mode: Mode) {
            let result = Cell<Void>()
            results.withLock { $0.append(result) }
            let task = Task {
                switch mode {
                case .background:
                    let report = await self.reconciler.runRound(waitForAgents: false)
                    #expect(report.safeStop == nil)
                case .waitingRound:
                    let report = await self.reconciler.runRound(waitForAgents: true)
                    #expect(report.safeStop == nil)
                case .untilIdle:
                    while !Task.isCancelled {
                        let report = await self.reconciler.runRound(waitForAgents: false)
                        #expect(report.safeStop == nil)
                        if report.isIdle || report.safeStop != nil { break }
                        await Task.yield()
                    }
                }
                result.resolve(.success(()))
            }
            runs.withLock { $0.append(task) }
        }
        func finishRuns() async throws {
            for result in results.withLock({ $0 }) {
                try await result.value(operation: "requested scheduling loop finishes")
            }
        }
        func drainAgents() async throws {
            let result = Cell<Void>()
            let task = Task {
                await self.reconciler.waitForAgents()
                result.resolve(.success(()))
            }
            runs.withLock { $0.append(task) }
            try await result.value(operation: "owned steps finish")
        }
        func stopHolding(_ id: NodeID, parent: NodeID, reason: Release) async throws {
            switch reason {
            case .landed:
                try await record(id, [.runFinished(run: "existing-\(id)", outcome: "landed"),
                                      .landed(commit: "landed-\(id)"), .phaseChanged(to: .proven)])
            case .escalated: try await record(id, [.flagSet(.escalated, reason: "Human intervention")])
            case .needsInput: try await record(id, [.flagSet(.needsInput, reason: "Human answer needed")])
            case .closed: await tracker.setClosed(id)
            case .replanned:
                let spec = try #require(await ledger.workingState().nodes[parent]?.spec)
                try await record(parent, [.replanned(spec: spec)])
            }
        }
        func cleanup() async throws {
            probe.release.resolve(.success(()))
            agents.release.resolve(.success(()))
            workspace.landingRelease.resolve(.success(()))
            let tasks = runs.withLock { $0 }
            let result = Cell<Void>()
            let cleanup = Task {
                for task in tasks { await task.value }
                await self.reconciler.shutdown(reason: "GH-77 cleanup")
                result.resolve(.success(()))
            }
            do { try await result.value(operation: "released fixtures drain and shut down") }
            catch {
                for task in tasks { task.cancel() }
                cleanup.cancel()
                throw error
            }
            try FileManager.default.removeItem(at: root)
        }
    }

    static func withFixture(
        limit: Int, settingOn: Bool = true, expectedEntries: Int = 1,
        holdBeforeClaim: Bool = true, holdImplementer: Bool = false, holdLanding: Bool = false,
        _ body: @Sendable (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture(limit: limit, settingOn: settingOn, expectedEntries: expectedEntries,
                                  holdBeforeClaim: holdBeforeClaim, holdImplementer: holdImplementer,
                                  holdLanding: holdLanding)
        do { try await body(fixture) }
        catch {
            try await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    actor WorkspaceFake: Workspace {
        nonisolated let root: URL
        nonisolated let landingEntered = Cell<Void>()
        nonisolated let landingRelease = Cell<Void>()
        let holdLanding: Bool
        init(root: URL, holdLanding: Bool) { self.root = root; self.holdLanding = holdLanding }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("GH-77 implementers ask a question rather than submit")
        }
        func head(of directory: URL) async throws -> String { "candidate-\(directory.lastPathComponent)" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            if directory.lastPathComponent == "queued" {
                landingEntered.resolve(.success(()))
                if holdLanding { try await landingRelease.value(operation: "release waiting landing") }
            }
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed-\(id)" }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor Tracker: TrackerAdapter {
        var tickets: [String: Ticket] = [:]
        var closed: Set<String> = []
        func add(_ ticket: Ticket) { tickets[ticket.key] = ticket }
        func setClosed(_ key: String) { closed.insert(key) }
        func pendingSignals() -> [AgentOSCore.Signal] { [] }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func consume(_ signal: AgentOSCore.Signal, reply: String) { Issue.record("No human signal expected") }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("No GH-77 child creation expected")
        }
        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }
        func isClosed(_ key: String) -> Bool { closed.contains(key) }
    }
    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Passed", log: "Passed")
        }
    }
}
