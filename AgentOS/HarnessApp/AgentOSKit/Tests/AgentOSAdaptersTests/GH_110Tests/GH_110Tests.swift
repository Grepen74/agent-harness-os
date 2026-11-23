// API: Reconciler.runRound selects and refreshes the real workspace's main reference using Policy.pullRequests.
// Existing MainBaselineCoordinator/MainTipRepository, requirement workspace methods, ledger observations,
// WorkingState.status(of:), and WorkPane expose the resulting commits, dependency readiness and fetch warning.
// No new declarations are needed. Criterion 6 (real-repo-mode.md's fetch/reference/warning documentation,
// including removal of the "nothing is fetched" claim) is source-only and is reviewed against the diff.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
import AgentOSUI

@Suite struct GH_110Tests {
    @Test
    func everyPublishingRoundFetchesEvenWhenTheDefaultBranchHasNotMoved() async throws {
        let f = try await Fixture(publishing: true)
        defer { f.cleanUp() }
        await f.tracker.observeMainAtSignalIntake {
            try await f.revision("refs/remotes/origin/\(f.defaultBranch)")
        }

        _ = try await f.round()
        let first = try f.fetchCount()
        #expect(first > 0)
        _ = try await f.round()
        let second = try f.fetchCount()
        #expect(second > first, "An unchanged tip does not remove the next round's fetch.")

        let moved = try await f.advanceOrigin(file: "next-default.txt")
        _ = try await f.round()
        #expect(try f.fetchCount() > second)
        #expect(try await f.revision("refs/remotes/origin/\(f.defaultBranch)") == moved)
        #expect(await f.tracker.mainAtSignalIntake.last == moved,
                "The fetch must precede signal intake, not merely happen somewhere later in the round.")
    }

    @Test(arguments: ["main", "trunk"])
    func baselineAndNewRequirementBranchesUseTheFetchedDefaultRatherThanLocalMain(_ branch: String) async throws {
        let f = try await Fixture(publishing: true, defaultBranch: branch)
        defer { f.cleanUp() }
        let local = try await f.advanceLocalDefault(file: "local-only.txt")
        let fetched = try await f.advanceOrigin(file: "origin-only.txt")

        _ = try await f.round()
        try await Self.expectBaseline(f, lastBased: f.initial, observes: fetched)
        let snapshot = try #require(try await f.workspace.createSnapshot())
        #expect(try await f.workspace.head(of: snapshot) == fetched,
                "An unscoped main snapshot must read the selected baseline, not the person's checkout.")
        await f.workspace.removeSnapshot(snapshot)
        let requirement = NodeIdentity(ticketKey: "GH-110-NEW", nodeID: "new-requirement")
        #expect(try await f.workspace.prepareRequirementBranch(for: requirement, leaves: []) == fetched)
        #expect(try await f.revision("agentos/GH-110-NEW") == fetched)
        #expect(try await f.revision("refs/heads/\(branch)") == local)

        let next = try await f.advanceOrigin(file: "origin-later.txt")
        _ = try await f.round()
        let later = NodeIdentity(ticketKey: "GH-110-LATER", nodeID: "later-requirement")
        #expect(try await f.workspace.prepareRequirementBranch(for: later, leaves: []) == next)
        #expect(try await f.revision("agentos/GH-110-NEW") == fetched,
                "Selecting a new main must not recreate an existing requirement branch.")
    }

    @Test(arguments: ["main", "trunk"])
    func requirementCatchUpUsesTheFetchedDefaultCommitAndKeepsItsOwnWork(_ branch: String) async throws {
        let f = try await Fixture(publishing: true, defaultBranch: branch)
        defer { f.cleanUp() }
        let requirement = try await f.addRequirement("CATCHUP")
        let own = try await f.advanceRequirement(requirement, file: "requirement-only.txt")
        let local = try await f.advanceLocalDefault(file: "local-only.txt")
        let fetched = try await f.advanceOrigin(file: "origin-only.txt")
        try await f.recordBaseline(fetched)

        _ = try await f.round()

        let state = await f.ledger.workingState()
        let root = try #require(state.nodes[requirement.nodeID])
        #expect(root.requirementBranchObservation?.main == fetched)
        #expect(root.lastCatchUpSuccess?.mainSHA == fetched)
        try #require(try await f.revision("refs/remotes/origin/\(branch)") == fetched,
                     "Catch-up must first fetch the selected default commit into the local object database.")
        #expect(try await f.workspace.isAncestor(fetched, of: f.branch(requirement)))
        #expect(try await f.workspace.isAncestor(own, of: f.branch(requirement)))
        #expect(try await !f.workspace.isAncestor(local, of: f.branch(requirement)),
                "Unpushed commits on the person's default branch must not enter published requirements.")
    }

    @Test(arguments: [false, true])
    func anOriginOnlyMergeShowsDoneAndUnblocksCrossRequirementDependencies(_ dependentHasBranch: Bool) async throws {
        let f = try await Fixture(publishing: true)
        defer { f.cleanUp() }
        let delivered = try await f.addRequirement("DELIVERED", proven: true)
        let commit = try await f.advanceRequirement(delivered, file: "delivered-feature.txt")
        try await f.recordLanding(delivered, commit: commit)
        let dependent = try await f.addDependent(on: delivered, createBranch: dependentHasBranch)
        try await f.mergeIntoOrigin(commit)
        try await f.recordBaseline(commit)
        #expect(try await !f.workspace.isAncestor(commit, of: "refs/heads/main"),
                "The fixture must represent a person who has not pulled the merged work.")
        #expect(await f.ledger.workingState().nodes[dependent]?.flags[.blocked] != nil)

        try await f.roundsUntil("origin-merged requirement and its dependency become ready") { state in
            guard let root = state.nodes[delivered.nodeID] else { return false }
            return state.status(of: root) == "Done" && state.nodes[dependent]?.flags[.blocked] == nil
        }

        let state = await f.ledger.workingState()
        let root = try #require(state.nodes[delivered.nodeID])
        #expect(root.requirementBranchObservation?.main == commit)
        #expect(try await f.workspace.requirementIsMerged(delivered))
        #expect(await f.tracker.statuses[delivered.ticketKey] == "Done")
        #expect(try await f.revision("refs/heads/main") == f.initial)
        if !dependentHasBranch {
            #expect(try await f.workspace.branch(nil, hasEverythingIn: commit),
                    "Dependencies without a requirement branch start from the fetched default.")
        } else {
            #expect(try await f.workspace.branch("agentos/GH-110-DEPENDENT", hasEverythingIn: commit))
        }
    }

    @Test(arguments: [false, true])
    func fetchingPreservesTheDefaultBranchCheckoutIndexAndDirtyFiles(_ defaultIsCheckedOut: Bool) async throws {
        let f = try await Fixture(publishing: true)
        defer { f.cleanUp() }
        if defaultIsCheckedOut { try await f.git(["switch", "-q", f.defaultBranch]) }
        try "staged\n".write(to: f.repo.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
        try await f.git(["add", "staged.txt"])
        try "unstaged after staging\n".write(to: f.repo.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
        try "personal edit\n".write(to: f.repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
        try "untracked work\n".write(to: f.repo.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
        let before = try await f.personalState()
        let fetched = try await f.advanceOrigin(file: "new-origin-file.txt")

        _ = try await f.round()

        #expect(try await f.revision("refs/remotes/origin/main") == fetched)
        #expect(try await f.personalState() == before)
    }

    @Test
    func anAgentRunningAcrossAnOriginFetchIsNotEscalatedOrRebasedByTheFetch() async throws {
        let f = try await Fixture(publishing: true)
        defer { f.cleanUp() }
        let requirement = try await f.addRequirement("BUSY")
        let leaf = try await f.prepareBuilder(requirement)
        defer { f.agents.release.open() }
        _ = try await f.round(waitForAgents: false)
        try await f.agents.started.wait(for: "GH-110 implementer enters its git-state watch")
        let run = try #require(await f.ledger.workingState().nodes[leaf]?.activeRun?.run)
        let head = try await f.workspace.head(of: f.workspace.worktree(for: leaf))
        let fetched = try await f.advanceOrigin(file: "origin-during-agent.txt")
        try await f.recordBaseline(fetched)

        _ = try await f.round(waitForAgents: false)

        #expect(try await f.revision("refs/remotes/origin/main") == fetched)
        #expect(await f.ledger.workingState().nodes[leaf]?.activeRun?.run == run)
        #expect(try await f.workspace.head(of: f.workspace.worktree(for: leaf)) == head,
                "Catch-up may move the requirement, but must leave the running leaf's checkout alone.")
        f.agents.release.open()
        try await withHangGuard("GH-110 implementer finishes after the fetch") {
            await f.reconciler.waitForAgents()
        }
        let node = try #require(await f.ledger.workingState().nodes[leaf])
        #expect(node.flags[.escalated] == nil)
        #expect(node.failedAttempts == 0)
        #expect(node.lastSubmission != nil, "The gated agent must submit normally, not fail the git-state watch.")
    }

    @MainActor @Test
    func aFailedFetchWarnsUsesTheLastFetchedCommitAndClearsAfterRecovery() async throws {
        try await Self.checkAttentionRenderer()
        let f = try await Fixture(publishing: true)
        defer { f.cleanUp() }
        let lastFetched = try await f.advanceOrigin(file: "last-fetched.txt")
        try await f.git(["fetch", "-q", "origin", "main"])
        _ = try await f.round()
        let requirement = try await f.addRequirement("OFFLINE", from: f.initial)
        let own = try await f.advanceRequirement(requirement, file: "offline-requirement.txt")
        let notFetched = try await f.advanceOrigin(file: "not-yet-fetched.txt")
        try await f.recordBaseline(lastFetched)
        try f.setFetchFailure(true)
        try await f.verifyFetchFailure()

        let failedRound = try await f.round()

        #expect(failedRound.safeStop == nil, "A failed fetch is a warning, not a safe stop.")
        #expect(try await f.revision("refs/remotes/origin/main") == lastFetched)
        let state = await f.ledger.workingState()
        #expect(state.nodes[requirement.nodeID]?.requirementBranchObservation?.main == lastFetched)
        #expect(state.nodes[requirement.nodeID]?.lastCatchUpSuccess?.mainSHA == lastFetched)
        #expect(try await f.workspace.isAncestor(lastFetched, of: f.branch(requirement)))
        #expect(try await f.workspace.isAncestor(own, of: f.branch(requirement)))
        #expect(try await f.git(["ls-tree", "--name-only", f.branch(requirement), "--", "not-yet-fetched.txt"]).isEmpty)
        let warning = try Self.attentionText(state)
        #expect(RenderedUI.shows("Needs attention", in: warning))
        #expect(RenderedUI.shows(Fixture.fetchError, in: warning), "The warning must include the actual git error.")
        #expect(RenderedUI.shows("last fetched", in: warning), "The warning must explain the fallback, not just say fetch failed.")

        try f.setFetchFailure(false)
        try await f.recordBaseline(notFetched)
        _ = try await f.round()
        #expect(try await f.revision("refs/remotes/origin/main") == notFetched)
        #expect(await f.ledger.workingState().nodes[requirement.nodeID]?.requirementBranchObservation?.main == notFetched)
        let recovered = try Self.attentionText(await f.ledger.workingState())
        #expect(!RenderedUI.shows(Fixture.fetchError, in: recovered))
        #expect(!RenderedUI.shows("last fetched", in: recovered))
    }

    @Test
    func publishingOffUsesLocalMainForBaselineNewBranchesAndCatchUpWithoutFetching() async throws {
        let f = try await Fixture(publishing: false)
        defer { f.cleanUp() }
        let requirement = try await f.addRequirement("LOCAL")
        let own = try await f.advanceRequirement(requirement, file: "requirement-local.txt")
        let local = try await f.advanceLocalDefault(file: "local-default.txt")
        let remote = try await f.advanceOrigin(file: "remote-default.txt")
        try await f.git(["fetch", "-q", "origin", f.defaultBranch])
        let before = try f.fetchCount()
        try await f.recordBaseline(local)

        _ = try await f.round()
        _ = try await f.round()

        #expect(try f.fetchCount() == before)
        #expect(try await f.revision("refs/remotes/origin/main") == remote,
                "The remote ref is deliberately already newer; publishing off must still use local main.")
        try await Self.expectBaseline(f, lastBased: f.initial, observes: local)
        let added = NodeIdentity(ticketKey: "GH-110-OFF", nodeID: "off-new")
        #expect(try await f.workspace.prepareRequirementBranch(for: added, leaves: []) == local)
        let state = await f.ledger.workingState()
        #expect(state.nodes[requirement.nodeID]?.requirementBranchObservation?.main == local)
        #expect(state.nodes[requirement.nodeID]?.lastCatchUpSuccess?.mainSHA == local)
        #expect(try await f.workspace.isAncestor(local, of: f.branch(requirement)))
        #expect(try await f.workspace.isAncestor(own, of: f.branch(requirement)))
        #expect(try await !f.workspace.isAncestor(remote, of: f.branch(requirement)))
    }

    @Test
    func publishingOffDoesNotTreatAnOriginOnlyMergeAsDoneOrSatisfyItsDependency() async throws {
        let f = try await Fixture(publishing: false)
        defer { f.cleanUp() }
        let requirement = try await f.addRequirement("LOCAL-MERGE", proven: true)
        let commit = try await f.advanceRequirement(requirement, file: "dependency.txt")
        try await f.recordLanding(requirement, commit: commit)
        let dependent = try await f.addDependent(on: requirement, createBranch: false)
        try await f.mergeIntoOrigin(commit)
        try await f.git(["fetch", "-q", "origin", "main"])
        let before = try f.fetchCount()
        try await f.recordBaseline(f.initial)

        _ = try await f.round()
        let remoteOnly = await f.ledger.workingState()
        #expect(remoteOnly.status(of: try #require(remoteOnly.nodes[requirement.nodeID])) == "In review")
        #expect(remoteOnly.nodes[dependent]?.flags[.blocked] != nil)
        #expect(try await !f.workspace.requirementIsMerged(requirement))
        #expect(try await !f.workspace.branch(nil, hasEverythingIn: commit))

        try await f.git(["update-ref", "refs/heads/main", commit, f.initial])
        try await f.recordBaseline(commit)
        try await f.roundsUntil("local merge satisfies the dependency with publishing off") { state in
            guard let root = state.nodes[requirement.nodeID] else { return false }
            return state.status(of: root) == "Done" && state.nodes[dependent]?.flags[.blocked] == nil
        }
        #expect(try f.fetchCount() == before)
        #expect(try await f.workspace.requirementIsMerged(requirement))
        #expect(try await f.workspace.branch(nil, hasEverythingIn: commit))
    }

    private static func expectBaseline(_ f: Fixture, lastBased: String, observes expected: String) async throws {
        let finished = TestGate()
        let coordinator = MainBaselineCoordinator(lastBasedMainCommit: lastBased, repository: f.workspace) { request in
            #expect(request.commit == expected)
            finished.open()
            return BaselineRunResult(passed: true, summary: "passed", seconds: 0,
                                     log: f.directory.appending(path: "baseline.log"), latestLogLine: nil)
        }
        await coordinator.reconcile()
        let observed = await coordinator.comparedMainCommits.last?.observed
        #expect(observed == expected, "The baseline must observe the same main commit selected for the round.")
        if let observed, observed != lastBased {
            try await finished.wait(for: "GH-110 baseline runner receives the selected main commit")
        }
    }

    @MainActor private static func attentionText(_ state: WorkingState) throws -> String {
        let model = HarnessViewModel()
        model.state = state
        return try RenderedUI.text(of: WorkPane().environment(model), size: CGSize(width: 1400, height: 900))
    }

    @MainActor private static func checkAttentionRenderer() async throws {
        let ledger = try Ledger()
        let spec = NodeSpec(id: "renderer-probe", kind: .leaf, title: "Existing attention",
                            intent: "Check the shared renderer", acceptanceCriteria: ["Attention is readable"])
        try await ledger.append([
            LedgerEvent(node: spec.id, by: .human("Person"), kind: .nodeCreated(spec: spec, ticket: "PROBE")),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .flagSet(.needsInput, reason: "Existing renderer probe")),
        ])
        let text = try Self.attentionText(await ledger.workingState())
        try #require(RenderedUI.shows("Needs attention", in: text))
        try #require(RenderedUI.shows("Existing renderer probe", in: text),
                     "Check the exact rendering path against an existing, ledger-backed attention item.")
    }
}
