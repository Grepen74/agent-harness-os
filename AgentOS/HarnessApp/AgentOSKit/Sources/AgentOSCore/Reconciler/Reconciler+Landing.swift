import Foundation

extension Reconciler {
    /// The landing queue (doc 08 §4, layer 3): rebase onto the latest main, run ALL tests (own + every proven
    /// node's), and only then merge. A leaf is proven only once it has landed.
    func land(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.displayName): nothing to land" }
        let run = Self.newRunID()
        let checker = Participant.agent(run: run, role: .verifier)
        let directory = workspace.worktree(for: node.id)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)

        // 1. Textual conflict → rework from the latest main. Not the agent's fault, so not a failed attempt.
        if case .conflict(let files) = try await workspace.rebaseOntoMain(directory) {
            try await workspace.resetForRework(directory)
            let reason = "merge conflict in \(files.isEmpty ? "some files" : files.joined(separator: ", ")) with newer work on main"
            try await write(node.id, by: checker, [
                .runFinished(run: run, outcome: "conflict"), .reworkNeeded(reason: reason), .phaseChanged(to: .ready)])
            await tracker.comment(on: node.ticket, "♻️ Rework: \(reason). The implementation is redone on the latest code; the tests are kept.")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) conflicted at landing → rework"
        }

        // 2. Re-check everything on top of the latest main.
        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: nil)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: directory, only: nil)
            }
        }
        let candidate = try await workspace.head(of: directory)
        if case .runnerCrash = output.failureKind {
            return try await recordRepeatedRunnerCrash(
                node,
                output: output,
                check: "all tests on latest main (landing)",
                builtBy: submission.run,
                checkedBy: run,
                commit: candidate
            )
        }
        let state = await ledger.workingState()
        let provenTargets = Set(state.nodes.values.filter { $0.phase == .proven }.map(\.spec.testTarget))
        var diagnosis: String?
        if !output.passed && !output.failingTargets.isEmpty
            && !output.failingTargets.contains(node.spec.testTarget)
            && output.failingTargets.isSubset(of: provenTargets) {
            let initial = output
            let baseline = await checkLatestMain()
            var repeated = await checks.runChecks(in: directory, only: nil)
            if case .runnerCrash = repeated.failureKind {
                repeated = await checks.runChecks(in: directory, only: nil)
            }
            let failures = initial.log.split(separator: "\n").filter { line in
                initial.failingTargets.contains { line.contains($0) }
                    || line.localizedCaseInsensitiveContains("fail")
                    || line.contains("recorded an issue") || line.contains("error:")
            }.joined(separator: "\n")
            let report = """
                Initial landing failure: \(initial.summary)
                Failing tests:
                \(failures.isEmpty ? initial.log : failures)
                Without the change on latest agentos/main: \(baseline.summary)
                With the change again: \(repeated.summary)
                """
            diagnosis = report
            output = CheckOutput(
                passed: repeated.passed,
                summary: report,
                log: """
                    Initial landing check:
                    \(initial.log)
                    Without the change on latest agentos/main:
                    \(baseline.log)
                    With the change again:
                    \(repeated.log)
                    """,
                failingTargets: repeated.failingTargets,
                failureKind: repeated.failureKind
            )
            if !baseline.passed || repeated.failureKind != .reportedFailure {
                let reason = """
                    Landing infrastructure problem on agentos/main; no failed attempt counted.
                    \(report)
                    Fix the baseline or test runner, then add harness:retry.
                    """
                let diagnosticEvidence = try makeEvidence(
                    node, check: "landing failure diagnosis", output: CheckOutput(
                        passed: false, summary: reason, log: output.log
                    ),
                    builtBy: submission.run, checkedBy: run, commit: candidate,
                    failureClassification: .landingInfrastructure
                )
                try await write(node.id, by: checker, [
                    .evidenceRecorded(diagnosticEvidence),
                    .runFinished(run: run, outcome: "landing infrastructure problem"),
                    .flagSet(.escalated, reason: reason),
                ])
                await tracker.comment(on: node.ticket, reason)
                return "\(node.displayName) landing infrastructure problem → needs human"
            }
        }
        var evidence = try makeEvidence(node, check: "all tests on latest main (landing)", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: candidate)

        // 3. Merge.
        if output.passed {
            if team.reviewer != nil, policy.review.requiresReview {
                let context = try await workspace.reviewContext(in: directory, against: policy.review.baseBranch)
                let level = policy.review.level(for: node.spec.touches + context.changedFiles)
                if level != .none {
                    let current = await ledger.workingState().nodes[node.id] ?? node
                    let prior = current.reviews.last { $0.stage == .change }
                    let result: ReviewResult
                    if let prior, prior.commit == context.commit, prior.result.passed {
                        result = prior.result
                    } else {
                        result = try await review(node, stage: .change, context: context, in: directory, run: run)
                    }
                    if !result.passed {
                        try await write(node.id, by: checker, [.evidenceRecorded(evidence)])
                        return try await returnReviewFindings(result, stage: .change, node: node, run: run, directory: directory)
                    }
                    if level == .agentAndHuman, current.approvedReviewCommit != context.commit {
                        try await write(node.id, by: checker, [
                            .evidenceRecorded(evidence), .runFinished(run: run, outcome: "waiting for human review"),
                            .humanReviewRequested(commit: context.commit),
                        ])
                        let screenshots = context.uiEvidence.map {
                            "\nBefore screenshot: \($0.beforeScreenshot ?? "missing")\nAfter screenshot: \($0.afterScreenshot ?? "missing")"
                        } ?? ""
                        await tracker.comment(on: node.ticket, """
                            Agent review passed for \(context.commit).
                            \(result.findings.joined(separator: "\n"))\(screenshots)
                            Review the change, then add harness:build to approve this candidate.
                            """)
                        return "\(node.displayName) → In review"
                    }
                }
            }
            try Task.checkCancellation()
            let main = try await workspace.landOnMain(node.id)
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .landed(commit: main), .runFinished(run: run, outcome: "landed"),
                .phaseChanged(to: .proven)])
            try? await workspace.removeWorktree(for: node.id)
            if let diagnosis {
                await tracker.comment(on: node.ticket, "Unreliable test in the initial landing check; both reruns passed.\n\(diagnosis)")
            }
            await tracker.comment(on: node.ticket, "🛬 Landed on main at \(main.prefix(8)) with all tests passing.")
            return "\(node.displayName) landed by \(run) → Proven"
        }

        // Which node's behaviour broke? Someone else's → two requirements may contradict (doc 08 §5).
        let broken = output.failingTargets.subtracting([node.spec.testTarget])
            .compactMap { target in state.nodes.values.first { $0.spec.testTarget == target && $0.phase == .proven } }
        var kinds: [EventKind] = [.evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready)]
        if let diagnosis, !broken.isEmpty && !output.failingTargets.contains(node.spec.testTarget)
            && output.failingTargets.isSubset(of: provenTargets) {
            let names = broken.map { "\($0.displayName) (\($0.spec.title))" }.joined(separator: ", ")
            let reason = """
                Requirements conflict: this change breaks proven behaviour of \(names). A human must decide which requirement wins.
                \(diagnosis)
                Next: comment with guidance, then add harness:retry.
                """
            kinds.append(.flagSet(.escalated, reason: reason))
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)")
            for other in broken {
                await tracker.comment(on: other.ticket, "ℹ️ \(node.displayName) (\(node.spec.title)) contradicts this ticket's acceptance criteria. Escalated there.")
            }
            return "\(node.displayName) breaks \(broken.map(\.displayName).joined(separator: ", ")) → requirements conflict, escalated"
        }
        evidence.failureClassification = .ownMistake
        let reranSameCandidate = node.evidence.last?.commit == candidate
        if node.landingRerunPending && reranSameCandidate {
            let reason = "Landing rerun failed; this is the agent's own mistake: \(output.summary)"
            kinds[0] = .landingReworkNeeded(evidence)
            kinds.append(.attemptFailed(summary: reason))
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "🔁 \(reason)")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed landing rerun; will retry"
        }
        let alreadyPassedOwnCheck = node.evidence.contains {
            $0.passed && $0.check == "own acceptance tests on branch" && $0.commit == submission.commit
        }
        if !alreadyPassedOwnCheck {
            let reason = "Landing check failed; this is the agent's own mistake: \(output.summary)"
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready),
            ])
            await tracker.comment(on: node.ticket, "🔁 \(reason)")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed at landing; will retry"
        }
        kinds[0] = .landingReworkNeeded(evidence)
        try await write(node.id, by: checker, kinds)
        let cause = node.landingRerunPending ? " after main moved" : ""
        await tracker.comment(
            on: node.ticket,
            "♻️ Landing check failed\(cause); this is the agent's own mistake: \(output.summary). "
                + "The implementer will rework the candidate."
        )
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed at landing; will retry"
    }

    private func checkLatestMain() async -> CheckOutput {
        do {
            guard let snapshot = try await workspace.createSnapshot() else {
                throw AgentFailure("Workspace cannot create a latest agentos/main snapshot")
            }
            do {
                try await workspace.prepareBuild(in: snapshot)
            } catch {
                await workspace.removeSnapshot(snapshot)
                throw error
            }
            var output = await checks.runChecks(in: snapshot, only: nil)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: snapshot, only: nil)
            }
            await workspace.removeSnapshot(snapshot)
            return output
        } catch {
            return CheckOutput(
                passed: false, summary: "Could not check latest agentos/main: \(error)", log: "\(error)"
            )
        }
    }
}
