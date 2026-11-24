import AgentOSTestSupport
import CoreGraphics
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@MainActor
struct ProcessDiagramTests {
    private static func diagram(_ settings: HarnessSettings = HarnessSettings()) -> ProcessDiagramPresentation {
        let model = HarnessViewModel()
        model.policy = EffectivePolicy.resolve(harness: settings, repo: nil, defaultBranch: "main")
        return model.processDiagram
    }

    @Test func recoveryEdgesAreDrawnOnlyForASelectionTheyTouch() throws {
        let diagram = Self.diagram()
        let recovery = Set(diagram.stages.filter { $0.workflow == .recovery }.map(\.id))
        let isRecovery = { (edge: ProcessTransitionPresentation) in
            recovery.contains(edge.from) || recovery.contains(edge.to)
        }
        let replan = try #require(diagram.transitions.first { $0.from == .resumeWork && $0.to == .breakdownGate })

        let unselected = diagram.drawnTransitions(for: nil)
        #expect(!unselected.contains(where: isRecovery))
        #expect(unselected.count == diagram.transitions.count { !isRecovery($0) })

        let gate = diagram.drawnTransitions(for: .stage(.breakdownGate)).filter(isRecovery)
        #expect(!gate.isEmpty)
        #expect(gate.allSatisfy { $0.from == .breakdownGate || $0.to == .breakdownGate })
        let resumeEdges = diagram.transitions.filter { $0.from == .resumeWork || $0.to == .resumeWork }
        #expect(resumeEdges.contains { $0.from == .resumeWork } && resumeEdges.contains { $0.to == .resumeWork })
        #expect(Set(diagram.drawnTransitions(for: .stage(.resumeWork)).filter(isRecovery).map(\.id))
                == Set(resumeEdges.map(\.id)))
        #expect(diagram.drawnTransitions(for: .transition(replan.id)).filter(isRecovery).map(\.id) == [replan.id])
    }

    @Test func edgesBetweenSideBySideLanesStayInTheGutter() {
        let requirement = CGRect(x: 0, y: 300, width: 400, height: 100)
        let leaf = CGRect(x: 450, y: 100, width: 400, height: 100)

        let toProven = ProcessEdgeRoute(from: leaf, to: requirement)
        #expect(toProven.points.allSatisfy { $0.x >= requirement.maxX && $0.x <= leaf.minX })
        #expect(toProven.points.first == CGPoint(x: leaf.minX, y: leaf.midY))
        #expect(toProven.points.last == CGPoint(x: requirement.maxX, y: requirement.midY))
        #expect(toProven.heading == CGVector(dx: -1, dy: 0))

        let rightward = ProcessEdgeRoute(from: requirement, to: leaf)
        #expect(rightward.points.last == CGPoint(x: leaf.minX, y: leaf.midY))
        #expect(rightward.heading == CGVector(dx: 1, dy: 0))
    }

    @Test func aFullWidthRecoveryEdgeUsesTheNarrowCardsRailInsteadOfCrossingTheOtherLane() {
        let requirement = CGRect(x: 0, y: 100, width: 400, height: 100)
        let recovery = CGRect(x: 0, y: 900, width: 850, height: 100)
        let leafColumn: ClosedRange<CGFloat> = 450...850

        let resume = ProcessEdgeRoute(from: recovery, to: requirement)
        #expect(resume.points.allSatisfy { !leafColumn.contains($0.x) })
        #expect(resume.points.first == CGPoint(x: requirement.maxX + 10, y: recovery.minY))
        #expect(resume.points.last == CGPoint(x: requirement.maxX, y: requirement.midY))

        let escalate = ProcessEdgeRoute(from: requirement, to: recovery)
        #expect(escalate.points.allSatisfy { !leafColumn.contains($0.x) })
        #expect(escalate.points.last == CGPoint(x: requirement.maxX + 10, y: recovery.minY))
        #expect(escalate.heading == CGVector(dx: 0, dy: 1))
        #expect(escalate.arrowhead == [CGPoint(x: 407, y: 895), CGPoint(x: 410, y: 900), CGPoint(x: 413, y: 895)])
    }

    @Test func cardsInOneLaneKeepTheRightHandRail() {
        let upper = CGRect(x: 450, y: 100, width: 400, height: 100)
        let lower = CGRect(x: 450, y: 300, width: 400, height: 100)

        let route = ProcessEdgeRoute(from: lower, to: upper)
        #expect(route.points == [CGPoint(x: 850, y: 350), CGPoint(x: 860, y: 350),
                                 CGPoint(x: 860, y: 150), CGPoint(x: 850, y: 150)])
        #expect(route.arrowhead == [CGPoint(x: 855, y: 147), CGPoint(x: 850, y: 150), CGPoint(x: 855, y: 153)])
    }

    @Test func anOffsetRouteRunsBesideTheReverseTransitionInsteadOfOnTopOfIt() {
        let children = CGRect(x: 0, y: 100, width: 400, height: 100)
        let proven = CGRect(x: 0, y: 300, width: 400, height: 100)
        let transition = ProcessEdgeRoute(from: children, to: proven)
        let link = ProcessEdgeRoute(from: proven, to: children, offset: ProcessEdgeRoute.parallelOffset)

        #expect(link.points == [CGPoint(x: 400, y: 356), CGPoint(x: 416, y: 356),
                                CGPoint(x: 416, y: 156), CGPoint(x: 400, y: 156)])
        #expect(Set(link.points.map(\.x)).isDisjoint(with: [transition.points[1].x]))
        #expect(Set(link.points.map(\.y)).isDisjoint(with: transition.points.map(\.y)))
    }

    private static let root = NodeID("wn-GH-1")
    private static let leaf = NodeID("wn-GH-1-1")

    /// A proven requirement with a proven leaf child: both sit at the catalog's Proven stage.
    private static func provenModel() async throws -> HarnessViewModel {
        let root = NodeSpec(id: Self.root, parent: nil, kind: .composite, title: "GH-1",
                            intent: "I", acceptanceCriteria: ["a"])
        let leaf = NodeSpec(id: Self.leaf, parent: root.id, kind: .leaf, title: "GH-1 leaf",
                            intent: "I", acceptanceCriteria: ["a"])
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: root.id, by: .reconciler, kind: .nodeCreated(spec: root, ticket: "GH-1")),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .nodeCreated(spec: leaf, ticket: "GH-1.1")),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
        ])
        let model = HarnessViewModel()
        model.policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: "main")
        model.state = await ledger.workingState()
        try #require(model.processSummary(for: Self.root)?.stageID == .proven)
        try #require(model.processSummary(for: Self.leaf)?.stageID == .proven)
        return model
    }

    @Test func eachLaneHasItsOwnProvenCardAndItsOwnEdges() throws {
        let diagram = Self.diagram()
        let ids = Set(diagram.stages.map(\.id))
        #expect(ids.isSuperset(of: ["leaf/proven", "composite/proven"]))
        #expect(!ids.contains(.proven))
        #expect(!diagram.transitions.contains { $0.from == .proven || $0.to == .proven })
        #expect(diagram.stages.first { $0.id == "leaf/proven" }?.workflow == .leaf)
        #expect(diagram.stages.first { $0.id == "composite/proven" }?.workflow == .requirement)
        let leafLane = diagram.stages.filter { $0.workflow == .leaf }.map(\.id)
        #expect(leafLane.firstIndex(of: "leaf/proven")! > leafLane.firstIndex(of: .singleChangeReview)!)

        let intoLeaf = Set(diagram.transitions.filter { $0.to == "leaf/proven" }.map(\.from))
        #expect(intoLeaf.contains(.singleChangeReview))
        #expect(!intoLeaf.contains(.children))
        let intoComposite = Set(diagram.transitions.filter { $0.to == "composite/proven" }.map(\.from))
        #expect(intoComposite.contains(.children))
        #expect(!intoComposite.contains(.singleChangeReview))
        // A root leaf hands off from its own Proven to the root-only stages.
        #expect(diagram.transitions.contains { $0.from == "leaf/proven" && $0.to == .finalVerification })
        #expect(diagram.transitions.contains { $0.from == "composite/proven" && $0.to == .finalVerification })
    }

    @Test func provenOccupancyAndTheWorkStageFilterFollowTheNodeKind() async throws {
        let model = try await Self.provenModel()
        let stages = model.processDiagram.stages
        #expect(stages.first { $0.id == "leaf/proven" }?.nodeIDs == [Self.leaf])
        #expect(stages.first { $0.id == "composite/proven" }?.nodeIDs == [Self.root])

        model.workStageFilterID = "leaf/proven"
        #expect(model.matchingWorkNodeIDs == [Self.leaf])
        #expect(model.workStageFilterTitle == "Proven (leaf)")
        model.workStageFilterID = "composite/proven"
        #expect(model.matchingWorkNodeIDs == [Self.root])
        model.workStageFilterID = .proven
        #expect(model.matchingWorkNodeIDs == [Self.root, Self.leaf])
    }

    @Test func aSelectedNodeOnlyShowsTheProvenCardOfItsKind() async throws {
        let model = try await Self.provenModel()
        model.selectedNodeID = Self.leaf
        let leafIDs = Set(model.processDiagram.stages.map(\.id))
        #expect(leafIDs.contains("leaf/proven") && !leafIDs.contains("composite/proven"))
        model.selectedNodeID = Self.root
        let rootIDs = Set(model.processDiagram.stages.map(\.id))
        #expect(rootIDs.contains("composite/proven") && !rootIDs.contains("leaf/proven"))
    }

    @Test func theClickedStageIsTheSelectionAndTheWorkNodesStageIsOnlyItsLocation() async throws {
        let model = try await Self.provenModel()
        model.selectedNodeID = Self.leaf
        model.processSelection = .stage(.implementation)
        let stages = model.processDiagram.stages
        func marker(_ id: String) throws -> ProcessStageMarker {
            model.processStageMarker(for: try #require(stages.first { $0.id == id }))
        }

        #expect(try marker(.implementation) == ProcessStageMarker(selected: true, nodeLocation: false))
        #expect(try marker("leaf/proven") == ProcessStageMarker(selected: false, nodeLocation: true))
        #expect(model.highlightedProcessStageID == .proven)

        model.processSelection = .stage("leaf/proven")
        #expect(try marker("leaf/proven") == ProcessStageMarker(selected: true, nodeLocation: true))
        #expect(try marker(.implementation) == ProcessStageMarker(selected: false, nodeLocation: false))
    }

    @Test func dashedChildLinksJoinFollowChildWorkflowsToEachChildsEntryAndBack() {
        let diagram = Self.diagram()
        let links = Set(diagram.childLinks)
        #expect(links == [
            ProcessChildLink(from: .children, to: .breakdownGate, role: .startsChild),
            ProcessChildLink(from: "composite/proven", to: .children, role: .reportsBack),
            ProcessChildLink(from: .children, to: .acceptanceTests, role: .startsChild),
            ProcessChildLink(from: "leaf/proven", to: .children, role: .reportsBack),
        ])
        let transitions = Set(diagram.transitions.map { "\($0.from)→\($0.to)" })
        #expect(links.allSatisfy { !transitions.contains("\($0.from)→\($0.to)") })
    }

    /// Proven → Follow child workflows and Follow child workflows → Breakdown gate meet at the parent
    /// card; sharing a rail and an attachment point drew them as one line from Proven to Breakdown gate.
    @Test func aChildReturnAndANestedChildEntryDoNotJoinIntoOneLine() throws {
        let gate = CGRect(x: 0, y: 0, width: 400, height: 100)
        let children = CGRect(x: 0, y: 200, width: 400, height: 100)
        let proven = CGRect(x: 0, y: 400, width: 400, height: 100)
        let links = Self.diagram().childLinks
        func route(_ link: ProcessChildLink, from source: CGRect, to target: CGRect) -> ProcessEdgeRoute {
            ProcessEdgeRoute(from: source, to: target, offset: link.route.offset,
                             verticalOffset: link.route.verticalOffset)
        }
        let back = route(try #require(links.first { $0.from == "composite/proven" }), from: proven, to: children)
        let entry = route(try #require(links.first { $0.to == .breakdownGate }), from: children, to: gate)
        let solidRail = ProcessEdgeRoute(from: children, to: gate).points[1].x

        #expect(try #require(back.points.last) != entry.points.first)
        #expect(back.points[1].x != entry.points[1].x)
        #expect(Set([back.points[1].x, entry.points[1].x]).isDisjoint(with: [solidRail]))
        #expect(try #require(back.points.last).y > children.midY)
        #expect(try #require(entry.points.first).y < children.midY)
    }

    @Test func everyProjectedCardSaysWhatHappensUnderEachPolicy() {
        var human = HarnessSettings()
        human.review.level = .agentAndHuman
        var publishing = HarnessSettings()
        publishing.pullRequests = true
        var single = HarnessSettings()
        single.landingBatchSize = 1
        single.review.level = .none
        var seen: Set<String> = []
        for settings in [HarnessSettings(), human, publishing, single] {
            for stage in Self.diagram(settings).stages {
                seen.insert(stage.id)
                #expect(!stage.whatHappens.isEmpty, "\(stage.id) has no description")
            }
        }
        #expect(seen.isSuperset(of: [.landing, .escalated, .diagnosis, .batchChecks, .landingApproval, .push,
                                     .pullRequest, "leaf/proven", "composite/proven"]))
    }

    @Test func provenAndBatchWordingFollowTheNodeKindAndTheEffectiveBatchSize() {
        var settings = HarnessSettings()
        settings.landingBatchSize = 3
        let stages = Self.diagram(settings).stages
        func text(_ id: String) -> String { stages.first { $0.id == id }?.whatHappens ?? "" }
        #expect(text("leaf/proven").contains("landed on the top-level requirement's branch"))
        #expect(text("composite/proven").contains("Every child is proven"))
        #expect(text("composite/proven").contains("not merged into main"))
        #expect(text(.batchChecks).contains("Up to 3 waiting changes"))
        #expect(text(.landingQueue).contains("up to 3"))
        #expect(Self.diagram(settings).landingBatchSize == 3)
    }

    @Test func changesThatNeedAPersonsReviewAreNeverDescribedAsBatched() throws {
        var settings = HarnessSettings()
        settings.landingBatchSize = 3
        settings.review.level = .agentAndHuman
        let diagram = Self.diagram(settings)
        let queue = try #require(diagram.stages.first { $0.id == .landingQueue }?.whatHappens)

        #expect(diagram.landingBatchSize == 1)
        #expect(queue.contains("one change at a time"))
        #expect(!diagram.stages.contains { $0.whatHappens.contains("batch of up to") })
    }

    @Test func workFilterAndSelectedNodeUseTheCardsPlainTitles() async throws {
        let spec = NodeSpec(id: Self.root, parent: nil, kind: .composite, title: "GH-1",
                            intent: "I", acceptanceCriteria: ["a"])
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: spec.id, by: .reconciler, kind: .nodeCreated(spec: spec, ticket: "GH-1")),
        ])
        let model = HarnessViewModel()
        model.policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: "main")
        model.state = await ledger.workingState()

        let summary = try #require(model.processSummary(for: Self.root))
        #expect(summary.stageID == .breakdownGate)
        #expect(summary.stageTitle == "Allow breakdown")
        #expect(model.processDiagram.stages.first { $0.id == .breakdownGate }?.title == "Allow breakdown")
        model.workStageFilterID = .children
        #expect(model.workStageFilterTitle == "Wait for child work to finish")
    }

    @Test func theLegendExplainsLanesAndLinesWithTheGlossaryCollapsed() throws {
        let model = HarnessViewModel()
        model.policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: "main")
        let suite = "ProcessDiagramTests.legend.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pane = ProcessPane().environment(model).defaultAppStorage(defaults)
        let text = try RenderedUI.text(of: pane, size: CGSize(width: 1_400, height: 1_000))
        for label in ["How to read this", "A ticket too big to build in one go", "small enough to build directly",
                      "Side paths when something goes wrong", "A ticket moves to the next stage",
                      "Nothing moves along it", "A person may need to act", "Words used here",
                      "Split into child tickets and wait for their work", "Tests first, then code, then land"] {
            #expect(RenderedUI.shows(label, in: text), "Missing \(label) in:\n\(text)")
        }
        #expect(!RenderedUI.shows("Lands: the requirement branch moves forward", in: text))
    }
}
