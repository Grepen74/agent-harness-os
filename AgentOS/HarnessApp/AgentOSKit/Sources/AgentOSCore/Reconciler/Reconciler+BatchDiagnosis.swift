import Foundation

extension Reconciler {
    enum BatchCheckResult {
        case passed(CheckOutput, unreliable: Bool)
        case escalated
        case needsSplit(String, failingTargets: Set<String>)
    }

    static let unreliableBatchNotice = "Unreliable test: the landing check failed, then passed when run again in full with no other work running."

    /// Diagnosis checks the unchanged candidate before permitting attribution or splitting.
    func checkLandingBatch(_ batch: LandingBatch, nodes: [NodeState], run: RunID) async throws -> BatchCheckResult {
        var initial = await checks.runChecks(in: batch.directory, only: nil)
        var stage = "Initial full check"
        if case .runnerCrash = initial.failureKind {
            try await recordBatchResult(batch, run: run, passed: false, detail: "\(stage): \(initial.summary)")
            try Task.checkCancellation()
            initial = await checks.runChecks(in: batch.directory, only: nil)
            stage += " runner retry"
        }
        let needsDiagnosis = !initial.passed && initial.failureKind == .reportedFailure
        if needsDiagnosis { quietLandings += 1 }
        defer { if needsDiagnosis { quietLandings -= 1 } }
        try await recordBatchResult(batch, run: run, passed: initial.passed, detail: "\(stage): \(initial.summary)")
        try Task.checkCancellation()
        if case .runnerCrash = initial.failureKind {
            for node in nodes {
                guard let submission = node.lastSubmission else { throw AgentFailure("No submission for \(node.id).") }
                _ = try await recordRepeatedRunnerCrash(node, output: initial, check: batch.id,
                    builtBy: submission.run, checkedBy: run, commit: batch.candidateCommit)
            }
            return .escalated
        }
        if initial.passed { return .passed(initial, unreliable: false) }

        await waitForOtherWork(than: nodes[0].id)
        try Task.checkCancellation()
        let again = try await batchCheck(batch, in: batch.directory, only: nil, stage: "Quiet full rerun",
                                        run: run, recordFullCheck: true)
        var log = "Initial full check:\n\(initial.log)\nQuiet full rerun:\n\(again.log)"
        var diagnosis = "Initial full check failed: \(initial.summary)\n"
            + "Quiet full rerun \(again.passed ? "passed" : "failed"): \(again.summary)"
        if again.failureKind != .reportedFailure {
            return try await escalateBatchInfrastructure(batch, nodes: nodes, run: run,
                problem: "The test runner didn't finish the full rerun.", diagnosis: diagnosis, log: log)
        }
        if again.passed {
            return .passed(CheckOutput(passed: true, summary: Self.unreliableBatchNotice + "\n" + diagnosis,
                                       log: log, checks: again.checks),
                           unreliable: true)
        }

        let suites = initial.failingTargets.union(again.failingTargets).sorted()
        if suites.isEmpty {
            return try await escalateBatchInfrastructure(batch, nodes: nodes, run: run,
                problem: "The full checks failed without identifying the failing suites; isolated diagnosis cannot run.",
                diagnosis: diagnosis, log: log)
        }
        let candidate = try await batchSelections(batch, suites: suites, in: batch.directory, stage: "Batch alone", run: run)
        log += "\nBatch alone:\n\(candidate.output.log)"
        diagnosis += "\nBatch alone: \(candidate.output.summary)"
        if let problem = candidate.problem {
            return try await escalateBatchInfrastructure(batch, nodes: nodes, run: run,
                problem: problem, diagnosis: diagnosis, log: log)
        }
        let baseline = try await batchBaseline(batch, for: nodes[0].id, suites: suites, run: run)
        log += "\nWithout the batch on latest \(batch.branch):\n\(baseline.output.log)"
        diagnosis += "\nWithout the batch on latest \(batch.branch): \(baseline.output.summary)"
        if let problem = baseline.problem {
            return try await escalateBatchInfrastructure(batch, nodes: nodes, run: run,
                problem: problem, diagnosis: diagnosis, log: log)
        }
        if !baseline.output.passed {
            return try await escalateBatchInfrastructure(batch, nodes: nodes, run: run,
                problem: "These tests fail on latest \(batch.branch) without the batch too.",
                diagnosis: diagnosis, log: log)
        }
        return .needsSplit("Batch diagnosis: \(batch.id) needs split.\n\(diagnosis)",
                           failingTargets: candidate.output.passed ? [] : candidate.output.failingTargets)
    }

    private func batchCheck(_ batch: LandingBatch, in directory: URL, only selection: String?,
                            stage: String, run: RunID, recordFullCheck: Bool = false) async throws -> CheckOutput {
        var output = await checks.runChecks(in: directory, only: selection)
        if recordFullCheck {
            try await recordBatchResult(batch, run: run, passed: output.passed,
                                        detail: "\(stage): \(output.summary)")
        }
        if case .runnerCrash = output.failureKind {
            try Task.checkCancellation()
            let retry = await checks.runChecks(in: directory, only: selection)
            if recordFullCheck {
                try await recordBatchResult(batch, run: run, passed: retry.passed,
                                            detail: "\(stage) runner retry: \(retry.summary)")
            }
            output = CheckOutput(passed: retry.passed,
                summary: "\(output.summary)\nRunner retry: \(retry.summary)",
                log: "\(output.log)\nRunner retry:\n\(retry.log)",
                failingTargets: retry.failingTargets, failureKind: retry.failureKind, checks: retry.checks)
        }
        try Task.checkCancellation()
        return output
    }

