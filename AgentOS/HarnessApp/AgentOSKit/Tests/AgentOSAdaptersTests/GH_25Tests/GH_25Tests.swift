// API contract: Reconciler.stopRun(_:by:) and shutdown(reason:) await task/process-tree cleanup;
// RepositorySession.recoverInterruptedRuns(in:) works without a runnable session. Running-now controls
// use HarnessViewModel.canStopRun(node:run:), stopRun(node:run:) and HarnessActions.stopRun(node:run:by:).
// CommandCheckRunner adds idleTimeout (default 600 seconds). All new signatures are in .agentos-report.json.

import Darwin
import Foundation
import Testing
import AgentOSCore
@testable import AgentOSAdapters
@testable import AgentOSUI

@Suite
struct GH_25Tests {
    @Test(arguments: [
        FailurePoint.rebase, .prepareLanding, .candidateHead, .merge, .preparePreCheck, .prepareAgent
    ])
    func throwingAfterARecordedStartAlwaysRecordsOneFinishWithTheError(_ failure: FailurePoint) async throws {
        let fixture = try await Fixture(failure: failure, command: "printf 'checks passed\\n'")
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let records = await fixture.ledger.allRecords()
        let starts = Self.starts(in: records)
        #expect(!starts.isEmpty, "The injected error must happen after a recorded start")
        for run in starts {
            let finishes = Self.finishes(for: run, in: records)
            #expect(finishes.count == 1)
            let outcome = try #require(finishes.first).outcome.lowercased()
            #expect(outcome.contains("error") || outcome.contains("fail"))
            #expect(outcome.contains(failure.message.lowercased()))
        }
        #expect(await fixture.ledger.workingState().running.isEmpty)
    }

