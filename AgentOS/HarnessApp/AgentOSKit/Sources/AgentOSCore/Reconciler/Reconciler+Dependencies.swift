import Foundation

extension Reconciler {
    func intakeExternal(_ report: inout RoundReport) async {
        let state = await ledger.workingState()
        for ref in (await external.deliveredKeys()).subtracting(state.resolvedExternal).sorted() {
            try? await write(nil, by: .adapter("external system"), [.externalDependencyResolved(ref: ref)])
            report.actions.append("\(ref) delivered by the other system")
        }
        let updated = await ledger.workingState()
        for node in updated.nodes.values where node.flags[.blocked] != nil {
            if unresolvedDependencies(of: node, in: updated).isEmpty {
                try? await write(node.id, by: .reconciler, [.flagCleared(.blocked)])
                await tracker.comment(on: node.ticket, "🔓 Unblocked: everything this waits for is done or delivered.")
                report.actions.append("\(node.displayName) unblocked")
            }
        }
        for node in updated.nodes.values {
            let closed = await tracker.isClosed(node.ticket)
            guard closed != node.ticketClosed else { continue }
            try? await write(node.id, by: .adapter("tracker"), [closed ? .ticketClosed : .ticketReopened])
            report.actions.append("\(node.displayName) \(closed ? "closed on the tracker: no more work on it" : "reopened")")
        }
    }

    /// What the node still waits for: its own links and specs, plus a parent's "Blocked by" that its breakdown didn't
    /// give to particular children (then it applies to all of them, e.g. a forgotten dependency added by replan).
    /// A dependency is met when the other system delivered it, or when it's another ticket (or node) here and that
    /// is proven.
    func unresolvedDependencies(of node: NodeState, in state: WorkingState) -> [String] {
        let ancestors = state.lineage(of: node.id).dropFirst()
        let inherited = ancestors.flatMap { ancestor in
            ancestor.spec.dependsOn.filter { ref in
                !state.subtree(of: ancestor.id).dropFirst().contains { $0.spec.dependsOn.contains(ref) }
            }
        }
        let wanted = node.links.filter { $0.type == .dependsOn }.map(\.to) + node.spec.dependsOn + inherited
        let siblings = (node.spec.after ?? []).compactMap { hash -> String? in
            let parent = node.spec.parent.flatMap { state.nodes[$0] }
            // A sibling the latest breakdown no longer has can't be waited for.
            guard let sibling = parent?.children.lazy.compactMap({ state.nodes[$0] })
                .first(where: { $0.spec.specHash == hash }) else { return nil }
            return sibling.phase == .proven ? nil : sibling.displayName
        }
        var seen = Set<String>()
        return siblings + wanted.filter { seen.insert($0).inserted }.filter { ref in
            if state.resolvedExternal.contains(ref) { return false }
            let here = state.nodes[ref] ?? state.node(forTicket: ref)
            return here?.phase != .proven
        }
    }
}
