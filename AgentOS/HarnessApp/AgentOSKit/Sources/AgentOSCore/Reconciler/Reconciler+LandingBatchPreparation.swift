import Foundation

private struct LandingBatchTampering: Error {
    let node: NodeID
    let commit: String
    let reason: String
}

extension Reconciler {
    func needsHumanLandingReview(_ node: NodeState) async throws -> Bool {
        guard team.reviewer != nil, policy.review.requiresReview else { return false }
        let context = try await workspace.reviewContext(in: workspace.worktree(for: node.id),
                                                        against: requirementBranch(for: node.id))
        return policy.review.level(for: node.spec.touches + context.changedFiles) == .agentAndHuman
    }

    func reworkLandingConflict(_ node: NodeState, files: [String], run: RunID) async throws -> String {
        try await resetForRework(node, in: workspace.worktree(for: node.id))
        let reason = "merge conflict in \(files.isEmpty ? "some files" : files.joined(separator: ", ")) with newer work on main"
        let predictions = PredictedPath.normalize(node.spec.predictedPaths)
        let additions = PredictedPath.normalize(files).filter { file in
            !predictions.contains { file == $0 || file.hasPrefix($0 + "/") }
        }
        var kinds: [EventKind] = []
        if !additions.isEmpty { kinds.append(.predictedPathsExpanded(files: additions)) }
        kinds += [.runFinished(run: run, outcome: "conflict"), .reworkNeeded(reason: reason), .phaseChanged(to: .ready)]
        try await write(node.id, by: .agent(run: run, role: .verifier), kinds)
        await tracker.comment(on: node.ticket, "♻️ Rework: \(reason). The implementation is redone on the latest code; the tests are kept.")
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) conflicted at landing → rework"
    }

    func reviewBeforeBatching(_ node: NodeState, run: RunID) async throws -> NodeState? {
        guard team.reviewer != nil, policy.review.requiresReview else { return node }
        let directory = workspace.worktree(for: node.id)
        if case .conflict(let files) = try await rebaseOntoMain(node, in: directory) {
            _ = try await reworkLandingConflict(node, files: files, run: run)
            return nil
        }
        let current = await ledger.workingState().nodes[node.id] ?? node
        let context = try await workspace.reviewContext(in: directory, against: requirementBranch(for: node.id))
        guard policy.review.level(for: node.spec.touches + context.changedFiles) != .none else { return current }
        let prior = current.reviews.last { $0.stage == .change }
        let result: ReviewResult
        if let prior, prior.commit == context.commit, prior.result.passed {
            result = prior.result
        } else {
            result = try await review(current, stage: .change, context: context, in: directory, run: run)
        }
        guard result.passed else {
            _ = try await returnReviewFindings(result, stage: .change, node: current, run: run, directory: directory)
            return nil
        }
        return await ledger.workingState().nodes[node.id]
    }

    func prepareLandingBatch(_ nodes: inout [NodeState], name: String,
                             run: RunID) async throws -> LandingBatchWorkspace? {
        while !nodes.isEmpty {
            let members = nodes
            do {
                return try await workspace.createLandingBatch(for: members.map(\.id)) { batch, member in
                    guard let node = members.first(where: { $0.id == member.node }) else {
                        throw AgentFailure("Unexpected landing batch member \(member.node).")
                    }
                    if let reason = try await self.protectedTestsViolation(
                        node, in: batch.directory, changedFiles: member.changedFiles
                    ) {
                        throw LandingBatchTampering(node: node.id, commit: member.commit, reason: reason)
                    }
                }
            } catch let conflict as LandingBatchConflict {
                guard let node = nodes.first(where: { $0.id == conflict.node }) else { throw conflict }
                try await recordBatchRemoval(node, name: name,
                    reason: "merge conflict in \(conflict.files.joined(separator: ", "))")
                _ = try await reworkLandingConflict(node, files: conflict.files, run: run)
                ownedRuns[node.id] = nil
                nodes.removeAll { $0.id == node.id }
            } catch let tampering as LandingBatchTampering {
                guard let node = nodes.first(where: { $0.id == tampering.node }),
                      let submission = node.lastSubmission else { throw tampering }
                try await recordBatchRemoval(node, name: name, reason: "tampered tests: \(tampering.reason)")
                let evidence = try makeEvidence(node, check: name,
                    output: CheckOutput(passed: false, summary: tampering.reason, log: tampering.reason),
                    builtBy: submission.run, checkedBy: run, commit: tampering.commit)
                _ = try await failOwnLandingCheck(node, evidence: evidence, run: run, candidate: tampering.commit)
                ownedRuns[node.id] = nil
                nodes.removeAll { $0.id == node.id }
            }
        }
        return nil
    }

    private func recordBatchRemoval(_ node: NodeState, name: String, reason: String) async throws {
        try await write(nil, by: .reconciler, [.landingBatchMemberRemoved(
            name: name, branch: await requirementBranch(for: node.id), node: node.id, reason: reason)])
    }
}
