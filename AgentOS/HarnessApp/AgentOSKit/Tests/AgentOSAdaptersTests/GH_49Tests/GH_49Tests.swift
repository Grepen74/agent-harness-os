// API contract: runRound() schedules without waiting; waitForAgents() drains durable cleanup without
// consuming actions. A scoped waitForAgents(for:) and an optional beforeStep initializer callback allow
// deterministic synchronization, including suspension after reservation but before runStarted.
import AgentOSAdapters
import AgentOSCore
import AgentOSSimulation
import Foundation
import Testing

@Suite struct GH_49Tests {
    @Test static func roundsReturnWhileAnEarlierStepIsStillRunning() async throws {
        try await withFixture { f in
            try await f.add("A")
            let first = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            #expect(first.safeStop == nil)
            #expect(!f.agents.release("A").isOpen)

            let later = try await bounded { await f.reconciler.runRound() }
            #expect(later.safeStop == nil)
            #expect(later.actions.isEmpty)
            #expect(!later.isIdle)
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun != nil)
            #expect(f.agents.starts == ["A"])
        }
    }

    @Test static func twoSlotsCountEarlierRoundsAndDoNotStartAThirdEligibleNode() async throws {
        try await withFixture(limit: 2) { f in
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            try await f.add("B")
            try await f.add("C")

            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.twoStarted.wait()
            let other = try #require(f.agents.starts.first { $0 != "A" })
            #expect(["B", "C"].contains(other))
            #expect(f.agents.starts.count == 2)
            #expect(await f.reconciler.busyNodes == Set(["A", other]))

            _ = try await bounded { await f.reconciler.runRound() }
            #expect(f.agents.starts.count == 2)
            #expect(await f.reconciler.busyNodes == Set(["A", other]))
            #expect(!f.agents.release("A").isOpen)
            #expect(!f.agents.release(other).isOpen)
        }
    }

    @Test static func theNextRoundFillsAFreedSlotWithoutWaitingForTheOtherStep() async throws {
        try await withFixture(limit: 2) { f in
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            try await f.add("B")
            try await f.add("C")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.twoStarted.wait()
            let finished = try #require(f.agents.starts.first { $0 != "A" })
            let remaining = finished == "B" ? "C" : "B"
            f.agents.release(finished).open()
            try await bounded { await f.reconciler.waitForAgents(for: [finished]) }

            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started(remaining).wait()
            #expect(!f.agents.release("A").isOpen)
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun != nil)
            #expect(await f.reconciler.busyNodes == Set(["A", remaining]))
        }
    }

    @Test static func waitingAlsoIncludesAStepThatHasNotRecordedItsClaimYet() async throws {
        try await withFixture(limit: 2) { f in
            f.beforeClaim.hold = true
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.beforeClaim.entered.wait()
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun == nil)

            let enteredWait = Signal()
            let returnedWait = Signal()
            let waiter = start {
                await observeWait(on: f.reconciler, entered: enteredWait, returned: returnedWait)
            }
            try await enteredWait.wait()
            // This must finish with the pre-claim barrier CLOSED. Ledger reads are never held.
            _ = try await bounded { await f.reconciler.runRound() }
            #expect(!returnedWait.isOpen)
            #expect(!f.beforeClaim.release.isOpen)
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun == nil)
            #expect(await f.reconciler.busyNodes == ["A"])

            f.beforeClaim.release.open()
            try await f.agents.started("A").wait()
            f.agents.release("A").open()
            try await waiter.value()
            try await bounded { await f.reconciler.waitForAgents(for: ["A"]) }
            #expect(f.beforeClaim.entries == ["A"])
            #expect(f.agents.starts == ["A"])
            #expect(await f.claimCount("A") == 1)
        }
    }

    @Test static func completionBeforeARoundIsReportedExactlyOnce() async throws {
        try await withFixture { f in
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            f.agents.release("A").open()
            try await bounded { await f.reconciler.waitForAgents() }

            let next = try await bounded { await f.reconciler.runRound() }
            #expect(next.actions.count == 1)
            let action = try #require(next.actions.first)
            #expect(action.contains("A"))
            #expect(!next.isIdle)
            let later = try await bounded { await f.reconciler.runRound() }
            #expect(!later.actions.contains(action))
            #expect(later.isIdle)
        }
    }

    @Test static func completionDuringAnAwaitIsIncludedInThatReturningRound() async throws {
        try await withFixture { f in
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            let roundBarrier = Barrier()
            await f.workspace.holdNextPrepare(roundBarrier)
            let round = start { await f.reconciler.runRound() }
            try await roundBarrier.entered.wait()

            f.agents.release("A").open()
            try await bounded { await f.reconciler.waitForAgents() }
            #expect(!round.isResolved)
            roundBarrier.release.open()
            let report = try await round.value()
            #expect(report.actions.count == 1)
            let action = try #require(report.actions.first)
            #expect(action.contains("A"))
            let next = try await bounded { await f.reconciler.runRound() }
            #expect(!next.actions.contains(action))
        }
    }

    @Test static func explicitWaitingDrainsCleanupWithoutSchedulingOrConsumingActions() async throws {
        try await withFixture { f in
            let cleanup = Barrier()
            await f.workspace.holdSnapshotCleanup(cleanup)
            try await f.add("A")
            _ = try await bounded { await f.reconciler.runRound() }
            try await f.agents.started("A").wait()
            try await f.add("B")
            let enteredWait = Signal()
            let returnedWait = Signal()
            let waiter = start {
                await observeWait(on: f.reconciler, entered: enteredWait, returned: returnedWait)
            }
            try await enteredWait.wait()
            f.agents.release("A").open()
            try await cleanup.entered.wait()
            #expect(!returnedWait.isOpen)
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun != nil)
            #expect(f.agents.starts == ["A"])

            cleanup.release.open()
            try await waiter.value()
            let records = await f.ledger.allRecords()
            #expect(records.contains {
                if case .runFinished = $0.event.kind { return $0.event.node == "A" }
                return false
            })
            #expect(await f.ledger.workingState().nodes["A"]?.activeRun == nil)
            #expect(await f.reconciler.busyNodes.isEmpty)
            #expect(f.agents.starts == ["A"])
            let report = try await bounded { await f.reconciler.runRound() }
            #expect(report.actions.filter { $0.contains("A") }.count == 1)
            let later = try await bounded { await f.reconciler.runRound() }
            #expect(later.actions.filter { $0.contains("A") }.isEmpty)
        }
    }

    @Test static func simulationStepReturnsFinishedEffectsAndTheirAction() async throws {
        try await withSimulation { sim, agents in
            try await seed("A", ledger: sim.ledger)
            let step = start {
                let report = await sim.step()
                let node = await sim.ledger.workingState().nodes["A"]
                return (report, node)
            }
            try await agents.started("A").wait()
            agents.release("A").open()
            let (report, node) = try await step.value()
            #expect(node?.activeRun == nil)
            #expect(node?.flags[.needsInput] != nil)
            #expect(report.actions.filter { $0.contains("A") }.count == 1)
            #expect(await sim.reconciler.busyNodes.isEmpty)
        }
    }

    @Test static func anExplicitlyWaitingRoundRetainsFinishedStepBehaviorForDirectCallers() async throws {
        try await withFixture { f in
            try await f.add("A")
            let round = start {
                let report = await f.reconciler.runRound(waitForAgents: true)
                let node = await f.ledger.workingState().nodes["A"]
                return (report, node)
            }
            try await f.agents.started("A").wait()
            f.agents.release("A").open()
            let (report, node) = try await round.value()
            #expect(node?.activeRun == nil)
            #expect(node?.flags[.needsInput] != nil)
            #expect(report.actions.filter { $0.contains("A") }.count == 1)
            #expect(await f.reconciler.busyNodes.isEmpty)
        }
    }

    @Test static func simulationRunUntilIdleDoesNotStopAtEmptyRunningReportsAndHonorsMaxRounds() async throws {
        try await withSimulation { sim, agents in
            try await seed("A", ledger: sim.ledger)
            _ = try await bounded { await sim.reconciler.runRound() }
            try await agents.started("A").wait()
            let reports = try await bounded { await sim.runUntilIdle(maxRounds: 3) }
            #expect(reports.count == 3)
            #expect(reports.allSatisfy { $0.actions.isEmpty && !$0.isIdle && $0.safeStop == nil })
            #expect(!agents.release("A").isOpen)
            agents.release("A").open()
            try await bounded { await sim.reconciler.waitForAgents() }
            let finished = try await bounded { await sim.runUntilIdle(maxRounds: 3) }
            #expect(finished.flatMap(\.actions).filter { $0.contains("A") }.count == 1)
            #expect(finished.last?.isIdle == true)
        }
    }

    @Test static func simulationRunUntilIdleStopsOnSafeStopEvenWithARunningStep() async throws {
        try await withSimulation { sim, agents in
            try await seed("A", ledger: sim.ledger)
            _ = try await bounded { await sim.reconciler.runRound() }
            try await agents.started("A").wait()
            try await sim.tamperWithLedgerForDemo()
            let reports: [RoundReport]
            do {
                reports = try await bounded { await sim.runUntilIdle(maxRounds: 4) }
            } catch {
                _ = try await sim.restoreLedgerAfterTamperDemo()
                throw error
            }
            _ = try await sim.restoreLedgerAfterTamperDemo()
            #expect(reports.count == 1)
            #expect(reports.first?.safeStop != nil)
            #expect(!agents.release("A").isOpen)
        }
    }

    @Test static func repositoryRunUntilIdleContinuesThroughEmptyRunningReportsAndHonorsMaxRounds() async throws {
        try await withRepository { session, agents, _ in
            try await seed("A", ledger: session.ledger)
            _ = try await bounded { await session.step() }
            try await agents.started("A").wait()
            let reports = try await bounded { await session.runUntilIdle(maxRounds: 3) }
            #expect(reports.count == 3)
            #expect(reports.allSatisfy { $0.actions.isEmpty && !$0.isIdle && $0.safeStop == nil })
            #expect(!agents.release("A").isOpen)
            agents.release("A").open()
            try await bounded { await session.reconciler.waitForAgents() }
            let finished = try await bounded { await session.runUntilIdle(maxRounds: 3) }
            #expect(finished.flatMap(\.actions).filter { $0.contains("A") }.count == 1)
            #expect(finished.last?.isIdle == true)
        }
    }

    @Test static func repositoryRunUntilIdleStopsOnSafeStopEvenWithARunningStep() async throws {
        try await withRepository { session, agents, store in
            try await seed("A", ledger: session.ledger)
            _ = try await bounded { await session.step() }
            try await agents.started("A").wait()
            store.failReads = true
            defer { store.failReads = false }
            let reports = try await bounded { await session.runUntilIdle(maxRounds: 4) }
            store.failReads = false
            #expect(reports.count == 1)
            #expect(reports.first?.safeStop != nil)
            #expect(!agents.release("A").isOpen)
        }
    }
}
