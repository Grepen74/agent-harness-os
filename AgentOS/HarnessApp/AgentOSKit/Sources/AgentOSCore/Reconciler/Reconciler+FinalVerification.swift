import Foundation

extension Reconciler {
    func verifyCompletedRequirements(_ report: inout RoundReport) async throws {
        guard !isVerifyingRequirements else { return }
        isVerifyingRequirements = true
        defer { isVerifyingRequirements = false }
        let state = await ledger.workingState()
        for root in state.roots where !root.ticketClosed && root.phase == .proven {
            let leaves = state.requirementLeaves(for: root.id)
            guard !leaves.isEmpty, leaves.allSatisfy({ $0.phase == .proven }),
                  !requirementIsHeld(root, in: state) else { continue }
            var unverifiedTip = false
            if policy.pullRequests, publisher != nil, root.pullRequestNumber == nil,
               root.publicationFailure == nil || root.publicationRetryPending,
               let verified = root.requirementVerification, verified.passed, let requirementBranches,
               let tip = try await requirementBranches.tip(of: root.requirementBranch ?? "agentos/\(root.ticket)") {
                unverifiedTip = tip != verified.commit
            }
            if !root.requirementVerificationStarted || root.requirementVerificationRetryPending || unverifiedTip {
                try await verifyRequirement(root)
                report.actions.append("\(root.displayName): final verification completed")
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

    private func verifyRequirement(_ root: NodeState) async throws {
        try await write(root.id, by: .reconciler, [.requirementVerificationStarted])
        let run = Self.newRunID()
        var directory: URL?
        var commit = root.requirementBranchObservation?.tip ?? root.landedCommit ?? "unavailable"
        let output: CheckOutput
        do {
            let checkout = try await workspace.requirementWorktree(for: root.identity)
            directory = checkout
            commit = try await workspace.head(of: checkout)
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
        ])
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
            guard !requirementIsHeld(root, in: state),
                  !state.lineage(of: root.id).contains(where: { !$0.flags.isEmpty }),
                  root.publicationFailure == nil || root.publicationRetryPending else { continue }
            guard root.requirementVerification?.passed == true || root.pullRequestNumber != nil else { continue }
            let branch = root.requirementBranch ?? "agentos/\(root.ticket)"
            let tip: String?
            if let requirementBranches {
                tip = try await requirementBranches.tip(of: branch)
            } else {
                tip = root.requirementBranchObservation?.tip ?? root.requirementVerification?.commit
            }
            guard let tip else { continue }
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
}
