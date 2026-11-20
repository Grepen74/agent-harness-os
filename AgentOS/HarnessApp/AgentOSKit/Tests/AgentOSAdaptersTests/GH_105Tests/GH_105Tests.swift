// API contract: Reconciler.drainLandingQueue(_:), the queue used by runRound(waitForAgents:),
// drains seeded .landing nodes using
// Workspace.createLandingBatch(for:validating:) -> LandingBatchWorkspace and Workspace.landBatch(_:).
// Existing landingBatchChecked records describe each full check; evidenceRecorded diagnosis reports
// retain rerun results, and runFinished records identify the outcome through the batch verifier run.
// LedgerPane displays those actual records. No new entry point or batch type is required.
// No acceptance criterion is source-only. Subsequent attribution and splitting are sibling work.

import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite struct GH_105Tests {
    @Test
    @MainActor
    func aPassingBatchValidatesTheQueueFixtureAndSharedLedgerRenderer() async throws {
        let fixture = try await Fixture(full: [Self.pass("batch-pass")])
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        #expect(await fixture.workspace.batchCreations == [Fixture.memberIDs])
        try await Self.expectEveryMemberLanded(fixture)
        let record = try #require(await fixture.ledger.allRecords().first {
            $0.event.kind.landingBatchCheck != nil
        })
        let check = try #require(record.event.kind.landingBatchCheck)
        let text = try await Self.ledgerText(record, state: fixture.ledger.workingState())
        #expect(RenderedUI.shows(check.name, in: text))
        #expect(RenderedUI.shows("passed", in: text))
        #expect(RenderedUI.shows(check.branch, in: text))
        #expect(RenderedUI.shows(String(check.candidateCommit.prefix(8)), in: text))
    }

    @Test
    func aBatchRunnerCrashIsRetriedOnceAndAPassingRetryLandsEveryMember() async throws {
        let fixture = try await Fixture(full: [Self.crash("initial-crash"), Self.pass("retry-pass")])
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        let calls = await fixture.checks.calls
        #expect(calls.count == 2, "Retry the batch, not each member separately")
        Self.expectUnchangedFullChecks(calls, count: 2, fixture: fixture)
        try await Self.expectEveryMemberLanded(fixture)
        for member in fixture.batch.members {
            #expect(!(await fixture.tracker.comments(on: member.node).contains {
                $0.contains("Runner crash repeated") || $0.contains("Unreliable test:")
            }), "A runner retry is not a failed test diagnosis")
        }
    }

    @Test
    func aSecondBatchRunnerCrashEscalatesEveryMemberWithoutCountingAnAttempt() async throws {
        let fixture = try await Fixture(full: [Self.crash("first-crash"), Self.crash("second-crash")])
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        Self.expectUnchangedFullChecks(await fixture.checks.calls, count: 2, fixture: fixture)
        try await Self.expectEveryMemberEscalated(
            fixture, classification: .runnerCrash, reason: "Runner crash repeated after one retry"
        )
        for member in fixture.batch.members {
            let comments = await fixture.tracker.comments(on: member.node).joined(separator: "\n")
            #expect(comments.contains("second-crash"))
            #expect(comments.contains("harness:retry"))
        }
    }

    @Test
    func anInitialCrashFollowedByAReportedFailureStillGetsTheQuietRerunAndIsolatedDiagnosis() async throws {
        let fixture = try await Fixture(
            full: [Self.crash("initial-crash"), Self.failure("retry-failure"), Self.failure("quiet-failure")],
            selectedCandidate: Self.failure("candidate-alone"),
            selectedBaseline: Self.failure("baseline-alone")
        )
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        let calls = await fixture.checks.calls
        try #require(calls.count >= 5, "Retry the crash, rerun the full failure quietly, then diagnose both tips")
        Self.expectUnchangedFullChecks(Array(calls.prefix(3)), count: 3, fixture: fixture)
        let isolated = calls.dropFirst(3)
        for directory in [fixture.workspace.candidate, fixture.workspace.snapshot] {
            let selections = isolated.filter { $0.directory == directory }
            #expect(selections.count == 1)
            #expect(selections.allSatisfy {
                $0.selection == "ExistingBehaviorTests"
                    && $0.commit == (directory == fixture.workspace.candidate
                                     ? fixture.batch.candidateCommit : Fixture.latestRequirement)
            })
        }
        try await Self.expectEveryMemberEscalated(
            fixture, classification: .landingInfrastructure, reason: "Landing infrastructure problem:"
        )
        let state = await fixture.ledger.workingState()
        for member in fixture.batch.members {
            let node = try #require(state.nodes[member.node])
            #expect(node.failedAttempts == fixture.priorAttempts[member.node])
            #expect(!(await fixture.tracker.comments(on: member.node).contains {
                $0.contains("Runner crash repeated")
            }))
        }
    }

    @Test(arguments: FailureOwner.allCases)
    func everyFullBatchFailureIsRerunUnchangedBeforeSplittingEvenForMembersOwnTests(
        _ owner: FailureOwner
    ) async throws {
        let targets = owner.targets
        let fixture = try await Fixture(full: [
            Self.failure("initial-failure", targets: targets), Self.pass("quiet-full-pass"),
        ])
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        Self.expectUnchangedFullChecks(await fixture.checks.calls, count: 2, fixture: fixture)
        #expect(await fixture.workspace.mutations == [.landBatch(Fixture.memberIDs)],
                "Do not rebuild, rebase, remove members, or split before the unchanged rerun")
        try await Self.expectEveryMemberLanded(fixture)
        for member in fixture.batch.members {
            #expect(await fixture.tracker.comments(on: member.node).contains {
                $0.contains(Self.unreliableNotice)
            })
        }
    }

    @Test(arguments: [BatchMove.waiting, .branchMoved])
    func aPassingQuietRerunStillHonorsTheWorkspaceLandingResult(_ move: BatchMove) async throws {
        let fixture = try await Fixture(
            full: [Self.failure("initial-failure"), Self.pass("quiet-full-pass")], move: move
        )
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        Self.expectUnchangedFullChecks(await fixture.checks.calls, count: 2, fixture: fixture)
        #expect(await fixture.workspace.batchCreations == [Fixture.memberIDs])
        #expect(await fixture.workspace.mutations == [.landBatch(Fixture.memberIDs)])
        let state = await fixture.ledger.workingState()
        for member in fixture.batch.members {
            let node = try #require(state.nodes[member.node])
            #expect(node.phase == .landing)
            #expect(node.activeRun == nil)
            #expect(node.landedCommit == nil)
            #expect(node.failedAttempts == fixture.priorAttempts[member.node])
            #expect(node.flags[.escalated] == nil)
            #expect(!(await fixture.tracker.comments(on: member.node).contains { $0.contains("🛬 Landed") }))
            if move == .waiting {
                #expect(await fixture.tracker.comments(on: member.node).contains {
                    $0.contains("Waiting to land") && $0.contains("checked out")
                })
            }
        }
    }

    @Test(arguments: HoldPoint.allCases)
    func diagnosisDrainsExistingAgentsAndPreviewsAndBlocksNewOnesUntilItsOutcome(
        _ hold: HoldPoint
    ) async throws {
        let fixture = try await Fixture(
            full: [Self.failure("initial"), Self.failure("rerun")],
            selectedCandidate: Self.failure("candidate-alone"),
            selectedBaseline: Self.failure("baseline-alone"),
            hold: hold, seedBatch: false
        )
        defer { fixture.cleanUp() }
        try await fixture.drainingAgents {
            try await fixture.addAgentNode("existing-step")
            await fixture.tracker.requestPreview("existing-preview")
            _ = await fixture.reconciler.runRound(waitForAgents: false)
            try await fixture.agents.stepStarted.wait(for: "the existing agent step")
            try await fixture.agents.previewStarted.wait(for: "the existing preview")
            try await fixture.seedBatch()

            let operation = Task { try await fixture.checkAndLand() }
            defer { operation.cancel() }
            try await eventually("diagnosis starting after the first full batch failure") {
                await fixture.reconciler.quietLandings > 0 || fixture.checks.finished.isOpen
            }
            try #require(await fixture.reconciler.quietLandings > 0,
                         "The failed batch must enter a quiet diagnosis, not singleton landings")
            #expect(await fixture.checks.calls.count == 1,
                    "The full rerun must wait for the already-running step AND preview")

            try await fixture.addAgentNode("waiting-step")
            await fixture.tracker.requestPreview("waiting-preview")
            _ = await fixture.reconciler.runRound(waitForAgents: false)
            #expect(await fixture.agents.started == ["existing-step", "existing-preview"])
            #expect(await fixture.checks.calls.count == 1)

            fixture.agents.release.open()
            try await eventually("the held diagnostic check") {
                fixture.checks.held.isOpen || fixture.checks.finished.isOpen
            }
            try #require(fixture.checks.held.isOpen, "Diagnosis must reach the requested rerun")
            #expect(await fixture.agents.active == 0, "Reruns run without another agent or preview")
            _ = await fixture.reconciler.runRound(waitForAgents: false)
            #expect(await fixture.agents.started == ["existing-step", "existing-preview"],
                    "A free slot must not start a step or preview while diagnosis is in progress")

            fixture.checks.release.open()
            try await withHangGuard("the batch diagnosis") { try await operation.value }
            #expect(await fixture.checks.calls.dropFirst().allSatisfy { $0.activeAgents == 0 },
                    "Every diagnostic check starts only after both agent steps and previews have finished")
            try await Self.expectEveryMemberEscalated(
                fixture, classification: .landingInfrastructure, reason: "Landing infrastructure problem:"
            )
            _ = await fixture.reconciler.runRound(waitForAgents: false)
            try await withHangGuard("work resuming after diagnosis") {
                await fixture.reconciler.waitForAgents()
            }
            #expect(await fixture.agents.started.isSuperset(of: ["waiting-step", "waiting-preview"]),
                    "The quiet interval ends with the diagnosis; pending work is not lost")
        }
    }

    @Test
    func twoFullFailuresRunTheUnionOfFailingSuitesAloneOnBatchTipAndLatestRequirement() async throws {
        let own = "GH_105_ATests"
        let other = "ExistingBehaviorTests"
        let fixture = try await Fixture(
            full: [Self.failure("first-full", targets: [own]), Self.failure("second-full", targets: [other])],
            selectedCandidate: Self.failure("batch-alone", targets: [own, other]),
            selectedBaseline: Self.failure("requirement-alone", targets: [own, other])
        )
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        let calls = await fixture.checks.calls
        try #require(calls.count >= 6, "Run both failing suites with and without the whole batch")
        Self.expectUnchangedFullChecks(Array(calls.prefix(2)), count: 2, fixture: fixture)
        let isolated = calls.dropFirst(2)
        #expect(isolated.allSatisfy { $0.selection != nil })
        for directory in [fixture.workspace.candidate, fixture.workspace.snapshot] {
            #expect(Set(isolated.filter { $0.directory == directory }.compactMap(\.selection)) == [own, other])
        }
        for call in isolated {
            #expect(call.commit == (call.directory == fixture.workspace.candidate
                                   ? fixture.batch.candidateCommit : Fixture.latestRequirement))
            #expect(call.members == (call.directory == fixture.workspace.candidate ? Fixture.memberIDs : []))
        }
        #expect(await fixture.workspace.snapshots.allSatisfy { Fixture.memberIDs.contains($0.requirement) })
        #expect(!(await fixture.workspace.snapshots.isEmpty))
        #expect(await fixture.workspace.prepared.contains(fixture.workspace.snapshot))
        #expect(await fixture.workspace.removedSnapshots.contains(fixture.workspace.snapshot))
        try await Self.expectEveryMemberEscalated(
            fixture, classification: .landingInfrastructure, reason: "Landing infrastructure problem:"
        )
    }

    @Test
    func twoFullFailuresWithoutSuiteNamesEscalateAsLandingInfrastructureWithoutSplitting() async throws {
        let fixture = try await Fixture(full: ["initial-unknown", "quiet-unknown"].map {
            CheckOutput(passed: false, summary: $0, log: "\($0): check failed without naming any tests")
        })
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        let calls = await fixture.checks.calls
        Self.expectUnchangedFullChecks(Array(calls.prefix(2)), count: 2, fixture: fixture)
        try await Self.expectEveryMemberEscalated(
            fixture, classification: .landingInfrastructure, reason: "Landing infrastructure problem:"
        )
    }

    @Test(arguments: InfrastructureProblem.allCases)
    func landingInfrastructureEscalatesTheEntireBatchWithoutSplittingOrCountingAttempts(
        _ problem: InfrastructureProblem
    ) async throws {
        let fixture = try await Fixture(
            full: problem.full,
            selectedCandidate: problem.candidate,
            selectedBaseline: problem.baseline
        )
        defer { fixture.cleanUp() }

        try await fixture.checkAndLand()

        try await Self.expectEveryMemberEscalated(
            fixture, classification: .landingInfrastructure, reason: "Landing infrastructure problem:"
        )
        let batchName = try await fixture.batchName()
        for member in fixture.batch.members {
            let comments = await fixture.tracker.comments(on: member.node).joined(separator: "\n")
            #expect(comments.contains("No failed attempt counted."))
            #expect(comments.contains(batchName), "Name the affected batch on every ticket")
            #expect(comments.localizedCaseInsensitiveContains(problem.explanation))
            #expect(comments.contains("harness:retry"))
        }
        let calls = await fixture.checks.calls
        #expect(calls.allSatisfy {
            $0.directory == fixture.workspace.candidate || $0.directory == fixture.workspace.snapshot
        })
        switch problem {
        case .rerunCrash:
            Self.expectUnchangedFullChecks(
                calls.filter { $0.directory == fixture.workspace.candidate && $0.selection == nil },
                count: 3, fixture: fixture
            )
        case .candidateCrash, .baselineCrash:
            let directory = problem == .candidateCrash ? fixture.workspace.candidate : fixture.workspace.snapshot
            let retried = calls.filter { $0.directory == directory && $0.selection != nil }
            #expect(retried.count == 2, "Retry the crashing selection once before escalating the batch")
            #expect(retried.allSatisfy {
                $0.selection == "ExistingBehaviorTests"
                    && $0.commit == (problem == .candidateCrash
                                     ? fixture.batch.candidateCommit : Fixture.latestRequirement)
                    && $0.members == (problem == .candidateCrash ? Fixture.memberIDs : [])
            }, "Retry the same suite on the same candidate or baseline")
        default:
            break
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func everyDiagnosisRerunResultAndOutcomeSurvivesLedgerReopeningAndAppearsInLedgerPane(
        _ baselineFails: Bool
    ) async throws {
        let markers = baselineFails
            ? ["initial-red", "full-red", "batch-red", "base-red"]
            : ["initial-red", "full-green"]
        let fixture = try await Fixture(
            full: [Self.failure(markers[0]), baselineFails ? Self.failure(markers[1]) : Self.pass(markers[1])],
            selectedCandidate: Self.failure("batch-red"), selectedBaseline: Self.failure("base-red")
        )
        defer { fixture.cleanUp() }
        let seedPosition = await fixture.ledger.allRecords().last?.position ?? -1

        try await fixture.checkAndLand()
        let reopened = try Ledger(store: fixture.store)
        #expect(await reopened.verifyChain().isIntact)
        let records = await reopened.records(after: seedPosition, limit: 200)
        let fullChecks = records.filter { $0.event.kind.landingBatchCheck != nil }
        try #require(fullChecks.count == 2, "Record the initial full batch check AND the unchanged full rerun")
        let initial = try #require(fullChecks.first?.event.kind.landingBatchCheck)
        #expect(fullChecks.compactMap(\.event.kind.landingBatchCheck?.passed) == [false, !baselineFails])
        let state = await reopened.workingState()
        for record in fullChecks {
            let check = try #require(record.event.kind.landingBatchCheck)
            #expect(check.name == initial.name && check.run == initial.run)
            #expect(check.nodes == Fixture.memberIDs)
            #expect(check.branch == fixture.batch.branch)
            #expect(check.candidateCommit == fixture.batch.candidateCommit)
            let visible = try await Self.ledgerText(record, state: state)
            #expect(RenderedUI.shows(check.name, in: visible))
            #expect(RenderedUI.shows(check.passed ? "passed" : "failed", in: visible))
        }
        for member in fixture.batch.members {
            let report = try #require(records.last {
                guard $0.event.node == member.node, case .evidenceRecorded(let evidence) = $0.event.kind else {
                    return false
                }
                return evidence.checkedBy == initial.run && evidence.commit == fixture.batch.candidateCommit
                    && markers.allSatisfy(evidence.summary.contains)
            }, "Persist each diagnosis result in evidence tied to the actual batch verifier and tip")
            guard case .evidenceRecorded(let evidence) = report.event.kind else { return }
            #expect(evidence.check.contains(initial.name))
            let log = try #require(fixture.artifacts.contents(at: evidence.artifactPath))
            for marker in markers {
                #expect(String(decoding: log, as: UTF8.self).contains(marker))
            }
            if member.node == Fixture.memberIDs[0] {
                let visible = try await Self.ledgerText(report, state: state)
                for marker in markers {
                    #expect(RenderedUI.shows(marker, in: visible), "Show diagnosis results, not just its batch name")
                }
                #expect(RenderedUI.shows(initial.name, in: visible))
            }
            let outcomeText = baselineFails ? "landing infrastructure problem" : "landed"
            let outcome = try #require(records.last {
                guard $0.event.node == member.node, case .runFinished(let run, let outcome) = $0.event.kind else {
                    return false
                }
                return run == initial.run && outcome.localizedCaseInsensitiveContains(outcomeText)
            }, "Persist the diagnosis outcome under the same verifier run as its batch check")
            if member.node == Fixture.memberIDs[0] {
                let visible = try await Self.ledgerText(outcome, state: state)
                #expect(RenderedUI.shows(initial.run, in: visible))
                #expect(RenderedUI.shows(outcomeText, in: visible))
            }
        }
    }

}

