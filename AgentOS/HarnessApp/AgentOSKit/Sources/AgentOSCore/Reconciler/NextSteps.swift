/// What a person can do next on a ticket, given where its node is. Every rejected signal ends with this, so a
/// "❌" always says which signal (if any) applies now, rather than leaving people to guess, e.g. with `harness:retry`.
extension Reconciler {
    static func nextSteps(for ticket: String, in state: WorkingState, allowed: Set<HarnessCommand>) -> [String] {
        func step(_ command: HarnessCommand?, _ text: String) -> String? {
            guard let command else { return text }
            return allowed.contains(command) ? text : nil
        }
        let node = state.node(forTicket: ticket)
        if node == nil, let replanned = state.superseded[ticket] {
            return ["Nothing: it was dropped when \(replanned) was replanned. Work on \(replanned) instead"]
        }
        guard let node else {
            return [
                step(.preview, "\(HarnessCommand.preview.label) to see a proposed breakdown first (creates nothing)"),
                step(.breakdown, "\(HarnessCommand.breakdown.label) to adopt it and approve its breakdown"),
                step(.go, "\(HarnessCommand.go.label) to adopt it, break it down and build it without stopping"),
            ].compactMap { $0 }
        }

        var steps: [String?] = []
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }), parent.phase != .split {
            steps.append(step(nil, "Nothing for now: \(parent.ticket) was replanned. Its next breakdown keeps this ticket " +
                "if it still contains it unchanged, or closes it"))
        } else if node.flags[.needsInput] != nil {
            steps.append(step(.retest, "\(HarnessCommand.retest.label) to discard the current tests and restart the test author"))
            if node.openQuestions.isEmpty {
                steps.append(step(.build, "\(HarnessCommand.build.label) to approve the acceptance tests as they are"))
                steps.append(step(.retry, "or comment with feedback on them, then \(HarnessCommand.retry.label)"))
            } else {
                steps.append(step(.retry, "Answer the questions in a comment, then \(HarnessCommand.retry.label)"))
            }
        } else if node.flags[.escalated] != nil {
            steps.append(step(.retest, "\(HarnessCommand.retest.label) to discard the current tests and restart the test author"))
            steps.append(step(.retry, "\(HarnessCommand.retry.label) to try again from where it stopped (its attempts start over)"))
        } else if let blocked = node.flags[.blocked] {
            steps.append(step(nil, "Nothing for now: it's blocked (\(blocked)) and continues by itself once that's resolved"))
        } else if node.phase == .proven {
            steps.append(step(nil, "Nothing: it's done"))
        } else if let run = node.activeRun {
            steps.append(step(nil, "Nothing for now: the \(run.role.title) is working on it; it asks here if it needs you"))
        } else if node.spec.kind == .composite && !state.hasGate(.breakdown, at: node.id) {
            steps.append(step(.breakdown, "\(HarnessCommand.breakdown.label) to approve its breakdown"))
            steps.append(step(.go, "\(HarnessCommand.go.label) to approve breakdown and build at once"))
        } else if node.spec.kind == .composite && node.phase == .specified {
            steps.append(step(nil, "Nothing for now: it's being broken down; the child tickets appear here when it's done"))
        } else if !state.hasGate(.build, at: node.id) {
            steps.append(step(.build, "\(HarnessCommand.build.label) to approve building it (and everything below it)"))
        } else {
            steps.append(step(nil, "Nothing for now: it's in progress (\(node.phase.rawValue)); it asks here if it needs you"))
        }

        let subtree = state.subtree(of: node.id)
        if node.spec.parent == nil, state.hasGate(.breakdown, at: node.id), !subtree.contains(where: hasStartedBuilding) {
            steps.append(step(.replan, "\(HarnessCommand.replan.label) to redo its plan from the ticket as it is now " +
                "(e.g. after changing its criteria or \"Blocked by\"), possible until building starts"))
        }

        let waiting = subtree.filter { $0.id != node.id }
            .filter { $0.flags[.needsInput] != nil || $0.flags[.escalated] != nil }
            .map(\.ticket)
        if !waiting.isEmpty {
            steps.append(step(nil, "Tickets below it need you: \(waiting.joined(separator: ", "))"))
        }
        return steps.compactMap { $0 }
    }

    /// The `nextSteps` as a few lines for a tracker reply.
    static func whatYouCanDo(_ steps: [String]) -> String {
        guard !steps.isEmpty else { return "" }
        return "\nWhat you can do now:\n" + steps.map { "- \($0)" }.joined(separator: "\n")
    }
}
