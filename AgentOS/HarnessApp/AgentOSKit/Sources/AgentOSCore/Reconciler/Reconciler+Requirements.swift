import Foundation

extension Reconciler {
    func restoreRequirementBranches() async throws {
        let state = await ledger.workingState()
        for requirement in state.roots where !requirement.ticketClosed && !requirement.requirementMerged {
            let leaves = state.requirementLeaves(for: requirement.id)
            let started = leaves.contains {
                $0.testsDigest != nil || $0.lastSubmission != nil || $0.activeRun != nil ||
                    (!$0.ticketClosed && !wantsDiagnosis($0) && canAdvance($0, in: state))
            }
            guard requirement.requirementBranch != nil || started else { continue }
            try await prepareRequirementBranch(of: requirement, in: state)
        }
    }

    /// Binds a leaf about to start to its requirement branch. It may be newer than the round's restore: a breakdown
    /// that finished meanwhile made it.
    func prepareRequirementBranch(forStarting node: NodeState, in state: WorkingState) async throws {
        guard node.spec.kind == .leaf, let requirement = state.lineage(of: node.id).last,
              !requirement.ticketClosed, !requirement.requirementMerged else { return }
        try await prepareRequirementBranch(of: requirement, in: state)
    }

    /// Binds the requirement's leaves to its branch, which is created from `main` the first time.
    private func prepareRequirementBranch(of requirement: NodeState, in state: WorkingState) async throws {
        let leaves = state.requirementLeaves(for: requirement.id)
        if let from = try await workspace.prepareRequirementBranch(for: requirement.identity, leaves: leaves.map(\.id)),
           requirement.requirementBranch == nil {
            try await write(requirement.id, by: .reconciler, [
                .requirementBranchCreated(branch: "agentos/\(requirement.ticket)", from: from),
            ])
        }
    }

    func requirementBranch(for id: NodeID) async -> String {
        let requirement = await ledger.workingState().lineage(of: id).last
        return requirement.map { $0.requirementBranch ?? "agentos/\($0.ticket)" } ?? "main"
    }
}
