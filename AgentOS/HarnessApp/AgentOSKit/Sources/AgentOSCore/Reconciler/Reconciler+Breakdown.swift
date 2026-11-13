import Foundation

extension Reconciler {
    /// `harness:replan`: the ticket changed (criteria, a forgotten "Blocked by", a breakdown that missed the point).
    /// Only before anything below it is built: replanning then costs no work that can't simply be redone. The node
    /// takes the ticket as it is now and starts over as just adopted, without gates, so people choose again how
    /// far it goes (preview, breakdown or go). The children wait for that breakdown, which keeps the unchanged ones.
    func replan(_ node: NodeState?, ticket: Ticket, by person: String) async throws -> String {
        let state = await ledger.workingState()
        guard let node else {
            throw Rejection(reason: "Not adopted yet, so there's no plan to redo. Edit the ticket and preview it again.")
        }
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }) {
            throw Rejection(reason: "\(ticket.key) is part of \(parent.displayName)'s breakdown. Replan \(parent.displayName) instead, " +
                "or comment here and add \(HarnessCommand.retry.label) when it's waiting for you.")
        }
        let subtree = state.subtree(of: node.id)
        if let started = subtree.first(where: Self.hasStartedBuilding) {
            throw Rejection(reason: "Building has started on \(started.ticket) (\(started.phase.rawValue)), so replanning " +
                "would throw away built work. Changing a spec once building has started isn't supported yet.")
        }
        let problems = policy.readinessProblems(ticket)
        guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }

        let spec = Planner.rootSpec(for: ticket)
        if node.spec.kind == .leaf { try? await workspace.removeWorktree(for: node.id) }
        try await write(node.id, by: .human(person), [.replanned(spec: spec)])
        let children = node.children.compactMap { state.nodes[$0]?.ticket }
        let closed = children.isEmpty ? "" : "\nIts child tickets (\(children.joined(separator: ", "))) are paused. The next " +
            "breakdown keeps those it still contains unchanged, with their tests and approvals, and closes the others."
        let replanned = await ledger.workingState()
        let missing = replanned.nodes[node.id].map { unresolvedDependencies(of: $0, in: replanned) } ?? spec.dependsOn
        let waits = missing.isEmpty ? "" : "\nWaits for: \(missing.joined(separator: ", "))."
        return "replanned from the ticket as it is now; nothing is approved yet.\(closed)\(waits)\n" +
            "Next: \(HarnessCommand.preview.label) to see the new breakdown first, \(HarnessCommand.breakdown.label) " +
            "to break it down, or \(HarnessCommand.go.label) to break it down and build it."
    }

    /// Past the point where replanning is free: an agent working on it, or code written, checked or landed.
    static func hasStartedBuilding(_ node: NodeState) -> Bool {
        node.activeRun != nil || node.lastSubmission != nil || node.landedCommit != nil
            || [.building, .checking, .landing, .proven].contains(node.phase)
    }

    func breakDown(_ node: NodeState, in state: WorkingState) async throws -> String {
        let proposed: [NodeSpec]
        let author: Participant
        var assumptions: [String] = []
        if let preview = state.previews[node.ticket], preview.specHash == node.spec.specHash {
            // What you saw is what you get: no regeneration (doc 05 §3).
            proposed = preview.proposal.map { spec in
                var child = spec
                child.parent = node.id
                return child
            }
            author = .reconciler
        } else {
            let run = Self.newRunID()
            author = .agent(run: run, role: .decomposer)
            try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .decomposer)], expecting: node.version)
            let breakdown: Breakdown
            do {
                breakdown = try await propose(
                    node.spec, ticketKey: node.ticket,
                    clarifications: state.clarifications(for: node.id), log: agentLog(node, run)
                )
                try Task.checkCancellation()
            } catch {
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"),
                    .flagSet(.escalated, reason: "Breakdown failed: \(error)")])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: breakdown failed (\(error)). Fix the ticket, then add harness:retry.")
                return "\(node.displayName) breakdown failed → escalated"
            }
            let questions = policy.questions(in: breakdown.report, role: .decomposer)
            guard questions.isEmpty else {
                return try await raise(questions, on: node, by: author, run: run, role: .decomposer)
            }
            try await recordSuggestions(breakdown.report.questions, on: node, role: .decomposer, by: author)
            proposed = Planner.childSpecs(parent: node.spec, proposals: breakdown.children)
            assumptions = policy.assumptions(in: breakdown.report)
            try await write(node.id, by: author, [.runFinished(run: run, outcome: "proposed \(proposed.count) children")]
                + (assumptions.isEmpty ? [] : [.assumptionsReported(role: .decomposer, assumptions: assumptions)]))
        }
        let note = Self.assumptionsNote("Assumptions the decomposer made", assumptions)
        let (children, revision) = try await revise(node, proposed: proposed, in: state)

        // Leaf check (doc 02 §4): a "breakdown" into one piece is the node itself, so it becomes the leaf.
        // Production: the decomposer runs the full leaf check before proposing children at all.
        if children.count <= 1 {
            let touches = children.first?.touches ?? [ComponentName.from(node.spec.title, maxWords: 3)]
            let needs = Set(node.spec.dependsOn + (children.first?.dependsOn ?? [])).sorted()
            try await write(node.id, by: author, [.becameLeaf(touches: touches)]
                + needs.map { .linkAdded(TypedLink(from: node.id, type: .dependsOn, to: $0)) })
            await tracker.comment(on: node.ticket, """
                🍃 No breakdown needed: small enough to build as it is (leaf check passed).
                \(Planner.describe(children, under: node.spec.title))\(note)\(revision)
                This ticket gets its own branch and acceptance tests next; then add harness:build.
                """)
            return "\(node.displayName) passed the leaf check: built as one leaf"
        }

        for var spec in children {
            // Revision matches existing children independently of their ticket-derived IDs.
            if await ledger.workingState().nodes[spec.id] != nil { continue }
            let key: String
            do {
                key = try await tracker.createChildTicket(parent: node.ticket, spec: spec, by: author)
            } catch {
                try await write(node.id, by: .reconciler, [.flagSet(.escalated, reason: "Couldn't create a child ticket: \(error)")])
                return "\(node.displayName) breakdown stopped: couldn't create \"\(spec.title)\" → escalated"
            }
            if tracker.createsChildTickets {
                spec.id = "wn-\(key)"
            }
            let links = spec.dependsOn.map { TypedLink(from: spec.id, type: .dependsOn, to: $0) }
            try await write(spec.id, by: author, [.nodeCreated(spec: spec, ticket: key)] + links.map { .linkAdded($0) })
        }
        try await write(node.id, by: .reconciler, [.phaseChanged(to: .split)])
        await tracker.comment(on: node.ticket, """
            🌳 Broken down. Each leaf gets its own branch and acceptance tests next; then add harness:build.
            \(Planner.describe(children, under: node.spec.title))\(note)\(revision)
            """)
        return "\(node.displayName) broken down into \(children.count) leaves"
    }

    /// After a replan the node still has its old children. Those the new breakdown contains unchanged (same spec
    /// fingerprint) are kept, with their tickets, tests and approvals, under their own ids; the others are dropped
    /// and their tickets closed as superseded. New children get ids no kept child uses.
    /// Returns the children to create (kept ones are skipped as already present) and a note for the ticket.
    private func revise(_ node: NodeState, proposed: [NodeSpec], in state: WorkingState) async throws -> ([NodeSpec], String) {
        let old = node.children.compactMap { state.nodes[$0] }
        guard !old.isEmpty else { return (proposed, "") }
        var unmatched = old
        var specs: [NodeSpec] = []
        var kept: [NodeSpec] = []
        for spec in proposed {
            if proposed.count > 1, let match = unmatched.firstIndex(where: { $0.spec.specHash == spec.specHash }) {
                var revised = spec
                revised.id = unmatched[match].id
                kept.append(revised)
                specs.append(revised)
                unmatched.remove(at: match)
            } else {
                specs.append(spec)
            }
        }
        var used = Set(kept.map(\.id))
        var next = proposed.count + old.count
        for index in specs.indices where !kept.contains(where: { $0.id == specs[index].id }) {
            while used.contains(specs[index].id) {
                next += 1
                specs[index].id = "\(node.id).\(next)"
            }
            used.insert(specs[index].id)
        }
        for gone in unmatched { try? await workspace.removeWorktree(for: gone.id) }
        try await write(node.id, by: .reconciler, [.breakdownRevised(kept: kept, dropped: unmatched.map(\.id))])
        for gone in unmatched {
            await tracker.close(gone.ticket, saying: "🗑 Superseded: \(node.displayName) was replanned and its new breakdown doesn't contain this.")
        }
        let keptTickets = kept.compactMap { state.nodes[$0.id]?.ticket }
        var lines: [String] = []
        if !keptTickets.isEmpty { lines.append("Kept from the old breakdown, with their tests: \(keptTickets.joined(separator: ", ")).") }
        if !unmatched.isEmpty { lines.append("Closed as superseded: \(unmatched.map(\.ticket).joined(separator: ", ")).") }
        return (specs, "\n" + lines.joined(separator: "\n"))
    }

    /// The decomposer looks at a snapshot of the latest code when the workspace can make one. Without it the
    /// breakdown still runs, from the ticket alone.
    func propose(
        _ spec: NodeSpec, ticketKey: String, clarifications: [Clarification], log: URL?
    ) async throws -> Breakdown {
        let codebase = try? await workspace.createSnapshot()
        let request = BreakdownRequest(
            spec: spec, existingComponents: workspace.existingComponents(), clarifications: clarifications,
            guesswork: policy.guesswork, log: log, codebase: codebase, ticketKey: ticketKey,
            agentContext: await makeAgentContext(ticketKey))
        do {
            let breakdown = try await checkedBreakdown(request)
            if let codebase { await workspace.removeSnapshot(codebase) }
            return breakdown
        } catch {
            if let codebase { await workspace.removeSnapshot(codebase) }
            throw error
        }
    }
}
