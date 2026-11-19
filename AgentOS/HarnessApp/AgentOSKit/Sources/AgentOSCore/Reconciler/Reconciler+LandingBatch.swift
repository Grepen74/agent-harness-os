import Foundation

extension Reconciler {
    func drainLandingQueue(_ report: inout RoundReport) async throws {
        let queue = await ledger.workingState().landingQueue
        var considered: Set<NodeID> = []
        for queued in queue {
            guard shutdownReason == nil, !Task.isCancelled,
                  slotsInUse < max(1, policy.maxParallelAgents) else { break }
            guard !considered.contains(queued.id) else { continue }
            if policy.landingBatchSize <= 1 || !workspace.supportsLandingBatches || policy.review.requiresReview {
                if let action = await step(queued.id, landing: true) { report.actions.append(action) }
                continue
            }
            let state = await ledger.workingState()
            guard let node = state.nodes[queued.id], eligibleForLanding(node, in: state) else { continue }
            var members = [node]
            let branch = await requirementBranch(for: node.id)
            for candidate in queue where candidate.id != node.id && !considered.contains(candidate.id) {
                guard members.count < policy.landingBatchSize else { break }
                guard let current = state.nodes[candidate.id], eligibleForLanding(current, in: state),
                      await requirementBranch(for: current.id) == branch else { continue }
                members.append(current)
            }
            considered.formUnion(members.map(\.id))
            if members.count > 1 {
                var ready: [NodeState] = []
                for member in members {
                    if let reason = try await workspace.whyLandingMustWait(for: member.id) {
                        if let action = await waitToLand(member, because: reason) { report.actions.append(action) }
                    } else {
                        ready.append(member)
                    }
                }
                members = ready
            }
            guard !members.isEmpty else { continue }
            guard shutdownReason == nil, !Task.isCancelled,
                  slotsInUse < max(1, policy.maxParallelAgents) else { break }
            if members.count == 1 {
                if let action = await step(members[0].id, landing: true) { report.actions.append(action) }
            } else {
                let task = Task {
                    let action = await self.performLandingBatch(members)
                    self.tasks[node.id] = nil
                    self.landingBatchNodes = []
                    return action
                }
                landingBatchNodes = Set(members.map(\.id))
                tasks[node.id] = task
                if let action = await task.value { report.actions.append(action) }
            }
        }
    }

    private func eligibleForLanding(_ node: NodeState, in state: WorkingState) -> Bool {
        node.phase == .landing && node.activeRun == nil && node.flags[.escalated] == nil &&
            !node.ticketClosed && !node.awaitingHumanReview && !busyNodes.contains(node.id) &&
            !requirementIsHeld(node, in: state) && node.lastSubmission != nil
    }

