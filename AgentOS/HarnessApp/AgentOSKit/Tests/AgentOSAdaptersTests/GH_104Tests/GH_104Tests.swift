// API contract: Reconciler.runRound(waitForAgents:) uses Policy.landingBatchSize and
// the existing Workspace.createLandingBatch(for:) -> LandingBatchWorkspace and
// Workspace.landBatch(_:) -> LandingBatchMove contract, retaining per-node ownership.
// LandingBatchConflict identifies a node and its conflicting files.
// Existing review requests, node state/evidence, tracker comments, ledger summaries
// and LedgerPane expose the outcomes. No particular batch event encoding is required.
// AC4's requirement to reuse the single-landing protected-tests rule, rather than
// copying it, is source-only and reviewed in the diff; its behavior is tested below.

import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import Foundation
import Testing

@Suite
struct GH_104Tests {
    @Test
    func agentReviewsSeeOnlyTheirRebasedNodeBeforeItJoinsTheBatch() async throws {
        let f = try await Fixture(review: .agent)
        defer { f.cleanUp() }

        try await f.round()

        let requests = await f.reviewer.requests
        #expect(Set(requests.map(\.spec.id)) == Set(f.ids))
        for id in f.ids {
            let request = try #require(requests.first { $0.spec.id == id })
            #expect(request.stage == .change)
            #expect(request.directory == f.workspace.worktree(for: id))
            #expect(request.context.baseBranch == Fixture.branch)
            #expect(request.context.commit == "rebased-\(id)")
            #expect(Set(request.context.changedFiles) == Set(await f.workspace.nodeFiles(id)))
            let operations = await f.audit.entries
            let rebased = try #require(operations.firstIndex(of: "rebase:\(id)"))
            let reviewed = try #require(operations.firstIndex(of: "review:\(id)"))
            let applied = try #require(operations.firstIndex(of: "apply:\(id)"))
            #expect(rebased < reviewed && reviewed < applied)
        }
        try await f.expectPassingBatch(f.ids)
    }

