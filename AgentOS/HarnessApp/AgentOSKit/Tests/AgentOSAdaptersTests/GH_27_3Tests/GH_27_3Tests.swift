// API contract: NodeIdentity.displayName is the canonical text used anywhere human-facing output identifies a node.

import AgentOSCore
import Testing

@Suite
struct GH_27_3Tests {
    @Test
    func legacyNodeIdentityShowsTheTicketBeforeTheNodeID() {
        let identity = NodeIdentity(ticketKey: "GH-18", nodeID: "wn-GH-15.1")

        #expect(identity.displayName == "GH-18 (wn-GH-15.1)")
    }

    @Test
    func ticketDerivedNodeIdentityDoesNotRepeatTheNodeID() {
        let identity = NodeIdentity(ticketKey: "GH-18", nodeID: "wn-GH-18")

        #expect(identity.displayName == "GH-18")
        #expect(!identity.displayName.contains("("))
    }
}
