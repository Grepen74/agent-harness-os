import Foundation

extension Reconciler {
    /// Whether the node waits because its implementer made no changes for the change review's findings.
    func isDisputingReviewFindings(_ node: NodeState) async -> Bool {
        guard node.flags[.needsInput] != nil else { return false }
        let records = await ledger.records(for: node.id)
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

    /// A scope request as a question for a person. Their answer reaches the implementer with the other answers.
    static func scopeQuestion(_ request: ScopeRequest, touches: [String]) -> AgentQuestion {
        let paths = request.paths.isEmpty ? "code" : request.paths.joined(separator: ", ")
        return AgentQuestion(question: "May the implementer change \(paths), outside what this work item touches " +
            "(\(touches.joined(separator: ", ")))? \(request.reason)")
    }

    func build(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .implementer)
        // Record the claim and intent first; only then start the agent.
        try await write(node.id, by: .reconciler, agentRunStarted(run, .implementer) + [.phaseChanged(to: .building)],
                        expecting: node.version)
        let directory = workspace.worktree(for: node.id)
        // What the run started from, so a run that runs out of time can tell whether it got any further.
        var carriedOver: String?
        var restoredAny = false
        // Set once the implementation is kept for broken-test routing, which then resets the worktree.
        var implementationKept = false
        do {
            // Start from the latest landing branch, so work landed since the tests were written (a dependency's,
            // say) is there to build on. On a conflict the branch stays as it was; the landing queue deals with it.
            _ = try await rebaseOntoMain(node, in: directory)
            // An earlier attempt that failed (ran out of time, say) left work to continue rather than redo.
            let unfinished = try await workspace.restoreUnfinishedWork(for: node.id, in: directory)
            carriedOver = Hashing.digest(ofFiles: unfinished, in: directory)
            restoredAny = !unfinished.isEmpty
            try await workspace.prepareBuild(in: directory)
            let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run), for: .implementer,
                                      unfinishedWork: unfinished)
            let implementationResult = try await withScratchDirectory(task.scratchDirectory) {
                try await recordingFallback(node.id, run: run) {
                    try await watchingUserGitState(node, run: run) {
                        try await team.implementer.implement(task)
                    }
                }
            }
            try Task.checkCancellation()
            let report = implementationResult as? AgentReport ?? AgentReport()
            var questions = policy.questions(in: report)
            if let scope = report.scopeRequest {
                // Never settled by a suggestion: only a person may widen what the work item touches. Stopping for a
                // person anyway, the questions it would have gone on with its own suggestions are theirs to see too.
                questions = report.questions.filter { !questions.contains($0) } + questions
                    + [Self.scopeQuestion(scope, touches: node.spec.touches)]
            }
            guard questions.isEmpty else {
                if report.scopeRequest == nil {
                    try await workspace.forgetUnfinishedWork(for: node.id)
                } else {
                    // The implementation may be right: the next run continues from it once a person has answered.
                    _ = try await keepUnfinishedWork(directory, of: node)
                }
                try await resetForRework(node, in: directory)
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
                try await workspace.forgetUnfinishedWork(for: node.id)
                // The implementation may be fine: the implementer continues from it once the test is settled.
                let kept: [String]
                do {
                    kept = try await workspace.keepImplementation(directory, for: node.id)
                } catch {
                    // Resetting now would lose the implementation: the worktree stays as it is, for a person.
                    let reason = "The implementer reported a broken test (\(brokenTest.testName): \(brokenTest.reason)), "
                        + "but its implementation couldn't be kept before sending the tests back (\(error)). The "
                        + "worktree is unchanged.\nCheck the repo, then add harness:retest (or comment and add harness:retry)."
                    try await write(node.id, by: .reconciler, [
                        .runFinished(run: run, outcome: "reported a broken test: \(brokenTest.testName)"),
                        .phaseChanged(to: .ready), .flagSet(.escalated, reason: reason),
                    ])
                    await tracker.comment(on: node.ticket, "⚠️ Needs a human: " + reason)
                    return "\(node.displayName) broken test \(brokenTest.testName) → Needs human (implementation not kept)"
                }
                implementationKept = true
                return try await routeBrokenTest(brokenTest, from: node, run: run, author: author, directory: directory,
                                                 keptImplementation: kept)
            }
            let commit = try await workspace.commitAll(
                in: directory,
                message: "\(node.spec.id): \(node.spec.title)",
                author: run
            )
            // Submitted (or nothing to submit): what an earlier attempt left is in the branch now or no longer needed.
            try await workspace.forgetUnfinishedWork(for: node.id)
            guard let commit else {
                if let findings = node.latestReviewFeedback, !node.reviewFeedbackAnswered, !node.landingReworkPending {
                    return try await disputeReviewFindings(findings, on: node, run: run, author: author)
                }
                if report.alreadySatisfied && !node.landingReworkPending {
                    // The tests' own commit is the candidate; the verifier decides whether they really pass.
                    let head = try await workspace.head(of: directory)
                    let files = try await workspace.changedFiles(in: directory)
                    try await write(node.id, by: author, [
                        .runFinished(run: run, outcome: "already satisfied; submitted the branch unchanged"),
                        .changeSubmitted(run: run, commit: head),
                        .actualChangedFilesRecorded(files: files), .phaseChanged(to: .checking)])
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
            let files = try await workspace.changedFiles(in: directory)
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "submitted"),
                .assumptionsReported(role: .implementer, assumptions: assumptions),
                .changeSubmitted(run: run, commit: commit),
                .actualChangedFilesRecorded(files: files),
                .phaseChanged(to: .checking),
            ])
            return "\(node.displayName) implemented by \(run) → Checking"
        } catch let error as UserGitStateChanged {
            // Not something another attempt fixes: a human checks what happened to their repo first.
            _ = try? await keepUnfinishedWork(directory, of: node)
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready),
                .flagSet(.escalated, reason: "\(error)")])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(error)\nWhen checked, add label harness:retry.")
            return "\(node.displayName) escalated: \(error)"
        } catch {
            let kept: [String]
            do {
                kept = try await keepUnfinishedWork(directory, of: node)
            } catch let keeping {
                // The next run would clean the worktree, and with it the only copy of this run's work.
                let reason = "Couldn't keep the failed run's unfinished work (\(keeping)). It is still uncommitted in " +
                    "\(directory.path). Run failure: \(error)"
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"),
                    .phaseChanged(to: .ready), .flagSet(.escalated, reason: reason)])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen checked, add label harness:retry.")
                return "\(node.displayName) escalated: \(reason)"
            }
            let outOfTime = (error as? AgentFailure)?.outOfTime == true
            if kept.isEmpty, restoredAny, !implementationKept {
                // It got any kept implementation back and undid all of it: that's not to come back either.
                let workspace = workspace, id = node.id
                _ = try? await Task { try await workspace.forgetUnfinishedWork(for: id) }.value
            }
            let fingerprint = kept.isEmpty ? "" : Hashing.digest(ofFiles: kept, in: directory)
            // Out of time but further along than it started: the next run continues, so this isn't a failed attempt.
            // A run that got no further counts; the run budget still caps how often it goes round.
            if outOfTime, !kept.isEmpty, let carriedOver, fingerprint != carriedOver {
                try await write(node.id, by: author, [.runFinished(run: run, outcome: "failed: \(error)"), .phaseChanged(to: .ready)])
                return "\(node.displayName) implementer ran out of time; will continue from its \(kept.count) unfinished files"
            }
            // Out of time, the work's fingerprint tells stalling ("the same failure twice") from progress in between.
            let summary = outOfTime
                ? "\(Self.firstLine(of: error)) (\(kept.isEmpty ? "no unfinished work" : "unfinished work \(fingerprint.prefix(8))"))"
                : "\(error)"
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: summary), .phaseChanged(to: .ready)])
            let retry = kept.isEmpty ? "will retry" : "will retry from its \(kept.count) unfinished files"
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) implementer failed (\(error)); \(retry)"
        }
    }

    /// Saves in a task of its own: a stopped run's task is cancelled, and its git commands would refuse to start.
    private func keepUnfinishedWork(_ directory: URL, of node: NodeState) async throws -> [String] {
        let workspace = workspace, id = node.id
        return try await Task { try await workspace.saveUnfinishedWork(directory, for: id) }.value
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
