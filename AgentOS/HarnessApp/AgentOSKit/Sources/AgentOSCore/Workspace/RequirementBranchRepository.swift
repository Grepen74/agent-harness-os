/// Local requirement refs and their relationship to the default branch. Merges are atomic:
/// a conflict must leave the requirement ref unchanged.
public protocol RequirementBranchRepository: Sendable {
    var defaultBranch: String { get }
    func requirementBranch(for ticket: String) -> String
    func tip(of branch: String) async throws -> String?
    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool
    func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult
    func changedFiles(in commit: String) async throws -> [String]
    func updateCatchUpMergeAid(for branch: String, files: [String]) async throws
}

public extension RequirementBranchRepository {
    func updateCatchUpMergeAid(for branch: String, files: [String]) async throws {}
}
