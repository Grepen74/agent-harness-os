import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@MainActor
struct WorkPaneRootsTests {
    private static func requirement(_ ticket: String, finalVerificationStarted: Bool) -> [LedgerEvent] {
        let root = NodeSpec(id: NodeID("wn-\(ticket)"), parent: nil, kind: .composite, title: ticket,
                            intent: "I", acceptanceCriteria: ["a"])
        let leaf = NodeSpec(id: NodeID("wn-\(ticket)-1"), parent: root.id, kind: .leaf, title: "\(ticket) leaf",
                            intent: "I", acceptanceCriteria: ["a"])
        var events = [
            LedgerEvent(node: root.id, by: .reconciler, kind: .nodeCreated(spec: root, ticket: ticket)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .nodeCreated(spec: leaf, ticket: "\(ticket).1")),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: .proven))
        ]
        if finalVerificationStarted {
            events.append(LedgerEvent(node: root.id, by: .reconciler, kind: .requirementVerificationStarted))
        }
        return events
    }

    @Test func hidingDoneItemsKeepsARequirementWhoseFinalVerificationNeedsAPerson() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.requirement("GH-58", finalVerificationStarted: true)
                                + Self.requirement("GH-57", finalVerificationStarted: false))
        let state = await ledger.workingState()
        try #require(state.attentionList.contains { $0.node.ticket == "GH-58" })

        #expect(WorkPane.roots(in: state, showingDone: false).map(\.ticket) == ["GH-58"])
        #expect(WorkPane.roots(in: state, showingDone: true).map(\.ticket) == ["GH-58", "GH-57"])
    }
}
