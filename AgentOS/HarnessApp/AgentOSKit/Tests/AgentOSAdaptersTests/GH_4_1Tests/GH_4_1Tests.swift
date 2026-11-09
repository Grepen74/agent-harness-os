// API contract: MainBaselineCoordinator observes local main without mutating it, serializes and deduplicates
// commit-specific baseline runs, records their trigger, and exposes repository-banner and finding presentations.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_4_1Tests {
    @Test
    func everyRoundComparesLocalMainWithTheLastLandingBase() async throws {
        let repository = MainRepositorySpy(tips: ["main-2", "main-2"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "main-1",
            repository: repository,
            runner: { await runner.run($0) }
        )

        await coordinator.reconcile()
        await runner.finish(commit: "main-2", passed: true)
        await coordinator.reconcile()

        #expect(await repository.observedTips == 2)
        #expect(await coordinator.comparedMainCommits == [
            .init(lastBased: "main-1", observed: "main-2"),
            .init(lastBased: "main-1", observed: "main-2"),
        ])
    }

    @Test
    func movedMainAutomaticallyRecordsOneTriggeredBaseline() async throws {
        let repository = MainRepositorySpy(tips: ["main-2"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "main-1",
            repository: repository,
            runner: { await runner.run($0) }
        )

        await coordinator.reconcile()
        #expect(await runner.startedCommits == ["main-2"])
        await runner.finish(commit: "main-2", passed: true)

        #expect(await coordinator.ledgerEvents == [
            .baselineStarted(commit: "main-2", trigger: .mainMoved),
            .baselineFinished(commit: "main-2", passed: true, trigger: .mainMoved),
        ])
    }

    @Test
    func rescanAndManualRunNeverCheckTheSameCommitTwice() async throws {
        let repository = MainRepositorySpy(tips: ["main-2", "main-2"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "main-1",
            repository: repository,
            runner: { await runner.run($0) }
        )

        await coordinator.requestBaseline(commit: "main-2", trigger: .scan)
        await coordinator.requestBaseline(commit: "main-2", trigger: .manual)
        await coordinator.reconcile()
        await runner.finish(commit: "main-2", passed: true)
        await coordinator.requestBaseline(commit: "main-2", trigger: .manual)
        await coordinator.reconcile()

        #expect(await runner.startedCommits == ["main-2"])
        #expect(await coordinator.ledgerEvents == [
            .baselineStarted(commit: "main-2", trigger: .scan),
            .baselineFinished(commit: "main-2", passed: true, trigger: .scan),
        ])
    }

    @Test
    func movementDuringARunFinishesItThenRunsOnlyTheNewestCommit() async throws {
        let repository = MainRepositorySpy(tips: ["main-2", "main-3", "main-4"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "main-1",
            repository: repository,
            runner: { await runner.run($0) }
        )

        await coordinator.reconcile()
        await coordinator.reconcile()
        await coordinator.reconcile()
        #expect(await runner.startedCommits == ["main-2"])

        await runner.finish(commit: "main-2", passed: true)
        await runner.waitUntilStarted("main-4")
        #expect(await runner.startedCommits == ["main-2", "main-4"])

        await runner.finish(commit: "main-4", passed: true)
        #expect(await coordinator.ledgerEvents == [
            .baselineStarted(commit: "main-2", trigger: .mainMoved),
            .baselineFinished(commit: "main-2", passed: true, trigger: .mainMoved),
            .baselineStarted(commit: "main-4", trigger: .mainMoved),
            .baselineFinished(commit: "main-4", passed: true, trigger: .mainMoved),
        ])
    }

    @Test
    func runningBannerDescribesTheRunAndWhatContinues() async throws {
        let repository = MainRepositorySpy(tips: ["1234567890abcdef"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "abcdef0123456789",
            repository: repository,
            runner: { await runner.run($0) },
            now: { Date(timeIntervalSince1970: 100) }
        )

        await coordinator.reconcile()
        await runner.log("Compiling AgentOSAdapters")
        let banner = try #require(await coordinator.banner(at: Date(timeIntervalSince1970: 234)))

        #expect(banner.title == "Baseline running on main at 12345678 · started because main moved from abcdef01 · 2m 14s")
        #expect(banner.message == "Catching up agentos/main waits; agents keep working.")
        #expect(banner.latestLogLine == "Compiling AgentOSAdapters")
        #expect(banner.fullLog != nil)
        #expect(banner.actions == [.stop])
    }

    @Test
    func baselineStatesUseCommitSpecificMessagesAndSeverity() async throws {
        let missingBeforeWork = MainBaselinePresentation.missing(
            mainCommit: "1234567890abcdef",
            commitsBehind: 0,
            workExists: false
        )
        let missingWithWork = MainBaselinePresentation.missing(
            mainCommit: "1234567890abcdef",
            commitsBehind: 3,
            workExists: true
        )
        let failed = MainBaselinePresentation.failed(
            mainCommit: "1234567890abcdef",
            log: URL(filePath: "/tmp/baseline.log")
        )
        let running = MainBaselinePresentation.running(mainCommit: "1234567890abcdef")
        let passed = MainBaselinePresentation.passed(mainCommit: "1234567890abcdef", seconds: 182)

        #expect(missingBeforeWork.severity == .blocker)
        #expect(missingBeforeWork.message == "Baseline not checked at 12345678")
        #expect(missingWithWork.severity == .warning)
        #expect(missingWithWork.message == "agentos/main is 3 commits behind main; catching up waits for a baseline")
        #expect(failed.severity == .warning)
        #expect(failed.message == "Baseline fails on main at 12345678")
        #expect(failed.actions == [.retry, .dismiss])
        #expect(running.message == "main moved to 12345678; baseline running…")
        #expect(passed.message == "Baseline passed in 3m 02s; catching up queued")
    }

    @Test
    func observingMovedMainDoesNotMutateTheRepository() async throws {
        let repository = MainRepositorySpy(tips: ["main-2"])
        let runner = ControlledBaselineRunner()
        let coordinator = MainBaselineCoordinator(
            lastBasedMainCommit: "main-1",
            repository: repository,
            runner: { await runner.run($0) }
        )
        let before = await repository.snapshot

        await coordinator.reconcile()
        await runner.finish(commit: "main-2", passed: true)

        #expect(await repository.snapshot == before)
        #expect(await repository.operations == [.readLocalMainTip])
    }
}

