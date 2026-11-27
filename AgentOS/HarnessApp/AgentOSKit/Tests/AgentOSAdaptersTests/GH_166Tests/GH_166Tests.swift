// Expected API: NodeSpec.integration (Bool, true marks an integration leaf), carried by nodeCreated
// and breakdownRevised events. Reconciler.runRound(waitForAgents:) starts the existing TestAuthor
// and Implementer protocols only when all current siblings are Proven. WorkPane renders the selected
// child's integration purpose and live wait from HarnessViewModel.state.
// All five GH-166 criteria are observable; none are source-only. No planner, hash, or prompt API is required.
import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import Foundation
import SwiftUI
import Testing

@Suite struct GH_166Tests {
    @Test(arguments: [Gate.breakdown, .build], AfterCase.allCases)
    func anIntegrationTestAuthorWaitsForEveryCurrentSiblingWhateverItsAfterSays(
        gate: Gate, after: AfterCase
    ) async throws {
        let fixture = try await Fixture(after: after)
        defer { fixture.removeFiles() }
        try await fixture.open(gate)
        try await fixture.settle()

        try #require(await fixture.agents.calls.isEmpty,
                     "An open gate and satisfied, absent, or incomplete after must not bypass an unfinished sibling.")
        #expect(await fixture.starts(of: .testAuthor).isEmpty)
        try await fixture.prove(fixture.pending.id)
        try await fixture.settle()

