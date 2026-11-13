// API contract: GH-48 supplies nonblocking runRound() and waitForAgents().
// Reconciler's beforeStep hook observes an owned step before runStarted.
// The MainActor HarnessLifecycleController in AgentOSAdapters is the shared app lifecycle boundary:
// pause preserves work; stopAndWait, close, quit and replacement drain it before returning/calling back.
// Legacy synchronous-round callers and Simulation.step must migrate in GH-48, not in this suite.

import Darwin
import Foundation
import Testing
import AgentOSCore
import AgentOSAdapters

@Suite @MainActor
struct GH_52Tests {
    @Test(arguments: [Phase.ready, .checking])
    func stoppingAnEarlierRoundWaitsForCleanupAndRequiresHumanRetry(_ phase: Phase) async throws {
        try await Self.withFixture(phases: [phase, .ready]) { fixture in
            _ = try await fixture.round()
            let worker = fixture.workers[0]
            try await Self.requireOpen(worker.started)
            try await Self.requireOpen(fixture.workers[1].started)
            _ = try await fixture.round()
            let run = try #require(await fixture.node(0)?.activeRun?.run)
            let neighbour = try #require(await fixture.node(1)?.activeRun?.run)
            let before = try #require(await fixture.node(0)).failedAttempts
            let finished = Gate()
            let stop = Task {
                do {
                    try await fixture.reconciler.stopRun(run, by: "Morgan")
                    await finished.open()
                } catch {
                    await finished.open()
                    throw error
                }
            }

            try await Self.requireOpen(worker.cancelled)
            try await Self.requireOpen(worker.processCleaned)
            #expect(worker.tree.livingPIDs.isEmpty)
            #expect(!(await finished.isOpen), "Stop must also join the still-blocked task cleanup")
            await worker.allowCleanup.open()
            try await stop.value

            try await fixture.reconciler.stopRun(run, by: "Morgan")
            let records = await fixture.ledger.allRecords()
            let finish = try #require(Self.finishes(run, in: records).first)
            #expect(Self.finishes(run, in: records).count == 1)
            #expect(finish.outcome.lowercased().contains("stop"))
            #expect(finish.outcome.contains("Morgan"))
            #expect(await fixture.node(0)?.activeRun == nil)
            #expect(await fixture.node(0)?.failedAttempts == before)
            #expect(await fixture.node(0)?.flags[.escalated]?.contains("harness:retry") == true)
            #expect(await fixture.node(1)?.activeRun?.run == neighbour)
            #expect(!(await fixture.workers[1].cancelled.isOpen))
            #expect(fixture.workers[1].tree.livingPIDs.count == 3)
            #expect(await fixture.tracker.comments.contains {
                $0.contains("Morgan") && $0.contains("harness:retry")
            })
            #expect(!records.contains {
                $0.event.node == fixture.ids[0] && Self.isFailedAttempt($0)
                    && $0.position > fixture.seedEnd
            })
            #expect(!records.contains {
                if case .evidenceRecorded(let evidence) = $0.event.kind {
                    return evidence.checkedBy == run
                }
                return false
            }, "A cancelled check must not publish its late result")

            let starts = Self.starts(in: records)
            for _ in 0..<2 { _ = try await fixture.round() }
            #expect(Self.starts(in: await fixture.ledger.allRecords()) == starts)
            #expect(await worker.calls == 1)

            let reopened = try Ledger(store: fixture.store)
            #expect(Self.finishes(run, in: await reopened.allRecords()).count == 1)
            #expect(await reopened.workingState().nodes[fixture.ids[0]]?.activeRun == nil)
            #expect(await reopened.workingState().nodes[fixture.ids[1]]?.activeRun?.run == neighbour)
        }
    }

    @Test
    func shutdownJoinsEarlierAgentsChecksAndStepsReservedBeforeTheirClaim() async throws {
        try await Self.withFixture(phases: [.ready, .checking, .ready], reserve: 2) { fixture in
            _ = try await fixture.round()
            for worker in fixture.workers.prefix(2) { try await Self.requireOpen(worker.started) }
            try await Self.requireOpen(fixture.observer.reserved)
            #expect(await fixture.node(2)?.activeRun == nil)
            #expect(await fixture.workers[2].calls == 0)
            _ = try await fixture.round()
            let runs = Self.starts(in: await fixture.ledger.allRecords())
            #expect(runs.count == 2)

            let finished = Gate()
            let shutdown = Task {
                await fixture.reconciler.shutdown(reason: "application quit")
                #expect(await fixture.observer.didExit)
                for worker in fixture.workers.prefix(2) { #expect(await worker.didExit) }
                await finished.open()
            }
            for worker in fixture.workers.prefix(2) {
                try await Self.requireOpen(worker.cancelled)
                try await Self.requireOpen(worker.processCleaned)
            }
            try await Self.requireOpen(fixture.observer.cancelled)
            #expect(!(await finished.isOpen))
            for worker in fixture.workers.prefix(2) { await worker.allowCleanup.open() }
            #expect(!(await finished.isOpen), "The pre-claim reservation is still owned and blocked")
            await fixture.observer.release.open()
            await shutdown.value
            await fixture.reconciler.waitForAgents()

            #expect(await fixture.observer.didExit)
            #expect(await fixture.workers[2].calls == 0)
            let records = await fixture.ledger.allRecords()
            #expect(Self.starts(in: records) == runs, "No reserved agent may start after shutdown begins")
            try await fixture.expectDrained(runs: runs, reason: "application quit")
            await fixture.reconciler.shutdown(reason: "repository window closed")
            _ = try await fixture.round()
            #expect(await fixture.ledger.allRecords().count == records.count)
        }
    }

    @Test(arguments: ["repository window closed", "application quit"])
    func appCloseAndQuitAwaitEarlierRoundAgentsAndChecksAndKeepTheirReason(_ reason: String) async throws {
        try await Self.withFixture(phases: [.ready, .checking]) { fixture in
            let lifecycle = HarnessLifecycleController(reconciler: fixture.reconciler)
            _ = try await fixture.round(using: lifecycle)
            for worker in fixture.workers { try await Self.requireOpen(worker.started) }
            _ = try await fixture.round(using: lifecycle)
            let runs = Self.starts(in: await fixture.ledger.allRecords())
            #expect(runs.count == 2)
            let completed = Gate()
            let closing = Task { @MainActor in
                if reason == "repository window closed" {
                    await lifecycle.close()
                } else {
                    await lifecycle.shutdown(reason: reason)
                }
                for worker in fixture.workers { #expect(await worker.didExit) }
                await completed.open()
            }

            for worker in fixture.workers {
                try await Self.requireOpen(worker.cancelled)
                try await Self.requireOpen(worker.processCleaned)
                #expect(worker.tree.livingPIDs.isEmpty)
            }
            #expect(!(await completed.isOpen), "The app cannot finish closing while task cleanup is held")
            for worker in fixture.workers { await worker.allowCleanup.open() }
            await closing.value

            try await fixture.expectDrained(runs: runs, reason: reason)
            await lifecycle.shutdown(reason: reason)
            _ = try await fixture.round(using: lifecycle)
            #expect(Self.starts(in: await fixture.ledger.allRecords()) == runs)
            for run in runs {
                #expect(Self.finishes(run, in: await fixture.ledger.allRecords()).count == 1)
            }
        }
    }

    @Test(arguments: ["repository session", "simulator", "ledger restore", "simulation storage reset"])
    func appReplacementCannotTouchOldStorageUntilStopAndWaitHasDrainedIt(_ operation: String) async throws {
        try await Self.withFixture(phases: [.ready, .checking]) { fixture in
            try await Self.withFixture(phases: []) { replacement in
                let lifecycle = HarnessLifecycleController(reconciler: fixture.reconciler)
                _ = try await fixture.round(using: lifecycle)
                for worker in fixture.workers { try await Self.requireOpen(worker.started) }
                _ = try await fixture.round(using: lifecycle)
                let runs = Self.starts(in: await fixture.ledger.allRecords())
                let enteredReplacement = Gate()
                var recordsAtReplacement = -1

                let changing = Task { @MainActor in
                    try await lifecycle.replaceSession {
                        await enteredReplacement.open()
                        for worker in fixture.workers {
                            #expect(await worker.didExit, "\(operation) began before old task cleanup")
                            #expect(worker.tree.livingPIDs.isEmpty)
                        }
                        #expect(await fixture.ledger.workingState().running.isEmpty)
                        let records = await fixture.ledger.allRecords()
                        for run in runs { #expect(Self.finishes(run, in: records).count == 1) }
                        recordsAtReplacement = records.count
                        // This callback is the first point permitted to swap a session or touch its storage.
                        try await replacement.ledger.record(
                            ReadinessScan(branch: "main", commit: "replacement", findings: []))
                        return replacement.reconciler
                    }
                }
                for worker in fixture.workers {
                    await worker.complete.open()
                    try await Self.requireOpen(worker.processCleaned)
                }
                #expect(!(await enteredReplacement.isOpen))
                for worker in fixture.workers { await worker.allowCleanup.open() }
                try await changing.value
                #expect(await enteredReplacement.isOpen)
                #expect(recordsAtReplacement >= 0)

                await fixture.reconciler.waitForAgents()
                _ = try await replacement.round(using: lifecycle)
                #expect(await fixture.ledger.allRecords().count == recordsAtReplacement)
                for worker in fixture.workers { #expect(await worker.calls == 1) }
            }
        }
    }

    @Test
    func overlappingReplacementsRunOneAtATimeAndNoneStartsAfterShutdown() async throws {
        try await Self.withFixture(phases: []) { fixture in
            let lifecycle = HarnessLifecycleController(reconciler: fixture.reconciler)
            let entered = Gate()
            let release = Gate()
            let secondMade = Gate()
            let first = Task { @MainActor in
                try await lifecycle.replaceSession {
                    await entered.open()
                    _ = await release.wait()
                    return fixture.reconciler
                }
            }
            try await Self.requireOpen(entered)
            let second = Task { @MainActor in
                try await lifecycle.replaceSession { await secondMade.open(); return fixture.reconciler }
            }
            let closing = Task { @MainActor in await lifecycle.close() }
            await release.open()
            try await first.value
            try await second.value
            await closing.value
            #expect(!(await secondMade.isOpen), "A replacement started after shutdown")
            #expect(lifecycle.isShutDown && !lifecycle.isReplacing)
        }
    }

    @Test
    func stopAndWaitItselfJoinsCrossRoundWorkBeforeReturning() async throws {
        try await Self.withFixture(phases: [.ready, .checking]) { fixture in
            let lifecycle = HarnessLifecycleController(reconciler: fixture.reconciler)
            _ = try await fixture.round(using: lifecycle)
            for worker in fixture.workers { try await Self.requireOpen(worker.started) }
            _ = try await fixture.round(using: lifecycle)
            let finished = Gate()
            let stopping = Task { @MainActor in
                await lifecycle.stopAndWait()
                for worker in fixture.workers { #expect(await worker.didExit) }
                await finished.open()
            }
            for worker in fixture.workers {
                await worker.complete.open()
                try await Self.requireOpen(worker.processCleaned)
            }
            #expect(!(await finished.isOpen))
            for worker in fixture.workers { await worker.allowCleanup.open() }
            await stopping.value
            for worker in fixture.workers {
                #expect(await worker.didExit)
                #expect(worker.tree.livingPIDs.isEmpty)
            }
            #expect(await fixture.ledger.workingState().running.isEmpty)
        }
    }

    @Test
    func pauseLeavesStartedWorkAliveAndResumeDoesNotDuplicateIt() async throws {
        try await Self.withFixture(phases: [.ready]) { fixture in
            let lifecycle = HarnessLifecycleController(reconciler: fixture.reconciler)
            _ = try await fixture.round(using: lifecycle)
            let worker = fixture.workers[0]
            try await Self.requireOpen(worker.started)
            let run = try #require(await fixture.node(0)?.activeRun?.run)

            lifecycle.setRunning(false)
            #expect(!(await worker.cancelled.isOpen))
            #expect(worker.tree.livingPIDs.count == 3)
            #expect(await fixture.node(0)?.activeRun?.run == run)
            lifecycle.setRunning(true)
            for _ in 0..<2 { _ = try await fixture.round(using: lifecycle) }
            lifecycle.setRunning(false)

            #expect(!(await worker.cancelled.isOpen))
            #expect(await worker.calls == 1)
            #expect(Self.starts(in: await fixture.ledger.allRecords()) == [run])
            #expect(Self.finishes(run, in: await fixture.ledger.allRecords()).isEmpty)
            await worker.complete.open()
            await worker.allowCleanup.open()
            await fixture.reconciler.waitForAgents()
            #expect(await worker.didExit)
            #expect(worker.tree.livingPIDs.isEmpty)
            #expect(Self.finishes(run, in: await fixture.ledger.allRecords()).count == 1)
            #expect(await fixture.node(0)?.failedAttempts == 2)
        }
    }

    @Test(arguments: [false, true])
    func reopeningReclaimsEveryUnfinishedRunEvenWhenReadinessBlocksASession(_ blocked: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GH52-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
        let previous = try Ledger(store: store)
        let phases: [Phase] = [.building, .checking, .landing]
        for (index, phase) in phases.enumerated() {
            let spec = Self.spec(index)
            try await previous.append([
                LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .nodeCreated(spec: spec, ticket: spec.id)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: phase)),
                LedgerEvent(node: spec.id, by: .reconciler,
                            kind: .runStarted(run: "interrupted-\(index)",
                                              role: index == 0 ? .implementer : .verifier))
            ])
        }
        let reopened = try Ledger(store: store)
        if blocked {
            let scan = ReadinessScan(branch: "main", commit: "current", findings: [
                Finding(check: "baseline", severity: .blocker, title: "Baseline out of date"),
                Finding(check: "config", severity: .blocker, title: "Repo config needs attention")
            ])
            try await reopened.record(scan)
            #expect(RepositorySession.blockers(scan).count == 2)
            _ = try await RepositorySession.recoverInterruptedRuns(in: reopened)
            _ = try await RepositorySession.recoverInterruptedRuns(in: reopened)
        } else {
            let reconciler = Self.reconciler(
                ledger: reopened, workspace: Workspaces(directory: directory),
                workers: [], tracker: Tracker(), observer: ReservationObserver(node: nil))
            let notes = await reconciler.recoverAfterRestart()
            #expect(notes.count == 3)
            #expect(await reconciler.recoverAfterRestart().isEmpty)
            await reconciler.shutdown(reason: "test cleanup")
        }

        let durable = try Ledger(store: store)
        #expect(await durable.workingState().running.isEmpty)
        #expect(await durable.workingState().nodes[Self.spec(0).id]?.phase == .ready)
        let records = await durable.allRecords()
        for index in phases.indices {
            let finishes = Self.finishes("interrupted-\(index)", in: records)
            #expect(finishes.count == 1)
            let finish = try #require(finishes.first)
            #expect(finish.outcome.lowercased().contains("abandoned"))
            #expect(finish.outcome.lowercased().contains("restart"))
            #expect(await durable.workingState().nodes[Self.spec(index).id]?.failedAttempts == 0)
        }
        #expect(await durable.verifyChain().isIntact)
    }

    private static func withFixture(
        phases: [Phase], reserve: Int? = nil, body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(phases: phases, reserve: reserve)
        do {
            try await body(fixture)
        } catch {
            try await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    private static func requireOpen(_ gate: Gate) async throws {
        guard await gate.wait() else { throw AgentFailure("Timed out waiting for GH-52 fixture synchronization") }
    }

    nonisolated private static func eventually(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AgentFailure("GH-52 child process did not become ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated private static func spec(_ index: Int) -> NodeSpec {
        NodeSpec(id: "wn-GH-52-\(index)", kind: .leaf, title: "Drain owned work \(index)",
                 intent: "Never write after replacement", acceptanceCriteria: ["Cleanup is joined"], touches: ["App"])
    }

    nonisolated private static func starts(in records: [RecordedEvent]) -> [RunID] {
        records.compactMap {
            if case .runStarted(let run, _) = $0.event.kind { return run }
            return nil
        }
    }

    private struct Finish: Sendable {
        let outcome: String
    }

    nonisolated private static func finishes(_ run: RunID, in records: [RecordedEvent]) -> [Finish] {
        records.compactMap {
            if case .runFinished(let id, let outcome) = $0.event.kind, id == run {
                return Finish(outcome: outcome)
            }
            return nil
        }
    }

    nonisolated private static func isFailedAttempt(_ record: RecordedEvent) -> Bool {
        if case .attemptFailed = record.event.kind { return true }
        return false
    }

    nonisolated private static func reconciler(
        ledger: Ledger, workspace: Workspaces, workers: [Worker], tracker: Tracker,
        observer: ReservationObserver
    ) -> Reconciler {
        let work = Work(workers: Dictionary(uniqueKeysWithValues: workers.map { ($0.id, $0) }))
        return Reconciler(
            ledger: ledger, tracker: tracker, external: NoExternal(), workspace: workspace,
            artifacts: Artifacts(), checks: work,
            team: AgentTeam(name: "GH-52", decomposer: work, testAuthor: work, implementer: work),
            policy: Policy(maxParallelAgents: 3), beforeStep: { await observer.stepReserved(for: $0) })
    }

    @MainActor private struct Fixture {
        let directory: URL
        let store: FileLedgerStore
        let ledger: Ledger
        let tracker: Tracker
        let reconciler: Reconciler
        let workers: [Worker]
        let ids: [NodeID]
        let observer: ReservationObserver
        let seedEnd: Int

        init(phases: [Phase], reserve: Int?) async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "GH52-lifecycle-\(UUID())")
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
            ledger = try Ledger(store: store)
            tracker = Tracker()
            let ids = phases.indices.map { GH_52Tests.spec($0).id }
            self.ids = ids
            let workers = try ids.map { try Worker(id: $0, directory: directory.appending(path: $0)) }
            self.workers = workers
            let observer = ReservationObserver(node: reserve.map { ids[$0] })
            self.observer = observer
            reconciler = GH_52Tests.reconciler(
                ledger: ledger, workspace: Workspaces(directory: directory),
                workers: workers, tracker: tracker, observer: observer)
            for (index, phase) in phases.enumerated() {
                let spec = GH_52Tests.spec(index)
                let folder = directory.appending(path: "\(spec.id)/Tests/\(spec.testTarget)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "fixed acceptance tests".write(to: folder.appending(path: "fixture.txt"),
                                                   atomically: true, encoding: .utf8)
                try await ledger.append([
                    LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .nodeCreated(spec: spec, ticket: spec.id)),
                    LedgerEvent(node: spec.id, by: .human("Morgan"), kind: .gateOpened(.build)),
                    LedgerEvent(node: spec.id, by: .reconciler,
                                kind: .testsFixed(digest: Hashing.digest(of: folder))),
                    LedgerEvent(node: spec.id, by: .agent(run: "prior-builder-\(index)", role: .implementer),
                                kind: .changeSubmitted(run: "prior-builder-\(index)", commit: "candidate")),
                    LedgerEvent(node: spec.id, by: .reconciler, kind: .attemptFailed(summary: "prior failure one")),
                    LedgerEvent(node: spec.id, by: .reconciler, kind: .attemptFailed(summary: "prior failure two")),
                    LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: phase))
                ])
            }
            seedEnd = await ledger.workingState().asOf
        }

        func node(_ index: Int) async -> NodeState? { await ledger.workingState().nodes[ids[index]] }

        @MainActor
        func round(using lifecycle: HarnessLifecycleController? = nil) async throws -> RoundReport {
            let returned = Gate()
            let task = Task {
                let report: RoundReport
                if let lifecycle { report = await lifecycle.step() }
                else { report = await reconciler.runRound() }
                await returned.open()
                return report
            }
            guard await returned.wait() else {
                await releaseAll()
                task.cancel()
                _ = await task.value
                throw AgentFailure("GH-48 prerequisite missing: a round waited for deliberately blocked owned work")
            }
            let report = await task.value
            #expect(report.safeStop == nil)
            return report
        }

        @MainActor
        func expectDrained(runs: [RunID], reason: String) async throws {
            for worker in workers {
                #expect(worker.tree.livingPIDs.isEmpty)
                if await worker.calls > 0 { #expect(await worker.didExit) }
            }
            let records = await ledger.allRecords()
            for run in runs {
                let finishes = GH_52Tests.finishes(run, in: records)
                #expect(finishes.count == 1)
                #expect(try #require(finishes.first).outcome.contains(reason))
            }
            #expect(await ledger.workingState().running.isEmpty)
            for id in ids { #expect(await ledger.workingState().nodes[id]?.failedAttempts == 2) }
            #expect(await ledger.verifyChain().isIntact)
        }

        func releaseAll() async {
            await observer.release.open()
            for worker in workers {
                await worker.complete.open()
                await worker.allowCleanup.open()
            }
        }

        func cleanup() async throws {
            await releaseAll()
            await reconciler.shutdown(reason: "test cleanup")
            await reconciler.waitForAgents()
            for worker in workers { worker.tree.killOwnedProcesses() }
            try FileManager.default.removeItem(at: directory)
        }
    }

    // Gates ignore cancellation deliberately: cancellation and cleanup completion are distinct events.
    // Each wait has a watchdog so a broken implementation reports failure instead of hanging the suite.
    private actor Gate {
        private(set) var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        private var timers: [UUID: Task<Void, Never>] = [:]

        func wait() async -> Bool {
            if isOpen { return true }
            let id = UUID()
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation
                timers[id] = Task {
                    do { try await Task.sleep(for: .seconds(8)) }
                    catch { return }
                    expire(id)
                }
            }
        }

        func open() {
            isOpen = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            for timer in timers.values { timer.cancel() }
            timers.removeAll()
            for continuation in pending { continuation.resume(returning: true) }
        }

        private func expire(_ id: UUID) {
            timers[id] = nil
            waiters.removeValue(forKey: id)?.resume(returning: false)
        }
    }

    private actor ReservationObserver {
        let node: NodeID?
        let reserved = Gate()
        let cancelled = Gate()
        let release = Gate()
        private(set) var didExit = false

        init(node: NodeID?) { self.node = node }

        func stepReserved(for id: NodeID) async {
            guard id == node else { return }
            let cancelled = cancelled
            await withTaskCancellationHandler {
                await reserved.open()
                #expect(await release.wait(), "Reserved step cleanup was never released")
            } onCancel: {
                Task { await cancelled.open() }
            }
            didExit = true
        }
    }

    private actor Worker {
        nonisolated let id: NodeID
        nonisolated let tree: ProcessTree
        let started = Gate()
        let cancelled = Gate()
        let processCleaned = Gate()
        let complete = Gate()
        let allowCleanup = Gate()
        private(set) var calls = 0
        private(set) var didExit = false

        init(id: NodeID, directory: URL) throws {
            self.id = id
            tree = try ProcessTree(directory: directory)
        }

        func perform() async throws {
            calls += 1
            let tree = tree
            let process = Task {
                try await ProcessRunner.run("/bin/sh", ["parent.sh"], in: tree.directory, timeout: .seconds(20))
            }
            let cancelled = cancelled
            let complete = complete
            do {
                try await GH_52Tests.eventually { tree.livingPIDs.count == 3 }
                await withTaskCancellationHandler {
                    await started.open()
                    #expect(await complete.wait(), "Worker was neither completed nor cancelled")
                } onCancel: {
                    process.cancel()
                    Task {
                        await cancelled.open()
                        await complete.open()
                    }
                }
                process.cancel()
                _ = await process.result
                await processCleaned.open()
                #expect(await allowCleanup.wait(), "Task cleanup was never released")
                didExit = true
                try Task.checkCancellation()
            } catch {
                process.cancel()
                _ = await process.result
                didExit = true
                throw error
            }
        }
    }

    private struct ProcessTree: Sendable {
        let directory: URL

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try """
                echo $$ > parent.pid
                /bin/sh child.sh &
                wait
                """.write(to: directory.appending(path: "parent.sh"), atomically: true, encoding: .utf8)
            try """
                trap '' TERM
                echo $$ > child.pid
                /bin/sleep 30 &
                echo $! > grandchild.pid
                wait
                """.write(to: directory.appending(path: "child.sh"), atomically: true, encoding: .utf8)
        }

        private var pids: [pid_t] {
            ["parent.pid", "child.pid", "grandchild.pid"].compactMap { name in
                guard let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8),
                      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
                return pid
            }
        }
        var livingPIDs: [pid_t] { pids.filter { kill($0, 0) == 0 || errno == EPERM } }
        func killOwnedProcesses() {
            for pid in livingPIDs.reversed() { _ = kill(pid, SIGKILL) }
        }
    }

    private struct Work: Implementer, TestAuthor, Decomposer, CheckRunner {
        let workers: [NodeID: Worker]

        func implement(_ task: AgentTask) async throws -> AgentReport {
            guard let worker = workers[task.spec.id] else { throw AgentFailure("Unexpected GH-52 agent") }
            try await worker.perform()
            return AgentReport()
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            guard let worker = workers[directory.lastPathComponent] else {
                Testing.Issue.record("Unexpected GH-52 check")
                return CheckOutput(passed: false, summary: "Unexpected check", log: "")
            }
            do {
                try await worker.perform()
                return CheckOutput(passed: true, summary: "passed", log: "passed")
            } catch {
                return CheckOutput(passed: false, summary: "\(error)", log: "\(error)")
            }
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-52 fixture does not schedule test authoring")
        }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-52 fixture does not schedule decomposition")
        }
    }

    private struct Workspaces: Workspace {
        let directory: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "candidate" }
        func head(of directory: URL) async throws -> String { "candidate" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    private actor Tracker: TrackerAdapter {
        private(set) var comments: [String] = []
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) { comments.append(reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { spec.id }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    private struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
