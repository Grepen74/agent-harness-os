import Foundation

extension Reconciler {
    func verifyCompletedRequirements(_ report: inout RoundReport) async throws {
        guard !isVerifyingRequirements else { return }
        isVerifyingRequirements = true
        defer { isVerifyingRequirements = false }
        if slotsInUse == 0 { try await publishRequirements() }
        let state = await ledger.workingState()
        let roots = state.roots.enumerated().sorted { lhs, rhs in
            switch (lhs.element.pullRequestNumber, rhs.element.pullRequestNumber) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        for root in roots where !root.ticketClosed && root.phase == .proven {
            guard shutdownReason == nil, !Task.isCancelled else { break }
            guard !root.requirementMerged, root.pullRequestState != .closed,
                  root.pullRequestNumber == nil || (policy.pullRequests && publisher != nil) else { continue }
            // Observed PRs in old ledgers have no harness-owned published tip to reverify.
            guard root.pullRequestNumber == nil || root.publishedCommit != nil ||
                  root.requirementVerificationRetryPending else { continue }
            let leaves = state.requirementLeaves(for: root.id)
            guard !leaves.isEmpty, leaves.allSatisfy({ $0.phase == .proven }),
                  !requirementIsHeld(root, in: state) else { continue }
            // Already in main, for example a requirement finished before requirement branches existed: main's
            // baseline checks it, so final verification would only repeat that and wait for a person on a failure.
            if root.pullRequestNumber == nil, root.requirementVerification?.passed != true,
               (try? await workspace.requirementIsMerged(root.identity)) == true {
                let branch = root.requirementBranch ?? "agentos/\(root.ticket)"
                let tip = try await requirementBranches?.tip(of: branch)
                try await write(root.id, by: .reconciler, [
                    .requirementMerged(commit: tip ?? root.requirementBranchObservation?.tip ?? root.landedCommit ?? "unknown"),
                ])
                report.actions.append("\(root.displayName): already in main, no final verification needed")
                continue
            }
            var unverifiedTip = false
            if policy.pullRequests, publisher != nil,
               root.publicationFailure == nil || root.publicationRetryPending,
               root.requirementVerificationStarted,
               let tip = try await requirementTip(root) {
                let records = await ledger.records(for: root.id)
                unverifiedTip = !records.contains {
                    if case .requirementVerificationFinished(let evidence) = $0.event.kind {
                        return evidence.commit == tip
                    }
                    return false
                }
            }
            // The root's own step (the one that marked it proven, still posting its comment) must end first: its
            // finish closes whatever run the root has open, and would close this verification's.
            if tasks[root.id] == nil,
               !root.requirementVerificationStarted || root.requirementVerificationRetryPending || unverifiedTip {
                report.actions.append("\(root.displayName): \(try await verifyRequirement(root))")
            }
            let current = await ledger.workingState().nodes[root.id]
            if let current, let verification = current.requirementVerification, verification.passed,
               !current.requirementMerged,
               try await workspace.requirementIsMerged(current.identity) {
                try await write(root.id, by: .reconciler, [
                    .requirementMerged(commit: verification.commit),
                ])
                report.actions.append("\(root.displayName): merged into main")
            }
        }
        // A push changes origin's tracking ref. Do not make an agent's git-state watch
        // attribute that harness-owned change to the agent.
        if slotsInUse == 0 { try await publishRequirements() }
    }

    /// Runs as the root's owned task, like a leaf's step, so Stop and shutdown can cancel it. Returns the action.
    private func verifyRequirement(_ root: NodeState) async throws -> String {
        let run = Self.newRunID()
        // A run, so the work pane lists the check as running, and a restart closes it as abandoned.
        try await write(root.id, by: .reconciler, [.requirementVerificationStarted, .runStarted(run: run, role: .verifier)])
        let task = Task<String?, Never> {
            var failure: String?
            do { try await self.checkRequirement(root, run: run) } catch { failure = "\(error)" }
            return await self.finishUnfinishedVerification(of: root.id, run: run, failure: failure)
        }
        tasks[root.id] = task
        let result = await task.value
        tasks[root.id] = nil
        return result ?? "final verification completed"
    }

    /// Every exit after the start, whether a stop, a shutdown or an error, closes the run, so it never shows as running
    /// until a restart. Written directly: the task may be cancelled. Without a result, the requirement shows as
    /// interrupted and waits for harness:retry.
    private func finishUnfinishedVerification(of id: NodeID, run: RunID, failure: String?) async -> String? {
        defer {
            if ownedRuns[id] == run { ownedRuns[id] = nil }
            stopReasons[run] = nil
        }
        guard await ledger.workingState().nodes[id]?.activeRun?.run == run else { return nil }
        let outcome = stopReasons[run] ?? shutdownReason.map { "stopped: \($0)" }
            ?? "failed: \(failure ?? "ended without recording a finish")"
        do {
            try await ledger.append([LedgerEvent(node: id, by: .reconciler, kind: .runFinished(run: run, outcome: outcome))])
            await projectStatus(of: id)
            return "final verification \(outcome)"
        } catch {
            return "⚠️ couldn't finish final verification \(run): \(error)"
        }
    }

    private func checkRequirement(_ root: NodeState, run: RunID) async throws {
        var directory: URL?
        var commit = root.requirementBranchObservation?.tip ?? root.landedCommit ?? "unavailable"
        let output: CheckOutput
        do {
            let checkout = try await workspace.requirementWorktree(for: root.identity)
            directory = checkout
            commit = try await workspace.head(of: checkout)
            if policy.pullRequests {
                try await publisher?.verificationStarted(requirement: root.identity, commit: commit)
            }
            try await workspace.prepareBuild(in: checkout)
            output = await checks.runChecks(in: checkout, only: nil)
        } catch {
            let message = "Final verification could not run: \(error)"
            output = CheckOutput(passed: false, summary: message, log: message)
        }
        if let directory { await workspace.removeSnapshot(directory) }
        let evidence = try makeEvidence(
            root, check: "final requirement verification", output: output,
            builtBy: root.lastSubmission?.run ?? "requirement", checkedBy: run, commit: commit)
        try await write(root.id, by: .agent(run: run, role: .verifier), [
            .requirementVerificationFinished(evidence), .evidenceRecorded(evidence),
            .runFinished(run: run, outcome: output.passed ? "passed" : "failed"),
        ])
        if policy.pullRequests {
            try await publisher?.verificationFinished(requirement: root.identity, commit: commit)
        }
        if output.passed {
            await tracker.comment(on: root.ticket,
                "Final verification passed at \(commit). Evidence: \(evidence.artifactPath). " +
                (policy.pullRequests
                    ? "The harness will publish agentos/\(root.ticket) for a person to review and merge into main."
                    : "In review: a person must merge agentos/\(root.ticket) into main."))
        } else {
            await tracker.comment(on: root.ticket, """
                Final verification failed at \(commit): \(output.summary)
                No agent rework will start. Fix the problem, then add harness:retry to run final verification again.
                Full output: \(evidence.artifactPath) (SHA-256 \(evidence.artifactSHA256))

                \(output.log)
                """)
        }
    }

    private func publishRequirements() async throws {
        guard policy.pullRequests, let publisher else { return }
        let state = await ledger.workingState()
        for root in state.roots where !root.ticketClosed && !root.requirementMerged {
            guard root.pullRequestState != .closed || root.publicationRetryPending else { continue }
            // An old ledger may know the PR but not the tip it published. Observing it
            // is not permission to republish; an explicit retry can recover that tip.
            guard root.pullRequestNumber == nil || root.publishedCommit != nil || root.publicationRetryPending else { continue }
            guard !requirementIsHeld(root, in: state),
                  !state.lineage(of: root.id).contains(where: { !$0.flags.isEmpty }),
                  root.publicationFailure == nil || root.publicationRetryPending else { continue }
            guard root.requirementVerification?.passed == true || root.pullRequestNumber != nil else { continue }
            let branch = root.requirementBranch ?? "agentos/\(root.ticket)"
            guard let tip = try await requirementTip(root) else { continue }
            guard root.publishedCommit != tip || root.publicationRetryPending else { continue }
            if root.pullRequestNumber == nil {
                let leaves = state.requirementLeaves(for: root.id)
                guard !leaves.isEmpty, leaves.allSatisfy({ $0.phase == .proven }),
                      root.requirementVerification?.passed == true,
                      root.requirementVerification?.commit == tip else { continue }
            }
            try await publisher.publish(requirement: root.identity, branch: branch, commit: tip)
        }
    }

    private func requirementTip(_ root: NodeState) async throws -> String? {
        if let requirementBranches {
            return try await requirementBranches.tip(of: root.requirementBranch ?? "agentos/\(root.ticket)")
        }
        let checkout = try await workspace.requirementWorktree(for: root.identity)
        do {
            let tip = try await workspace.head(of: checkout)
            await workspace.removeSnapshot(checkout)
            return tip
        } catch {
            await workspace.removeSnapshot(checkout)
            throw error
        }
    }
}
