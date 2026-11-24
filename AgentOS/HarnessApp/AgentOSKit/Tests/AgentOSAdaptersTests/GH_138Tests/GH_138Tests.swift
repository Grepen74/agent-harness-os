// API contract: ProcessPane reads HarnessViewModel's effective policy, working state,
// processDiagram and processSelection; selection changes only UI state. The diagram exposes
// identifiable stages (title, nodeIDs, waitsOnPerson, waitingNodeIDs) and guarded transitions
// (from/to stage IDs, reason, condition). RepositoryInspectorPane binds its selected tab.
// The App's use of that shared inspector (criterion 1 integration) and real-repo-mode.md's
// catalog attribution (criterion 6, documentation only) require diff review, not source tests.

import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import Foundation
import SwiftUI
import Testing

@Suite @MainActor
struct GH_138Tests {
    @Test
    func sharedRendererReadsAnExistingPane() throws {
        let model = HarnessViewModel()
        let text = try Self.text(LedgerPane().environment(model))
        Self.expectShown(["Ledger", "0 records", "Verify chain"], in: text)
    }

    @Test
    func repositoryInspectorOffersProcessAlongsideReadinessPolicyAndLedger() throws {
        let model = Self.model()
        let text = try Self.text(RepositoryInspectorPane(selection: .constant(.process)).environment(model))

        Self.expectShown(["Readiness", "Policy", "Ledger", "Process", "Requirement", "Leaf",
                          "Review the acceptance tests", "Review the code change"], in: text)
    }

    @Test
    func defaultProcessDrawsBothWorkflowsIncludingBothAgentReviews() throws {
        let model = Self.model()
        let diagram = model.processDiagram
        let review = try Self.stage("Review the acceptance tests", in: model)
        let change = try Self.stage("Review the code change", in: model)
        #expect(review.id != change.id)
        #expect(!review.waitsOnPerson)
        #expect(!change.waitsOnPerson)
        #expect(!diagram.transitions.isEmpty)
        for transition in diagram.transitions {
            #expect(diagram.stages.contains { $0.id == transition.from })
            #expect(diagram.stages.contains { $0.id == transition.to })
        }

        let text = try Self.text(ProcessPane().environment(model))
        Self.expectShown(["Process", "Requirement", "Leaf", "Allow breakdown", "Write acceptance tests",
                          "Review the acceptance tests", "Allow build", "Write the code", "Review the code change"], in: text)
    }

    @Test
    func processUsesTheResolvedRepoPolicyRatherThanTheHarnessDefaults() throws {
        var harness = HarnessSettings()
        harness.pullRequests = true
        let repo = try RepoConfig.parse("""
            { "test": { "command": "swift test" }, "pullRequests": false,
              "review": { "level": "agent+human" } }
            """).config
        let model = Self.model(harness: harness, repo: repo)
        let approval = try Self.stage("Approve landing", in: model)
        #expect(approval.waitsOnPerson)
        Self.expectShown(["Requirement", "Leaf", "Review the acceptance tests", "Review the code change",
                          "Approve landing", "Final check of the requirement branch"],
                         in: try Self.text(ProcessPane().environment(model)))
        #expect(!model.processDiagram.stages.contains { Self.sameTitle($0.title, "Push the requirement branch") })
        #expect(!model.processDiagram.stages.contains { Self.sameTitle($0.title, "Open or update the pull request") })

        harness.review.level = .none
        model.policy = EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
        #expect(!model.processDiagram.stages.contains { Self.sameTitle($0.title, "Review the acceptance tests") })
        #expect(!model.processDiagram.stages.contains { Self.sameTitle($0.title, "Review the code change") })
        #expect(!model.processDiagram.stages.contains { Self.sameTitle($0.title, "Approve landing") })
        let withoutReviews = try Self.text(ProcessPane().environment(model))
        Self.expectShown(["Requirement", "Leaf", "Final check of the requirement branch"], in: withoutReviews)
        #expect(!RenderedUI.shows("Review the acceptance tests", in: withoutReviews))
        #expect(!RenderedUI.shows("Review the code change", in: withoutReviews))
        #expect(!RenderedUI.shows("Approve landing", in: withoutReviews))
    }

