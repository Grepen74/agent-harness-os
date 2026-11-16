extension Reconciler {
    func overlapHold(for node: NodeState, in state: WorkingState) -> OverlapHold? {
        guard policy.avoidOverlappingWork, node.spec.kind == .leaf, node.phase == .ready, !wantsDiagnosis(node),
              unresolvedDependencies(of: node, in: state).isEmpty else { return nil }
        for id in state.creationOrder {
            guard let other = state.nodes[id], other.id != node.id, holdsOverlapPaths(other, in: state) else { continue }
            let firstPaths = PredictedPath.normalize(node.spec.predictedPaths)
            let secondPaths = PredictedPath.normalize(other.actualChangedFiles ?? other.spec.predictedPaths)
            if other.actualChangedFiles != nil && secondPaths.isEmpty { continue }
            if firstPaths.isEmpty || secondPaths.isEmpty {
                let components = Set(node.spec.touches).intersection(other.spec.touches).sorted()
                if !components.isEmpty {
                    return OverlapHold(waitingFor: other.id, paths: [], components: components)
                }
            } else {
                let paths = firstPaths.flatMap { first in
                    secondPaths.compactMap { second -> String? in
                        if first == second || first.hasPrefix(second + "/") { return first }
                        if second.hasPrefix(first + "/") { return second }
                        return nil
                    }
                }
                if !paths.isEmpty { return OverlapHold(waitingFor: other.id, paths: paths, components: []) }
            }
        }
        return nil
    }

    private func holdsOverlapPaths(_ node: NodeState, in state: WorkingState) -> Bool {
        guard node.flags[.escalated] == nil, node.flags[.needsInput] == nil, !node.ticketClosed else { return false }
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }), parent.phase != .split { return false }
        // Reservations count before the step records its claim or changes phase.
        return node.phase == .building || node.phase == .checking || node.phase == .landing ||
            (node.spec.kind == .leaf && node.phase == .ready && tasks[node.id] != nil &&
                unresolvedDependencies(of: node, in: state).isEmpty)
    }

    /// Compare-and-swap keeps concurrent rounds from reporting the same transition twice.
    func updateOverlapHold(_ node: NodeState, to hold: OverlapHold?, in state: WorkingState) async throws -> Bool {
        guard node.overlapHold != hold else { return true }
        var kinds: [EventKind] = []
        if let previous = node.overlapHold {
            kinds.append(.overlapHoldEnded(waitingFor: previous.waitingFor,
                                          paths: previous.paths, components: previous.components))
        }
        if let hold {
            kinds.append(.overlapHoldStarted(waitingFor: hold.waitingFor, paths: hold.paths, components: hold.components))
        }
        do {
            try await write(node.id, by: .reconciler, kinds, expecting: node.version)
        } catch LedgerError.conflict {
            return false // A concurrent step or signal won; reconsider it with fresh state next round.
        }
        if let hold {
            let message = hold.message(waitingFor: state.nodes[hold.waitingFor]?.displayName ?? hold.waitingFor)
            await tracker.comment(on: node.ticket, message)
            completedActions.append("\(node.displayName): \(message)")
        } else {
            completedActions.append("\(node.displayName): overlap hold ended")
        }
        return true
    }

    func clearObsoleteOverlapHolds() async throws {
        let state = await ledger.workingState()
        for id in state.creationOrder {
            guard let node = state.nodes[id], node.overlapHold != nil, tasks[id] == nil else { continue }
            let hold = canAdvance(node, in: state) ? overlapHold(for: node, in: state) : nil
            _ = try await updateOverlapHold(node, to: hold, in: state)
        }
    }
}
