import AgentOSCore
import Foundation

extension CatchUpCoordinator {
    public func catchUp(
        after baseline: Baseline,
        acceptanceTests: @escaping @Sendable (URL) async throws -> Bool
    ) async throws -> CatchUpOutcome? {
        guard baseline.passed else { return nil }
        guard baseline.commit == (try await workspace.localMainTip()) else { return nil }
        if requirement == nil {
            var outcome: CatchUpOutcome?
            for coordinator in try await requirementCoordinators() {
                if let result = try await coordinator.catchUp(after: baseline, acceptanceTests: acceptanceTests) {
                    outcome = result
                }
            }
            return outcome
        }
        return try await catchUpRequirement(after: baseline, acceptanceTests: acceptanceTests)
    }

    /// `busy`: nodes with a step in progress. Their worktrees are left alone; landing rebases them later.
    public func reconcile(force: Bool = false, busy: Set<NodeID> = []) async -> String? {
        guard requirement == nil else {
            return await reconcileRequirement(force: force, busy: busy)
        }
        do {
            try await workspace.prepare()
            var messages: [String] = []
            for coordinator in try await requirementCoordinators() {
                if let message = await coordinator.reconcile(force: force, busy: busy) { messages.append(message) }
            }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        } catch {
            return "⚠️ Catch-up failed: \(error)"
        }
    }

    func status() async -> CatchUpStatus {
        let state = await ledger.workingState()
        if requirement == nil, let coordinator = presentationCoordinator(in: state) {
            return await coordinator.status()
        }
        return await requirementStatus(in: state)
    }

    func status(for ticket: String) async -> CatchUpStatus {
        guard let coordinator = await coordinator(for: ticket) else {
            return CatchUpStatus(conflict: nil, lastSuccess: nil, banner: nil, attentionItems: [], scanFinding: nil)
        }
        return await coordinator.status()
    }

    func conflictDiff(for ticket: String) async throws -> String {
        guard let coordinator = await coordinator(for: ticket) else {
            throw AgentFailure("No requirement branch exists for \(ticket).")
        }
        return try await coordinator.conflictDiff()
    }

    func openInTerminal(for ticket: String) async throws -> URL {
        guard let coordinator = await coordinator(for: ticket) else {
            throw AgentFailure("No requirement branch exists for \(ticket).")
        }
        return try await coordinator.openInTerminal()
    }

    func conflictDiff() async throws -> String {
        if requirement == nil {
            guard let coordinator = presentationCoordinator(in: await ledger.workingState()) else {
                throw AgentFailure("There is no requirement branch to catch up.")
            }
            return try await coordinator.conflictDiff()
        }
        return try await requirementConflictDiff()
    }

    func openInTerminal() async throws -> URL {
        if requirement == nil {
            guard let coordinator = presentationCoordinator(in: await ledger.workingState()) else {
                throw AgentFailure("There is no requirement branch to catch up.")
            }
            return try await coordinator.openInTerminal()
        }
        return try await openRequirementInTerminal()
    }

    /// Shows an unresolved conflict on its tickets again, e.g. after a round projected their usual statuses.
    func projectCurrentConflict() async {
        for root in await ledger.workingState().roots {
            await projectConflict(root.catchUpConflict)
        }
    }

    private func coordinator(for ticket: String) async -> CatchUpCoordinator? {
        guard let root = await ledger.workingState().roots.first(where: { $0.ticket == ticket }) else { return nil }
        return CatchUpCoordinator(workspace: workspace, ledger: ledger, tracker: tracker,
                                  landingQueue: landingQueue, requirement: root.identity)
    }

    private func requirementCoordinators() async throws -> [CatchUpCoordinator] {
        let state = await ledger.workingState()
        var coordinators: [CatchUpCoordinator] = []
        for root in state.roots where !root.ticketClosed {
            let leaves = state.requirementLeaves(for: root.id)
            guard root.requirementBranch != nil || leaves.contains(where: { $0.testsDigest != nil }) else { continue }
            if let from = try await workspace.prepareRequirementBranch(for: root.identity, leaves: leaves.map(\.id)),
               root.requirementBranch == nil {
                try await ledger.append([
                    LedgerEvent(node: root.id, by: .adapter("Catch-up"),
                                kind: .requirementBranchCreated(branch: "agentos/\(root.ticket)", from: from)),
                ])
            }
            coordinators.append(CatchUpCoordinator(workspace: workspace, ledger: ledger, tracker: tracker,
                                                   landingQueue: landingQueue, requirement: root.identity))
        }
        return coordinators
    }

    private func presentationCoordinator(in state: WorkingState) -> CatchUpCoordinator? {
        guard let root = state.roots.first(where: { $0.catchUpConflict != nil })
            ?? state.roots.first(where: { $0.requirementBranch != nil }) else { return nil }
        return CatchUpCoordinator(workspace: workspace, ledger: ledger, tracker: tracker,
                                  landingQueue: landingQueue, requirement: root.identity)
    }
}