        #expect(await fixture.agents.calls.map(\.role) == [.testAuthor])
        #expect(await fixture.agents.calls.map(\.node) == [fixture.integration.id])
        #expect(await fixture.starts(of: .testAuthor).count == 1)
    }

    @Test(arguments: [Phase.specified, .ready, .building, .checking, .landing])
    func aSiblingIsNotCompleteMerelyBecauseItHasStartedOrReachedLanding(phase: Phase) async throws {
        let fixture = try await Fixture(pendingPhase: phase)
        defer { fixture.removeFiles() }
        try await fixture.open(.breakdown)
        try await fixture.settle()

        #expect(await fixture.agents.calls.isEmpty, "Only Proven releases the integration test author.")
        #expect(await fixture.starts(of: .testAuthor).isEmpty)
    }

    @Test(arguments: [AgentRole.testAuthor, .implementer])
    func allOtherChildrenBeingProvenReleasesTheIntegrationAgent(role: AgentRole) async throws {
        let fixture = try await Fixture(integrationPhase: role == .testAuthor ? .specified : .ready)
        defer { fixture.removeFiles() }
        try await fixture.prove(fixture.pending.id)
        try await fixture.open(role == .testAuthor ? .breakdown : .build)
        try await fixture.settle()

        #expect(await fixture.agents.calls.map(\.role) == [role],
                "The recorder must observe actual public agent calls, not just an eligibility decision.")
        #expect(await fixture.agents.calls.map(\.node) == [fixture.integration.id])
        #expect(await fixture.starts(of: role).count == 1)
    }

    @Test(arguments: [AgentRole.testAuthor, .implementer])
    func aCompositeSiblingReleasesIntegrationOnlyAfterItsEntireSubtreeIsProven(role: AgentRole) async throws {
        let fixture = try await Fixture(
            integrationPhase: role == .testAuthor ? .specified : .ready, compositeSibling: true)
        defer { fixture.removeFiles() }
        try await fixture.open(role == .testAuthor ? .breakdown : .build)
        try await fixture.settle()

        let before = await fixture.ledger.workingState()
        #expect(before.nodes[fixture.pending.id]?.phase == .split)
        #expect(before.nodes[fixture.nested.id]?.phase == .split)
        try #require(await fixture.agents.calls.isEmpty,
                     "A composite is still a waiting sibling while a deeper descendant remains unfinished.")
        try await fixture.prove(fixture.lastDescendant.id)
        try await fixture.settle()

        let after = await fixture.ledger.workingState()
        #expect(after.subtree(of: fixture.pending.id).allSatisfy { $0.phase == .proven })
        let call = try #require(await fixture.agents.calls.first)
        #expect(call.node == fixture.integration.id)
        #expect(call.role == role)
        #expect(call.siblingSubtreePhases.allSatisfy { $0 == .proven },
                "The subtree must already be Proven at the instant the integration agent is called.")
        #expect(await fixture.starts(of: role).count == 1)
    }

    @Test
    func anUnprovenSiblingDroppedByTheLatestBreakdownNoLongerHoldsTheTestAuthor() async throws {
        let fixture = try await Fixture(after: .onlyProven)
        defer { fixture.removeFiles() }
        try await fixture.open(.breakdown)
        try await fixture.settle()
        try #require(await fixture.agents.calls.isEmpty, "The original current sibling must initially hold it.")

        try await fixture.revise(dropping: [fixture.pending.id])
        let revised = await fixture.ledger.workingState()
        let parent = try #require(revised.nodes[fixture.root.id])
        #expect(!parent.children.contains(fixture.pending.id))
        try await fixture.settle()

        #expect(await fixture.agents.calls.map(\.node) == [fixture.integration.id])
        #expect(await fixture.starts(of: .testAuthor).count == 1)
    }

    @Test(arguments: [AgentRole.testAuthor, .implementer])
    func aNewSiblingAddedByTheLatestBreakdownHoldsIntegrationDespiteTheOldAfter(role: AgentRole) async throws {
        let fixture = try await Fixture(
            after: .onlyProven, integrationPhase: role == .testAuthor ? .specified : .ready)
        defer { fixture.removeFiles() }
        try await fixture.prove(fixture.pending.id)
        try await fixture.settle()
        try #require(await fixture.agents.calls.isEmpty, "The integration gate is still closed.")
        let added = Self.spec("new", parent: fixture.root.id)
        try await fixture.revise(adding: added)
        try await fixture.open(role == .testAuthor ? .breakdown : .build)
        try await fixture.settle()

        try #require(await fixture.agents.calls.isEmpty,
                     "The current child list, not the integration child's old dependency hashes, decides the wait.")
        #expect(await fixture.starts(of: role).isEmpty)
        try await fixture.prove(added.id)
        try await fixture.settle()
        #expect(await fixture.agents.calls.map(\.role) == [role])
        #expect(await fixture.agents.calls.map(\.node) == [fixture.integration.id])
    }

    @Test(arguments: AfterCase.allCases)
    func aReadyIntegrationLeafWithAnOpenBuildGateWaitsForAllOtherChildren(after: AfterCase) async throws {
        let fixture = try await Fixture(after: after, integrationPhase: .ready)
        defer { fixture.removeFiles() }
        try await fixture.open(.build)
        try await fixture.settle()

        try #require(await fixture.agents.calls.isEmpty,
                     "Review completion and an open build gate do not waive the all-siblings-Proven requirement.")
        #expect(await fixture.starts(of: .implementer).isEmpty)
        try await fixture.prove(fixture.pending.id)
        try await fixture.settle()
        #expect(await fixture.agents.calls.map(\.role) == [.implementer])
        #expect(await fixture.starts(of: .implementer).count == 1)
    }

    @Test(arguments: [false, true], [AgentRole.testAuthor, .implementer])
    func anOrdinaryLeafKeepsItsExistingStartBehaviour(markFalse: Bool, role: AgentRole) async throws {
        let fixture = try await Fixture(
            integrationPhase: role == .testAuthor ? .specified : .ready, marked: false, markFalse: markFalse)
        defer { fixture.removeFiles() }
        try await fixture.open(role == .testAuthor ? .breakdown : .build)
        try await fixture.settle()

        #expect(await fixture.agents.calls.map(\.role) == [role],
                "Neither an absent nor a false integration mark imposes the new sibling wait.")
        #expect(await fixture.agents.calls.map(\.node) == [fixture.integration.id])
        #expect(await fixture.ledger.workingState().nodes[fixture.pending.id]?.phase != .proven)
    }

    @MainActor @Test(arguments: [Phase.specified, .ready], [false, true])
    func workDetailsShowIntegrationPurposeAndOnlyShowTheWaitWhileASiblingIsUnproven(
        phase: Phase, compositeSibling: Bool
    ) async throws {
        let fixture = try await Fixture(integrationPhase: phase, compositeSibling: compositeSibling)
        defer { fixture.removeFiles() }
        let waiting = try await Self.detailText(fixture)

        #expect(RenderedUI.shows("integration tests", in: waiting), "\(waiting)")
        #expect(RenderedUI.shows("waiting for all other children", in: waiting), "\(waiting)")
        if compositeSibling {
            try await fixture.prove(fixture.lastDescendant.id)
            try await fixture.settle()
        } else {
            try await fixture.prove(fixture.pending.id)
        }
        let released = try await Self.detailText(fixture)
        #expect(RenderedUI.shows("integration tests", in: released), "\(released)")
        #expect(!RenderedUI.shows("waiting for all other children", in: released), "\(released)")
    }

    @MainActor @Test(arguments: [false, true])
    func ordinaryWorkDetailsShowNeitherIntegrationPurposeNorItsSiblingWait(markFalse: Bool) async throws {
        let fixture = try await Fixture(marked: false, markFalse: markFalse)
        defer { fixture.removeFiles() }
        let before = try await Self.detailText(fixture)
        #expect(!RenderedUI.shows("integration tests", in: before), "\(before)")
        #expect(!RenderedUI.shows("waiting for all other children", in: before), "\(before)")
        try await fixture.prove(fixture.pending.id)
        let after = try await Self.detailText(fixture)
        #expect(!RenderedUI.shows("integration tests", in: after), "\(after)")
        #expect(!RenderedUI.shows("waiting for all other children", in: after), "\(after)")
    }

    @MainActor @Test
    func workDetailsUpdateTheIntegrationWaitWhenTheLatestBreakdownReplacesASibling() async throws {
        let fixture = try await Fixture()
        defer { fixture.removeFiles() }
        let initial = try await Self.detailText(fixture)
        #expect(RenderedUI.shows("waiting for all other children", in: initial), "\(initial)")
        try await fixture.revise(dropping: [fixture.pending.id])
        let dropped = try await Self.detailText(fixture)
        #expect(RenderedUI.shows("integration tests", in: dropped), "\(dropped)")
        #expect(!RenderedUI.shows("waiting for all other children", in: dropped), "\(dropped)")
        try await fixture.revise(adding: Self.spec("replacement", parent: fixture.root.id))
        let added = try await Self.detailText(fixture)
        #expect(RenderedUI.shows("integration tests", in: added), "\(added)")
        #expect(RenderedUI.shows("waiting for all other children", in: added), "\(added)")
    }

    static func spec(_ name: String, parent: NodeID? = nil, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(id: "wn-GH-166-\(name)", parent: parent, kind: kind, title: "Work \(name)",
                 intent: "Observe \(name)", acceptanceCriteria: ["The \(name) behaviour works"])
    }

    @MainActor private static func detailText(_ fixture: Fixture) async throws -> String {
        let model = HarnessViewModel()
        model.state = await fixture.ledger.workingState()
        model.selectedNodeID = fixture.integration.id
        let text = try RenderedUI.text(
            of: WorkPane().environment(model), size: CGSize(width: 1500, height: 1300))
        try #require(RenderedUI.shows("Test suite", in: text)
                     && RenderedUI.shows(fixture.integration.testTarget, in: text),
                     "The existing selected-child detail must render before testing new labels: \(text)")
        return text
    }

    enum AfterCase: CaseIterable, Sendable {
        case omitted, empty, onlyProven, missingHash, duplicateFingerprint
    }
}
