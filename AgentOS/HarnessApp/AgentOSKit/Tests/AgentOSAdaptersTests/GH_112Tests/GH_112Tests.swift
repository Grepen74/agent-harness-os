// Expected API: existing Reconciler.runRound(waitForAgents:), Ledger/WorkingState,
// Workspace, RequirementBranchRepository, CheckRunner and PullRequestPublicationCoordinator
// with injected GitHubTransport and git commands. No new public symbols are required:
// verification is observed through checks, commit-status requests and ledger evidence.
// Criterion 6 is documentation-only: the reviewer checks real-repo-mode.md for tip-change
// reverification, queue order and main moving during verification.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite
struct GH_112Tests {
    @Test(arguments: TipChange.allCases, [true, false])
    func everyUnverifiedPublishedTipIsPushedAndVerifiedWithoutASignal(
        change: TipChange, passed: Bool
    ) async throws {
        let f = try await Fixture.make()
        let root = try #require(f.roots.first)
        let tip = try await f.changeTip(of: root, by: change)
        await f.checks.setResult(passed: passed)
        try await Self.whileFirstCheckIsHeld(f) {
            let calls = await f.checks.calls
            #expect(calls.first?.commit == tip, "Verify the new tip, not the previously verified commit.")
            #expect(calls.first?.suite == nil, "Final verification runs the full checks.")
            try await Self.expectPushedAndPending(f, root: root, commit: tip)
            #expect(await f.tracker.pendingSignals().isEmpty)
        }
        try await Self.expectVerification(f, root: root, commit: tip, passed: passed)
        try await Self.expectLifecycle(f, root: root, commit: tip, passed: passed)
        #expect(await f.agents.calls.isEmpty)
        if change == .catchUp {
            #expect(await f.ledger.workingState().nodes[root.id]?.lastCatchUpSuccess?.newAgentOSMainTip == tip)
        }
        if change == .personResolvingCatchUpConflict {
            #expect(await f.ledger.workingState().nodes[root.id]?.catchUpConflict == nil)
            #expect(await f.ledger.workingState().nodes[root.id]?.lastCatchUpSuccess?.method == .manual)
        }
    }

    @Test(arguments: [true, false])
    func anUnchangedTipWithAFinalResultDoesNotRepeatVerificationOrStatus(passed: Bool) async throws {
        let f = try await Fixture.make()
        let root = try #require(f.roots.first)
        let tip = try await f.changeTip(of: root, by: .personCommit)
        await f.checks.setResult(passed: passed)
        f.checks.release.open()
        try await f.drain()
        try await Self.expectVerification(f, root: root, commit: tip, passed: passed)
        try await Self.expectLifecycle(f, root: root, commit: tip, passed: passed)
        let checkCount = await f.checks.calls.count
        let statusCount = await f.github.statuses.count
        let pushCount = await f.git.pushes.count
        let resultCount = await f.results(for: root).count

        try await f.drain()
        let replay = try await Self.replay(f.ledger)
        let restarted = f.makeReconciler(ledger: replay)
        _ = await restarted.recoverAfterRestart()
        try await f.drain(using: restarted)
        try await f.drain(using: restarted)
        #expect(await f.checks.calls.count == checkCount)
        #expect(await f.github.statuses.count == statusCount)
        #expect(await f.git.pushes.count == pushCount)
        #expect(await f.results(for: root, in: replay).count == resultCount)
    }

