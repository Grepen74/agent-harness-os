import Foundation

extension Reconciler {
    /// Fast feedback on the leaf's own branch: only its own acceptance tests (doc 08 §4, layer 2).
    func preCheck(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.displayName): nothing submitted" }
        let run = Self.newRunID()
        let directory = workspace.worktree(for: node.id)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)

        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: node.spec.testTarget)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: directory, only: node.spec.testTarget)
            }
        }
        if case .runnerCrash = output.failureKind {
            return try await recordRepeatedRunnerCrash(
                node,
                output: output,
                check: "own acceptance tests on branch",
                builtBy: submission.run,
                checkedBy: run,
                commit: submission.commit
            )
        }
        try Task.checkCancellation()
        let evidence = try makeEvidence(node, check: "own acceptance tests on branch", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: submission.commit,
                                        failureClassification: output.passed ? nil : .ownMistake)
        try await write(node.id, by: .agent(run: run, role: .verifier), [
            .evidenceRecorded(evidence), .runFinished(run: run, outcome: output.passed ? "passed" : "failed"),
            .phaseChanged(to: output.passed ? .landing : .ready)])
        if output.passed { return "\(node.displayName) pre-checked by \(run) → Landing queue" }
        await tracker.comment(on: node.ticket, "🔁 Pre-check failed; this is the agent's own mistake: \(output.summary)")
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed pre-check; will retry"
    }

    // MARK: Helpers

    func recordRepeatedRunnerCrash(
        _ node: NodeState,
        output: CheckOutput,
        check: String,
        builtBy: RunID,
        checkedBy: RunID,
        commit: String
    ) async throws -> String {
        let evidence = try makeEvidence(
            node,
            check: check,
            output: output,
            builtBy: builtBy,
            checkedBy: checkedBy,
            commit: commit,
            failureClassification: .runnerCrash
        )
        let reason = "Runner crash repeated after one retry: \(output.summary)"
        try await write(node.id, by: .agent(run: checkedBy, role: .verifier), [
            .evidenceRecorded(evidence),
            .runFinished(run: checkedBy, outcome: "runner crash"),
            .flagSet(.escalated, reason: reason),
        ])
        let tail = output.log.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(60)
            .joined(separator: "\n")
        await tracker.comment(on: node.ticket, """
            ⚠️ Needs a human: \(reason)
            Full stored log: \(evidence.artifactPath)

            <details>
            <summary>Last 60 runner log lines</summary>

            \(tail)
            </details>

            When the runner is available, add harness:retry.
            """)
        return "\(node.displayName) runner crash repeated → needs human"
    }

    func testsDigest(_ node: NodeState, in directory: URL) -> String {
        Hashing.digest(of: directory.appending(path: workspace.testFolder(for: node.spec)))
    }

    /// Acceptance tests are locked: the node's own must match their fingerprint, and the branch may not touch
    /// any other node's tests (the implementer must never "fix" a conflict by editing someone else's tests),
    /// nor any protected path (e.g. the agents' own instructions).
    func protectedTestsViolation(_ node: NodeState, in directory: URL) async throws -> String? {
        if testsDigest(node, in: directory) != node.testsDigest {
            return "Acceptance tests were changed after they were fixed (not allowed)"
        }
        let changed = try await workspace.changedFiles(in: directory)
        let own = workspace.testFolder(for: node.spec) + "/"
        let others = changed.filter { $0.hasPrefix(workspace.testArea) && !$0.hasPrefix(own) }
        if !others.isEmpty { return "Changed other nodes' tests (not allowed): \(others.joined(separator: ", "))" }
        let protected = policy.protectedPathViolations(changed)
        return protected.isEmpty ? nil : "Changed protected files (not allowed): \(protected.joined(separator: ", "))"
    }

    func makeEvidence(_ node: NodeState, check: String, output: CheckOutput, builtBy: RunID, checkedBy: RunID,
                              commit: String, failureClassification: FailureClassification? = nil) throws -> Evidence {
        let artifact = try artifacts.put(named: "\(node.id)-\(checkedBy).log", contents: Data(output.log.utf8))
        return Evidence(check: check, passed: output.passed, summary: output.summary, specHash: node.spec.specHash,
                        builtBy: builtBy, checkedBy: checkedBy, artifactPath: artifact.path, artifactSHA256: artifact.sha256,
                        commit: commit, failureClassification: failureClassification)
    }
}