    @Test
    func selectingStagesShowsTheirActorsAndCurrentLoopLimitsAndShapingSettings() throws {
        let repo = try RepoConfig.parse("""
            { "test": { "command": "swift test" },
              "limits": { "maxAttempts": 2, "maxAgentRuns": 6 },
              "review": { "maxRounds": 7 } }
            """).config
        let model = Self.model(repo: repo)
        #expect(model.policy?.problems.isEmpty == true)

        let tests = try Self.stage("Write acceptance tests", in: model)
        model.processSelection = .stage(tests.id)
        Self.expectShown(["test author", "maxAgentRuns", "6"],
                         in: try Self.text(ProcessPane().environment(model)))

        let review = try Self.stage("Review the acceptance tests", in: model)
        model.processSelection = .stage(review.id)
        Self.expectShown(["Reviewer", "review.maxRounds", "7", "review.level", "agent"],
                         in: try Self.text(ProcessPane().environment(model)))

        let implementation = try Self.stage("Write the code", in: model)
        model.processSelection = .stage(implementation.id)
        Self.expectShown(["implementer", "maxAttempts", "2"],
                         in: try Self.text(ProcessPane().environment(model)))

        let gate = try Self.stage("Allow build", in: model)
        model.processSelection = .stage(gate.id)
        Self.expectShown(["Waiting on a person", "guesswork", "assume-and-report", "harness:build"],
                         in: try Self.text(ProcessPane().environment(model)))
    }

