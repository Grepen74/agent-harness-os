/// Local requirement refs and their relationship to the default branch. Merges are atomic:
/// a conflict must leave the requirement ref unchanged.
public protocol RequirementBranchRepository: Sendable {
    var defaultBranch: String { get }
    /// Selects main for the round, returning an actionable warning when fetching needs a retry.
    func refreshMain(publishing: Bool) async throws -> String?
    /// The same selected main used by baseline checks, new branches and dependency checks.
    func mainTip() async throws -> String
    func requirementBranch(for ticket: String) -> String
    func tip(of branch: String) async throws -> String?
    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool
    func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult
    func changedFiles(in commit: String) async throws -> [String]
    /// Removes the `merge=union` aids older harness versions left for catch-up conflicts. They hid the real
    /// conflict from a person's own merge and left broken code behind.
    func removeCatchUpMergeAids() async throws
}

public extension RequirementBranchRepository {
    func refreshMain(publishing: Bool) async throws -> String? { nil }
    func mainTip() async throws -> String {
        guard let main = try await tip(of: defaultBranch) else {
            throw AgentFailure("Default branch \(defaultBranch) is missing; restore it before catching up requirements.")
        }
        return main
    }
    func removeCatchUpMergeAids() async throws {}
}
