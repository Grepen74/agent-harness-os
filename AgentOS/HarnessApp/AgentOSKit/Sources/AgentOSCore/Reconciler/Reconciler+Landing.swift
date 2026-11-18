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
        if case .conflict(let files) = try await rebaseOntoMain(node, in: directory) {
            try await resetForRework(node, in: directory)
            let reason = "merge conflict in \(files.isEmpty ? "some files" : files.joined(separator: ", ")) with newer work on main"
            let predictions = PredictedPath.normalize(node.spec.predictedPaths)
            let additions = PredictedPath.normalize(files).filter { file in
                !predictions.contains { file == $0 || file.hasPrefix($0 + "/") }
            }
            var kinds: [EventKind] = []
            if !additions.isEmpty { kinds.append(.predictedPathsExpanded(files: additions)) }
            kinds += [.runFinished(run: run, outcome: "conflict"), .reworkNeeded(reason: reason), .phaseChanged(to: .ready)]
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "♻️ Rework: \(reason). The implementation is redone on the latest code; the tests are kept.")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) conflicted at landing → rework"
        }

        // 2. Re-check everything on top of the latest main.
        var output: CheckOutput
        // The rebase may have moved the lock on other work's tests.
        let rebased = await ledger.workingState().nodes[node.id] ?? node
        if let tampered = try await protectedTestsViolation(rebased, in: directory) {
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
        // The tests that failed twice in the full check but passed alone, with and without the change, and how
        // they were rerun.
        var failingOnlyUnderLoad: (tests: [String], rerun: String)?
        // The change's failures show only in the whole check, which passes on agentos/main: it disturbs them.
        var disturbs = false
        // Failures only in other suites may be unreliable tests, main's or the runner's problem, or a conflict.
        if !output.passed && !output.failingTargets.isEmpty && !output.failingTargets.contains(node.spec.testTarget) {
            let initial = output
            // The rerun and its diagnosis run with no other work on the machine: load may be what failed.
            quietLandings += 1
            defer { quietLandings -= 1 }
            await waitForOtherWork(than: node.id)
            try Task.checkCancellation()
            // First the whole check again, unchanged: passing it is as good as passing the first time.
            var again = await checks.runChecks(in: directory, only: nil)
            if case .runnerCrash = again.failureKind {
                again = await checks.runChecks(in: directory, only: nil)
            }
            var report = """
                Initial landing failure: \(initial.summary)
                Failing tests:
                \(Self.failureLines(in: initial))
                The whole check again with the change, with no other work running: \(again.summary)
                """
            var log = """
                Initial landing check:
                \(initial.log)
                The whole check again with the change, with no other work running:
                \(again.log)
                """
            var decisive = again
            var problem: String?
            if !again.passed && again.failureKind != .reportedFailure {
                problem = "The test runner didn't finish the rerun."
            } else if !again.passed && !again.failingTargets.isEmpty
                && !again.failingTargets.contains(node.spec.testTarget) {
                // Failed again: only the failing suites, alone. Passing alone doesn't prove the tests unreliable
                // (the change may cause interference under load), so this only decides who looks at it.
                let suites = initial.failingTargets.union(again.failingTargets).sorted()
                let how = checks.selectsSuites ? "alone" : "again (the repo's checks can't run one suite, so all tests)"
                let (alone, aloneRanNothing) = await runChecks(only: suites, in: directory)
                let (onMain, mainRanNothing) = await checkLatestMain(only: suites)
                report += """

                    \(suites.joined(separator: ", ")) rerun \(how):
                    With the change: \(alone.summary)
                    Without the change on latest agentos/main: \(onMain.summary)
                    """
                log += """

                    \(suites.joined(separator: ", ")) rerun \(how) with the change:
                    \(alone.log)
                    Without the change on latest agentos/main:
                    \(onMain.log)
                    """
                let missing = Array(Set(aloneRanNothing + mainRanNothing)).sorted()
                if !alone.passed && alone.failureKind != .reportedFailure
                    || !onMain.passed && onMain.failureKind != .reportedFailure {
                    problem = "The test runner didn't finish the rerun alone."
                } else if !missing.isEmpty {
                    problem = "Running only \(missing.joined(separator: ", ")) ran none of those tests; check test.only."
                } else if !onMain.passed {
                    problem = "These tests fail on latest agentos/main without the change too."
                } else if alone.passed && checks.selectsSuites {
                    // Passing alone both ways: does the whole check fail without the change too?
                    let mainFull = await checkLatestMainFully()
                    report += "\nThe whole check without the change on latest agentos/main: \(mainFull.summary)"
                    log += "\nThe whole check without the change on latest agentos/main:\n\(mainFull.log)"
                    if mainFull.passed {
                        disturbs = true
                        report += """

                            The change makes these tests fail in the whole check, with no other work running, though \
                            they pass alone and the whole check passes without it: it disturbs them (shared state, \
                            order, timing or load). Fix that in the change.
                            """
                    } else if mainFull.failureKind != .reportedFailure {
                        problem = "The test runner didn't finish the whole check on latest agentos/main."
                    } else {
                        let tests = initial.failingTests.union(again.failingTests)
                        failingOnlyUnderLoad = (tests.isEmpty ? suites : tests.sorted(), how)
                    }
                } else if alone.passed {
                    let tests = initial.failingTests.union(again.failingTests)
                    failingOnlyUnderLoad = (tests.isEmpty ? suites : tests.sorted(), how)
                } else {
                    decisive = alone
                }
            }
            diagnosis = report
            output = CheckOutput(
                passed: decisive.passed, summary: report, log: log,
                failingTargets: decisive.failingTargets, failureKind: decisive.failureKind
            )
            if let problem {
                let reason = """
                    Landing infrastructure problem: \(problem) No failed attempt counted.
                    \(report)
                    Fix agentos/main or the test runner, then add harness:retry.
                    """
                let diagnosticEvidence = try makeEvidence(
                    node, check: "landing failure diagnosis", output: CheckOutput(
                        passed: false, summary: reason, log: log
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
                await tracker.comment(on: node.ticket, """
                    Unreliable test: the landing check failed, then passed when run again in full with no other work running.
                    \(diagnosis)
                    """)
            }
            await tracker.comment(on: node.ticket, "🛬 Landed on main at \(main.prefix(8)) with all tests passing.")
            return "\(node.displayName) landed by \(run) → Proven"
        }

        // Which node's behaviour broke? Someone else's → two requirements may contradict (doc 08 §5).
        let broken = output.failingTargets.subtracting([node.spec.testTarget])
            .compactMap { target in state.nodes.values.first { $0.spec.testTarget == target && $0.phase == .proven } }
        if let diagnosis, let failingOnlyUnderLoad {
            let reason = """
                Unreliable tests or interference under load (not a requirements conflict): \
                \(failingOnlyUnderLoad.tests.joined(separator: ", ")) failed in the full landing check twice but \
                passed when rerun \(failingOnlyUnderLoad.rerun), with and without the change. No failed attempt \
                counted; the change hasn't landed.
                \(diagnosis)
                Next: make those tests reliable on agentos/main, or check whether this change slows or disturbs \
                them, then add harness:retry to check it again.
                """
            evidence.failureClassification = .unreliableTests
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .runFinished(run: run, outcome: "unreliable tests"),
                .flagSet(.escalated, reason: reason),
            ])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)")
            return "\(node.displayName) landing failed only under load → escalated"
        }
        var kinds: [EventKind] = [.evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready)]
        if let diagnosis, !disturbs, !broken.isEmpty && !output.failingTargets.contains(node.spec.testTarget)
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

    /// Runs each suite on its own (retrying a crashed runner once) and combines the results. Without a way to
    /// select a suite, that's one run of all tests.
    /// `ranNothing` names the selections whose output says they ran no test.
    private func runChecks(only suites: [String], in directory: URL) async -> (output: CheckOutput, ranNothing: [String]) {
        let selections: [String?] = checks.selectsSuites ? suites : [nil]
        var outputs: [CheckOutput] = []
        var ranNothing: [String] = []
        for suite in selections {
            var output = await checks.runChecks(in: directory, only: suite)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: directory, only: suite)
            }
            if output.passed && Self.ranNoTests(output) { ranNothing.append(suite ?? "all tests") }
            outputs.append(output)
        }
        guard outputs.count != 1 else { return (outputs[0], ranNothing) }
        return (CheckOutput(
            passed: outputs.allSatisfy(\.passed),
            summary: zip(suites, outputs).map { "\($0): \($1.summary)" }.joined(separator: "\n"),
            log: outputs.map(\.log).joined(separator: "\n"),
            failingTargets: outputs.reduce(into: []) { $0.formUnion($1.failingTargets) },
            failureKind: outputs.first { !$0.passed && $0.failureKind != .reportedFailure }?.failureKind ?? .reportedFailure
        ), ranNothing)
    }

    /// The log lines that report a failure, without "started" lines of tests whose names mention failing.
    static func failureLines(in output: CheckOutput) -> String {
        let lines = output.log.split(separator: "\n")
        let issues = lines.filter {
            $0.contains("recorded an issue") || $0.contains("error:") || ($0.contains("Test Case") && $0.contains("failed"))
        }
        let failures = issues.isEmpty ? lines.filter { line in
            !line.hasSuffix(" started.") && (output.failingTargets.contains { line.contains($0) }
                || line.localizedCaseInsensitiveContains("fail"))
        } : issues
        return failures.isEmpty ? output.log : failures.joined(separator: "\n")
    }

    /// Whether the output says no test ran: a selection that matches no test passes without running any. Swift
    /// Testing says "Test run with 0 tests", XCTest "Executed 0 tests". Output that says neither counts as run.
    static func ranNoTests(_ output: CheckOutput) -> Bool {
        let log = output.log
        if log.contains(/Test run with [1-9]/) || log.contains(/Executed [1-9]\d* tests?/) { return false }
        return log.contains("Test run with 0 tests") || log.contains("Executed 0 tests")
    }

    /// All checks on latest agentos/main, without the change. A main it can't check counts as a runner problem.
    private func checkLatestMainFully() async -> CheckOutput {
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
            return CheckOutput(passed: false, summary: "Could not check latest agentos/main: \(error)", log: "\(error)",
                               failureKind: .runnerCrash(signal: nil))
        }
    }

    private func checkLatestMain(only suites: [String]) async -> (output: CheckOutput, ranNothing: [String]) {
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
            let output = await runChecks(only: suites, in: snapshot)
            await workspace.removeSnapshot(snapshot)
            return output
        } catch {
            return (CheckOutput(
                passed: false, summary: "Could not check latest agentos/main: \(error)", log: "\(error)"
            ), [])
        }
    }
}