    @Test
    func aPublishedVerificationFailureWaitsForAHumanRetryOnTheCurrentTip() async throws {
        let f = try await Fixture.make()
        let root = try #require(f.roots.first)
        let tip = try await f.changeTip(of: root, by: .personCommit)
        let summary = "Checkout integration rejected the new tip: " + String(repeating: "failure detail ", count: 20)
        await f.checks.setResult(passed: false, summary: summary)
        f.checks.release.open()
        try await f.drain()
        try await Self.expectVerification(f, root: root, commit: tip, passed: false)
        let state = await f.ledger.workingState()
        #expect(state.attentionList.contains {
            $0.node.id == root.id && $0.reason.contains(summary) && $0.reason.contains("harness:retry")
        })
        #expect(await f.tracker.ticket(root.ticket)?.comments.contains {
            $0.text.contains(tip) && $0.text.contains(summary) && $0.text.contains("harness:retry")
        } == true)
        let node = try #require(state.nodes[root.id])
        #expect(state.status(of: node) == "Needs attention" || state.attentionList.contains { $0.node.id == root.id },
                "Failed published verification must be visible in Needs attention.")
        #expect(await f.tracker.ticket(root.ticket)?.status == state.status(of: node))
        let failure = try #require(await f.github.statuses.last { $0.commit == tip && $0.state == "failure" })
        #expect(!failure.description.isEmpty)
        #expect(failure.description.count <= 140)
        #expect(await f.agents.calls.isEmpty)

        await f.checks.setResult(passed: true)
        try await f.drain()
        #expect(await f.checks.calls.count == 2, "Fixing a check does not authorize retrying the failed commit.")
        await f.tracker.retry(root.ticket)
        try await f.drain()
        #expect(await f.checks.calls.map(\.commit) == [tip, tip, tip], "Failed, failed quietly, retried by a person.")
        try await Self.expectVerification(f, root: root, commit: tip, passed: true)
        #expect(await f.ledger.workingState().attentionList.contains { $0.node.id == root.id } == false)
        #expect(await f.tracker.pendingSignals().isEmpty)
        #expect(await f.agents.calls.isEmpty)
    }

    @Test
    func aNewTipAfterFailureIsVerifiedWithoutRetryingTheFailedCommit() async throws {
        let f = try await Fixture.make()
        let root = try #require(f.roots.first)
        let failedTip = try await f.changeTip(of: root, by: .personCommit)
        await f.checks.setResult(passed: false)
        f.checks.release.open()
        try await f.drain()
        try await Self.expectVerification(f, root: root, commit: failedTip, passed: false)

        let fixedTip = try await f.changeTip(of: root, by: .personCommit)
        await f.checks.setResult(passed: true)
        try await f.drain()
        #expect(await f.checks.calls.map(\.commit) == [failedTip, failedTip, fixedTip])
        try await Self.expectLifecycle(f, root: root, commit: fixedTip, passed: true)
        try await Self.expectVerification(f, root: root, commit: fixedTip, passed: true)
        #expect(await f.tracker.pendingSignals().isEmpty)
        #expect(await f.ledger.workingState().attentionList.contains { $0.node.id == root.id } == false)
        #expect(await f.agents.calls.isEmpty)
    }

    @Test
    func finalVerificationIsSerialInPRNumberThenUnpublishedCreationOrder() async throws {
        let f = try await Fixture.make(pullRequests: [nil, 42, 7, nil, 19])
        var tips: [NodeID: String] = [:]
        for root in f.roots {
            tips[root.id] = try await f.changeTip(of: root, by: .personCommit)
        }
        let expectedRoots = [f.roots[2], f.roots[4], f.roots[1], f.roots[0], f.roots[3]]
        let expectedTips = try expectedRoots.map { try #require(tips[$0.id]) }
        try await Self.whileFirstCheckIsHeld(f) {
            #expect(await f.checks.calls.first?.commit == expectedTips.first)
            // A concurrent round has reached the point where it could have started another check.
            let concurrent = await f.reconciler.runRound(waitForAgents: false)
            #expect(concurrent.safeStop == nil)
            #expect(await f.checks.calls.count == 1)
            #expect(await f.checks.maximumActive == 1)
        }
        #expect(await f.checks.calls.map(\.commit) == expectedTips)
        #expect(await f.checks.maximumActive == 1)
        let trace = await f.trace.events
        for pair in zip(expectedTips, expectedTips.dropFirst()) {
            let finished = try #require(trace.firstIndex(of: .checkFinished(pair.0, true)))
            let started = try #require(trace.firstIndex(of: .checkStarted(pair.1)))
            #expect(finished < started, "Finish one requirement's verification before starting the next.")
        }
        for root in f.roots {
            try await Self.expectVerification(f, root: root, commit: try #require(tips[root.id]), passed: true)
        }
    }

    @Test(arguments: [true, false])
    func mainMovingDuringVerificationKeepsTheResultOnItsCommitThenVerifiesTheCaughtUpTip(
        passed: Bool
    ) async throws {
        let f = try await Fixture.make()
        let root = try #require(f.roots.first)
        let checkingTip = try await f.changeTip(of: root, by: .personCommit)
        let nextMain = "main-moved-during-check"
        let caughtUpTip = "caught-up-after-running-check"
        await f.checks.setResult(passed: passed)
        try await Self.whileFirstCheckIsHeld(f, drain: false) {
            #expect(await f.checks.calls.first?.commit == checkingTip)
            await f.workspace.advanceMain(to: nextMain, mergedTip: caughtUpTip, branch: root.branch)
        }
        try await Self.expectVerification(f, root: root, commit: checkingTip, passed: passed)
        #expect(await f.github.statuses.contains {
            $0.commit == checkingTip && $0.state == (passed ? "success" : "failure")
        })
        #expect(await f.checks.calls.count == (passed ? 1 : 2))
        #expect(await f.workspace.tip(of: root.branch) == checkingTip)

        try await f.baseline(nextMain)
        await f.checks.setResult(passed: true)
        try await f.drain()
        #expect(await f.checks.calls.map(\.commit) == (passed ? [checkingTip] : [checkingTip, checkingTip]) + [caughtUpTip])
        try await Self.expectLifecycle(f, root: root, commit: caughtUpTip, passed: true)
        try await Self.expectVerification(f, root: root, commit: caughtUpTip, passed: true)
        #expect(await f.results(for: root).contains { $0.commit == checkingTip && $0.passed == passed })
        #expect(await f.ledger.workingState().nodes[root.id]?.lastCatchUpSuccess?.mainSHA == nextMain)
        #expect(await f.tracker.pendingSignals().isEmpty)
    }

    @Test(arguments: ["main", "trunk", "agentos/main", "agentos/leaf/wn-GH-112",
                      "agentos/GH-112:main", "+agentos/GH-112", "refs/tags/release"])
    func thePushBoundaryRejectsNonRequirementRefsAndKeepsValidPushesNonForcing(branch: String) async throws {
        let f = try await Fixture.make()
        let publisher = f.publisher()
        await #expect(throws: (any Error).self) {
            try await publisher.push(branch: branch)
        }
        #expect(await f.git.pushes.isEmpty)
        let root = try #require(f.roots.first)
        _ = try await publisher.push(branch: root.branch)
        let push = try #require(await f.git.pushes.first)
        try Self.expectSafePush(push.arguments, branch: root.branch)
        #expect(await f.github.mutations.isEmpty, "Pushing must not merge any pull request.")
    }

    @Test
    func anInitialVerificationRecordsTheCheckoutCommitAndItsCheckOutput() async throws {
        let f = try await Fixture.make(pullRequests: [nil])
        let root = try #require(f.roots.first)
        let initial = try #require(await f.workspace.tip(of: root.branch))
        f.checks.release.open()
        try await f.drain()
        try await Self.expectVerification(f, root: root, commit: initial, passed: true)
        #expect(await f.checks.calls.map(\.commit) == [initial])
        #expect(await f.trace.events.contains(.checkStarted(initial)))
        #expect(await f.trace.events.contains(.checkFinished(initial, true)))
    }
}
