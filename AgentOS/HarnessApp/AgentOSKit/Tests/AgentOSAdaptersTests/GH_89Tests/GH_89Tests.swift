// API contract: Reconciler accepts a RequirementBranchRepository alongside its Workspace.
// The repository supplies local branch tips, ancestry, atomic main merges and commit paths;
// ordinary rounds use ledger baselines, catch up each requirement, and project ledger-derived statuses.
// RequirementBranchRepository: defaultBranch; requirementBranch(for:); tip(of:); isAncestor(_:of:);
// mergeMain(_:into:) -> RebaseResult; changedFiles(in:). See GH_89TestsSupport.swift for signatures.
// No criteria are excluded as documentation/source-only checks.
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_89Tests {
    @Test
    func everyPassingMainAdvanceCatchesUpEachOpenRequirementAndOnlyItsOwnIdleActiveLeaves() async throws {
        try await Self.withFixture { f in
            let gate = Gate()
            defer { gate.release() }
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-running", parent: "a", build: true)
            await f.agents.hold("a-running", at: gate)
            try await f.baseline("base")
            try await f.round(waitForAgents: false)
            try await gate.entered.wait(for: "GH-89 implementer entry")
            try #require(await f.reconciler.busyNodes.contains("a-running"))
            try #require(await f.ledger.workingState().nodes["a-running"]?.phase == .building)

            try await f.composite("a-group", parent: "a")
            try await f.leaf("a-active", parent: "a-group")
            try await f.leaf("a-landed", parent: "a", phase: .proven)
            try await f.leaf("a-unauthored", parent: "a", phase: .specified, tests: false)
            try await f.requirement("b", ticket: "GH-102")
            try await f.leaf("b-active", parent: "b")
            try await f.requirement("closed", ticket: "GH-103", closed: true)
            try await f.leaf("closed-leaf", parent: "closed")
            try await f.leaf("single", ticket: "GH-104")
            let unchanged = await f.workspace.leafTips(["a-running", "a-landed", "a-unauthored", "closed-leaf"])
            let closedTip = await f.workspace.tip(of: "agentos/GH-103")

            for main in ["main-one", "main-two"] {
                let oldA = try #require(await f.workspace.tip(of: "agentos/GH-101"))
                let oldB = try #require(await f.workspace.tip(of: "agentos/GH-102"))
                await f.workspace.advanceMain(to: main, files: ["Main/\(main).swift"])
                try await f.baseline(main)
                await f.workspace.clearCalls()
                try await f.round(waitForAgents: false)

                let merges = await f.workspace.mergeCalls
                #expect(Set(merges.map(\.branch)) == ["agentos/GH-101", "agentos/GH-102", "agentos/GH-104"])
                #expect(merges.count == 3)
                #expect(merges.allSatisfy { $0.main == main })
                let rebases = await f.workspace.rebaseCalls
                #expect(Set(rebases.map(\.leaf)) == ["a-active", "b-active", "single"])
                #expect(rebases.count == 3)
                for (leaf, branch) in [
                    ("a-active", "agentos/GH-101"), ("b-active", "agentos/GH-102"), ("single", "agentos/GH-104"),
                ] {
                    let tip = try #require(await f.workspace.tip(of: branch))
                    #expect(await f.workspace.isAncestor(main, of: tip))
                    #expect(rebases.contains { $0.leaf == leaf && $0.branch == branch && $0.tip == tip })
                    let leafTip = try #require(await f.workspace.leafTips([leaf])[leaf])
                    #expect(await f.workspace.isAncestor(tip, of: leafTip))
                }
                let newA = try #require(await f.workspace.tip(of: "agentos/GH-101"))
                let newB = try #require(await f.workspace.tip(of: "agentos/GH-102"))
                #expect(await f.workspace.isAncestor(oldA, of: newA))
                #expect(await f.workspace.isAncestor(oldB, of: newB))
                #expect(!(await f.workspace.isAncestor(oldB, of: newA)))
                #expect(!(await f.workspace.isAncestor(oldA, of: newB)))
                #expect(await f.workspace.leafTips(Array(unchanged.keys)) == unchanged)
                #expect(await f.workspace.tip(of: "agentos/GH-103") == closedTip)
            }
        }
    }

    @Test(arguments: BaselineCase.allCases)
    func mainWithoutAPassingBaselineForItsCurrentTipDoesNotMoveBranchesOrLeaves(_ example: BaselineCase) async throws {
        try await Self.withFixture { f in
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-active", parent: "a")
            let branchTip = await f.workspace.tip(of: "agentos/GH-101")
            let leafTips = await f.workspace.leafTips(["a-active"])
            await f.workspace.advanceMain(to: "unchecked-main", files: ["Main/New.swift"])
            switch example {
            case .missing: break
            case .failed: try await f.baseline("unchecked-main", passed: false)
            case .stale: try await f.baseline("base")
            }

            try await f.round()

            #expect(await f.workspace.mergeCalls.isEmpty)
            #expect(await f.workspace.rebaseCalls.isEmpty)
            #expect(await f.workspace.tip(of: "agentos/GH-101") == branchTip)
            #expect(await f.workspace.leafTips(["a-active"]) == leafTips)
        }
    }

    @Test(arguments: [Phase.checking, .landing])
    func checkingAndLandingLeavesCatchUpBeforeVerificationOnTheirRequirementBranch(_ phase: Phase) async throws {
        try await Self.withFixture { f in
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-candidate", parent: "a", phase: phase)
            try await f.requirement("b", ticket: "GH-102")
            try await f.leaf("b-active", parent: "b")
            await f.workspace.advanceMain(to: "main-one", files: ["Main/New.swift"])
            try await f.baseline("main-one")

            try await f.settle()

            let checks = await f.checks.observations.filter { $0.leaf == "a-candidate" }
            #expect(!checks.isEmpty)
            if phase == .checking {
                #expect(checks.contains { $0.selection != nil }, "The own-suite check must still run")
            }
            for check in checks {
                #expect(await f.workspace.isAncestor("main-one", of: check.tip),
                        "Verification must not run on the stale leaf before catch-up")
                #expect(await f.workspace.isAncestor(check.requirementTip, of: check.tip))
            }
            #expect(await f.ledger.workingState().nodes["a-candidate"]?.phase == .proven)
            let bTip = try #require(await f.workspace.tip(of: "agentos/GH-102"))
            let bLeaf = try #require(await f.workspace.leafTips(["b-active"])["b-active"])
            #expect(await f.workspace.isAncestor("main-one", of: bTip))
            #expect(await f.workspace.isAncestor(bTip, of: bLeaf))
            #expect(!(await f.workspace.isAncestor(bTip, of: try #require(checks.first).tip)),
                    "Another requirement's branch must not become this leaf's base")
        }
    }

    @Test
    func aLeafRebaseConflictGoesToReworkWithoutRollingBackItsRequirementOrOtherLeaves() async throws {
        try await Self.withFixture { f in
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-conflict", parent: "a")
            try await f.leaf("a-clean", parent: "a")
            try await f.requirement("b", ticket: "GH-102")
            try await f.leaf("b-active", parent: "b")
            let digest = await f.ledger.workingState().nodes["a-conflict"]?.testsDigest
            await f.workspace.conflictLeaf("a-conflict", files: ["Shared/Rules.swift"])
            await f.workspace.advanceMain(to: "main-one", files: ["Shared/Rules.swift"])
            try await f.baseline("main-one")

            try await f.settle()

            let state = await f.ledger.workingState()
            let leaf = try #require(state.nodes["a-conflict"])
            #expect(leaf.phase == .ready)
            #expect(leaf.reworks == 1)
            #expect(leaf.failedAttempts == 0)
            #expect(leaf.testsDigest == digest)
            #expect(Hashing.digest(of: f.workspace.worktree(for: leaf.id)
                .appending(path: f.workspace.testFolder(for: leaf.spec))) == digest)
            #expect(!state.attentionList.contains { $0.node.id == "a" })
            #expect(await f.workspace.resetCalls == ["a-conflict"])
            for (id, branch) in [
                ("a-conflict", "agentos/GH-101"), ("a-clean", "agentos/GH-101"), ("b-active", "agentos/GH-102"),
            ] {
                let tip = try #require(await f.workspace.tip(of: branch))
                let leafTip = try #require(await f.workspace.leafTips([id])[id])
                #expect(await f.workspace.isAncestor("main-one", of: tip))
                #expect(await f.workspace.isAncestor(tip, of: leafTip))
            }
            #expect(await f.tracker.ticket("a-conflict")?.comments.contains {
                $0.text.contains("Shared/Rules.swift") && $0.text.localizedCaseInsensitiveContains("rework")
            } == true)
        }
    }

    @Test
    func aConflictKeepsItsBranchUnchangedAndWaitsOnItsOwnTicketWhileOtherRequirementsBuildAndLand() async throws {
        try await Self.withFixture { f in
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-ready", parent: "a", build: true)
            try await f.leaf("a-queued", parent: "a", phase: .landing)
            try await f.requirement("b", ticket: "GH-102")
            try await f.leaf("b-ready", parent: "b", build: true)
            try await f.leaf("b-queued", parent: "b", phase: .landing)
            let oldA = await f.workspace.tip(of: "agentos/GH-101")
            let oldLeaves = await f.workspace.leafTips(["a-ready", "a-queued"])
            await f.workspace.advanceMain(to: "main-one", files: ["Shared/One.swift", "Shared/Two.swift"])
            await f.workspace.conflict("agentos/GH-101", with: "main-one", files: ["Shared/One.swift", "Shared/Two.swift"])
            try await f.baseline("main-one")

            try await f.settle()

            #expect(await f.workspace.tip(of: "agentos/GH-101") == oldA)
            #expect(await f.workspace.leafTips(["a-ready", "a-queued"]) == oldLeaves)
            #expect(!(await f.agents.starts).contains("a-ready"))
            #expect((await f.agents.starts).contains("b-ready"))
            let state = await f.ledger.workingState()
            #expect(state.nodes["a-queued"]?.phase == .landing)
            #expect(state.nodes["b-queued"]?.phase == .proven)
            let bTip = try #require(await f.workspace.tip(of: "agentos/GH-102"))
            #expect(await f.workspace.isAncestor("main-one", of: bTip))
            try await f.expectWaiting("a", branch: "agentos/GH-101", files: ["Shared/One.swift", "Shared/Two.swift"])
            let records = await f.ledger.allRecords()
            #expect(try records.contains {
                try Self.event($0.event, mentions: ["agentos/GH-101", "Shared/One.swift", "Shared/Two.swift"])
            }, "The conflict's branch and files must be recoverable from the ledger")
            #expect(await f.ledger.verifyChain().problem == nil)
        }
    }

    @Test
    func manualCatchUpIsRecognisedAfterRestartWithoutASignalAndDoesNotClearAnotherRequirementConflict() async throws {
        try await Self.withFixture { f in
            for (id, ticket) in [("a", "GH-101"), ("b", "GH-102")] {
                try await f.requirement(id, ticket: ticket)
                try await f.leaf("\(id)-ready", parent: id, build: true)
                await f.workspace.conflict("agentos/\(ticket)", with: "main-one", files: ["Shared/\(id).swift"])
            }
            await f.workspace.advanceMain(to: "main-one", files: ["Shared/a.swift", "Shared/b.swift"])
            try await f.baseline("main-one")
            try await f.settle()
            let before = await f.agents.starts
            #expect(!before.contains("a-ready") && !before.contains("b-ready"))
            try await f.expectWaiting("a", branch: "agentos/GH-101", files: ["Shared/a.swift"])
            try await f.expectWaiting("b", branch: "agentos/GH-102", files: ["Shared/b.swift"])
            let unchangedB = await f.workspace.tip(of: "agentos/GH-102")
            let manualTip = try await f.workspace.manuallyCatchUp("agentos/GH-101", to: "main-one")
            let restarted = f.makeReconciler()

            try await f.settle(using: restarted)

            #expect((await f.agents.starts).contains("a-ready"))
            #expect(!(await f.agents.starts).contains("b-ready"))
            #expect(await f.workspace.tip(of: "agentos/GH-101") == manualTip)
            #expect(await f.workspace.tip(of: "agentos/GH-102") == unchangedB)
            #expect((await f.workspace.rebaseCalls).contains { $0.leaf == "a-ready" && $0.tip == manualTip })
            let state = await f.ledger.workingState()
            #expect(!state.attentionList.contains { $0.node.id == "a" })
            try await f.expectWaiting("b", branch: "agentos/GH-102", files: ["Shared/b.swift"])
            #expect(await f.tracker.pendingSignals().isEmpty)
            #expect(!(await f.ledger.allRecords()).contains {
                if case .signalAccepted = $0.event.kind { return true }
                return false
            })
            await restarted.shutdown(reason: "GH-89 restart scenario finished")
        }
    }

    @Test
    func conflictCommentNamesTheRequirementWhoseConflictingWorkIsInMainButNotUnmergedWork() async throws {
        try await Self.withFixture { f in
            let file = "Shared/Rules.swift"
            try await f.requirement("source", ticket: "GH-201")
            try await f.leaf("source-leaf", parent: "source", ticket: "GH-211", phase: .proven, paths: [file])
            try await f.requirement("unmerged", ticket: "GH-202")
            try await f.leaf("unmerged-leaf", parent: "unmerged", phase: .proven, paths: [file])
            try await f.requirement("target", ticket: "GH-203")
            try await f.leaf("target-leaf", parent: "target")
            let source = try #require(await f.workspace.tip(of: "agentos/GH-201"))
            await f.workspace.advanceMain(to: "merged-source", files: [], including: [source])
            await f.workspace.conflict("agentos/GH-203", with: "merged-source", files: [file])
            try await f.baseline("merged-source")

            try await f.settle()

            let comments = try #require(await f.tracker.ticket("GH-203")).comments.map(\.text)
            #expect(comments.contains { $0.contains(file) && $0.contains("GH-201") },
                    "Name the top-level source requirement, not just its child or the target requirement")
            #expect(!comments.contains { $0.contains(file) && $0.contains("GH-202") },
                    "Changing the same file on an unmerged requirement does not make it the cause")
        }
    }

    @Test(arguments: [Phase.building, .checking, .landing])
    func overlapsAcrossRequirementsStopHoldingAsSoonAsTheFirstLeafLandsEvenBeforeMainContainsIt(_ phase: Phase) async throws {
        try await Self.withFixture { f in
            let gate = Gate()
            try await f.requirement("a", ticket: "GH-101")
            if phase == .building {
                try await f.leaf("a-running", parent: "a", paths: ["Shared"], build: true)
                await f.agents.hold("a-running", at: gate)
            } else {
                try await f.leaf("a-running", parent: "a", phase: phase, paths: ["Shared"])
                await f.checks.hold("a-running", ownSuite: phase == .checking, at: gate)
            }
            try await f.requirement("b", ticket: "GH-102")
            try await f.baseline("base")
            let runningRound = Task { try await f.round(waitForAgents: false) }
            do {
                try await gate.entered.wait(for: "GH-89 building, checking or landing entry")
                #expect(await f.ledger.workingState().nodes["a-running"]?.phase == phase)
                try await f.leaf("b-ready", parent: "b", paths: ["Shared/Rules.swift"], build: true)
                try await f.round(waitForAgents: false)
                #expect(!(await f.agents.starts).contains("b-ready"))
                #expect(await f.ledger.workingState().nodes["b-ready"]?.overlapHold?.waitingFor == "a-running")
                gate.release()
                _ = try await runningRound.value
            } catch {
                gate.release()
                _ = try? await runningRound.value
                throw error
            }
            try await f.settle()

            let state = await f.ledger.workingState()
            let first = try #require(state.nodes["a-running"])
            let landed = try #require(first.landedCommit)
            #expect(first.phase == .proven)
            #expect(first.evidence.contains { $0.passed })
            #expect((await f.agents.starts).contains("b-ready"))
            #expect(state.nodes["b-ready"]?.overlapHold == nil)
            #expect(!(await f.workspace.isAncestor(landed, of: "base")))
            let requirement = try #require(state.nodes["a"])
            #expect(state.status(of: requirement) != "Done")
        }
    }

    @Test(arguments: [false, true])
    func landingAllLeavesIsInReviewAndDoesNotUnblockAnotherRequirementUntilItsTipIsInMain(singleLeaf: Bool) async throws {
        try await Self.withFixture { f in
            if singleLeaf {
                try await f.leaf("a", ticket: "GH-101", phase: .proven)
            } else {
                try await f.requirement("a", ticket: "GH-101")
                try await f.leaf("a-landed", parent: "a", phase: .proven)
            }
            try await f.requirement("b", ticket: "GH-102", dependsOn: ["GH-101"])
            try await f.leaf("b-ready", parent: "b", build: true)
            try await f.baseline("base")

            try await f.settle()

            let before = await f.ledger.workingState()
            #expect(before.status(of: try #require(before.nodes["a"])) == "In review")
            #expect(await f.tracker.ticket("GH-101")?.status == "In review")
            #expect(!(await f.agents.starts).contains("b-ready"))
            let tip = try #require(await f.workspace.tip(of: "agentos/GH-101"))
            #expect(!(await f.workspace.isAncestor(tip, of: "base")))
            await f.workspace.advanceMain(to: "person-merged-a", files: [], including: [tip])
            try await f.baseline("person-merged-a")

            try await f.settle()

            let after = await f.ledger.workingState()
            #expect(after.status(of: try #require(after.nodes["a"])) == "Done")
            #expect(await f.tracker.ticket("GH-101")?.status == "Done")
            #expect((await f.agents.starts).contains("b-ready"))
            let records = await f.ledger.allRecords()
            let started = try #require(records.first {
                if case .runStarted(_, .implementer) = $0.event.kind { return $0.event.node == "b-ready" }
                return false
            })
            let prefix = try Ledger()
            try await prefix.append(records.filter { $0.position < started.position }.map(\.event))
            let whenStarted = await prefix.workingState()
            #expect(whenStarted.status(of: try #require(whenStarted.nodes["a"])) == "Done",
                    "The dependency must already be Done when the dependent claims its implementer")
        }
    }

    @Test
    func containingTheRequirementTipInMainIsNotEnoughWhileALeafIsUnproven() async throws {
        try await Self.withFixture { f in
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("a-landed", parent: "a", phase: .proven)
            try await f.leaf("a-unfinished", parent: "a")
            try await f.requirement("b", ticket: "GH-102", dependsOn: ["GH-101"])
            try await f.leaf("b-ready", parent: "b", build: true)
            let tip = try #require(await f.workspace.tip(of: "agentos/GH-101"))
            await f.workspace.advanceMain(to: "partial-merge", files: [], including: [tip])
            try await f.baseline("partial-merge")

            try await f.settle()

            let state = await f.ledger.workingState()
            #expect(state.status(of: try #require(state.nodes["a"])) != "Done")
            #expect(!(await f.agents.starts).contains("b-ready"))
        }
    }

    @Test
    func existingRoundsWithoutRequirementBranchesStillStartAndLandLeaves() async throws {
        try await Self.withFixture { f in
            let gate = Gate()
            defer { gate.release() }
            try await f.requirement("a", ticket: "GH-101")
            try await f.leaf("ready-control", parent: "a", build: true)
            try await f.leaf("queued-control", parent: "a", phase: .landing)
            await f.agents.hold("ready-control", at: gate)
            let existing = Reconciler(
                ledger: f.ledger, tracker: f.tracker, external: External(), workspace: f.workspace,
                artifacts: Artifacts(), checks: f.checks, team: f.agents.team, policy: Policy(maxParallelAgents: 4))
            let report = await existing.runRound(waitForAgents: false)
            try await gate.entered.wait(for: "GH-89 existing implementer control")
            #expect(await f.ledger.workingState().nodes["ready-control"]?.phase == .building)
            gate.release()
            await existing.waitForAgents()
            #expect(report.safeStop == nil)
            #expect((await f.agents.starts).contains("ready-control"))
            let state = await f.ledger.workingState()
            #expect(state.nodes["queued-control"]?.phase == .proven)
            #expect(state.nodes["queued-control"]?.evidence.contains { $0.passed } == true)
            #expect(await f.checks.observations.contains { $0.leaf == "queued-control" && $0.selection == nil })
            await existing.shutdown(reason: "Existing-round fixture control finished")
        }
    }
}
