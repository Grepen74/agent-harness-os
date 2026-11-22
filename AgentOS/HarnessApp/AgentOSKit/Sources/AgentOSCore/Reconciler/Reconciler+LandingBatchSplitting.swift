import Foundation

extension Reconciler {
    /// Resolve owners in one place so batch attribution and single-landing conflicts use the same rule.
    static func testOwners(of targets: Set<String>, among nodes: [NodeState]) -> [NodeState] {
        targets.sorted().compactMap { target in nodes.first { $0.spec.testTarget == target } }
    }

    func resolveLandingBatchFailure(_ nodes: [NodeState], name: String,
                                    failingTargets: Set<String>) async throws -> String? {
        guard nodes.count > 1 else { return try await landSmallerGroup(nodes) }
        let state = await ledger.workingState()
        let owners = Self.testOwners(of: failingTargets, among: Array(state.nodes.values))
        let ownerIDs = Set(owners.map(\.id))
        let memberIDs = Set(nodes.map(\.id))
        var actions: [String] = []
        if !owners.isEmpty, Set(owners.map(\.spec.testTarget)) == failingTargets,
           ownerIDs.isSubset(of: memberIDs) {
            let removed = nodes.filter { ownerIDs.contains($0.id) }
            let remaining = nodes.filter { !ownerIDs.contains($0.id) }
            try await write(nil, by: .reconciler, [.landingBatchOwnersRemoved(
                batch: name, removed: removed.map(\.id), remaining: remaining.map(\.id))])
            if let action = try await landSmallerGroup(remaining) { actions.append(action) }
            // Known failing owners are isolated only after the healthy remainder has landed.
            for node in removed {
                if let action = try await landSmallerGroup([node]) { actions.append(action) }
            }
        } else {
            let middle = nodes.count / 2
            let first = Array(nodes.prefix(middle))
            let second = Array(nodes.dropFirst(middle))
            try await write(nil, by: .reconciler, [.landingBatchSplit(
                batch: name, first: first.map(\.id), second: second.map(\.id))])
            if let action = try await landSmallerGroup(first) { actions.append(action) }
            if let action = try await landSmallerGroup(second) { actions.append(action) }
        }
        return actions.isEmpty ? nil : actions.joined(separator: "\n")
    }

    private func landSmallerGroup(_ nodes: [NodeState]) async throws -> String? {
        try Task.checkCancellation()
        guard shutdownReason == nil else { return nil }
        let state = await ledger.workingState()
        var ready: [NodeState] = []
        for node in nodes {
            guard let current = state.nodes[node.id], current.phase == .landing,
                  current.activeRun == nil, current.flags[.escalated] == nil,
                  !current.ticketClosed, !current.awaitingHumanReview,
                  !requirementIsHeld(current, in: state) else { continue }
            if let reason = try await workspace.whyLandingMustWait(for: current.id) {
                _ = await waitToLand(current, because: reason)
            } else {
                ready.append(current)
            }
        }
        guard let first = ready.first else { return nil }
        if ready.count == 1 {
            let action = try await land(first)
            ownedRuns[first.id] = nil
            return action
        }
        return await performLandingBatch(ready)
    }
}
