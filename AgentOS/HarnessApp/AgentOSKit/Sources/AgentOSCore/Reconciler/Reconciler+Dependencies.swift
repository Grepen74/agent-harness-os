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
    /// is proven. Proven work in another requirement must also be where this node's work starts: it landed on its
    /// own requirement branch, so until it's merged into `main` (and caught up) this node would be built without it.
    /// With requirement branches, that other requirement must also be Done (verified and merged) as a whole.
    func unresolvedDependencies(of node: NodeState, in state: WorkingState) -> [String] {
        let siblings = (node.spec.after ?? []).compactMap { hash -> String? in
            let parent = node.spec.parent.flatMap { state.nodes[$0] }
            // A sibling the latest breakdown no longer has can't be waited for.
            guard let sibling = parent?.children.lazy.compactMap({ state.nodes[$0] })
                .first(where: { $0.spec.specHash == hash }) else { return nil }
            return sibling.phase == .proven ? nil : sibling.displayName
        }
        let requirement = state.lineage(of: node.id).last?.id
        let there = requirement.flatMap { dependenciesThere[$0] } ?? []
        return siblings + wantedDependencies(of: node, in: state).compactMap { ref in
            if state.resolvedExternal.contains(ref) { return nil }
            guard let here = state.nodes[ref] ?? state.node(forTicket: ref) else { return ref }
            guard let theirs = state.lineage(of: here.id).last, theirs.id != requirement else {
                return here.phase == .proven ? nil : ref
            }
            // With requirement branches, the other requirement as a whole must be done and merged.
            if requirementBranches != nil || theirs.requirementBranchObservation != nil
                || theirs.requirementVerificationStarted || theirs.pullRequestNumber != nil {
                let merged = theirs.requirementMerged || theirs.requirementBranchObservation != nil
                guard merged, state.status(of: theirs) == "Done" else { return ref }
            }
            guard here.phase == .proven else { return ref }
            // Its work must also be where this node's work starts (e.g. a merged pull request not pulled yet).
            // Proven since the last refresh counts as not there until it's checked.
            return there.contains(here.id) ? nil : "\(ref) to be merged into main"
        }
    }

    /// Every dependency by name, once: links, specs, and a parent's that its breakdown didn't give to particular children.
    private func wantedDependencies(of node: NodeState, in state: WorkingState) -> [String] {
        let ancestors = state.lineage(of: node.id).dropFirst()
        let inherited = ancestors.flatMap { ancestor in
            ancestor.spec.dependsOn.filter { ref in
                !state.subtree(of: ancestor.id).dropFirst().contains { $0.spec.dependsOn.contains(ref) }
            }
        }
        let wanted = node.links.filter { $0.type == .dependsOn }.map(\.to) + node.spec.dependsOn + inherited
        var seen = Set<String>()
        return wanted.filter { seen.insert($0).inserted }
    }

    /// Asks the workspace, for every unfinished node's proven dependencies in another requirement, whether the node's
    /// requirement branch (or `main`, before it has one) has their latest landed commit yet. A requirement branch
    /// only moves forward, so that commit has the earlier landings too; checking those on their own would fail
    /// once later work changed the same lines.
    func refreshDependenciesThere() async {
        let state = await ledger.workingState()
        var found: [NodeID: Set<NodeID>] = [:]
        var asked = Set<String>()
        for node in state.nodes.values where node.phase != .proven && !node.ticketClosed {
            guard let requirement = state.lineage(of: node.id).last else { continue }
            for ref in wantedDependencies(of: node, in: state) {
                guard let dependency = state.nodes[ref] ?? state.node(forTicket: ref), dependency.phase == .proven,
                      state.lineage(of: dependency.id).last?.id != requirement.id,
                      asked.insert("\(requirement.id) \(dependency.id)").inserted else { continue }
                let latest = state.subtree(of: dependency.id).filter { $0.landedCommit != nil }
                    .max { ($0.landedAt ?? 0) < ($1.landedAt ?? 0) }?.landedCommit
                guard let commit = latest else {
                    found[requirement.id, default: []].insert(dependency.id)
                    continue
                }
                let key = "\(requirement.id) \(commit)"
                if !dependencyCommitsThere.contains(key),
                   (try? await workspace.branch(requirement.requirementBranch, hasEverythingIn: commit)) == true {
                    dependencyCommitsThere.insert(key)
                }
                if dependencyCommitsThere.contains(key) { found[requirement.id, default: []].insert(dependency.id) }
            }
        }
        dependenciesThere = found
    }
}
