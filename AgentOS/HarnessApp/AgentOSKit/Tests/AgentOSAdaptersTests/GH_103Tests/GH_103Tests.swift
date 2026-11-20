// API contract: Policy.landingBatchSize selects singleton or batched landing through the existing
// Reconciler.runRound(waitForAgents:) and RepositoryWorkspace APIs. EventKind.landingBatchCheck
// projects a persisted check as LandingBatchCheck(name, branch, nodes in queue order,
// candidateCommit, passed, run); Evidence.checkedBy links each member to that check's run.
// EventKind.summary is the human-readable ledger row, also exercised through LedgerPane.
// Source-only review: AC1's migration of legacy singleton fixtures to an explicit size of 1,
// and AC6's batch-landing descriptions in docs/real-repo-mode.md and HarnessApp/README.md.
// Failing-batch diagnosis/splitting and pre-batch review/conflict/tampering are sibling work;
// diagnosis and review below are regressions of the size-1 path, not new batch behavior.

import AgentOSAdapters
import AgentOSTestSupport
import AgentOSUI
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore

@Suite
struct GH_103Tests {
    @Test
    func sizeOneChecksAndLandsEachQueuedNodeBeforeCheckingTheNext() async throws {
        let f = try await Fixture(batchSize: 1)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-1")
        let newer = try await f.addLeaf("newer", under: root)
        let older = try await f.addLeaf("older", under: root)
        try await f.enqueue([older, newer])

        try await f.finishLandings([older, newer])

        let calls = await f.checks.calls.filter { !$0.members.isEmpty }
        #expect(calls.map(\.members) == [[older.id], [newer.id]])
        #expect(calls.allSatisfy { $0.selection == nil })
        let state = await f.ledger.workingState()
        let first = try #require(state.nodes[older.id]?.landedCommit)
        #expect(calls.last?.tips[root.branch] == first, "The second check starts after the first landing")
        for leaf in [older, newer] {
            let node = try #require(state.nodes[leaf.id])
            let commit = try #require(node.landedCommit)
            #expect(node.phase == .proven)
            #expect(node.failedAttempts == 0)
            #expect(await f.tracker.comments(on: leaf.ticket).contains {
                $0.hasPrefix("🛬 Landed on \(root.branch) at \(commit.prefix(8)) with all tests passing.")
            })
        }
    }

    @Test(arguments: [false, true])
    func sizeOneKeepsTheWholeCheckRerunAndFailureDiagnosisComments(rerunPasses: Bool) async throws {
        let failure = CheckOutput(passed: false, summary: "ExistingTests.regression failed",
                                  log: "Test Case '-[ExistingTests regression]' failed",
                                  failingTargets: ["ExistingTests"])
        let outputs = rerunPasses ? [failure, Self.pass] : [failure, failure, Self.pass, Self.pass, Self.pass]
        let f = try await Fixture(batchSize: 1, outputs: outputs)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-2")
        let leaf = try await f.addLeaf("diagnosis", under: root)
        try await f.enqueue([leaf])

        _ = try await f.round()

        let calls = await f.checks.calls
        #expect(calls.prefix(2).allSatisfy { $0.selection == nil && $0.members == [leaf.id] })
        #expect(calls.first?.commit == calls.dropFirst().first?.commit, "Retry the identical candidate")
        let node = try #require(await f.ledger.workingState().nodes[leaf.id])
        let comments = await f.tracker.comments(on: leaf.ticket).joined(separator: "\n")
        if rerunPasses {
            #expect(calls.count == 2)
            #expect(node.phase == .proven)
            #expect(node.failedAttempts == 0)
            #expect(comments.contains("Unreliable test:"))
            #expect(comments.contains("with no other work running"))
            #expect(comments.contains("🛬 Landed on \(root.branch)"))
        } else {
            #expect(calls.count == 5)
            #expect(calls.map(\.selection) == [nil, nil, "ExistingTests", "ExistingTests", nil])
            #expect(calls[2].members == [leaf.id])
            #expect(calls[3].members.isEmpty && calls[4].members.isEmpty)
            #expect(calls[3].commit == f.initialMain && calls[4].commit == f.initialMain)
            #expect(node.phase == .ready)
            #expect(node.landedCommit == nil)
            #expect(node.failedAttempts == 1)
            #expect(node.flags[.escalated] == nil)
            #expect(comments.contains("own mistake"))
            #expect(comments.contains("disturbs them"))
            #expect(comments.contains(root.branch))
        }
        #expect(comments.contains("ExistingTests.regression"))
    }

    @Test(arguments: [ReviewLevel.agent, .agentAndHuman])
    func sizeOneKeepsChangeReviewFindingsAndExactCommitHumanApproval(level: ReviewLevel) async throws {
        let reviewer = RecordingReviewer(passed: level == .agentAndHuman)
        let f = try await Fixture(batchSize: 1, reviewLevel: level, reviewer: reviewer)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-3")
        let leaf = try await f.addLeaf("reviewed", under: root)
        try await f.enqueue([leaf])

        _ = try await f.round()

        let requests = await reviewer.requests
        #expect(requests.count == 1)
        #expect(requests.first?.stage == .change)
        #expect(requests.first?.context.baseBranch == root.branch)
        let reviewed = try #require(requests.first?.context.commit)
        let node = try #require(await f.ledger.workingState().nodes[leaf.id])
        let comments = await f.tracker.comments(on: leaf.ticket).joined(separator: "\n")
        #expect(node.landedCommit == nil)
        #expect(try await f.revision(root.branch) == f.initialMain)
        if level == .agent {
            #expect(node.phase == .ready)
            #expect(comments.contains("change review findings:"))
            #expect(comments.contains("Return the missing validation error"))
            #expect(comments.contains("harness:retry"))
        } else {
            #expect(node.awaitingHumanReview)
            #expect(await f.ledger.workingState().status(of: node) == "In review")
            #expect(comments.contains(reviewed))
            #expect(comments.contains("harness:build"))
            _ = try await f.round()
            #expect(await reviewer.requests.count == 1)
            #expect(await f.ledger.workingState().nodes[leaf.id]?.landedCommit == nil)
            try await f.ledger.append([
                LedgerEvent(node: leaf.id, by: .human("Developer"), kind: .humanReviewApproved(commit: reviewed)),
            ])
            try await f.finishLandings([leaf])
            #expect(await reviewer.requests.count == 1, "Reuse the passed review of this exact commit")
            #expect(await f.ledger.workingState().nodes[leaf.id]?.landedCommit == reviewed)
        }
    }

    @Test(arguments: [2, 3])
    func batchesUseQueueAgeNotCreationOrderAndCheckAtMostTheConfiguredSizeTogether(size: Int) async throws {
        let f = try await Fixture(batchSize: size)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-4")
        var leaves: [Leaf] = []
        for name in ["d", "b", "e", "a", "c"] { leaves.append(try await f.addLeaf(name, under: root)) }
        let queue = leaves.sorted { $0.id < $1.id }
        try await f.enqueue(queue)
        let tipBeforeBatch = try await f.advance(root, file: "latest-requirement.txt")

        try await f.finishLandings(queue)

        let calls = await f.checks.calls.filter { !$0.members.isEmpty }
        let groups = stride(from: 0, to: queue.count, by: size).map {
            Array(queue[$0..<min($0 + size, queue.count)]).map(\.id)
        }
        #expect(calls.map(\.members) == groups, "Fill each batch oldest first; check its combined tip once")
        #expect(calls.allSatisfy { $0.selection == nil })
        #expect(calls.first?.tips[root.branch] == tipBeforeBatch)
        for call in calls {
            if call.members.count > 1 {
                #expect(call.directory != f.repo)
                #expect(!leaves.contains { f.workspace.worktree(for: $0.id).standardizedFileURL == call.directory })
            }
            #expect(try await f.contains(tipBeforeBatch, in: call.commit), "Build from the latest requirement tip")
            #expect(call.subjects == call.members.flatMap { Self.subjects(for: $0) })
        }
    }

    @Test
    func differentRequirementBranchesNeverShareACheckedBatch() async throws {
        let f = try await Fixture(batchSize: 3)
        defer { f.cleanUp() }
        let a = try await f.addRequirement("REQ-5")
        let b = try await f.addRequirement("REQ-6")
        let a1 = try await f.addLeaf("a1", under: a)
        let b1 = try await f.addLeaf("b1", under: b)
        let a2 = try await f.addLeaf("a2", under: a)
        let b2 = try await f.addLeaf("b2", under: b)
        try await f.enqueue([a1, b1, a2, b2])

        try await f.finishLandings([a1, b1, a2, b2])

        let calls = await f.checks.calls.filter { !$0.members.isEmpty }
        #expect(calls.map(\.members) == [[a1.id, a2.id], [b1.id, b2.id]])
        #expect(try await f.paths(at: a.branch).contains(Self.marker(a2.id)))
        #expect(try await f.paths(at: b.branch).contains(Self.marker(b2.id)))
        #expect(try await !f.paths(at: a.branch).contains(Self.marker(b1.id)))
        #expect(try await !f.paths(at: b.branch).contains(Self.marker(a1.id)))
    }

    @Test
    func onlyOneLandingCheckRunsAcrossRoundsAndBranchesWhileABatchTakesOneAgentSlot() async throws {
        let f = try await Fixture(batchSize: 3, maxParallelAgents: 2, holdFirstCheck: true)
        defer { f.cleanUp() }
        let a = try await f.addRequirement("REQ-7")
        let b = try await f.addRequirement("REQ-8")
        var landing: [Leaf] = []
        for name in ["a1", "a2", "a3"] { landing.append(try await f.addLeaf(name, under: a)) }
        landing.append(try await f.addLeaf("b1", under: b))
        landing.append(try await f.addLeaf("b2", under: b))
        let extra1 = try await f.addUnbuiltLeaf("extra1", under: a)
        let extra2 = try await f.addUnbuiltLeaf("extra2", under: a)
        try await f.enqueue(landing)
        let running = Task { try await f.round(waitForAgents: false) }
        defer { f.checks.release.open(); f.agents.release.open(); running.cancel() }
        try await f.checks.entered.wait(for: "the first landing check")
        #expect(await f.checks.calls.first?.members == Array(landing.prefix(3)).map(\.id))
        try await f.ledger.append([extra1, extra2].map {
            LedgerEvent(node: $0.id, by: .human("Developer"), kind: .gateOpened(.build))
        })

        _ = try await f.round(waitForAgents: false)
        try await f.agents.entered.wait(for: "ordinary work using the other agent slot")
        _ = try await f.round(waitForAgents: false)

        #expect(await f.agents.started.count == 1, "A batch uses one slot, not one per member or zero slots")
        #expect(await f.checks.calls.count == 1, "A second round cannot start another batch or single landing")
        #expect(await f.checks.maximumConcurrentCalls == 1)
        f.agents.release.open()
        f.checks.release.open()
        _ = try await withHangGuard("the held landing round") { try await running.value }
        try await f.finishLandings(landing)
        try await withHangGuard("ordinary agents finishing") { await f.reconciler.waitForAgents() }
        #expect(await f.checks.maximumConcurrentCalls == 1)
    }

    @Test(arguments: [1, 3])
    func checkedOutRequirementWaitsOnceWithoutARunAndDoesNotBlockAnotherRequirement(size: Int) async throws {
        let f = try await Fixture(batchSize: size)
        defer { f.cleanUp() }
        let held = try await f.addRequirement("REQ-9")
        let free = try await f.addRequirement("REQ-10")
        let waiting = [try await f.addLeaf("held1", under: held), try await f.addLeaf("held2", under: held)]
        let ready = [try await f.addLeaf("free1", under: free), try await f.addLeaf("free2", under: free)]
        try await f.enqueue([waiting[0], ready[0], waiting[1], ready[1]])
        let checkout = try await f.checkout(held)

        _ = try await f.round()
        _ = try await f.round()

        for leaf in waiting {
            let node = try #require(await f.ledger.workingState().nodes[leaf.id])
            #expect(node.phase == .landing && node.activeRun == nil)
            #expect(node.failedAttempts == 0 && node.agentRunsSinceHuman == 0)
            #expect(await f.ledger.records(for: leaf.id).allSatisfy {
                if case .runStarted = $0.event.kind { return false }
                return true
            })
            let comments = await f.tracker.comments(on: leaf.ticket)
            #expect(comments.filter { $0.hasPrefix("⏸ Waiting to land:") }.count == 1)
            #expect(comments.contains { $0.contains(held.branch) && $0.contains("Switch that checkout") })
        }
        #expect(await f.checks.calls.allSatisfy { Set($0.members).isDisjoint(with: waiting.map(\.id)) })
        #expect(await f.ledger.workingState().nodes[ready[0].id]?.phase == .proven)
        #expect(await f.ledger.workingState().nodes[ready[1].id]?.phase == .proven)
        #expect(try await f.revision(held.branch) == f.initialMain)
        try await f.removeCheckout(checkout)
        try await f.finishLandings(waiting)
    }

    @Test
    func checkingOutTheRequirementDuringABatchCheckPreventsEveryMemberFromLanding() async throws {
        let f = try await Fixture(batchSize: 3, holdFirstCheck: true)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-11")
        let leaves = [try await f.addLeaf("late1", under: root), try await f.addLeaf("late2", under: root)]
        try await f.enqueue(leaves)
        let running = Task { try await f.round() }
        defer { f.checks.release.open(); running.cancel() }
        try await f.checks.entered.wait(for: "the batch being checked")
        #expect(await f.checks.calls.first?.members == leaves.map(\.id))
        let checkout = try await f.checkout(root)
        f.checks.release.open()

        _ = try await withHangGuard("landing rechecking the checkout wait") { try await running.value }
        _ = try await f.round()

        #expect(try await f.revision(root.branch) == f.initialMain)
        for leaf in leaves {
            let node = try #require(await f.ledger.workingState().nodes[leaf.id])
            #expect(node.phase == .landing && node.landedCommit == nil && node.activeRun == nil)
            #expect(node.failedAttempts == 0)
            #expect(await f.tracker.comments(on: leaf.ticket).filter { $0.hasPrefix("⏸ Waiting to land:") }.count == 1)
        }
        #expect(await f.checks.calls.count == 1, "Waiting again must not consume another check run")
        try await f.removeCheckout(checkout)
        try await f.finishLandings(leaves)
    }

    @Test
    func passingBatchRecordsEachMembersOwnCommitAndSharedCheckEvidenceWithNamedLandedComments() async throws {
        let f = try await Fixture(batchSize: 3)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-12")
        let leaves = [try await f.addLeaf("one", under: root), try await f.addLeaf("two", under: root),
                      try await f.addLeaf("three", under: root)]
        try await f.enqueue(leaves)

        try await f.finishLandings(leaves)

        let records = await f.ledger.allRecords()
        let batch = try #require(records.compactMap { $0.event.kind.landingBatchCheck }.first)
        #expect(!batch.name.isEmpty)
        #expect(batch.branch == root.branch && batch.nodes == leaves.map(\.id) && batch.passed)
        #expect(await f.checks.calls.filter { $0.selection == nil }.count == 1)
        #expect(batch.candidateCommit == (await f.checks.calls.first?.commit))
        let state = await f.ledger.workingState()
        var commits: [String] = []
        for leaf in leaves {
            let node = try #require(state.nodes[leaf.id])
            let commit = try #require(node.landedCommit)
            commits.append(commit)
            #expect(node.phase == .proven && node.activeRun == nil && node.failedAttempts == 0)
            #expect(try await f.git(["show", "-s", "--format=%s", commit]) == "\(leaf.id) second")
            let evidence = try #require(node.evidence.last { $0.passed && $0.checkedBy == batch.run })
            #expect(evidence.commit == batch.candidateCommit, "Earlier members point to the combined check, not an unchecked prefix")
            #expect(evidence.builtBy == leaf.builder && evidence.checkedBy != evidence.builtBy)
            #expect(try String(contentsOf: URL(filePath: evidence.artifactPath), encoding: .utf8) == Self.pass.log)
            #expect(evidence.artifactSHA256 == Hashing.sha256(Data(Self.pass.log.utf8)))
            #expect(await f.tracker.comments(on: leaf.ticket).contains {
                $0.hasPrefix("🛬 Landed on \(root.branch) at \(commit.prefix(8)) with all tests passing.")
                    && $0.contains(batch.name)
            })
        }
        #expect(Set(commits).count == leaves.count)
        #expect(commits.last == batch.candidateCommit)
        #expect(try await f.revision(root.branch) == batch.candidateCommit)
    }

    @Test
    func batchKeepsEveryNodesCommitsInQueueOrderWithNoUIEvidenceInAnyLandedCommit() async throws {
        let f = try await Fixture(batchSize: 3)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-13")
        let leaves = [try await f.addLeaf("first", under: root, uiEvidence: true),
                      try await f.addLeaf("second", under: root, uiEvidence: true)]
        try await f.enqueue(leaves)

        try await f.finishLandings(leaves)

        let history = try await f.git(["log", "--reverse", "--format=%H", "\(f.initialMain)..\(root.branch)"])
            .split(separator: "\n").map(String.init)
        let subjects = try await f.git(["log", "--reverse", "--format=%s", "\(f.initialMain)..\(root.branch)"])
            .split(separator: "\n").map(String.init)
        #expect(subjects == leaves.flatMap { Self.subjects(for: $0.id) }, "Keep acceptance and both implementation commits, not a squash")
        for commit in history {
            let paths = try await f.paths(at: commit)
            #expect(!paths.contains { $0 == ".agentos-ui-evidence.json" || $0.hasPrefix(".agentos-ui-evidence/") },
                    "Removing evidence only in a final cleanup commit still publishes it in earlier commits")
        }
        for leaf in leaves {
            #expect(try await f.paths(at: root.branch).contains(Self.marker(leaf.id)))
            #expect(try await f.paths(at: root.branch).contains("Changes/\(leaf.id)/second.txt"))
        }
    }

    @Test
    func movingTheRequirementDuringChecksCannotOverwriteThatTipWithTheStaleBatch() async throws {
        let f = try await Fixture(batchSize: 3, holdFirstCheck: true)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-14")
        let leaves = [try await f.addLeaf("cas1", under: root), try await f.addLeaf("cas2", under: root)]
        try await f.enqueue(leaves)
        let running = Task { try await f.round() }
        defer { f.checks.release.open(); running.cancel() }
        try await f.checks.entered.wait(for: "a checked candidate based on the old branch tip")
        let stale = try #require(await f.checks.calls.first)
        #expect(stale.members == leaves.map(\.id))
        let concurrentTip = try await f.advance(root, file: "concurrent-change.txt")
        f.checks.release.open()

        _ = try await withHangGuard("the compare-and-swap landing") { try await running.value }

        let finalTip = try await f.revision(root.branch)
        #expect(try await f.contains(concurrentTip, in: finalTip), "Never lose work that moved the ref after the check started")
        #expect(finalTip != stale.commit)
        let state = await f.ledger.workingState()
        for leaf in leaves {
            if let landed = state.nodes[leaf.id]?.landedCommit {
                #expect(try await f.contains(concurrentTip, in: landed))
                let evidence = try #require(state.nodes[leaf.id]?.evidence.last { $0.passed })
                #expect(evidence.commit != stale.commit, "An automatic retry must check the new candidate before landing")
            }
        }
    }

    @Test
    func aFailedBatchCheckAlsoRecordsItsBranchMembersCandidateAndFailedResult() async throws {
        let f = try await Fixture(batchSize: 2)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-16")
        let leaves = [try await f.addLeaf("failure1", under: root), try await f.addLeaf("failure2", under: root)]
        try await f.enqueue(leaves)
        await f.checks.returnEveryTime(CheckOutput(
            passed: false, summary: "batch tests failed", log: "batch tests failed",
            failingTargets: Set(leaves.map(\.spec.testTarget))))

        _ = try await f.round()

        let firstCheck = try #require(await f.checks.calls.first)
        let record = try #require(await f.ledger.allRecords().first {
            guard let batch = $0.event.kind.landingBatchCheck else { return false }
            return batch.candidateCommit == firstCheck.commit && !batch.passed
        })
        let batch = try #require(record.event.kind.landingBatchCheck)
        #expect(!batch.name.isEmpty && !batch.run.isEmpty)
        #expect(batch.branch == root.branch)
        #expect(batch.nodes == leaves.map(\.id))
        #expect(record.event.kind.summary.localizedCaseInsensitiveContains("failed"))
    }

    @Test @MainActor
    func everyBatchCheckSurvivesLedgerReloadAndItsDetailsAppearInTheLedgerPane() async throws {
        let model = HarnessViewModel()
        let calibration = try Ledger()
        try await calibration.append([
            LedgerEvent(node: nil, by: .reconciler,
                        kind: .signalAccepted(ticket: "GH-103", command: .retry, reply: "accepted")),
        ])
        await model.refreshLedger(from: calibration)
        let knownText = try RenderedUI.text(of: LedgerPane().environment(model), size: CGSize(width: 1800, height: 800))
        try #require(RenderedUI.shows("harness:retry on GH-103 accepted", in: knownText),
                     "Verify the shared renderer against an existing ledger row before using it for batch evidence")
        let f = try await Fixture(batchSize: 2)
        defer { f.cleanUp() }
        let root = try await f.addRequirement("REQ-15")
        let leaves = [try await f.addLeaf("log1", under: root), try await f.addLeaf("log2", under: root),
                      try await f.addLeaf("log3", under: root), try await f.addLeaf("log4", under: root)]
        try await f.enqueue(leaves)

        try await f.finishLandings(leaves)

        let restored = try Ledger(store: FileLedgerStore(fileURL: f.ledgerFile))
        #expect(await restored.verifyChain().isIntact)
        let recorded = await restored.allRecords().filter { $0.event.kind.landingBatchCheck != nil }
        #expect(recorded.count == 2, "Record every full batch check, not just the final branch tip")
        #expect(recorded.compactMap { $0.event.kind.landingBatchCheck }
                == (await f.ledger.allRecords()).compactMap { $0.event.kind.landingBatchCheck })
        try #require(!recorded.isEmpty)
        await model.refreshLedger(from: restored)
        for record in recorded {
            let batch = try #require(record.event.kind.landingBatchCheck)
            let summary = record.event.kind.summary
            let expected = [batch.name, batch.branch, String(batch.candidateCommit.prefix(8)), "passed"] + batch.nodes
            for detail in expected { #expect(summary.localizedCaseInsensitiveContains(detail)) }
            await model.ledgerPage.selectKind(LedgerEventKind(record.event.kind))
            let text = try RenderedUI.text(of: LedgerPane().environment(model), size: CGSize(width: 2400, height: 1000))
            for detail in expected { #expect(RenderedUI.shows(detail, in: text), "Missing ledger detail: \(detail)") }
        }
    }
}