private extension GH_105Tests {
    static let unreliableNotice = "Unreliable test: the landing check failed, then passed when run again in full with no other work running."

    static func expectUnchangedFullChecks(_ calls: [CheckCall], count: Int, fixture: Fixture) {
        #expect(calls.count == count)
        for call in calls {
            #expect(call.selection == nil, "Run the full check before considering any selection or split")
            #expect(call.directory == fixture.batch.directory)
            #expect(call.commit == fixture.batch.candidateCommit)
            #expect(call.members == Fixture.memberIDs, "Keep every member in the unchanged rerun")
        }
    }

    static func expectEveryMemberLanded(_ fixture: Fixture) async throws {
        let state = await fixture.ledger.workingState()
        let batchName = try await fixture.batchName()
        #expect(await fixture.workspace.mutations == [.landBatch(Fixture.memberIDs)])
        #expect(await fixture.workspace.batchCreations == [Fixture.memberIDs])
        for member in fixture.batch.members {
            let node = try #require(state.nodes[member.node])
            #expect(node.phase == .proven)
            #expect(node.landedCommit == member.commit, "Record the member's own commit, not the batch tip for all")
            #expect(node.failedAttempts == fixture.priorAttempts[member.node])
            #expect(node.flags[.escalated] == nil)
            #expect(node.activeRun == nil)
            #expect(node.evidence.contains {
                $0.passed && $0.commit == fixture.batch.candidateCommit && $0.check.contains(batchName)
            },
                    "Every member points to the common batch check")
            #expect(await fixture.tracker.comments(on: member.node).contains {
                $0.contains("Landed") && $0.contains(batchName)
            })
        }
    }

    static func expectEveryMemberEscalated(
        _ fixture: Fixture, classification: FailureClassification, reason: String
    ) async throws {
        #expect(await fixture.workspace.mutations.isEmpty, "An infrastructure escalation neither splits nor lands")
        #expect(await fixture.workspace.batchCreations == [Fixture.memberIDs], "Do not split or remove any members")
        let state = await fixture.ledger.workingState()
        for member in fixture.batch.members {
            let node = try #require(state.nodes[member.node])
            #expect(node.flags[.escalated]?.contains(reason) == true)
            #expect(node.phase == .landing)
            #expect(node.failedAttempts == fixture.priorAttempts[member.node])
            #expect(node.landedCommit == nil)
            #expect(node.activeRun == nil)
            let evidence = try #require(node.evidence.last { $0.failureClassification == classification })
            #expect(!evidence.passed)
            #expect(evidence.commit == fixture.batch.candidateCommit)
            #expect(!evidence.artifactPath.isEmpty)
            #expect(fixture.artifacts.contents(at: evidence.artifactPath) != nil)
            #expect(await fixture.tracker.comments(on: member.node).contains { $0.contains(reason) })
        }
    }

    @MainActor
    static func ledgerText(_ record: RecordedEvent, state: WorkingState) async throws -> String {
        let page = try Ledger()
        try await page.append([record.event])
        let model = HarnessViewModel()
        model.state = state
        await model.refreshLedger(from: page)
        return try RenderedUI.text(
            of: LedgerPane().environment(model), size: CGSize(width: 1800, height: 1000)
        )
    }
}
