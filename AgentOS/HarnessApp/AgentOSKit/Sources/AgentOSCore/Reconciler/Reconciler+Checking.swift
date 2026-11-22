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

    /// Moves a leaf onto the latest landing branch. Work landed there may have changed other work's tests the leaf
    /// updated as well: their lock moves with them.
    func rebaseOntoMain(_ node: NodeState, in directory: URL) async throws -> RebaseResult {
        try await renewingOtherTestsLock(node, in: directory) { try await workspace.rebaseOntoMain(directory) }
    }

    /// Starts the implementation over from the leaf's tests on the latest landing branch, moving the lock as above.
    func resetForRework(_ node: NodeState, in directory: URL) async throws {
        try await renewingOtherTestsLock(node, in: directory) { try await workspace.resetForRework(directory) }
    }

    private func renewingOtherTestsLock<T>(_ node: NodeState, in directory: URL,
                                           _ move: () async throws -> T) async throws -> T {
        let current = await ledger.workingState().nodes[node.id] ?? node
        // The move throws uncommitted changes away first, so they don't count.
        try await workspace.discardChanges(keeping: [], in: directory)
        let intact = current.updatedOtherTestsIntact(in: directory)
        let result = try await move()
        if let renewal = current.renewedOtherTestsLock(in: directory, wasIntact: intact) {
            try await write(node.id, by: .reconciler, [renewal])
        }
        return result
    }

    func testsDigest(_ node: NodeState, in directory: URL) -> String {
        Hashing.digest(of: directory.appending(path: workspace.testFolder(for: node.spec)))
    }

    /// Acceptance tests are locked: the node's own must match their fingerprint, and the branch may not touch
    /// any other node's tests (the implementer must never "fix" a conflict by editing someone else's tests),
    /// nor any protected path (e.g. the agents' own instructions). The only exception: other work's tests the
    /// test author updated with the acceptance tests, locked by their own fingerprint.
    func protectedTestsViolation(_ node: NodeState, in directory: URL,
                                 changedFiles: [String]? = nil) async throws -> String? {
        if testsDigest(node, in: directory) != node.testsDigest {
            return "Acceptance tests were changed after they were fixed (not allowed)"
        }
        if !node.updatedOtherTests.isEmpty,
           Hashing.digest(ofFiles: node.updatedOtherTests, in: directory) != node.updatedOtherTestsDigest {
            return "Other work's tests the acceptance tests updated were changed afterwards (not allowed): "
                + node.updatedOtherTests.joined(separator: ", ")
        }
        let changed: [String]
        if let changedFiles { changed = changedFiles }
        else { changed = try await workspace.changedFiles(in: directory) }
        let own = workspace.testFolder(for: node.spec) + "/"
        let others = changed.filter {
            workspace.isInUpdatableTestArea($0) && !$0.hasPrefix(own) && !node.updatedOtherTests.contains($0)
        }
        if !others.isEmpty { return "Changed other nodes' tests (not allowed): \(others.joined(separator: ", "))" }
        let protected = policy.protectedPathViolations(changed)
        return protected.isEmpty ? nil : "Changed protected files (not allowed): \(protected.joined(separator: ", "))"
    }

    func makeEvidence(_ node: NodeState, check: String, output: CheckOutput, builtBy: RunID, checkedBy: RunID,
                              commit: String, failureClassification: FailureClassification? = nil) throws -> Evidence {
        let artifact = try artifacts.put(named: "\(node.id)-\(checkedBy).log", contents: Data(output.log.utf8))
        return Evidence(check: check, passed: output.passed, summary: output.summary, specHash: node.spec.specHash,
                        builtBy: builtBy, checkedBy: checkedBy, artifactPath: artifact.path, artifactSHA256: artifact.sha256,
                        commit: commit, failureClassification: failureClassification,
                        details: output.failingTests.isEmpty ? nil : output.failingTests.sorted().joined(separator: "\n"),
                        checks: output.checks.isEmpty ? nil : output.checks)
    }
}

public extension NodeState {
    /// Whether other work's tests this node's acceptance tests updated are as they were locked.
    func updatedOtherTestsIntact(in directory: URL) -> Bool {
        updatedOtherTests.isEmpty || Hashing.digest(ofFiles: updatedOtherTests, in: directory) == updatedOtherTestsDigest
    }

    /// After the harness moved the leaf onto a newer landing branch: the new lock when that changed those tests,
    /// and only when they were intact before, so nothing an agent changed is ever accepted.
    func renewedOtherTestsLock(in directory: URL, wasIntact: Bool) -> EventKind? {
        guard wasIntact, !updatedOtherTests.isEmpty else { return nil }
        let digest = Hashing.digest(ofFiles: updatedOtherTests, in: directory)
        return digest == updatedOtherTestsDigest ? nil : .otherTestsUpdated(files: updatedOtherTests, digest: digest)
    }
}
