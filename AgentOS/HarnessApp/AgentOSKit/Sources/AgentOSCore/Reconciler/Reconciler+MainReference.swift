import Foundation

extension Reconciler {
    func refreshMainReference() async throws {
        guard let repository = requirementBranches else { return }
        let warning = try await repository.refreshMain(publishing: policy.pullRequests)
        guard warning != (await ledger.workingState()).mainFetchWarning else { return }
        try await ledger.append([
            LedgerEvent(node: nil, by: .reconciler, kind: .mainFetchWarningChanged(warning: warning)),
        ])
    }
}
