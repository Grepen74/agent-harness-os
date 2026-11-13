extension Reconciler {
    /// Only eligible proposals consume the check budget; questions still follow the usual intake path.
    func checkedBreakdown(_ initial: BreakdownRequest) async throws -> Breakdown {
        var request = initial
        let ticket = initial.identity.ticketKey
        for attempt in 0...1 {
            try Task.checkCancellation()
            let breakdown = try await team.decomposer.proposeChildren(request)
            try Task.checkCancellation()
            guard policy.questions(in: breakdown.report, role: .decomposer).isEmpty else { return breakdown }

            let check = BreakdownCheckFeedback(
                proposal: breakdown.children, findings: BreakdownChecker.check(breakdown.children))
            let node = await ledger.workingState().node(forTicket: ticket)?.id
            let retry = attempt == 0 && !check.findings.isEmpty
            var events: [EventKind] = [.breakdownChecked(ticket: ticket, check: check)]
            if retry { events.append(.breakdownRetryRequested(ticket: ticket, feedback: check)) }
            try await ledger.append(events.map { LedgerEvent(node: node, by: .reconciler, kind: $0) })

            let outcome = check.findings.isEmpty ? "no findings." :
                "advisory findings:\n\n" + check.findings.map(\.explanation).joined(separator: "\n\n")
            let next: String
            if retry {
                next = "Retrying the decomposer once with this proposal and its structured findings."
            } else if !check.findings.isEmpty {
                let correction = node == nil
                    ? "Comment with corrections or edit the ticket, then add harness:preview."
                    : "Comment with corrections, then add harness:replan."
                next = "You can approve anyway despite these warnings with harness:go. " + correction
                    + " Warnings do not open or revoke gates and do not stop already-authorized work."
            } else {
                next = "The proposal can proceed under the existing approvals."
            }
            await tracker.comment(on: ticket,
                "\(attempt == 0 ? "Initial" : "Second") breakdown check: \(outcome)\n\n\(next)")
            guard retry else { return breakdown }
            request = BreakdownRequest(
                spec: initial.spec, existingComponents: initial.existingComponents,
                clarifications: initial.clarifications, guesswork: initial.guesswork, log: initial.log,
                codebase: initial.codebase, ticketKey: ticket, agentContext: initial.agentContext,
                checkerFeedback: [check])
        }
        preconditionFailure("The second checked proposal always returns")
    }
}
