import Testing
import AgentOSCore
@testable import AgentOSUI

struct TrackerPaneTests {
    private func ticket(_ key: String, parent: String? = nil) -> Ticket {
        Ticket(key: key, title: key, description: "", acceptanceCriteria: [], parentKey: parent, createdBy: .human("Ann"))
    }

    @MainActor @Test func ticketsAreInKeyOrderWithChildrenUnderTheirParent() {
        let tickets = [ticket("GH-8"), ticket("GH-12", parent: "GH-4"), ticket("GH-5"),
                       ticket("GH-10", parent: "GH-4"), ticket("GH-4"), ticket("GH-9", parent: "GH-4")]
        let ordered = TrackerPane.treeOrdered(tickets).map { "\($0.ticket.key)/\($0.depth)" }
        #expect(ordered == ["GH-4/0", "GH-9/1", "GH-10/1", "GH-12/1", "GH-5/0", "GH-8/0"])
    }
}
