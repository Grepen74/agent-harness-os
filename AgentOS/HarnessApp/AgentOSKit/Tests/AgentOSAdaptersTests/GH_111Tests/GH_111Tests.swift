// Expected API: RequirementPublisher.reconcileVerificationStatuses() is an awaited, round-level
// hook, implemented by PullRequestPublicationCoordinator and invoked by Reconciler even when no
// branch needs publishing. Successful posts append EventKind.requirementVerificationStatusPosted
// (commit: String, state: RequirementVerificationStatus), whose Codable states are pending/success/failure.
// Existing publication, final-verification Evidence, ledger replay and attentionList APIs are reused.
// Criterion 6 is documentation-only: the reviewer checks real-repo-mode.md's status descriptions
// and retry explanation against the diff; it intentionally has no source-text test.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite
struct GH_111Tests {
    @Test
    func aPushedTipWithoutItsOwnFinalResultImmediatelyGetsPending() async throws {
        let fixture = try await Self.fixture()
        try await fixture.recordResult(commit: Self.oldSHA, passed: true)
        // A passing leaf check on this tip is not final requirement verification.
        try await fixture.append(.evidenceRecorded(Self.evidence(
            fixture.spec, commit: Self.sha, passed: true, check: "leaf acceptance")),
            by: .agent(run: "verify-\(Self.sha)", role: .verifier))
        let publisher = fixture.publisher()

        try await publisher.reconcile([fixture.request()])

        #expect(await fixture.git.pushes == 1)
        let post = try #require(await fixture.github.posts.first,
                                "Pushing an unverified tip must immediately post pending.")
        #expect(await fixture.github.posts.count == 1)
        Self.expect(post, commit: Self.sha, state: .pending, description: "Waiting for final verification")
        let operations = await fixture.trace.operations
        let push = try #require(operations.firstIndex(of: "push"))
        let status = try #require(operations.firstIndex(of: "status:\(Self.sha):pending"))
        #expect(push < status, "A status cannot precede the successful push.")
        #expect(try await fixture.recordedStatuses() == [.init(commit: Self.sha, state: .pending)])
    }

    @Test(arguments: [true, false])
    func aTipWithAnExactFinalResultIsPublishedWithThatResultNotPending(passed: Bool) async throws {
        let fixture = try await Self.fixture()
        let summary = "Checkout acceptance failed"
        try await fixture.recordResult(commit: Self.sha, passed: passed, summary: summary)

        try await fixture.publisher().reconcile([fixture.request()])

        #expect(await fixture.git.pushes == 1)
        let post = try #require(await fixture.github.posts.first)
        #expect(await fixture.github.posts.count == 1)
        Self.expect(post, commit: Self.sha, state: passed ? .success : .failure,
                    description: passed ? "Final verification passed" : summary)
        #expect(try await fixture.recordedStatuses() == [
            .init(commit: Self.sha, state: passed ? .success : .failure),
        ])
    }

    @Test(arguments: [true, false])
    func aFinalResultUpdatesExactlyItsPushedCommitEvenAfterTheBranchMoves(passed: Bool) async throws {
        let fixture = try await Self.fixture()
        let publisher = fixture.publisher()
        try await publisher.reconcile([fixture.request()])
        try #require(await fixture.github.posts.count == 1, "The pushed commit first needs a pending status.")
        await fixture.git.setTip(Self.nextSHA)
        try await fixture.append(.requirementBranchObserved(
            branch: fixture.branch, tip: Self.nextSHA, main: Self.oldSHA, containedInMain: false))
        try await fixture.recordResult(commit: Self.sha, passed: passed, summary: "Receipt test failed")

        try await publisher.reconcileVerificationStatuses()

        let posts = await fixture.github.posts
        try #require(posts.count == 2, "The newly recorded result must produce a terminal status.")
        Self.expect(posts[1], commit: Self.sha, state: passed ? .success : .failure,
                    description: passed ? "Final verification passed" : "Receipt test failed")
        #expect(!posts.contains { $0.path.hasSuffix("/\(Self.nextSHA)") },
                "The result must never be attributed to the current branch tip.")
        #expect(try await fixture.recordedStatuses() == [
            .init(commit: Self.sha, state: .pending),
            .init(commit: Self.sha, state: passed ? .success : .failure),
        ])
    }

    @Test(arguments: [0, 139, 140, 141, 350])
    func failureDescriptionsKeepTheSummaryPrefixWithin140Characters(length: Int) async throws {
        let fixture = try await Self.fixture(pushed: true)
        let summary = String(repeating: "Validation failed: ", count: 25).prefix(length)
        try await fixture.recordResult(commit: Self.sha, passed: false, summary: String(summary))

        try await fixture.publisher().reconcileVerificationStatuses()

        let post = try #require(await fixture.github.posts.first,
                                "A recorded failed verification must post failure.")
        let expected = summary.count > 140 ? String(summary.prefix(139)) + "…" : String(summary)
        Self.expect(post, commit: Self.sha, state: .failure, description: expected)
        #expect(post.description.count <= 140)
    }

    @Test(arguments: [ResultKind.absent, .passed, .failed])
    func observedOrLandedCommitsWithoutAHarnessPushGetNoStatus(result: ResultKind) async throws {
        let fixture = try await Self.fixture()
        if result != .absent {
            try await fixture.recordResult(commit: Self.sha, passed: result == .passed)
        }

        try await fixture.publisher().reconcileVerificationStatuses()

        #expect(await fixture.github.posts.isEmpty)
        #expect(try await fixture.recordedStatuses().isEmpty)
        #expect(await fixture.git.pushes == 0)
    }

    @Test(arguments: [ResultKind.absent, .passed, .failed])
    func publishingOffSuppressesStatusesEvenForPreviouslyPushedCommits(result: ResultKind) async throws {
        let fixture = try await Self.fixture(pushed: true, enabled: false)
        if result != .absent {
            try await fixture.recordResult(commit: Self.sha, passed: result == .passed)
        }
        let publisher = fixture.publisher()

        try await publisher.reconcile([fixture.request()])
        try await publisher.reconcileVerificationStatuses()
        let reconciler = fixture.reconciler(publisher: publisher)
        try await Self.round(reconciler)

        #expect(await fixture.github.posts.isEmpty)
        #expect(try await fixture.recordedStatuses().isEmpty)
        #expect(await fixture.git.pushes == 0)
    }

    @Test
    func aRejectedPushDoesNotAuthorizeAStatus() async throws {
        let fixture = try await Self.fixture()
        try await fixture.recordResult(commit: Self.sha, passed: true)
        await fixture.git.rejectPush()

        try await fixture.publisher().reconcile([fixture.request()])
        try await fixture.publisher().reconcileVerificationStatuses()

        #expect(await fixture.git.pushes == 1)
        #expect(await fixture.github.posts.isEmpty)
        #expect(try await fixture.recordedStatuses().isEmpty)
        #expect(!(await fixture.ledger.records(for: fixture.spec.id).contains {
            if case .requirementPushed = $0.event.kind { return true }
            return false
        }))
    }

    @Test
    func recordedStatesAreNotRepostedAcrossRoundsOrLedgerReplay() async throws {
        let fixture = try await Self.fixture(pushed: true)
        let publisher = fixture.publisher()
        try await publisher.reconcileVerificationStatuses()
        try #require(try await fixture.recordedStatuses() == [.init(commit: Self.sha, state: .pending)])
        try await publisher.reconcileVerificationStatuses()
        #expect(await fixture.github.posts.count == 1)
        try await fixture.recordResult(commit: Self.sha, passed: true)
        try await publisher.reconcileVerificationStatuses()
        try #require(try await fixture.recordedStatuses() == [
            .init(commit: Self.sha, state: .pending), .init(commit: Self.sha, state: .success),
        ])

        let replay = try await Self.replay(fixture.ledger)
        #expect(await replay.verifyChain().isIntact)
        let restartedPublisher = fixture.publisher(ledger: replay)
        let reconciler = fixture.reconciler(ledger: replay, publisher: restartedPublisher)
        _ = await reconciler.recoverAfterRestart()
        try await Self.round(reconciler)
        try await Self.round(reconciler)
        try await restartedPublisher.reconcileVerificationStatuses()

        #expect(await fixture.github.posts.count == 2,
                "Commit/state pairs remain deduplicated after durable ledger replay.")
        #expect(await fixture.checks.calls == 0)
        #expect(await fixture.agents.calls.isEmpty)
    }

    @Test(arguments: [true, false])
    func aRestartPostsAnUnpostedFinalResultWithoutRunningChecksAgain(passed: Bool) async throws {
        let fixture = try await Self.fixture(pushed: true)
        try await fixture.recordResult(commit: Self.sha, passed: passed, summary: "Address check failed")
        let replay = try await Self.replay(fixture.ledger)
        let publisher = fixture.publisher(ledger: replay)
        let reconciler = fixture.reconciler(ledger: replay, publisher: publisher)
        _ = await reconciler.recoverAfterRestart()

        try await Self.round(reconciler)

        let post = try #require(await fixture.github.posts.first,
                                "A normal restarted round must publish the durable result.")
        Self.expect(post, commit: Self.sha, state: passed ? .success : .failure,
                    description: passed ? "Final verification passed" : "Address check failed")
        #expect(try await fixture.recordedStatuses(in: replay) == [
            .init(commit: Self.sha, state: passed ? .success : .failure),
        ])
        #expect(await fixture.checks.calls == 0, "Status recovery must not rerun final verification.")
        #expect(await fixture.agents.calls.isEmpty)
        #expect(await fixture.git.pushes == 0, "Recovering a status must not repush an unchanged branch.")
        try await Self.round(reconciler)
        #expect(await fixture.github.posts.count == 1)
    }

    @Test(arguments: [true, false])
    func resultsForMultiplePushedCommitsSurviveOutOfOrderCompletionAndRestart(latestPassed: Bool) async throws {
        let fixture = try await Self.fixture(pushed: true)
        try await fixture.append(.requirementPushed(branch: fixture.branch, commit: Self.nextSHA))
        try await fixture.append(.requirementPublicationFinished(commit: Self.nextSHA))
        await fixture.git.setTip(Self.nextSHA)
        try await fixture.recordResult(commit: Self.nextSHA, passed: latestPassed, summary: "New receipt check failed")
        try await fixture.recordResult(commit: Self.sha, passed: true)
        let replay = try await Self.replay(fixture.ledger)

        try await fixture.publisher(ledger: replay).reconcileVerificationStatuses()

        let posts = await fixture.github.posts
        try #require(posts.count == 2, "Both pushed commits need their own durable result, not only the latest Evidence.")
        let old = try #require(posts.first { $0.path.hasSuffix("/\(Self.sha)") })
        let new = try #require(posts.first { $0.path.hasSuffix("/\(Self.nextSHA)") })
        Self.expect(old, commit: Self.sha, state: .success, description: "Final verification passed")
        Self.expect(new, commit: Self.nextSHA, state: latestPassed ? .success : .failure,
                    description: latestPassed ? "Final verification passed" : "New receipt check failed")
        #expect(Set(try await fixture.recordedStatuses(in: replay)) == Set([
            StatusRecord(commit: Self.sha, state: .success),
            StatusRecord(commit: Self.nextSHA, state: latestPassed ? .success : .failure),
        ]))
    }

    @Test
    func failedStatusPostsRetryOncePerRoundKeepAttentionAndDoNotChangeTicketStatusOrStartRework() async throws {
        let fixture = try await Self.fixture(pushed: true)
        try await fixture.recordResult(commit: Self.sha, passed: true)
        await fixture.github.failStatusPosts(2)
        let publisher = fixture.publisher()
        let reconciler = fixture.reconciler(publisher: publisher)
        let before = await fixture.ledger.workingState()
        let originalStatus = before.status(of: try #require(before.nodes[fixture.spec.id]))
        #expect(originalStatus == "In review")

        try await Self.round(reconciler)

        try #require(await fixture.github.posts.count == 1, "A failed status is attempted at most once in a round.")
        #expect(try await fixture.recordedStatuses().isEmpty, "A failed HTTP request is not a successful ledger post.")
        try await fixture.expectStatusFailure(in: fixture.ledger, status: originalStatus)

        try await Self.round(reconciler)

        #expect(await fixture.github.posts.count == 2, "The next round retries without harness:retry.")
        #expect(try await fixture.recordedStatuses().isEmpty)
        try await fixture.expectStatusFailure(in: fixture.ledger, status: originalStatus)
        try await Self.round(reconciler)

        #expect(await fixture.github.posts.count == 3)
        #expect(try await fixture.recordedStatuses() == [.init(commit: Self.sha, state: .success)])
        let recovered = await fixture.ledger.workingState()
        #expect(!recovered.attentionList.contains {
            $0.node.id == fixture.spec.id && !$0.reason.isEmpty && $0.reason.localizedCaseInsensitiveContains("status")
        })
        #expect(recovered.status(of: try #require(recovered.nodes[fixture.spec.id])) == originalStatus)
        try await Self.round(reconciler)
        #expect(await fixture.github.posts.count == 3)
        for post in await fixture.github.posts {
            Self.expect(post, commit: Self.sha, state: .success, description: "Final verification passed")
        }
        #expect(await fixture.agents.calls.isEmpty)
        #expect(await fixture.checks.calls == 0)
    }

    @Test
    func aStatusFailureAfterPushDoesNotTurnIntoAPullRequestPublicationFailure() async throws {
        let fixture = try await Self.fixture()
        await fixture.github.failStatusPosts(1)

        try await fixture.publisher().reconcile([fixture.request()])

        try #require(await fixture.github.posts.count == 1)
        #expect(await fixture.git.pushes == 1)
        #expect(await fixture.github.pullRequestUpdates == 1, "A status failure must not stop updating the open PR.")
        let state = await fixture.ledger.workingState()
        let root = try #require(state.nodes[fixture.spec.id])
        #expect(root.publishedCommit == Self.sha)
        #expect(root.publicationFailure == nil, "Status retries are separate from human-only publication retries.")
        #expect(state.status(of: root) == "In review")
        #expect(state.attentionList.contains {
            $0.node.id == fixture.spec.id && !$0.reason.isEmpty && $0.reason.localizedCaseInsensitiveContains("status")
        })
        #expect(try await fixture.recordedStatuses().isEmpty)
    }
}
