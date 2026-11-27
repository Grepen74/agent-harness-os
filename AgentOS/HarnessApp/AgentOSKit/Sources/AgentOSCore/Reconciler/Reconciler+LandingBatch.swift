import Foundation

extension Reconciler {
    func drainLandingQueue(_ report: inout RoundReport) async throws {
        guard quietLandings == 0 else { return }
        let queue = await ledger.workingState().landingQueue
        var considered: Set<NodeID> = []
        for queued in queue {
            guard quietLandings == 0, shutdownReason == nil, !Task.isCancelled,
                  slotsInUse < max(1, policy.maxParallelAgents) else { break }
            guard !considered.contains(queued.id) else { continue }
            if policy.landingBatchSize <= 1 || !workspace.supportsLandingBatches {
                if let action = await step(queued.id, landing: true) { report.actions.append(action) }
                continue
            }
            let state = await ledger.workingState()
            guard let node = state.nodes[queued.id], eligibleForLanding(node, in: state) else { continue }
            guard let needsReview = try await checkingLanding(node, &report, {
                try await needsHumanLandingReview(node)
            }) else {
                considered.insert(node.id)
                continue
            }
            if needsReview {
                guard quietLandings == 0, shutdownReason == nil, !Task.isCancelled else { break }
                considered.insert(node.id)
                if let action = await step(node.id, landing: true) { report.actions.append(action) }
                continue
            }
            var members = [node]
            let branch = await requirementBranch(for: node.id)
            for candidate in queue where candidate.id != node.id && !considered.contains(candidate.id) {
                guard members.count < policy.landingBatchSize else { break }
                guard let current = state.nodes[candidate.id], eligibleForLanding(current, in: state),
                      await requirementBranch(for: current.id) == branch else { continue }
                guard let needsReview = try await checkingLanding(current, &report, {
                    try await needsHumanLandingReview(current)
                }) else {
                    considered.insert(current.id)
                    continue
                }
                guard !needsReview else { continue }
                members.append(current)
            }
            considered.formUnion(members.map(\.id))
            if members.count > 1 {
                var ready: [NodeState] = []
                for member in members {
                    guard let wait = try await checkingLanding(member, &report, {
                        try await workspace.whyLandingMustWait(for: member.id)
                    }) else { continue }
                    if let reason = wait {
                        if let action = await waitToLand(member, because: reason) { report.actions.append(action) }
                    } else {
                        ready.append(member)
                    }
                }
                members = ready
            }
            guard !members.isEmpty else { continue }
            // A final verification may have started its quiet recheck while this round was suspended.
            guard quietLandings == 0, shutdownReason == nil, !Task.isCancelled,
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

    /// A queued node's own landing checks look at its worktree. When one fails (the worktree isn't clean, say),
    /// only that node stops: it's escalated, and the rest of the queue goes on.
    private func checkingLanding<T>(_ node: NodeState, _ report: inout RoundReport,
                                    _ check: () async throws -> T) async throws -> T? {
        do {
            return try await check()
        } catch let error as LedgerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var reason = "Couldn't check whether \(node.displayName) can land: \(error)"
            if !reason.contains("harness:retry") { reason += " Check the worktree, then add harness:retry." }
            try await write(node.id, by: .reconciler, [.flagSet(.escalated, reason: reason)])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)")
            report.actions.append(reason)
            return nil
        }
    }

    private func eligibleForLanding(_ node: NodeState, in state: WorkingState) -> Bool {
        node.phase == .landing && node.activeRun == nil && node.flags[.escalated] == nil &&
            !node.ticketClosed && !node.awaitingHumanReview && !busyNodes.contains(node.id) &&
            !requirementIsHeld(node, in: state) && node.lastSubmission != nil
    }

    func performLandingBatch(_ queued: [NodeState]) async -> String? {
        var nodes = queued
        let run = Self.newRunID()
        let name = "Landing batch \(run)"
        var candidate: LandingBatchWorkspace?
        do {
            for node in nodes {
                landingWaits.remove(node.id)
                try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)
            }
            var reviewed: [NodeState] = []
            for node in nodes {
                if let ready = try await reviewBeforeBatching(node, run: run) {
                    reviewed.append(ready)
                } else {
                    ownedRuns[node.id] = nil
                }
            }
            nodes = reviewed
            guard let batch = try await prepareLandingBatch(&nodes, name: name, run: run) else {
                return "\(name): no eligible members"
            }
            candidate = batch
            try await workspace.prepareBuild(in: batch.directory)
            let diagnosisBatch = LandingBatch(id: name, workspace: batch)
            switch try await checkLandingBatch(diagnosisBatch, nodes: nodes, run: run) {
            case .passed(let output, let unreliable):
                let events = try batchLandingEvents(diagnosisBatch, nodes: nodes, output: output, run: run)
                try Task.checkCancellation()
                switch try await workspace.landBatch(batch) {
                case .landed:
                    try await recordBatchLanded(diagnosisBatch, nodes: nodes, events: events,
                                                unreliable: unreliable)
                case .waiting(let reason):
                    try await finishBatchRuns(nodes, run: run, outcome: "waiting to land")
                    for node in nodes { _ = await waitToLand(node, because: reason) }
                case .branchMoved:
                    try await finishBatchRuns(nodes, run: run, outcome: "requirement branch moved; batch must be checked again")
                }
            case .escalated:
                break
            case .needsSplit(let diagnosis, let owners):
                try await finishBatchRuns(nodes, run: run, outcome: diagnosis)
                await workspace.removeSnapshot(batch.directory)
                candidate = nil
                return try await resolveLandingBatchFailure(nodes, name: name, owners: owners)
            }
            await workspace.removeSnapshot(batch.directory)
            for node in nodes { ownedRuns[node.id] = nil }
            return "\(name) on \(batch.branch): checked"
        } catch {
            if let candidate { await workspace.removeSnapshot(candidate.directory) }
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
}
