import Foundation

extension Reconciler {
    /// Whether the node waits because its implementer made no changes for the change review's findings.
    func isDisputingReviewFindings(_ node: NodeState) async -> Bool {
        guard node.flags[.needsInput] != nil else { return false }
        let records = await ledger.allRecords().filter { $0.event.node == node.id }
        guard let flag = records.last(where: {
            if case .flagSet(.needsInput, _) = $0.event.kind { return true }
            return false
        }) else { return false }
        for record in records.reversed() where record.position < flag.position {
            switch record.event.kind {
            case .runFinished(_, let outcome): return outcome == Self.unaddressedFindingsOutcome
            case .runStarted: return false
            default: continue
            }
        }
        return false
    }

    static let unaddressedFindingsOutcome = "made no changes for the review findings"

    func build(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .implementer)
        // Record the claim and intent first; only then start the agent.
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .implementer), .phaseChanged(to: .building)],
                        expecting: node.version)
        let directory = workspace.worktree(for: node.id)
        do {
            // Start from the latest landing branch, so work landed since the tests were written (a dependency's,
            // say) is there to build on. On a conflict the branch stays as it was; the landing queue deals with it.
            _ = try await workspace.rebaseOntoMain(directory)
            try await workspace.prepareBuild(in: directory)
            let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run), for: .implementer)
            let implementationResult = try await withScratchDirectory(task.scratchDirectory) {
                try await watchingUserGitState(node, run: run) {
                    try await team.implementer.implement(task)
                }
            }
            try Task.checkCancellation()
            let report = implementationResult as? AgentReport ?? AgentReport()
            let questions = policy.questions(in: report)
            guard questions.isEmpty else {
                try await workspace.resetForRework(directory)
                return try await raise(
                    questions,
                    on: node,
                    by: author,
                    run: run,
                    role: .implementer,
                    additionalKinds: [.phaseChanged(to: .ready)]
                )
            }
            await postProceedingOnSuggestions(report.questions, on: node.ticket)
            let assumptions = policy.assumptions(in: report)
            if let brokenTest = report.brokenTest {
                return try await routeBrokenTest(brokenTest, from: node, run: run, author: author, directory: directory)
            }
            guard let commit = try await workspace.commitAll(
                in: directory,
                message: "\(node.spec.id): \(node.spec.title)",
                author: run
            ) else {
                if let findings = node.latestReviewFeedback, !node.reviewFeedbackAnswered, !node.landingReworkPending {
                    return try await disputeReviewFindings(findings, on: node, run: run, author: author)
                }
                if report.alreadySatisfied && !node.landingReworkPending {
                    // The tests' own commit is the candidate; the verifier decides whether they really pass.
                    let head = try await workspace.head(of: directory)
                    try await write(node.id, by: author, [
                        .runFinished(run: run, outcome: "already satisfied; submitted the branch unchanged"),
                        .changeSubmitted(run: run, commit: head), .phaseChanged(to: .checking)])
                    return "\(node.ticket) already satisfied (\(run)) → Checking"
                }
                guard node.landingReworkPending else { throw AgentFailure("submitted no changes") }
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "submitted no changes; rerunning landing check"),
                    .landingRerunRequested(run: run),
                    .phaseChanged(to: .landing),
                ])
                return "\(node.displayName) submitted no changes after landing rework → Landing queue"
            }
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "submitted"),
                .assumptionsReported(role: .implementer, assumptions: assumptions),
                .changeSubmitted(run: run, commit: commit),
                .phaseChanged(to: .checking),
            ])
            return "\(node.displayName) implemented by \(run) → Checking"
        } catch let error as UserGitStateChanged {
            // Not something another attempt fixes: a human checks what happened to their repo first.
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready),
                .flagSet(.escalated, reason: "\(error)")])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(error)\nWhen checked, add label harness:retry.")
            return "\(node.displayName) escalated: \(error)"
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready)])
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) implementer failed (\(error)); will retry"
        }
    }

    /// The implementer changed nothing for the change review's findings. Submitting the same branch again would only
    /// repeat that review, so a person decides: the findings may be about the tests, or simply wrong.
    private func disputeReviewFindings(
        _ findings: String, on node: NodeState, run: RunID, author: Participant
    ) async throws -> String {
        let reason = """
            The implementer made no changes for the change review's findings:
            \(findings)
            Next: if they are about this ticket's acceptance tests, comment how to change them, then add \
            harness:retest. If the code should change, comment how, then add harness:retry. If the findings are \
            wrong, say so in a comment, then add harness:retry.
            """
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: Self.unaddressedFindingsOutcome),
            .phaseChanged(to: .ready),
            .flagSet(.needsInput, reason: reason),
        ])
        await tracker.comment(on: node.ticket, "\(Self.needsInputMarker): \(reason)")
        return "\(node.displayName) made no changes for the review findings → waiting for a person"
    }
}