    @Test
    func selectingATransitionShowsItsReasonAndGuardInsteadOfStageDetails() throws {
        let model = Self.model()
        let gate = try Self.stage("Allow build", in: model)
        let implementation = try Self.stage("Write the code", in: model)
        let transition = try #require(model.processDiagram.transitions.first {
            $0.from == gate.id && $0.to == implementation.id
        }, "The diagram must connect the build gate to implementation")
        #expect(!transition.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!transition.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        model.processSelection = .stage(gate.id)
        _ = try Self.text(ProcessPane().environment(model))
        model.processSelection = .transition(transition.id)
        #expect(model.processSelection == .transition(transition.id))
        Self.expectShown(["Reason", transition.reason, "Condition", transition.condition],
                         in: try Self.text(ProcessPane().environment(model)))
    }

    @Test
    func humanReviewRendersThePersonsLandingApprovalAndItsBuildSignal() throws {
        var harness = HarnessSettings()
        harness.review.level = .agentAndHuman
        let model = Self.model(harness: harness)
        let approval = try Self.stage("Approve landing", in: model)
        #expect(approval.waitsOnPerson)

        let overview = try Self.text(ProcessPane().environment(model))
        Self.expectShown(["Requirement", "Leaf", "Review the acceptance tests", "Review the code change", "Approve landing"],
                         in: overview)
        model.processSelection = .stage(approval.id)
        Self.expectShown(["Waiting on a person", "review.level", "agent+human", "harness:build"],
                         in: try Self.text(ProcessPane().environment(model)))
    }

    @Test
    func everyRepoNodeIsCountedOnceIncludingNestedCompositesAndARootLeaf() async throws {
        let (ledger, model) = try await Self.populatedModel()
        let stages = model.processDiagram.stages
        let counted = stages.flatMap { Array($0.nodeIDs) }
        #expect(Set(counted) == Set(model.state.nodes.keys))
        #expect(counted.count == model.state.nodes.count, "A root leaf must not count in both workflows")

        let build = try Self.stage("Allow build", in: model)
        #expect(build.nodeIDs == Set(["ready-a", "ready-b"]))
        #expect(build.waitingNodeIDs == build.nodeIDs)
        let implementation = try Self.stage("Write the code", in: model)
        #expect(implementation.nodeIDs == Set(["building-child", "building-root-leaf"]))
        #expect(implementation.waitingNodeIDs.isEmpty)
        let breakdown = try Self.stage("Allow breakdown", in: model)
        #expect(breakdown.nodeIDs == Set(["other-root"]))
        #expect(breakdown.waitingNodeIDs == breakdown.nodeIDs)
        for stage in stages {
            #expect(stage.waitingNodeIDs.isSubset(of: stage.nodeIDs))
            if !stage.waitsOnPerson { #expect(stage.waitingNodeIDs.isEmpty) }
        }

        try await ledger.append([
            Self.event("ready-a", .gateOpened(.build), by: .human("Reviewer")),
            Self.event("ready-a", .phaseChanged(to: .building)),
            Self.event("ready-a", .runStarted(run: "new-builder", role: .implementer)),
        ])
        model.state = await ledger.workingState()
        await model.refreshHistory(from: ledger)
        #expect(try Self.stage("Allow build", in: model).nodeIDs == Set(["ready-b"]))
        #expect(try Self.stage("Write the code", in: model).nodeIDs
                == Set(["ready-a", "building-child", "building-root-leaf"]))
        let updated = model.processDiagram.stages.flatMap { Array($0.nodeIDs) }
        #expect(updated.count == model.state.nodes.count)
        #expect(Set(updated) == Set(model.state.nodes.keys))
    }

    @Test
    func humanGatesShowNumberedWaitMarksAndEachSelectedStageShowsItsNodeCount() async throws {
        let (ledger, model) = try await Self.populatedModel()
        Self.expectShown(["2 nodes", "2 waiting on a person"],
                         in: try Self.text(ProcessPane().environment(model)))
        for (title, count, nodeCount) in [("Allow breakdown", 1, "1 node"), ("Allow build", 2, "2 nodes")] {
            let stage = try Self.stage(title, in: model)
            #expect(stage.waitsOnPerson)
            #expect(stage.waitingNodeIDs.count == count)
            model.processSelection = .stage(stage.id)
            Self.expectShown([title, nodeCount, "\(count) waiting on a person"],
                             in: try Self.text(ProcessPane().environment(model)))
        }
        let implementation = try Self.stage("Write the code", in: model)
        #expect(!implementation.waitsOnPerson)
        model.processSelection = .stage(implementation.id)
        Self.expectShown(["Write the code", "2 nodes"], in: try Self.text(ProcessPane().environment(model)))

        try await ledger.append([
            Self.event("ready-a", .gateOpened(.build), by: .human("Reviewer")),
            Self.event("ready-a", .phaseChanged(to: .building)),
            Self.event("ready-a", .runStarted(run: "count-refresh-builder", role: .implementer)),
        ])
        model.state = await ledger.workingState()
        await model.refreshHistory(from: ledger)
        Self.expectShown(["Write the code", "3 nodes"], in: try Self.text(ProcessPane().environment(model)))
        let gate = try Self.stage("Allow build", in: model)
        #expect(gate.waitingNodeIDs == Set(["ready-b"]))
        model.processSelection = .stage(gate.id)
        Self.expectShown(["Allow build", "1 waiting on a person"],
                         in: try Self.text(ProcessPane().environment(model)))
    }

    @Test
    func openingSelectingAndReopeningProcessNeverWritesLedgerEvents() async throws {
        let (ledger, model) = try await Self.populatedModel()
        let actions = MutationProbe()
        model.actions = actions
        let before = await ledger.allRecords()
        let beforeHistory = model.records.map(\.hash)

        Self.expectShown(["Process", "Requirement", "Leaf"],
                         in: try Self.text(RepositoryInspectorPane(selection: .constant(.process)).environment(model)))
        let diagram = model.processDiagram
        try #require(!diagram.stages.isEmpty)
        try #require(!diagram.transitions.isEmpty)
        for stage in diagram.stages.prefix(3) {
            model.processSelection = .stage(stage.id)
            _ = try Self.text(ProcessPane().environment(model))
        }
        for transition in diagram.transitions.prefix(2) {
            model.processSelection = .transition(transition.id)
            _ = try Self.text(ProcessPane().environment(model))
        }
        model.processSelection = nil
        _ = try Self.text(RepositoryInspectorPane(selection: .constant(.ledger)).environment(model))
        _ = try Self.text(RepositoryInspectorPane(selection: .constant(.process)).environment(model))

        let after = await ledger.allRecords()
        #expect(after.map(\.hash) == before.map(\.hash))
        #expect(model.records.map(\.hash) == beforeHistory)
        #expect(model.state.nodes.mapValues(\.version) == (await ledger.workingState()).nodes.mapValues(\.version))
        #expect(actions.mutations.isEmpty, "A Process selection must not send a writing action: \(actions.mutations)")
    }

    private static func model(harness: HarnessSettings = HarnessSettings(), repo: RepoConfig? = nil) -> HarnessViewModel {
        let model = HarnessViewModel()
        model.policy = EffectivePolicy.resolve(harness: harness, repo: repo, defaultBranch: "main")
        model.config = repo
        return model
    }

    private static func text<Content: View>(_ view: Content) throws -> String {
        try RenderedUI.text(of: view.environment(\.locale, Locale(identifier: "en_US")),
                            size: CGSize(width: 1_400, height: 2_400))
    }

    private static func expectShown(_ labels: [String], in text: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        for label in labels {
            #expect(RenderedUI.shows(label, in: text), "Missing \(label) in:\n\(text)", sourceLocation: sourceLocation)
        }
    }

    private static func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased().filter(\.isLetter) == rhs.lowercased().filter(\.isLetter)
    }

    private static func stage(_ title: String, in model: HarnessViewModel) throws -> ProcessStagePresentation {
        try #require(model.processDiagram.stages.first { Self.sameTitle($0.title, title) },
                     "The effective workflow must contain \(title)")
    }

    private static func event(_ node: NodeID, _ kind: EventKind,
                              by: Participant = .reconciler) -> LedgerEvent {
        LedgerEvent(node: node, by: by, kind: kind, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func populatedModel() async throws -> (Ledger, HarnessViewModel) {
        let ledger = try Ledger()
        let specs: [NodeSpec] = [
            Self.spec("root", kind: .composite),
            Self.spec("nested", parent: "root", kind: .composite),
            Self.spec("other-root", kind: .composite),
            Self.spec("ready-a", parent: "nested"),
            Self.spec("ready-b", parent: "root"),
            Self.spec("building-child", parent: "root"),
            Self.spec("building-root-leaf"),
        ]
        try await ledger.append(specs.map { Self.event($0.id, .nodeCreated(spec: $0, ticket: $0.id)) })
        var events = [Self.event("root", .gateOpened(.breakdown), by: .human("Planner")),
                      Self.event("root", .phaseChanged(to: .split)),
                      Self.event("root", .requirementBranchCreated(branch: "agentos/root", from: "main")),
                      Self.event("building-root-leaf", .requirementBranchCreated(
                        branch: "agentos/building-root-leaf", from: "main"))]
        for id in ["ready-a", "ready-b", "building-child", "building-root-leaf"] {
            events += [
                Self.event(id, .testsFixed(digest: "tests-\(id)")),
                Self.event(id, .reviewRecorded(ReviewRecord(
                    stage: .acceptanceTests, result: ReviewResult(passed: true, findings: []),
                    commit: "tests-\(id)", uiEvidence: nil))),
                Self.event(id, .phaseChanged(to: .ready)),
            ]
        }
        for id in ["building-child", "building-root-leaf"] {
            events += [
                Self.event(id, .gateOpened(.build), by: .human("Builder")),
                Self.event(id, .phaseChanged(to: .building)),
                Self.event(id, .runStarted(run: "builder-\(id)", role: .implementer)),
            ]
        }
        try await ledger.append(events)
        let model = Self.model()
        model.state = await ledger.workingState()
        await model.refreshHistory(from: ledger)
        await model.refreshLedger(from: ledger)
        return (ledger, model)
    }

    private static func spec(_ id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(id: id, parent: parent, kind: kind, title: id, intent: "Show repository workflow occupancy",
                 acceptanceCriteria: ["Count this node in its current stage only"])
    }

    @MainActor
    private final class MutationProbe: HarnessActions {
        var mutations: [String] = []
        func stopRun(node: NodeID, run: RunID, by person: String) async { mutations.append("stopRun") }
        func stopPreview(run: RunID, by person: String) async { mutations.append("stopPreview") }
        func addLabel(_ name: String, to key: String) async { mutations.append("addLabel") }
        func removeLabel(_ name: String, from key: String) async { mutations.append("removeLabel") }
        func comment(_ text: String, on key: String) async { mutations.append("comment") }
        func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {
            mutations.append("createTicket")
        }
        func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {
            mutations.append("edit")
        }
        func verifyChain() async {}
        func tamperWithLedger() async { mutations.append("tamperWithLedger") }
        func restoreLedger() async { mutations.append("restoreLedger") }
        func runBaseline() async { mutations.append("runBaseline") }
        func rescan() async { mutations.append("rescan") }
        func open(_ path: String) {}
        func openRepoConfig() { mutations.append("openRepoConfig") }
    }
}
