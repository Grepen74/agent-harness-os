import Foundation

extension Reconciler {
    func workLink(_ node: NodeState) -> String {
        if node.ticket.hasPrefix("GH-"), let number = Int(node.ticket.dropFirst(3)),
           !tracker.contextRepository.isEmpty {
            return "[\(node.displayName)](https://github.com/\(tracker.contextRepository)/issues/\(number))"
        }
        return "[\(node.displayName)](\(workspace.worktree(for: node.id).absoluteString))"
    }

    func escalateIfNeeded(_ id: NodeID) async throws -> String? {
        guard let node = await ledger.workingState().nodes[id], let reason = policy.escalationReason(for: node) else { return nil }
        try await write(id, by: .reconciler, [.flagSet(.escalated, reason: reason)])
        await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen fixed, add label harness:retry.")
        return "\(node.displayName) escalated: \(reason)"
    }

    func projectStatuses() async {
        let state = await ledger.workingState()
        for node in state.nodes.values where !node.ticketClosed {
            await tracker.setStatus(of: node.ticket, to: state.status(of: node))
        }
    }

    /// One node's status and its children's (theirs depends on the parent's phase), as soon as it changes:
    /// a round can take as long as its slowest agent or landing check, so waiting for its end left tickets
    /// showing a status from half an hour ago.
    func projectStatus(of id: NodeID) async {
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return }
        for affected in [node] + node.children.compactMap({ state.nodes[$0] }) where !affected.ticketClosed {
            await tracker.setStatus(of: affected.ticket, to: state.status(of: affected))
        }
    }

    func write(_ node: NodeID?, by who: Participant, _ kinds: [EventKind], expecting version: Int? = nil) async throws {
        try Task.checkCancellation()
        let events = kinds.map { LedgerEvent(node: node, by: who, kind: $0) }
        let expecting = node.flatMap { id in version.map { [id: $0] } } ?? [:]
        let starting = kinds.compactMap { kind -> RunID? in
            if case .runStarted(let run, _) = kind { return run }
            return nil
        }.first
        if let node, let starting { ownedRuns[node] = starting }
        do {
            try await ledger.append(events, expecting: expecting)
        } catch {
            if let node, starting != nil { ownedRuns[node] = nil }
            throw error
        }
        if let node { await projectStatus(of: node) }
    }
}
