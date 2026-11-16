/// A ready leaf's current overlap reservation, replayed from the ledger.
public struct OverlapHold: Sendable, Equatable {
    public let waitingFor: NodeID
    public let paths: [String]
    public let components: [String]

    public init(waitingFor: NodeID, paths: [String], components: [String]) {
        self.waitingFor = waitingFor
        self.paths = Array(Set(paths)).sorted()
        self.components = Array(Set(components)).sorted()
    }

    public func message(waitingFor name: String) -> String {
        let overlap = paths.isEmpty
            ? "both touch components \(components.joined(separator: ", "))"
            : "both change \(paths.joined(separator: ", "))"
        return "Waiting for \(name) to land: \(overlap). " +
            "This leaf starts by itself once \(name) lands or stops being in progress. Nothing needs to be done."
    }
}

extension WorkingState {
    public func overlapHoldMessage(for node: NodeState) -> String? {
        guard node.phase == .ready, !node.ticketClosed, node.flags[.escalated] == nil,
              node.flags[.needsInput] == nil, let hold = node.overlapHold else { return nil }
        return hold.message(waitingFor: nodes[hold.waitingFor]?.displayName ?? hold.waitingFor)
    }
}
