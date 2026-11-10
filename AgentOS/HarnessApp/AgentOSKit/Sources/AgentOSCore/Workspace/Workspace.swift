import Foundation

public enum RebaseResult: Sendable {
    case clean
    case conflict(files: [String])
}

public struct ActiveLeavesCatchUpResult: Sendable, Equatable {
    public var rebased: [NodeID]
    public var rework: [NodeID: [String]]

    public init(rebased: [NodeID] = [], rework: [NodeID: [String]] = [:]) {
        self.rebased = rebased
        self.rework = rework
    }
}

/// The product's code as the reconciler sees it (doc 08): `main`, one branch and working copy per leaf,
/// and a landing step that moves `main` forward. The reconciler never runs git itself.
///
/// "`main`" here means the branch work is based on and lands on: `main` in the simulator, the landing
/// branch (`agentos/main`) on a real repo.
///
/// Adapters: `SimulationWorkspace` (a git monorepo the simulator creates) and `RepositoryWorkspace` (an
/// existing repo, with worktrees outside it and landing on a local branch).
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
    /// Every file this branch changed since it left `main`, relative to the repo's top folder.
    func changedFiles(in directory: URL) async throws -> [String]
    /// Where every node's acceptance tests live, relative to the repo's top folder, ending in "/".
    var testArea: String { get }
    /// The folder with this node's own acceptance tests (inside `testArea`, no trailing "/").
    func testFolder(for spec: NodeSpec) -> String
    /// What agents need to know about the repo: its layout, how to build and test, what not to do.
    var agentContext: String { get }

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

    /// A fingerprint of the repo state that belongs to you, not the harness: refs outside its own branches, git
    /// config, hooks. An agent run must leave it unchanged. Empty when the harness owns the whole repo.
    func userGitState() async throws -> [String]

    /// A throwaway checkout of the latest `main` for agents that only read the code (the decomposer), so they
    /// see the repo and its instruction files (AGENTS.md). Nil when the workspace has none. Anything written
    /// to it is lost when it's removed.
    func createSnapshot() async throws -> URL?
    func removeSnapshot(_ directory: URL) async
}

extension Workspace {
    public func userGitState() async throws -> [String] { [] }
    public func createSnapshot() async throws -> URL? { nil }
    public func removeSnapshot(_ directory: URL) async {}

    /// Moves active leaves onto the latest `main`, independently putting conflicting leaves into rework.
    public func catchUpActiveLeaves(_ ids: [NodeID]) async throws -> ActiveLeavesCatchUpResult {
        var result = ActiveLeavesCatchUpResult()
        for id in ids {
            let directory = worktree(for: id)
            switch try await rebaseOntoMain(directory) {
            case .clean:
                result.rebased.append(id)
            case .conflict(let files):
                try await resetForRework(directory)
                result.rework[id] = Array(Set(files)).sorted()
            }
        }
        return result
    }
}
