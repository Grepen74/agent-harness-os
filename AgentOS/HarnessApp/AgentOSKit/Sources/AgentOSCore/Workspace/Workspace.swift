import Foundation

public enum RebaseResult: Sendable {
    case clean
    case conflict(files: [String])
}

/// The product's code as the reconciler sees it (doc 08): `main`, one branch and working copy per leaf,
/// and a landing step that moves `main` forward. The reconciler never runs git itself.
///
/// Adapters: `SimulationWorkspace` (a git monorepo the simulator creates). Planned: a workspace on an
/// existing repo, with worktrees outside it and landing on a local branch.
public protocol Workspace: Sendable {
    /// Makes sure the repository exists and is usable. Called at the start of every round.
    func prepare() async throws

    func branch(for id: NodeID) -> String
    func worktree(for id: NodeID) -> URL
    /// A fresh branch from the latest `main`, checked out in the leaf's own working copy.
    func createWorktree(for id: NodeID) async throws -> URL
    func removeWorktree(for id: NodeID) async throws

    /// Commits everything in the working copy as the given run. Returns the new commit, or nil if nothing changed.
    @discardableResult
    func commitAll(in directory: URL, message: String, author: String) async throws -> String?
    func head(of directory: URL) async throws -> String
    /// Files under Tests/ that this branch changed since it left `main`.
    func changedTestFiles(in directory: URL) async throws -> [String]

    /// Replays the branch on top of the latest `main`. On conflict, everything is put back as it was.
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult
    func abortRebase(_ directory: URL) async throws
    /// Rework: keep only the branch's acceptance tests, drop the implementation, move onto the latest `main`.
    func resetForRework(_ directory: URL) async throws
    /// Moves `main` to the leaf's (already rebased and checked) branch. Returns the new `main`.
    func landOnMain(_ id: NodeID) async throws -> String

    /// Components that exist on `main` (for the decomposer's catalog).
    func existingComponents() -> [String]
    /// Whatever must happen before building, e.g. generating a manifest or project file.
    func prepareBuild(in directory: URL) async throws
}
