import Foundation

extension Reconciler {
    func requirementIsHeld(_ node: NodeState, in state: WorkingState) -> Bool {
        state.lineage(of: node.id).contains { $0.catchUpConflict != nil }
    }

    public func retryRequirementCatchUp() async -> RoundReport {
        var report = RoundReport()
        guard shutdownReason == nil, !isCatchingUpRequirements, !isVerifyingRequirements else { return report }
        isCatchingUpRequirements = true
        defer { isCatchingUpRequirements = false }
        do {
            try await reconcileRequirementBranches(&report, force: true)
        } catch {
            report.safeStop = "Couldn't retry requirement catch-up: \(error)"
        }
        return report
    }

    func reconcileRequirementBranches(_ report: inout RoundReport, force: Bool = false) async throws {
        guard let repository = requirementBranches else { return }
        guard let main = try await repository.tip(of: repository.defaultBranch) else {
            throw AgentFailure("Default branch \(repository.defaultBranch) is missing; restore it before catching up requirements.")
        }
        let state = await ledger.workingState()
        let canCatchUp = state.baseline?.passed == true && state.baseline?.commit == main

        for root in state.roots where !root.ticketClosed && !root.requirementMerged {
            let branch = repository.requirementBranch(for: root.ticket)
            guard let oldTip = try await repository.tip(of: branch) else { continue }
            guard canCatchUp else {
                try await observeRequirement(root, branch: branch, tip: oldTip, main: main, repository: repository)
                continue
            }
            let containsMain = try await repository.isAncestor(main, of: oldTip)
            let conflict = root.catchUpConflict
            // A recorded conflict is retried only for new main, or resolved by a person's merge.
            if !force, !containsMain, conflict?.mainSHA == main { continue }

            var moved = false
            if !containsMain {
                try await repository.updateCatchUpMergeAid(for: branch, files: [])
                switch try await repository.mergeMain(main, into: branch) {
                case .clean:
                    moved = true
                case .conflict(let files):
                    let files = Array(Set(files)).sorted()
                    let tickets = try await mergedRequirements(changing: files, into: main,
                                                               except: root.id, in: state, repository: repository)
                    try await observeRequirement(root, branch: branch, tip: oldTip, main: main,
                                                 repository: repository)
                    try await write(root.id, by: .reconciler, [
                        .requirementCatchUpConflicted(branch: branch, main: main, files: files, tickets: [root.ticket]),
                    ])
                    try await repository.updateCatchUpMergeAid(for: branch, files: files)
                    let sources = tickets.isEmpty ? "" : " Work already in main from: \(tickets.joined(separator: ", "))."
                    await tracker.comment(on: root.ticket,
                        "Catch-up conflict on \(branch) with main \(main) in \(files.joined(separator: ", "))." +
                        sources + " Waiting for a person: merge main into \(branch) and resolve the conflicts. " +
                        "The harness recognises the merge automatically; no harness:retry signal is needed.")
                    report.actions.append("\(root.displayName): catch-up conflict on \(branch)")
                    continue
                }
            }
            guard let tip = try await repository.tip(of: branch) else {
                throw AgentFailure("Requirement branch \(branch) disappeared during catch-up.")
            }
            let lastSuccess = root.lastCatchUpSuccess
            if moved || conflict != nil || lastSuccess?.mainSHA != main || lastSuccess?.newAgentOSMainTip != tip {
                try await rebaseRequirementLeaves(root.id)
                try await repository.updateCatchUpMergeAid(for: branch, files: [])
                try await write(root.id, by: .reconciler, [
                    .catchUpSucceeded(main: main, newAgentOSMainTip: tip,
                                      method: containsMain && conflict != nil ? .manual : .automatic),
                ])
                report.actions.append("\(root.displayName): caught \(branch) up with main")
            }
            try await observeRequirement(root, branch: branch, tip: tip, main: main, repository: repository)
        }
    }

    private func observeRequirement(_ root: NodeState, branch: String, tip: String, main: String,
                                    repository: any RequirementBranchRepository) async throws {
        let contained = try await repository.isAncestor(tip, of: main)
        let previous = root.requirementBranchObservation
        guard previous?.tip != tip || previous?.main != main || previous?.containedInMain != contained else { return }
        try await write(root.id, by: .reconciler, [
            .requirementBranchObserved(branch: branch, tip: tip, main: main, containedInMain: contained),
        ])
    }

    private func rebaseRequirementLeaves(_ id: NodeID) async throws {
        let state = await ledger.workingState()
        let active = state.requirementLeaves(for: id).filter {
            $0.testsDigest != nil && $0.phase != .proven && !$0.ticketClosed &&
                $0.activeRun == nil && !busyNodes.contains($0.id)
        }
        for node in active {
            let directory = workspace.worktree(for: node.id)
            switch try await rebaseOntoMain(node, in: directory) {
            case .clean:
                if let submission = node.lastSubmission {
                    let commit = try await workspace.head(of: directory)
                    if commit != submission.commit {
                        try await write(node.id, by: .reconciler, [.changeSubmitted(run: submission.run, commit: commit)])
                    }
                }
            case .conflict(let files):
                try await resetForRework(node, in: directory)
                let reason = "merge conflict in \(files.joined(separator: ", ")) after requirement catch-up with main"
                try await write(node.id, by: .reconciler, [
                    .reworkNeeded(reason: reason), .phaseChanged(to: .ready),
                ])
                await tracker.comment(on: node.ticket,
                    "Rework: \(reason). The implementation is redone on the latest requirement branch; acceptance tests are kept.")
            }
        }
    }

    private func mergedRequirements(changing files: [String], into main: String, except target: NodeID,
                                    in state: WorkingState,
                                    repository: any RequirementBranchRepository) async throws -> [String] {
        var tickets = Set<String>()
        for node in state.nodes.values where node.phase == .proven {
            guard let commit = node.landedCommit, let root = state.lineage(of: node.id).last,
                  root.id != target, try await repository.isAncestor(commit, of: main) else { continue }
            let changed = try await repository.changedFiles(in: commit)
            if !Set(files).isDisjoint(with: changed) { tickets.insert(root.ticket) }
        }
        return tickets.sorted()
    }
}