    @Test
    func failedAgentReviewReturnsFindingsAndDoesNotContaminateTheOtherNodesBatch() async throws {
        let f = try await Fixture(review: .agent, rejected: "wn-GH104-B")
        defer { f.cleanUp() }

        try await f.round()

        let rejected = try #require(await f.node(f.ids[1]))
        #expect(rejected.phase == .ready)
        #expect(rejected.landedCommit == nil)
        #expect(rejected.latestReviewFeedback?.contains(ReviewerFake.finding) == true)
        #expect(await f.tracker.comments(on: rejected.ticket).contains {
            $0.contains(ReviewerFake.finding) && $0.contains("harness:retry")
        })
        #expect(!(await f.workspace.applied).contains(rejected.id))
        try await f.expectPassingBatch([f.ids[0], f.ids[2]])
    }

    @Test
    func humanReviewedNodeWaitsInReviewAndLandsAloneOnlyAfterBuildApprovesItsCommit() async throws {
        let human = "wn-GH104-B"
        let f = try await Fixture(human: human)
        defer { f.cleanUp() }

        try await f.round()

        let waiting = try #require(await f.node(human))
        let requested = try #require(waiting.pendingHumanReview)
        let state = await f.ledger.workingState()
        #expect(state.status(of: waiting) == "In review")
        #expect(waiting.landedCommit == nil)
        #expect(waiting.failedAttempts == 0)
        #expect(!(await f.workspace.applied).contains(human))
        #expect(await f.checks.calls.contains { $0.nodes == [human] && $0.only == nil })
        #expect(await f.tracker.comments(on: waiting.ticket).contains {
            $0.contains(requested) && $0.contains("harness:build")
        })
        try await f.expectPassingBatch([f.ids[0], f.ids[2]], allowingSingles: true)

        try await f.round()
        #expect(await f.node(human)?.pendingHumanReview == requested,
                "Another round must not approve a human review")
        await f.tracker.sendBuild(on: waiting.ticket)
        try await f.round()

        let landed = try #require(await f.node(human))
        #expect(landed.phase == .proven)
        #expect(landed.approvedReviewCommit == requested)
        #expect(landed.landedCommit == requested)
        #expect(await f.workspace.singleLandings.contains(human))
        #expect(!(await f.workspace.batchLandings).contains { $0.contains(human) })
        #expect(await f.ledger.records(for: human).contains {
            if case .humanReviewApproved(let commit) = $0.event.kind {
                return $0.event.by.isHuman && commit == requested
            }
            return false
        })
    }

    @Test
    func approvalOfAnOlderHumanReviewCommitDoesNotApproveARewrittenCandidate() async throws {
        let human = "wn-GH104-B"
        let f = try await Fixture(human: human)
        defer { f.cleanUp() }
        try await f.round()
        let previous = try #require(await f.node(human)?.pendingHumanReview)
        try await f.record(human, [.humanReviewApproved(commit: previous)], by: .human("Developer"))
        try await f.workspace.rewriteCandidate(human, commit: "new-human-candidate")
        try await f.record(human, [.changeSubmitted(run: "builder", commit: "new-human-candidate")])

        try await f.round()

        let node = try #require(await f.node(human))
        #expect(node.pendingHumanReview == "new-human-candidate")
        #expect(node.approvedReviewCommit != node.pendingHumanReview)
        #expect(node.landedCommit == nil)
        #expect(!(await f.workspace.singleLandings).contains(human))
        #expect(!(await f.workspace.batchLandings).contains { $0.contains(human) })
    }

    @Test
    func conflictDuringBatchApplicationReworksOnlyThatNodeWithoutCountingAFailure() async throws {
        let f = try await Fixture(conflicting: "wn-GH104-B")
        defer { f.cleanUp() }

        try await f.round()

        let conflicted = try #require(await f.node(f.ids[1]))
        #expect(conflicted.phase == .ready)
        #expect(conflicted.failedAttempts == 0)
        #expect(conflicted.reworks == 1)
        #expect(conflicted.flags[.escalated] == nil)
        #expect(conflicted.landedCommit == nil)
        #expect(conflicted.spec.predictedPaths.contains("Sources/Shared"))
        #expect(conflicted.spec.predictedPaths.contains("Sources/Unpredicted.swift"))
        #expect(!conflicted.spec.predictedPaths.contains("Sources/Shared/Known.swift"),
                "An already predicted directory covers its conflicting child")
        #expect(await f.workspace.reworked.contains(conflicted.id))
        #expect(await f.tracker.comments(on: conflicted.ticket).contains {
            $0.hasPrefix("♻️ Rework: merge conflict in ")
                && Fixture.conflictFiles.allSatisfy($0.contains)
        })
        try await f.expectPassingBatch([f.ids[0], f.ids[2]])
    }

    @Test(arguments: Tampering.allCases)
    func tamperingIntroducedOnlyWhenAppliedIsRejectedBeforeFullChecksAndPeersStillLand(
        tampering: Tampering
    ) async throws {
        let f = try await Fixture(tampering: tampering)
        defer { f.cleanUp() }
        let bad = f.ids[tampering.position]
        let before = try #require(await f.node(bad))
        let ownDirectory = f.workspace.worktree(for: bad)
        #expect(Hashing.digest(of: ownDirectory.appending(path: f.workspace.testFolder(for: before.spec)))
                == before.testsDigest, "The fixture's single-node candidate starts intact")
        #expect(before.updatedOtherTestsIntact(in: ownDirectory))
        let single = try await Fixture(batchSize: 1, tampering: tampering)
        defer { single.cleanUp() }
        try await single.workspace.tamperSingleCandidate(bad)
        try await single.round()
        let singleRejection = try #require(await single.node(bad))
        try #require(singleRejection.evidence.contains { !$0.passed && $0.summary.contains(tampering.summary) },
                     "Validate the rejection against today's single-landing protected-tests rule")

        try await f.round()

        let rejected = try #require(await f.node(bad))
        #expect(rejected.phase == .ready)
        #expect(rejected.landedCommit == nil)
        #expect(rejected.reworks == 0, "Test tampering is a failed landing check, not a textual conflict")
        #expect(rejected.failedAttempts == singleRejection.failedAttempts)
        #expect(rejected.landingReworkPending == singleRejection.landingReworkPending)
        #expect(rejected.flags[.escalated] == singleRejection.flags[.escalated])
        let failure = try #require(rejected.evidence.last { !$0.passed })
        #expect(failure.summary.contains(tampering.summary))
        #expect(failure.failureClassification == .ownMistake)
        #expect(await f.tracker.comments(on: rejected.ticket).contains { $0.contains(tampering.summary) })
        #expect(await f.checks.calls.allSatisfy { !$0.nodes.contains(bad) },
                "No full check may run the tampered intermediate or final candidate")
        try await f.expectPassingBatch(f.ids.filter { $0 != bad })
    }

    @Test
    func authorizedUpdatedTestsAndEarlierNodesAcceptanceTestsAreNotMistakenForTampering() async throws {
        let f = try await Fixture(authorizedUpdates: true)
        defer { f.cleanUp() }

        try await f.round()

        try await f.expectPassingBatch(f.ids)
        for id in f.ids {
            #expect(await f.node(id)?.evidence.allSatisfy(\.passed) == true)
        }
    }

    @Test
    @MainActor
    func batchLedgerAndLedgerPaneNameEveryRemovedNodeAndItsOwnReason() async throws {
        let f = try await Fixture(count: 4, conflicting: "wn-GH104-B", tampering: .updatedOtherTests)
        defer { f.cleanUp() }
        let model = HarnessViewModel()
        let probe = try Ledger()
        try await probe.append([LedgerEvent(node: nil, by: .reconciler,
                                           kind: .reworkNeeded(reason: "merge conflict in Probe.swift"))])
        await model.refreshLedger(from: probe)
        let initial = try Self.ledgerText(model)
        try #require(RenderedUI.shows("Probe.swift", in: initial),
                     "Probe the existing LedgerPane with the shared hidden-window renderer")

        try await f.round()

        let batchRecords = await f.ledger.allRecords().filter {
            $0.event.kind.summary.localizedCaseInsensitiveContains("batch")
        }
        let conflict = try #require(batchRecords.first {
            $0.event.kind.summary.contains("GH104-B")
                && $0.event.kind.summary.localizedCaseInsensitiveContains("conflict")
        }, "A batch record must associate the removed node with its conflict")
        let tampered = try #require(batchRecords.first {
            $0.event.kind.summary.contains("GH104-C")
                && $0.event.kind.summary.localizedCaseInsensitiveContains("tamper")
        }, "A batch record must associate the removed node with test tampering")
        #expect(batchRecords.contains { $0.event.kind.summary.contains(Fixture.branch) })
        #expect(await f.ledger.verifyChain().isIntact)

        for (record, ticket, reason) in [(conflict, "GH104-B", "conflict"), (tampered, "GH104-C", "tamper")] {
            let page = try Ledger()
            try await page.append([record.event])
            model.state = await f.ledger.workingState()
            await model.refreshLedger(from: page)
            let text = try Self.ledgerText(model)
            #expect(RenderedUI.shows(ticket, in: text))
            #expect(RenderedUI.shows(reason, in: text))
        }
        try await f.expectPassingBatch([f.ids[0], f.ids[3]])
    }

    @Test
    func fixtureCanLandAndRecordAnExistingSingleNodeWithoutBatchSupport() async throws {
        let f = try await Fixture(count: 1, batchSize: 1)
        defer { f.cleanUp() }

        try await f.round()

        #expect(await f.node(f.ids[0])?.phase == .proven)
        #expect(await f.workspace.singleLandings == f.ids)
        #expect(await f.checks.calls.map(\.nodes) == [f.ids])
        #expect(await f.tracker.comments(on: Fixture.ticket(f.ids[0])).contains { $0.contains("🛬 Landed") })
    }

    @Test
    func batchFixtureAppliesAndRollsBackFilesWithAccurateExistingTestDigests() async throws {
        let f = try await Fixture(tampering: .ownTests)
        defer { f.cleanUp() }
        let good = try #require(await f.node(f.ids[1]))
        let bad = try #require(await f.node(f.ids[0]))
        let batch = try await f.workspace.createLandingBatch(for: [good.id])
        let directory = batch.directory
        let base = batch.baseCommit
        let checkpoint = batch.candidateCommit
        #expect(Hashing.digest(of: directory.appending(path: f.workspace.testFolder(for: good.spec))) == good.testsDigest)
        #expect(try await f.workspace.changedFiles(in: directory, since: base) == f.workspace.nodeFiles(good.id))

        _ = try await f.workspace.applyToLandingBatch(bad.id, in: directory)

        #expect(Hashing.digest(of: directory.appending(path: f.workspace.testFolder(for: bad.spec))) != bad.testsDigest)
        #expect(try await f.workspace.changedFiles(in: directory, since: checkpoint) == f.workspace.nodeFiles(bad.id))
        try await f.workspace.resetLandingBatch(directory, to: checkpoint)
        #expect(try await f.workspace.tree(in: directory).nodes == [good.id])
        #expect(try await f.workspace.changedFiles(in: directory, since: base) == f.workspace.nodeFiles(good.id))
        #expect(Hashing.digest(of: directory.appending(path: f.workspace.testFolder(for: good.spec))) == good.testsDigest)
    }

    @MainActor
    private static func ledgerText(_ model: HarnessViewModel) throws -> String {
        try RenderedUI.text(of: LedgerPane().environment(model), size: CGSize(width: 1_700, height: 800))
    }
}
