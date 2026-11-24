// API contract: HarnessViewModel owns selectedNodeID and workStageFilterID, exposes node-specific
// ProcessNodeSummary values (opaque catalog stage IDs, status/wait reason, interruption and counters),
// highlightedProcessStageID, matchingWorkNodeIDs and visibleWorkNodeIDs, and clearWorkStageFilter().
// ProcessPane and WorkPane consume this shared state; selecting/filtering is read-only.
// Counter values are displayed as "current / limit"; WorkPane offers a "Clear stage filter" button.
// Criterion 6's real-repo-mode.md documentation is source-only and is checked in the implementation diff.

import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite(.serialized) @MainActor struct GH_139Tests {
    @Test
    func existingControlsValidateTheRenderingAndActionHelpers() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        let text = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        try #require(RenderedUI.shows("Work tree", in: text))
        try #require(RenderedUI.shows("Weather requirement", in: text))
        try Self.verifyButtonBridge()
    }

    @Test
    func selectionProjectsTheSelectedNodeWithItsOwnReviewPolicyAndCurrentStage() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        var policy = try #require(model.policy)
        policy.policy.review.level = .none
        policy.policy.review.areas = ["SensitiveUI": .agentAndHuman]
        model.policy = policy
        try await ledger.append([
            Self.event(.actualChangedFilesRecorded(files: ["SensitiveUI/Editor.swift"]), node: Self.checking),
        ])
        await Self.refresh(model, from: ledger)

        model.selectedNodeID = Self.building
        let first = try #require(model.selectedNodeProcess, "Selecting a Work node must project it for Process")
        #expect(first.nodeID == Self.building)
        #expect(first.reviewLevel == .none)
        #expect(model.highlightedProcessStageID == first.stageID)
        #expect(first.status == model.state.status(of: try #require(model.state.nodes[Self.building])))

        model.selectedNodeID = Self.checking
        let second = try #require(model.selectedNodeProcess)
        #expect(second.nodeID == Self.checking)
        #expect(second.reviewLevel == .agentAndHuman, "Changed files participate in the selected node's policy")
        #expect(second.stageID != first.stageID)
        #expect(model.highlightedProcessStageID == second.stageID)

        try await ledger.append([
            Self.event(.phaseChanged(to: .landing), node: Self.checking),
        ])
        await Self.refresh(model, from: ledger)
        let advanced = try #require(model.selectedNodeProcess)
        #expect(advanced.nodeID == Self.checking)
        #expect(advanced.stageID != second.stageID, "The selected diagram must follow new ledger snapshots")
        #expect(model.highlightedProcessStageID == advanced.stageID)

        model.selectedNodeID = nil
        #expect(model.selectedNodeProcess == nil)
        #expect(model.highlightedProcessStageID == nil)
    }

    @Test(arguments: [Flag.blocked, .needsInput, .escalated])
    func aWaitingSelectionUsesTheHarnessStatusAndExplainsWhatToDo(flag: Flag) async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(.acceptanceTests))
        let reason = "The acceptance criteria need clarification; comment with guidance, then add harness:retry."
        try await ledger.append([Self.event(.flagSet(flag, reason: reason))])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf

        let summary = try #require(model.selectedNodeProcess)
        let node = try #require(model.state.nodes[Self.leaf])
        #expect(summary.status == model.state.status(of: node))
        #expect(try #require(summary.waitReason).contains(reason))
        #expect(model.highlightedProcessStageID == summary.stageID)
    }

    @Test(arguments: [AgentRole.testAuthor, .implementer, .verifier])
    func anInterruptedRunKeepsItsOriginalStageUntilWorkResumes(role: AgentRole) async throws {
        let ledger = try Ledger()
        let phase: Phase = role == .testAuthor ? .specified : role == .implementer ? .building : .checking
        try await ledger.append(Self.reviewSetup(.acceptanceTests) + [
            Self.event(.phaseChanged(to: phase)),
            Self.event(.runStarted(run: "interrupted-run", role: role)),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        let running = try #require(model.selectedNodeProcess)
        #expect(!running.interrupted)

        var interruption = [Self.event(.runFinished(
            run: "interrupted-run", outcome: "abandoned: claim expired (harness restarted)"))]
        if role == .implementer {
            interruption.append(Self.event(.phaseChanged(to: .ready)))
        }
        try await ledger.append(interruption)
        await Self.refresh(model, from: ledger)
        let interrupted = try #require(model.selectedNodeProcess)
        #expect(interrupted.interrupted)
        #expect(interrupted.stageID == running.stageID, "Show where the interrupted run was, not its recovery phase")
        #expect(model.highlightedProcessStageID == running.stageID)

        try await ledger.append([
            Self.event(.phaseChanged(to: phase)),
            Self.event(.runStarted(run: "resumed-run", role: role)),
        ])
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).interrupted == false)
        try await ledger.append([Self.event(.runFinished(run: "resumed-run", outcome: "completed"))])
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).interrupted == false)
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func countersUseEffectiveLimitsAndOnlyAgentRunsSinceTheLastHumanAction(stage: ReviewStage) async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(stage)
            + Self.run("old-author", role: .testAuthor)
            + Self.run("old-implementer", role: .implementer)
            + [Self.event(.gateOpened(.build), by: .human("Pat"))]
            + Self.run("new-author", role: .testAuthor)
            + Self.run("new-implementer-one", role: .implementer)
            + Self.run("new-verifier", role: .verifier)
            + Self.run("new-diagnoser", role: .diagnoser)
            + Self.run("new-implementer-two", role: .implementer)
            + [
                Self.event(.attemptFailed(summary: "compiler failure")),
                Self.event(.attemptFailed(summary: "own check failed")),
                Self.event(.reworkNeeded(reason: "landing conflict one")),
                Self.event(.reworkNeeded(reason: "landing conflict two")),
                Self.event(.reworkNeeded(reason: "landing conflict three")),
                Self.review(stage, findings: ["Still open: fix the result"]),
                Self.review(Self.otherStage(stage), findings: ["Unrelated stage finding"]),
            ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        let counters = try #require(model.selectedNodeProcess).counters
        #expect(counters.failedAttempts == 2)
        #expect(counters.maxAttempts == 5)
        #expect(counters.landingReworks == 3)
        #expect(counters.maxReworks == 7)
        #expect(counters.agentRunsSinceHuman == 3, "Verifier and diagnoser runs do not consume this budget")
        #expect(counters.maxAgentRuns == 11)
        #expect(counters.reviewStage == stage)
        #expect(counters.failedReviews == 1, "Do not sum failures from the other review stage")
        #expect(counters.reviewMaxRounds == 3)
        #expect(counters.reviewRoundAllowance == 3)

        let text = try RenderedUI.text(of: ProcessPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows("2 / 5", in: text), "Show failed attempts against maxAttempts")
        #expect(RenderedUI.shows("3 / 7", in: text), "Show landing reworks against maxReworks")
        #expect(RenderedUI.shows("3 / 11", in: text), "Show budgeted agent runs against maxAgentRuns")
        #expect(RenderedUI.shows("1 / 3", in: text), "Show current-stage failed reviews against review.maxRounds")

        try await ledger.append([Self.event(.gateOpened(.breakdown), by: .human("Pat"))])
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).counters.agentRunsSinceHuman == 0)
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func aPassingReviewStartsANewFailedReviewBudgetForOnlyThatStage(stage: ReviewStage) async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(stage) + [
            Self.review(stage, findings: ["First problem"]),
            Self.review(stage, findings: ["Still open: first problem"]),
            Self.review(Self.otherStage(stage), passed: true),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 2)

        try await ledger.append([Self.review(stage, passed: true)])
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 0)

        try await ledger.append([
            Self.review(Self.otherStage(stage), findings: ["Other stage still has a problem"]),
            Self.review(stage, findings: ["A later problem after previously passing"]),
        ])
        await Self.refresh(model, from: ledger)
        let counters = try #require(model.selectedNodeProcess).counters
        #expect(counters.failedReviews == 1)
        #expect(counters.reviewRoundAllowance == counters.reviewMaxRounds)
        #expect(model.state.nodes[Self.leaf]?.reviews.count == 6, "Reset the counter, not the audit history")
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change], Recovery.allCases)
    func humanRecoveryStartsANewFailedReviewBudget(stage: ReviewStage, recovery: Recovery) async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(stage) + [
            Self.review(stage, findings: ["First problem"]),
            Self.review(stage, findings: ["Still open: first problem"]),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 2)

        try await ledger.append(Self.recoveryEvents(recovery))
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 0)

        try await ledger.append([
            Self.event(.phaseChanged(to: stage == .acceptanceTests ? .specified : .landing)),
            Self.review(stage, findings: ["A finding on the new work"]),
        ])
        await Self.refresh(model, from: ledger)
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 1)
    }

    @Test
    func automaticReworkAndHumanActionsOnOtherNodesDoNotResetTheReviewBudget() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(.acceptanceTests) + [
            Self.review(.acceptanceTests, findings: ["First finding"]),
            Self.event(.phaseChanged(to: .specified)),
            Self.review(.acceptanceTests, findings: ["Still open: first finding"]),
            Self.event(.attemptsReset, node: Self.root, by: .human("Pat")),
            Self.review(.acceptanceTests, node: Self.root, passed: true),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        #expect(try #require(model.selectedNodeProcess).counters.failedReviews == 2)
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change], [2, 3])
    func convergingReviewsShowAnAllowanceOfTwiceMaxRoundsWithoutAnUnboundedExtension(
        stage: ReviewStage, maxRounds: Int
    ) async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(stage))
        let model = await Self.model(ledger, maxRounds: maxRounds)
        model.selectedNodeID = Self.leaf
        for round in 1...(2 * maxRounds) {
            let findings = round == 1 ? ["First defect", "Second defect"] : ["New: defect \(round)"]
            try await ledger.append([Self.review(stage, findings: findings)])
            await Self.refresh(model, from: ledger)
            let counters = try #require(model.selectedNodeProcess).counters
            #expect(counters.failedReviews == round)
            #expect(counters.reviewMaxRounds == maxRounds)
            #expect(counters.reviewRoundAllowance == (round < maxRounds ? maxRounds : 2 * maxRounds))
            if round == maxRounds {
                let text = try RenderedUI.text(of: ProcessPane().environment(model), size: Self.paneSize)
                #expect(RenderedUI.shows("\(round) / \(2 * maxRounds)", in: text),
                        "A converging selected node must show the extended review allowance")
            }
        }
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func repeatedOrIncreasingFindingsDoNotEarnTheConvergingAllowance(stage: ReviewStage) async throws {
        for latest in [["Still open: original defect"], ["New: one", "New: two"]] {
            let ledger = try Ledger()
            try await ledger.append(Self.reviewSetup(stage) + [
                Self.review(stage, findings: ["Original defect"]),
                Self.review(stage, findings: latest),
            ])
            let model = await Self.model(ledger, maxRounds: 2)
            model.selectedNodeID = Self.leaf
            let counters = try #require(model.selectedNodeProcess).counters
            #expect(counters.failedReviews == 2)
            #expect(counters.reviewRoundAllowance == 2)
        }
    }

    @Test
    func filteringKeepsAllAncestorsButCountsOnlyNodesActuallyInTheStage() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        let stage = try #require(model.processSummary(for: Self.building)).stageID
        #expect(stage != (try #require(model.processSummary(for: Self.checking))).stageID)
        model.workStageFilterID = stage

        #expect(model.matchingWorkNodeIDs == [Self.building, Self.alsoBuilding])
        #expect(model.visibleWorkNodeIDs == [Self.root, Self.group, Self.building, Self.alsoBuilding])
        #expect(!model.matchingWorkNodeIDs.contains(Self.root), "A context ancestor must not inflate the stage count")
        #expect(!model.matchingWorkNodeIDs.contains(Self.group))

        model.clearWorkStageFilter()
        #expect(model.workStageFilterID == nil)
        #expect(model.visibleWorkNodeIDs == Set(model.state.nodes.keys))
    }

    @Test
    func aSelectedNodeHiddenByTheStageFilterStaysSelectedAndHighlightedInProcess() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.checking
        let selected = try #require(model.selectedNodeProcess)
        model.workStageFilterID = try #require(model.processSummary(for: Self.building)).stageID
        #expect(!model.visibleWorkNodeIDs.contains(Self.checking))
        #expect(model.selectedNodeID == Self.checking)
        #expect(model.selectedNodeProcess?.nodeID == Self.checking)
        #expect(model.highlightedProcessStageID == selected.stageID)
        model.clearWorkStageFilter()
        #expect(model.selectedNodeID == Self.checking)
        #expect(model.highlightedProcessStageID == selected.stageID)
    }

    @Test
    func selectingNodesAndStagesFilteringAndClearingNeverAddLedgerEvents() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        let actions = RecordingActions()
        model.actions = actions
        let before = await ledger.allRecords()
        let position = model.state.asOf
        model.selectedNodeID = Self.checking
        model.workStageFilterID = try #require(model.processSummary(for: Self.building)).stageID
        #expect(model.matchingWorkNodeIDs == [Self.building, Self.alsoBuilding])
        #expect(model.selectedNodeID == Self.checking)
        _ = model.selectedNodeProcess
        _ = model.visibleWorkNodeIDs
        _ = try RenderedUI.text(of: ProcessPane().environment(model), size: Self.paneSize)
        _ = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        model.clearWorkStageFilter()
        #expect(model.workStageFilterID == nil)
        model.selectedNodeID = Self.building
        model.selectedNodeID = nil

        let after = await ledger.allRecords()
        #expect(after.map(\.hash) == before.map(\.hash))
        #expect(model.records.map(\.hash) == before.map(\.hash))
        #expect(model.state.asOf == position)
        #expect(actions.requests.isEmpty, "Selection must not send tracker or harness commands")
        let reopened = await Self.model(ledger)
        #expect(reopened.selectedNodeID == nil)
        #expect(reopened.workStageFilterID == nil)
    }

    @Test
    func renderedWorkPaneUsesTheSameSelectionAsProcess() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.checking
        let checking = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows(Self.checking, in: checking), "The shared selection must open that node's details")
        #expect(!RenderedUI.shows("No node selected", in: checking))

        model.selectedNodeID = Self.building
        let building = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows(Self.building, in: building))
        #expect(!RenderedUI.shows(Self.checking, in: building))
    }

    @Test
    func renderedWorkPaneShowsMatchingChildrenWithContextAndAnActionableClearControl() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        let baseline = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        try #require(RenderedUI.shows("Work tree", in: baseline), "Validate the shared renderer against the existing pane")
        try #require(RenderedUI.shows("Weather requirement", in: baseline))
        try #require(RenderedUI.shows("Other work", in: baseline))
        model.workStageFilterID = try #require(model.processSummary(for: Self.building)).stageID
        let host = Self.interactiveHost(WorkPane().environment(model))
        let filtered = try RenderedUI.text(in: RenderedUI.image(of: host)).joined(separator: "\n")
        #expect(RenderedUI.shows("Weather requirement", in: filtered))
        #expect(RenderedUI.shows("Forecast group", in: filtered))
        #expect(RenderedUI.shows("First build", in: filtered))
        #expect(RenderedUI.shows("Second build", in: filtered))
        #expect(!RenderedUI.shows("Checking sibling", in: filtered))
        #expect(!RenderedUI.shows("Other work", in: filtered))
        #expect(RenderedUI.shows("Clear stage filter", in: filtered))
        #expect(model.matchingWorkNodeIDs.count == 2)

        try Self.pressClearFilter(in: host)
        #expect(model.workStageFilterID == nil)
        let cleared = try RenderedUI.text(of: WorkPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows("Other work", in: cleared))
    }

    @Test
    func aLongTitleTruncatesWithoutHidingTheTicketKeyOrWrappingTheStatus() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.treeEvents())
        let model = await Self.model(ledger)
        let short = try #require(model.state.nodes[Self.building])
        var long = short
        long.spec.title = "Feature layout: carry a leaf's tests forward without overwriting other work, and document "
            + String(repeating: "both layouts in detail ", count: 6)
        func height(_ node: NodeState, width: CGFloat) -> CGFloat {
            NSHostingView(rootView: NodeRow(node: node, status: "Ready").frame(width: width)).fittingSize.height
        }
        for width: CGFloat in [480, 200] {
            #expect(height(long, width: width) == height(short, width: width), "The status must stay on one line")
        }

        let text = try RenderedUI.text(of: NodeRow(node: long, status: "Ready"), size: CGSize(width: 480, height: 40))
        #expect(RenderedUI.shows(long.displayName, in: text), "\(text)")
        #expect(RenderedUI.shows("Ready", in: text), "\(text)")
        #expect(RenderedUI.shows("Feature layout", in: text), "\(text)")
        // A deeply indented row: the status still gets its width before the title.
        let narrow = try RenderedUI.text(of: NodeRow(node: long, status: "Ready"), size: CGSize(width: 200, height: 40))
        #expect(RenderedUI.shows("Ready", in: narrow), "\(narrow)")
    }

    @Test
    func renderedProcessShowsTheHiddenSelectedNodesStageStatusAndWaitReason() async throws {
        let ledger = try Ledger()
        let reason = "Confirm the forecast units, then add harness:retry."
        try await ledger.append(Self.treeEvents() + [
            Self.event(.flagSet(.needsInput, reason: reason), node: Self.checking),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.checking
        let summary = try #require(model.selectedNodeProcess)
        model.workStageFilterID = try #require(model.processSummary(for: Self.building)).stageID
        #expect(!model.visibleWorkNodeIDs.contains(Self.checking))
        let text = try RenderedUI.text(of: ProcessPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows("Checking sibling", in: text))
        #expect(RenderedUI.shows(summary.stageTitle, in: text))
        #expect(RenderedUI.shows(model.state.status(of: try #require(model.state.nodes[Self.checking])), in: text))
        #expect(RenderedUI.shows(reason, in: text))
        #expect(model.highlightedProcessStageID == summary.stageID)
    }

    @Test
    func renderedProcessMarksAnInterruptedSelectedRun() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.reviewSetup(.acceptanceTests) + [
            Self.event(.runStarted(run: "author-interrupted", role: .testAuthor)),
            Self.event(.runFinished(run: "author-interrupted",
                                    outcome: "abandoned: claim expired (harness restarted)")),
        ])
        let model = await Self.model(ledger)
        model.selectedNodeID = Self.leaf
        let text = try RenderedUI.text(of: ProcessPane().environment(model), size: Self.paneSize)
        #expect(RenderedUI.shows("Review candidate", in: text))
        #expect(RenderedUI.shows("Interrupted", in: text))
    }
}