    private func batchSelections(_ batch: LandingBatch, suites: [String], in directory: URL,
                                 stage: String, run: RunID) async throws -> (output: CheckOutput, problem: String?) {
        let selections: [String?] = checks.selectsSuites ? suites : [nil]
        var outputs: [CheckOutput] = []
        var problem: String?
        for selection in selections {
            let output = try await batchCheck(batch, in: directory, only: selection, stage: stage, run: run)
            outputs.append(output)
            if output.failureKind != .reportedFailure {
                problem = "The test runner didn't finish \(stage) (\(selection ?? "all tests"))."
            } else if Self.ranNoTests(output) {
                problem = "Running only \(selection ?? "all tests") ran none of those tests; check test.only."
            }
        }
        return (CheckOutput(
            passed: outputs.allSatisfy(\.passed),
            summary: zip(selections, outputs).map {
                "\($0 ?? "all tests") \($1.passed ? "passed" : "failed"): \($1.summary)"
            }.joined(separator: "\n"),
            log: outputs.map(\.log).joined(separator: "\n"),
            failingTargets: outputs.reduce(into: []) { $0.formUnion($1.failingTargets) }
        ), problem)
    }

    private func batchBaseline(_ batch: LandingBatch, for node: NodeID, suites: [String],
                               run: RunID) async throws -> (output: CheckOutput, problem: String?) {
        let snapshot: URL
        do {
            guard let created = try await workspace.createSnapshot(for: node) else {
                throw AgentFailure("Workspace cannot create a latest \(batch.branch) snapshot.")
            }
            snapshot = created
        } catch {
            try Task.checkCancellation()
            let reason = "The test runner could not check latest \(batch.branch) without the batch: \(error)"
            return (CheckOutput(passed: false, summary: reason, log: reason), reason)
        }
        do { try await workspace.prepareBuild(in: snapshot) }
        catch {
            await workspace.removeSnapshot(snapshot)
            try Task.checkCancellation()
            let reason = "The test runner could not prepare latest \(batch.branch) without the batch: \(error)"
            return (CheckOutput(passed: false, summary: reason, log: reason), reason)
        }
        do {
            let result = try await batchSelections(batch, suites: suites, in: snapshot, stage: "Without batch alone", run: run)
            await workspace.removeSnapshot(snapshot)
            return result
        } catch {
            await workspace.removeSnapshot(snapshot)
            throw error
        }
    }

    private func escalateBatchInfrastructure(_ batch: LandingBatch, nodes: [NodeState], run: RunID,
                                             problem: String, diagnosis: String, log: String) async throws -> BatchCheckResult {
        let reason = "Landing infrastructure problem: \(problem) Batch \(batch.id). No failed attempt counted. "
            + "Fix \(batch.branch) or the test runner, then add harness:retry."
        for node in nodes {
            guard let submission = node.lastSubmission else { throw AgentFailure("No submission for \(node.id).") }
            let evidence = try makeEvidence(node, check: "\(batch.id) landing failure diagnosis",
                output: CheckOutput(passed: false, summary: reason + "\n" + diagnosis, log: log), builtBy: submission.run,
                checkedBy: run, commit: batch.candidateCommit, failureClassification: .landingInfrastructure)
            try await write(node.id, by: .agent(run: run, role: .verifier), [
                .evidenceRecorded(evidence), .runFinished(run: run, outcome: "landing infrastructure problem"),
                .flagSet(.escalated, reason: reason),
            ])
            await tracker.comment(on: node.ticket, reason)
        }
        return .escalated
    }

    private func recordBatchResult(_ batch: LandingBatch, run: RunID, passed: Bool, detail: String) async throws {
        try await write(nil, by: .agent(run: run, role: .verifier), [
            .landingBatchChecked(LandingBatchCheck(name: batch.id, branch: batch.branch,
                nodes: batch.members.map(\.node), candidateCommit: batch.candidateCommit,
                passed: passed, run: run, detail: detail)),
        ])
    }

    func batchLandingEvents(_ batch: LandingBatch, nodes: [NodeState], output: CheckOutput,
                            run: RunID) throws -> [LedgerEvent] {
        var events: [LedgerEvent] = []
        for member in batch.members {
            guard let node = nodes.first(where: { $0.id == member.node }),
                  let submission = node.lastSubmission else {
                throw AgentFailure("The batch member \(member.node) has no submitted change.")
            }
            let evidence = try makeEvidence(node, check: batch.id, output: output, builtBy: submission.run,
                                            checkedBy: run, commit: batch.candidateCommit)
            events += [.evidenceRecorded(evidence), .landed(commit: member.commit),
                       .runFinished(run: run, outcome: "landed"), .phaseChanged(to: .proven)]
                .map { LedgerEvent(node: node.id, by: .agent(run: run, role: .verifier), kind: $0, at: now()) }
        }
        return events
    }

    func recordBatchLanded(_ batch: LandingBatch, nodes: [NodeState], events: [LedgerEvent],
                           unreliable: Bool) async throws {
        try await ledger.append(events)
        for member in batch.members {
            guard let node = nodes.first(where: { $0.id == member.node }) else { continue }
            try? await workspace.removeWorktree(for: node.id)
            if unreliable { await tracker.comment(on: node.ticket, Self.unreliableBatchNotice + "\nBatch \(batch.id).") }
            await tracker.comment(on: node.ticket,
                "🛬 Landed on \(batch.branch) at \(member.commit.prefix(8)) with all tests passing. \(batch.id).")
        }
    }
}
