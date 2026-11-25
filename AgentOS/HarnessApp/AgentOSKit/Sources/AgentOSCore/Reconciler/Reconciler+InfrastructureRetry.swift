import Foundation

extension Reconciler {
    /// How runs end that trying again may fix by itself: the machine or the landing branch failed, not the change.
    static let infrastructureOutcomes: Set<String> = ["landing infrastructure problem", "unreliable tests", "runner crash"]

    static func isInfrastructureOutcome(_ outcome: String) -> Bool {
        infrastructureOutcomes.contains(outcome) || WorkspaceProblem.isOutcome(outcome)
    }

    /// Ends `run` on a workspace problem and escalates it for `retryInfrastructureProblems`: no failed attempt, and
    /// the run gives its turn of the run budget back. `keeping` is recorded first, e.g. the draft the run took over.
    func stopForWorkspaceProblem(_ problem: WorkspaceProblem, on node: NodeState, run: RunID, by author: Participant,
                                 keeping: [EventKind] = []) async throws -> String {
        let reason = workspaceProblemReason(problem.outcome)
        // The escalation right after the run's finish: that's how `retryInfrastructureProblems` finds the cause.
        try await write(node.id, by: author, keeping + [
            .runFinished(run: run, outcome: problem.outcome), .flagSet(.escalated, reason: reason)])
        await tracker.comment(on: node.ticket, "⚠️ " + reason)
        return "\(node.displayName) \(problem.outcome) → tries again by itself"
    }

    func workspaceProblemReason(_ outcome: String) -> String {
        let delays = policy.infrastructureRetryDelays
        let retry = delays.isEmpty ? "" : " It is tried again by itself after \(Int(delays[0] / 60)) minutes."
        return "\(outcome.prefix(1).uppercased() + outcome.dropFirst()).\(retry) To try now, check the machine and "
            + "the working copy, then add harness:retry."
    }

    /// Clears escalations that an infrastructure problem caused once their wait (`Policy.infrastructureRetryDelays`)
    /// is over, so the work is tried again without a person. It still needs every check to pass. Each try since a
    /// person last acted uses up one wait; after the last, the escalation stays for a person. Also returns when the
    /// earliest escalation still waiting is due.
    func retryInfrastructureProblems(in state: WorkingState) async throws -> (actions: [String], nextDue: Date?) {
        let delays = policy.infrastructureRetryDelays
        guard !delays.isEmpty else { return ([], nil) }
        var actions: [String] = []
        var nextDue: Date?
        for id in state.creationOrder {
            guard let node = state.nodes[id], node.flags[.escalated] != nil, !node.ticketClosed, tasks[id] == nil,
                  node.activeRun == nil else { continue }
            let records = await ledger.records(for: id)
            guard let escalation = records.lastIndex(where: {
                if case .flagSet(.escalated, _) = $0.event.kind { return true }
                return false
            }), escalation > 0, case .runFinished(_, let outcome) = records[escalation - 1].event.kind,
                  Self.isInfrastructureOutcome(outcome) else { continue }
            let sincePerson = records.lastIndex { if case .human = $0.event.by { return true }; return false }
                .map { $0 + 1 } ?? 0
            let tries = records[sincePerson...].filter {
                guard case .reconciler = $0.event.by, case .flagCleared(.escalated) = $0.event.kind else { return false }
                return true
            }.count
            guard tries < delays.count else { continue }
            let due = records[escalation].event.at.addingTimeInterval(delays[tries])
            guard now() >= due else {
                nextDue = min(nextDue ?? due, due)
                continue
            }
            try await write(id, by: .reconciler, [.flagCleared(.escalated)], expecting: node.version)
            await tracker.comment(on: node.ticket, """
                🔁 Trying again by itself (\(tries + 1) of \(delays.count)) after an infrastructure problem \
                (\(outcome)). It still needs every check to pass.
                """)
            actions.append("\(node.displayName) retried after an infrastructure problem (\(tries + 1) of \(delays.count))")
        }
        return (actions, nextDue)
    }
}