    @Test(arguments: [Phase.ready, .checking, .landing])
    func aNormallyExitedTaskIsNotLeftInRunningNow(_ phase: Phase) async throws {
        let fixture = try await Fixture(phase: phase, command: "printf 'finished normally\\n'")
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        #expect(await fixture.probe.active == 0)
        let state = await fixture.ledger.workingState()
        #expect(state.running.isEmpty)
        let records = await fixture.ledger.allRecords()
        #expect(!Self.starts(in: records).isEmpty)
        for run in Self.starts(in: records) {
            #expect(Self.finishes(for: run, in: records).count == 1)
        }
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor, .implementer, .verifier])
    @MainActor
    func runningNowOffersStopForEveryRoleAndAttributesItToThePerson(_ role: AgentRole) async throws {
        let fixture = try await Fixture(role: role)
        defer { fixture.cleanup() }
        let watchdog = fixture.tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let round = Task { await fixture.reconciler.runRound(waitForAgents: true) }
        defer { round.cancel() }
        try await Self.eventually { fixture.tree.isReady }
        let node = try #require(await fixture.node())
        let run = try #require(node.activeRun)
        #expect(run.role == role)

        let actions = StopActions(reconciler: fixture.reconciler)
        let model = HarnessViewModel()
        model.you = "Morgan"
        model.actions = actions
        model.state = await fixture.ledger.workingState()
        #expect(model.canStopRun(node: node.id, run: run.run))
        #expect(!model.canStopRun(node: node.id, run: "not-the-active-run"))

        let started = ContinuousClock.now
        await model.stopRun(node: node.id, run: run.run)
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(actions.requests == [StopRequest(node: node.id, run: run.run, person: "Morgan")])
        #expect(actions.error == nil)
        #expect(fixture.tree.livingPIDs.isEmpty, "Stop must await cleanup, not just request it")
        _ = await round.value

        let records = await fixture.ledger.allRecords()
        let finish = try #require(Self.finishes(for: run.run, in: records).only)
        #expect(finish.outcome.lowercased().contains("stopped"))
        #expect(finish.outcome.contains("Morgan"))
        #expect(await fixture.node()?.failedAttempts == 0)
        #expect(await fixture.probe.active == 0)
        model.state = await fixture.ledger.workingState()
        #expect(model.state.running.isEmpty)
        #expect(!model.canStopRun(node: node.id, run: run.run))
        #expect(await fixture.tracker.comments.contains {
            $0.lowercased().contains("stop") && $0.contains("Morgan") && $0.contains("harness:retry")
        })
    }

    @Test
    func aStoppedNodeDoesNotRestartUntilAHumanRetries() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        try await fixture.ledger.append([
            LedgerEvent(node: fixture.spec.id, by: .reconciler, kind: .attemptFailed(summary: "prior failure one")),
            LedgerEvent(node: fixture.spec.id, by: .reconciler, kind: .attemptFailed(summary: "prior failure two")),
        ])
        let watchdog = fixture.tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let round = Task { await fixture.reconciler.runRound(waitForAgents: true) }
        defer { round.cancel() }
        try await Self.eventually { fixture.tree.isReady }
        let run = try #require(await fixture.node()?.activeRun?.run)
        try await fixture.reconciler.stopRun(run, by: "Morgan")
        _ = await round.value
        let startCount = Self.starts(in: await fixture.ledger.allRecords()).count

        for _ in 0..<3 { _ = await fixture.reconciler.runRound(waitForAgents: true) }

        #expect(Self.starts(in: await fixture.ledger.allRecords()).count == startCount)
        #expect(await fixture.node()?.failedAttempts == 2, "Stop neither adds an attempt nor erases prior failures")
        #expect(await fixture.ledger.workingState().running.isEmpty)

        try fixture.tree.removePIDFiles()
        await fixture.tracker.retry()
        let retryRound = Task { await fixture.reconciler.runRound(waitForAgents: true) }
        defer { retryRound.cancel() }
        try await Self.eventually { fixture.tree.isReady }
        let retriedRun = try #require(await fixture.node()?.activeRun?.run)
        #expect(retriedRun != run)
        #expect(Self.starts(in: await fixture.ledger.allRecords()).count == startCount + 1)
        try await fixture.reconciler.stopRun(retriedRun, by: "Morgan")
        _ = await retryRound.value
        #expect(await fixture.node()?.failedAttempts == 0)
    }

    @Test(arguments: [Phase.checking, .landing])
    func stoppingACheckDoesNotCreateAnOwnMistakeOrLandItsLateResult(_ phase: Phase) async throws {
        let fixture = try await Fixture(phase: phase)
        defer { fixture.cleanup() }
        let watchdog = fixture.tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let round = Task { await fixture.reconciler.runRound(waitForAgents: true) }
        defer { round.cancel() }
        try await Self.eventually { fixture.tree.isReady }
        let run = try #require(await fixture.node()?.activeRun?.run)

        try await fixture.reconciler.stopRun(run, by: "Morgan")
        _ = await round.value

        #expect(await fixture.node()?.failedAttempts == 0)
        #expect(await fixture.node()?.landedCommit == nil)
        #expect(await fixture.ledger.workingState().running.isEmpty)
        let records = await fixture.ledger.allRecords()
        #expect(Self.finishes(for: run, in: records).count == 1)
        #expect(!records.contains {
            if case .evidenceRecorded(let evidence) = $0.event.kind {
                return evidence.checkedBy == run && evidence.failureClassification == .ownMistake
            }
            return false
        })
        #expect(fixture.tree.livingPIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func timeoutAndTaskCancellationKillChildrenAndGrandchildren(_ cancel: Bool) async throws {
        let tree = try ProcessTree()
        defer { tree.cleanup() }
        let watchdog = tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let task = Task {
            try await ProcessRunner.run(
                "/bin/sh", ["parent.sh"], in: tree.directory,
                timeout: cancel ? .seconds(20) : .seconds(2)
            )
        }
        defer { task.cancel() }
        try await Self.eventually { tree.isReady }
        #expect(tree.livingPIDs.count == 3)
        let started = ContinuousClock.now

        if cancel { task.cancel() }
        let result = await task.result

        #expect(ContinuousClock.now - started < .seconds(4))
        if case .success(let output) = result { #expect(output.status != 0) }
        #expect(tree.livingPIDs.isEmpty, "The runner returned while descendants were still alive")
    }

    @Test(arguments: [false, true])
    func openingARepositoryAbandonsOldRunsEvenWithoutAStartableSession(_ blocked: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GH25-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
        let previous = try Ledger(store: store)
        for (index, role) in [AgentRole.implementer, .verifier].enumerated() {
            let spec = Self.spec(id: "wn-old-\(index)")
            try await previous.append([
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .nodeCreated(spec: spec, ticket: "OLD-\(index)")),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: index == 0 ? .building : .landing)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .runStarted(run: "old-\(index)", role: role)),
            ])
        }
        let reopened = try Ledger(store: store)
        if blocked {
            let scan = ReadinessScan(branch: "main", commit: "new-main", findings: [
                Finding(check: "baseline", severity: .blocker, title: "Baseline out of date"),
                Finding(check: "config", severity: .blocker, title: "Repo config needs attention"),
            ])
            try await reopened.record(scan)
            #expect(RepositorySession.blockers(scan).count == 2)
        }

        // The repository-open hook cannot require a RepositorySession or working workspace.
        _ = try await RepositorySession.recoverInterruptedRuns(in: reopened)
        _ = try await RepositorySession.recoverInterruptedRuns(in: reopened)

        #expect(await reopened.workingState().running.isEmpty)
        let replayed = try Ledger(store: store)
        #expect(await replayed.workingState().running.isEmpty)
        let records = await replayed.allRecords()
        for run in ["old-0", "old-1"] {
            let finish = try #require(Self.finishes(for: run, in: records).only)
            #expect(finish.outcome.lowercased().contains("abandoned"))
            #expect(finish.outcome.lowercased().contains("restart"))
        }
        #expect(await replayed.verifyChain().isIntact)
    }

    @Test(arguments: ["repository window closed", "application quit"])
    func repositoryCloseAndAppQuitAwaitAllRunningTasksAndTheirChildren(_ reason: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let watchdog = fixture.tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let second = Self.spec(id: "wn-GH-25-check")
        try await fixture.seed(second, phase: .checking)
        let round = Task { await fixture.reconciler.runRound(waitForAgents: true) }
        defer { round.cancel() }
        try await Self.eventually { await fixture.probe.active == 2 }
        try await Self.eventually { fixture.tree.livingPIDs.count == 6 }
        let runs = await fixture.ledger.workingState().running.compactMap(\.activeRun?.run)
        #expect(runs.count == 2)

        let started = ContinuousClock.now
        await fixture.reconciler.shutdown(reason: reason)
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(await fixture.probe.active == 0)
        #expect(fixture.tree.livingPIDs.isEmpty)
        #expect(await fixture.ledger.workingState().running.isEmpty)
        _ = await round.value

        let records = await fixture.ledger.allRecords()
        for run in runs {
            let finish = try #require(Self.finishes(for: run, in: records).only)
            #expect(finish.outcome.lowercased().contains(reason))
        }
        #expect(await fixture.node()?.failedAttempts == 0)
        #expect(await fixture.ledger.workingState().nodes[second.id]?.failedAttempts == 0)
        await fixture.reconciler.shutdown(reason: reason)
        for run in runs {
            #expect(Self.finishes(for: run, in: await fixture.ledger.allRecords()).count == 1)
        }
    }

    @Test(arguments: ["prepare", "build", "test", "extra"])
    func aSilentCheckIsEndedAsHungBeforeItsFullTimeoutAndRetainsItsLogTail(_ step: String) async throws {
        let tree = try ProcessTree()
        defer { tree.cleanup() }
        let watchdog = tree.cleanupWatchdog()
        defer { watchdog.cancel() }
        let hanging = "printf 'last diagnostic before silence\\n'; /bin/sh parent.sh"
        let config = RepoConfig(
            build: .init(prepare: step == "prepare" ? hanging : nil, command: step == "build" ? hanging : nil),
            test: .init(command: step == "test" ? hanging : "printf 'tests passed\\n'"),
            checks: step == "extra" ? [.init(name: "extra", command: hanging)] : nil
        )
        let defaultRunner = CommandCheckRunner(config: config)
        #expect(defaultRunner.idleTimeout == .seconds(600))
        let runner = CommandCheckRunner(config: config, timeout: .seconds(20), idleTimeout: .seconds(1))

        let started = ContinuousClock.now
        let output = await runner.runChecks(in: tree.directory, only: nil)

        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(!output.passed)
        #expect(output.summary.lowercased().contains("hung"))
        #expect(output.summary.contains(step))
        #expect(output.log.contains("last diagnostic before silence"))
        #expect(output.log.lowercased().contains("hung"))
        #expect(tree.livingPIDs.isEmpty)
    }

    @Test
    func outputWithoutNewlinesResetsTheIdleDeadline() async throws {
        let tree = try ProcessTree()
        defer { tree.cleanup() }
        let config = RepoConfig(test: .init(command: """
            i=0
            while [ "$i" -lt 8 ]; do
                printf '.'
                /bin/sleep 0.2
                i=$((i + 1))
            done
            """))
        let runner = CommandCheckRunner(config: config, timeout: .seconds(5), idleTimeout: .seconds(1))

        let started = ContinuousClock.now
        let output = await runner.runChecks(in: tree.directory, only: nil)

        #expect(ContinuousClock.now - started > .seconds(1))
        #expect(output.passed)
        #expect(output.log.contains("........"))
        #expect(!output.summary.lowercased().contains("hung"))
    }

    private static func spec(id: NodeID = "wn-GH-25", kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(id: id, parent: nil, kind: kind, title: "Stop runs",
                 intent: "Never leave work silently running", acceptanceCriteria: ["Runs end durably"])
    }

    private static func starts(in records: [RecordedEvent]) -> [RunID] {
        records.compactMap {
            if case .runStarted(let run, _) = $0.event.kind { return run }
            return nil
        }
    }

    private struct Finish {
        let outcome: String
    }

    private static func finishes(for run: RunID, in records: [RecordedEvent]) -> [Finish] {
        records.compactMap {
            if case .runFinished(let finished, let outcome) = $0.event.kind, finished == run {
                return Finish(outcome: outcome)
            }
            return nil
        }
    }

    private static func eventually(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw AgentFailure("Timed out waiting for the acceptance-test fixture to become ready")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    enum FailurePoint: String, Sendable {
        case rebase, prepareLanding, candidateHead, merge, preparePreCheck, prepareAgent
        var message: String { "injected GH-25 \(rawValue) error" }
        var phase: Phase {
            switch self {
            case .preparePreCheck: .checking
            case .prepareAgent: .ready
            default: .landing
            }
        }
    }

    private struct Fixture: Sendable {
        let tree: ProcessTree
        let ledger: Ledger
        let tracker: Tracker
        let reconciler: Reconciler
        let probe: Probe
        let spec: NodeSpec

        init(phase: Phase = .ready, role: AgentRole = .implementer,
             failure: FailurePoint? = nil, command: String? = nil) async throws {
            tree = try ProcessTree()
            ledger = try Ledger()
            tracker = Tracker()
            probe = Probe()
            spec = GH_25Tests.spec(kind: role == .decomposer ? .composite : .leaf)
            let work = Work(directory: tree.directory, command: command ?? "/bin/sh parent.sh", probe: probe)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: FakeWorkspace(directory: tree.directory, failure: failure),
                artifacts: MemoryArtifacts(), checks: work,
                team: AgentTeam(name: "GH-25", decomposer: work, testAuthor: work, implementer: work),
                policy: Policy(maxParallelAgents: 2)
            )
            let initialPhase: Phase
            if let failure { initialPhase = failure.phase }
            else if role == .decomposer || role == .testAuthor { initialPhase = .specified }
            else if role == .verifier { initialPhase = .checking }
            else { initialPhase = phase }
            try await seed(spec, phase: initialPhase)
        }

        func seed(_ spec: NodeSpec, phase: Phase) async throws {
            let folder = tree.directory.appending(path: "Tests/\(spec.testTarget)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "fixed acceptance fixture".write(to: folder.appending(path: "fixture.txt"),
                                                atomically: true, encoding: .utf8)
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .nodeCreated(spec: spec, ticket: spec.id)),
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .gateOpened(.build)),
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .gateOpened(.breakdown)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: folder))),
                LedgerEvent(node: spec.id, by: .agent(run: "builder", role: .implementer),
                            kind: .changeSubmitted(run: "builder", commit: "candidate")),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: phase)),
            ])
        }

        func node() async -> NodeState? { await ledger.workingState().nodes[spec.id] }
        func cleanup() { tree.cleanup() }
    }

    private actor Probe {
        private(set) var active = 0
        func enter() { active += 1 }
        func leave() { active -= 1 }
    }

    private struct Work: Decomposer, TestAuthor, Implementer, CheckRunner {
        let directory: URL
        let command: String
        let probe: Probe

        func perform() async throws {
            await probe.enter()
            do {
                let result = try await ProcessRunner.run("/bin/sh", ["-c", command], in: directory, timeout: .seconds(20))
                try Task.checkCancellation()
                guard result.status == 0 else { throw AgentFailure("fixture process ended: \(result.status)") }
                await probe.leave()
            } catch {
                await probe.leave()
                throw error
            }
        }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            try await perform()
            return Breakdown(children: [])
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            try await perform()
            return AgentReport()
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            try await perform()
            return AgentReport()
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            do {
                try await perform()
                return CheckOutput(passed: true, summary: "passed", log: "passed")
            } catch {
                return CheckOutput(passed: false, summary: "\(error)", log: "\(error)")
            }
        }
    }

    private struct FakeWorkspace: Workspace {
        let directory: URL
        let failure: FailurePoint?
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
        func head(of directory: URL) async throws -> String {
            try fail(at: .candidateHead)
            return "candidate"
        }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            try fail(at: .rebase)
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            try fail(at: .merge)
            return "landed"
        }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {
            for point in [FailurePoint.prepareLanding, .preparePreCheck, .prepareAgent] { try fail(at: point) }
        }
        private func fail(at point: FailurePoint) throws {
            if failure == point { throw AgentFailure(point.message) }
        }
    }

    private actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: "Stop runs", description: "Never silently leave work running",
                   acceptanceCriteria: ["Runs end durably"], createdBy: .human("Morgan"))
        }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { spec.id }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
        func retry() { signals.append(Signal(ticket: "wn-GH-25", command: .retry, setBy: .human("Morgan"))) }
    }

    private struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct StopRequest: Equatable {
        let node: NodeID
        let run: RunID
        let person: String
    }

    @MainActor
    private final class StopActions: HarnessActions {
        let reconciler: Reconciler
        var requests: [StopRequest] = []
        var error: String?
        init(reconciler: Reconciler) { self.reconciler = reconciler }
        func stopRun(node: NodeID, run: RunID, by person: String) async {
            requests.append(StopRequest(node: node, run: run, person: person))
            do { try await reconciler.stopRun(run, by: person) }
            catch { self.error = "\(error)" }
        }
        func addLabel(_ name: String, to key: String) async {}
        func removeLabel(_ name: String, from key: String) async {}
        func comment(_ text: String, on key: String) async {}
        func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func verifyChain() async {}
        func open(_ path: String) {}
    }

    private struct ProcessTree: Sendable {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH25-process-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try """
                mkdir "run-$$"
                cd "run-$$" || exit 1
                echo $$ > parent.pid
                /bin/sh ../child.sh &
                wait
                """.write(to: directory.appending(path: "parent.sh"), atomically: true, encoding: .utf8)
            try """
                trap '' TERM
                echo $$ > child.pid
                /bin/sleep 60 &
                echo $! > grandchild.pid
                wait
                """.write(to: directory.appending(path: "child.sh"), atomically: true, encoding: .utf8)
        }

        private var pidFiles: [URL] {
            let runs = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            return runs.filter { $0.lastPathComponent.hasPrefix("run-") }.flatMap { run in
                ["parent.pid", "child.pid", "grandchild.pid"].map { run.appending(path: $0) }
            }
        }
        private var pids: [pid_t] {
            pidFiles.compactMap {
                guard let text = try? String(contentsOf: $0, encoding: .utf8),
                      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
                return pid
            }
        }
        var isReady: Bool { !pids.isEmpty && pids.count.isMultiple(of: 3) }
        var livingPIDs: [pid_t] { pids.filter { kill($0, 0) == 0 || errno == EPERM } }

        func removePIDFiles() throws {
            for file in pidFiles where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        func killOwnedProcesses() {
            for pid in pids.reversed() where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
        func cleanup() {
            killOwnedProcesses()
            try? FileManager.default.removeItem(at: directory)
        }
        func cleanupWatchdog() -> Task<Void, Never> {
            Task {
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
                killOwnedProcesses()
            }
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