private enum MainRepositoryOperation: Equatable {
    case readLocalMainTip
}

private struct MainRepositorySnapshot: Equatable {
    let localMain: String
    let currentCheckout: String
    let remoteRefs: [String: String]
    let workingTreeDigest: String
}

private actor MainRepositorySpy: MainTipRepository {
    private var tips: [String]
    private(set) var operations: [MainRepositoryOperation] = []
    private(set) var observedTips = 0
    let snapshot = MainRepositorySnapshot(
        localMain: "main-2",
        currentCheckout: "feature",
        remoteRefs: ["origin/main": "remote-1"],
        workingTreeDigest: "unchanged"
    )

    init(tips: [String]) {
        self.tips = tips
    }

    func localMainTip() async throws -> String {
        operations.append(.readLocalMainTip)
        observedTips += 1
        return tips.removeFirst()
    }
}

private actor ControlledBaselineRunner {
    private var continuations: [String: CheckedContinuation<BaselineRunResult, Never>] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var activeRequests: [String: MainBaselineRequest] = [:]
    private(set) var startedCommits: [String] = []

    func run(_ request: MainBaselineRequest) async -> BaselineRunResult {
        activeRequests[request.commit] = request
        startedCommits.append(request.commit)
        startWaiters.removeValue(forKey: request.commit)?.forEach { $0.resume() }
        return await withCheckedContinuation { continuations[request.commit] = $0 }
    }

    func finish(commit: String, passed: Bool) {
        activeRequests.removeValue(forKey: commit)
        continuations.removeValue(forKey: commit)?.resume(returning: .init(
            passed: passed,
            summary: passed ? "Passed" : "Failed",
            seconds: 1,
            log: URL(filePath: "/tmp/\(commit).log"),
            latestLogLine: nil
        ))
    }

    func log(_ line: String) async {
        guard let request = activeRequests.values.first else { return }
        await request.reportLogLine(line)
    }

    func waitUntilStarted(_ commit: String) async {
        if startedCommits.contains(commit) { return }
        await withCheckedContinuation { startWaiters[commit, default: []].append($0) }
    }
}
