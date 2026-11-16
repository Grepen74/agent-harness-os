extension Reconciler {
    func isHeldForOverlap(_ node: NodeState, in state: WorkingState) -> Bool {
        guard policy.avoidOverlappingWork, node.spec.kind == .leaf, node.phase == .ready, !wantsDiagnosis(node),
              unresolvedDependencies(of: node, in: state).isEmpty else { return false }
        return state.nodes.values.contains { other in
            guard other.id != node.id, other.flags[.escalated] == nil, other.flags[.needsInput] == nil,
                  !other.ticketClosed else { return false }
            if let parent = other.spec.parent.flatMap({ state.nodes[$0] }), parent.phase != .split { return false }

            let inProgress = other.phase == .building || other.phase == .checking || other.phase == .landing
            // A reservation holds its paths before the step records a claim or changes phase.
            let reservedBuild = other.spec.kind == .leaf && other.phase == .ready && tasks[other.id] != nil &&
                unresolvedDependencies(of: other, in: state).isEmpty
            guard inProgress || reservedBuild else { return false }
            return Self.overlaps(node.spec, other.spec)
        }
    }

    private static func overlaps(_ first: NodeSpec, _ second: NodeSpec) -> Bool {
        let firstPaths = first.predictedPaths
        let secondPaths = second.predictedPaths
        guard !firstPaths.isEmpty, !secondPaths.isEmpty else {
            return !Set(first.touches).isDisjoint(with: second.touches)
        }
        return firstPaths.contains { firstPath in
            secondPaths.contains { secondPath in
                firstPath == secondPath || firstPath.hasPrefix(secondPath + "/") ||
                    secondPath.hasPrefix(firstPath + "/")
            }
        }
    }
}
