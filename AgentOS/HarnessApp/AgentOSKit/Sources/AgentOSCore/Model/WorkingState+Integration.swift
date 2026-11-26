extension WorkingState {
    /// Integration leaves wait on the current breakdown, not on potentially stale dependency fingerprints.
    public func isWaitingForIntegrationSiblings(_ node: NodeState) -> Bool {
        guard node.spec.kind == .leaf, node.spec.integration,
              let parentID = node.spec.parent, let parent = nodes[parentID] else { return false }
        return parent.children.contains { $0 != node.id && nodes[$0]?.phase != .proven }
    }
}