    private func performLandingBatch(_ nodes: [NodeState]) async -> String? {
        let run = Self.newRunID()
        let name = "Landing batch \(run)"
        var candidate: LandingBatchWorkspace?
        do {
            for node in nodes {
                landingWaits.remove(node.id)
                try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)
            }
            let batch = try await workspace.createLandingBatch(for: nodes.map(\.id))
            candidate = batch
            var violation: String?
            for member in batch.members {
                guard let node = nodes.first(where: { $0.id == member.node }) else { continue }
                if let reason = try await protectedTestsViolation(node, in: batch.directory, changedFiles: member.changedFiles) {
                    violation = reason
                    break
                }
            }
            if let violation {
                try await finishBatchRuns(nodes, run: run, outcome: "batch safety check: \(violation)")
                await workspace.removeSnapshot(batch.directory)
                candidate = nil
                return try await landIndividually(nodes)
            }
            try await workspace.prepareBuild(in: batch.directory)
            let output = await checks.runChecks(in: batch.directory, only: nil)
            try await write(nil, by: .agent(run: run, role: .verifier), [
                .landingBatchChecked(LandingBatchCheck(name: name, branch: batch.branch, nodes: nodes.map(\.id),
                    candidateCommit: batch.candidateCommit, passed: output.passed, run: run)),
            ])
            if output.passed {
                var events: [LedgerEvent] = []
                for member in batch.members {
                    guard let node = nodes.first(where: { $0.id == member.node }),
                          let submission = node.lastSubmission else {
                        throw AgentFailure("The batch member \(member.node) has no submitted change.")
                    }
                    let evidence = try makeEvidence(node, check: name, output: output, builtBy: submission.run,
                                                    checkedBy: run, commit: batch.candidateCommit)
                    events += [.evidenceRecorded(evidence), .landed(commit: member.commit),
                               .runFinished(run: run, outcome: "landed"), .phaseChanged(to: .proven)]
                        .map { LedgerEvent(node: node.id, by: .agent(run: run, role: .verifier), kind: $0, at: now()) }
                }
                try Task.checkCancellation()
                switch try await workspace.landBatch(batch) {
                case .landed:
                    try await ledger.append(events)
                    for member in batch.members {
                        guard let node = nodes.first(where: { $0.id == member.node }) else { continue }
                        try? await workspace.removeWorktree(for: node.id)
                        await tracker.comment(on: node.ticket,
                            "🛬 Landed on \(batch.branch) at \(member.commit.prefix(8)) with all tests passing. \(name).")
                    }
                case .waiting(let reason):
                    try await finishBatchRuns(nodes, run: run, outcome: "waiting to land")
                    for node in nodes { _ = await waitToLand(node, because: reason) }
                case .branchMoved:
                    try await finishBatchRuns(nodes, run: run, outcome: "requirement branch moved; batch must be checked again")
                }
            } else {
                // Attribution remains on the established singleton path until batch diagnosis can identify an owner.
                try await finishBatchRuns(nodes, run: run, outcome: "batch failed; checking members individually")
                await workspace.removeSnapshot(batch.directory)
                candidate = nil
                return try await landIndividually(nodes)
            }
            await workspace.removeSnapshot(batch.directory)
            for node in nodes { ownedRuns[node.id] = nil }
            return "\(name) on \(batch.branch): \(output.passed ? "checked" : "failed")"
        } catch {
            if let candidate { await workspace.removeSnapshot(candidate.directory) }
            if error is LandingBatchConflict {
                do {
                    try await finishBatchRuns(nodes, run: run, outcome: "batch conflict; rebasing members individually")
                    return try await landIndividually(nodes)
                } catch {
                    return await failLandingBatch(nodes, name: name, error: error)
                }
            }
            return await failLandingBatch(nodes, name: name, error: error)
        }
    }

    private func failLandingBatch(_ nodes: [NodeState], name: String, error: any Error) async -> String {
        defer {
            for node in nodes {
                if let run = ownedRuns.removeValue(forKey: node.id) { stopReasons.removeValue(forKey: run) }
            }
        }
        let reason = "\(name) could not finish: \(error). Check the workspace, then add harness:retry."
        do {
            for node in nodes {
                if let run = ownedRuns[node.id], await ledger.workingState().nodes[node.id]?.activeRun?.run == run {
                    try await ledger.append([
                        LedgerEvent(node: node.id, by: .reconciler, kind: .runFinished(run: run, outcome: reason)),
                        LedgerEvent(node: node.id, by: .reconciler, kind: .flagSet(.escalated, reason: reason)),
                    ])
                    await tracker.comment(on: node.ticket, reason)
                }
            }
        } catch {
            let failure = "\(reason) Could not record the batch finish: \(error)"
            lifecycleFailure = failure
            return failure
        }
        return reason
    }

    private func finishBatchRuns(_ nodes: [NodeState], run: RunID, outcome: String) async throws {
        for node in nodes {
            try await write(node.id, by: .agent(run: run, role: .verifier), [.runFinished(run: run, outcome: outcome)])
            ownedRuns[node.id] = nil
        }
    }

    private func landIndividually(_ nodes: [NodeState]) async throws -> String? {
        var actions: [String] = []
        for node in nodes {
            if let current = await ledger.workingState().nodes[node.id], let action = try await land(current) {
                actions.append(action)
            }
            ownedRuns[node.id] = nil
        }
        return actions.isEmpty ? nil : actions.joined(separator: "\n")
    }
}
