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
/// "`main`" in the historical method names means the leaf's requirement branch.
///
/// Adapters: `SimulationWorkspace` (a git monorepo the simulator creates) and `RepositoryWorkspace` (an
/// existing repo, with worktrees outside it and landing on a local branch).
public protocol Workspace: Sendable {
    var supportsLandingBatches: Bool { get }
    func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace
    func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove
    /// Makes sure the repository exists and is usable. Called at the start of every round.
    func prepare() async throws
    /// Binds every descendant leaf to its requirement, creating its branch from current main once.
    /// Returns the starting commit only when the branch was created.
    func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String?
    func catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String
    /// A disposable checkout of the requirement tip for full final verification.
    func requirementWorktree(for requirement: NodeIdentity) async throws -> URL
    func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool

    func branch(for id: NodeID) -> String
    func worktree(for id: NodeID) -> URL
    /// A fresh branch from the latest `main`, checked out in the leaf's own working copy.
    func createWorktree(for id: NodeID) async throws -> URL
    /// Like `createWorktree(for:)`, but `paths` (folders or files) hold what the leaf's branch last had there:
    /// tests that came back are fixed where they are, not rewritten from nothing.
    func createWorktree(for id: NodeID, keeping paths: [String]) async throws -> URL
    func removeWorktree(for id: NodeID) async throws

    /// Commits everything in the working copy as the given run. Returns the new commit, or nil if nothing changed.
    @discardableResult
    func commitAll(in directory: URL, message: String, author: String) async throws -> String?
    /// Puts everything except `paths` (folders or files) back as the last commit has it: changes undone, new files
    /// removed. Files git ignores, such as build output, stay. The test author builds its tests against
    /// placeholder code this throws away.
    func discardChanges(keeping paths: [String], in directory: URL) async throws
    func head(of directory: URL) async throws -> String
    /// Every file this branch changed since it left `main`, relative to the repo's top folder.
    func changedFiles(in directory: URL) async throws -> [String]
    func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext
    /// Where every node's acceptance tests live, relative to the repo's top folder, ending in "/".
    var testArea: String { get }
    /// Where other work's existing tests live, which the test author may update where a criterion of its item
    /// deliberately changes what they check: `testArea` and any further folders the repo names, each ending in "/".
    /// Neither the implementer nor anyone else may change them.
    var updatableTestAreas: [String] { get }
    /// The folder with this node's own acceptance tests (inside `testArea`, no trailing "/").
    func testFolder(for spec: NodeSpec) -> String
    /// What agents need to know about the repo: its layout, how to build and test, what not to do.
    var agentContext: String { get }
    var designDocumentPaths: [String] { get }

    /// Replays the branch on top of the latest `main`. On conflict, everything is put back as it was.
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult
    func abortRebase(_ directory: URL) async throws
    /// Rework: keep only the branch's acceptance tests, drop the implementation, move onto the latest `main`.
    func resetForRework(_ directory: URL) async throws
    /// Keeps a failed implementer run's uncommitted changes (say, it ran out of time) outside the working copy,
    /// which the next run's rebase and catch-up clean. Returns the changed paths; empty when there were none. Saved
    /// work replaces a kept implementation; with nothing to save, the kept implementation stays.
    func saveUnfinishedWork(_ directory: URL, for id: NodeID) async throws -> [String]
    /// Puts saved unfinished work (or else a kept implementation) back into the working copy, uncommitted. Returns
    /// its paths; empty when nothing was saved or it no longer applies to the branch (then it's forgotten). It stays
    /// saved until the resumed run ends: a failure saves over it, anything else forgets it. A new worktree forgets
    /// unfinished work too, but not a kept implementation.
    func restoreUnfinishedWork(for id: NodeID, in directory: URL) async throws -> [String]
    func forgetUnfinishedWork(for id: NodeID) async throws
    /// Keeps the branch's implementation (everything after its acceptance-tests commit, committed or not, except
    /// changes to tests) before the tests go back to the test author. New worktrees don't forget it; the next implementer run gets it back as unfinished work
    /// when there is none of its own. Returns its paths; empty when there was no implementation.
    func keepImplementation(_ directory: URL, for id: NodeID) async throws -> [String]
    /// Keeps a failed test-author run's uncommitted changes (its tests, placeholders, kept earlier tests) outside
    /// the working copy. Unlike unfinished work, a new or removed worktree doesn't forget it: the next test-author
    /// run starts from a fresh worktree and puts the draft back. Returns the changed paths; empty when there were none.
    func saveTestDraft(_ directory: URL, for id: NodeID) async throws -> [String]
    /// Puts a saved test draft back into the working copy, uncommitted, and returns its paths. When it no longer
    /// applies as a whole (the landing branch changed under it), only its files in the test area come back.
    /// Empty when nothing was saved.
    func restoreTestDraft(for id: NodeID, in directory: URL) async throws -> [String]
    func forgetTestDraft(for id: NodeID) async throws
    /// Moves `main` to the leaf's (already rebased and checked) branch. Returns the new `main`.
    func landOnMain(_ id: NodeID) async throws -> String
    /// Why the leaf's landing (requirement) branch can't move right now and what a person does about it (e.g. a
    /// checkout has it checked out); nil when it can. Nothing lands meanwhile, and nothing fails: landing goes on
    /// once this is nil.
    func whyLandingMustWait(for id: NodeID) async throws -> String?
    /// Whether `branch` (nil: `main`) has everything `commit` has, merged, squashed or rebased. Another requirement's
    /// landed work counts as done for work that depends on it only once it's where that work starts, since
    /// requirement branches don't share commits.
    func branch(_ branch: String?, hasEverythingIn commit: String) async throws -> Bool

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
    /// A snapshot of this leaf's requirement branch, for landing failure diagnosis.
    func createSnapshot(for id: NodeID) async throws -> URL?
    func removeSnapshot(_ directory: URL) async
}

public extension Workspace {
    var supportsLandingBatches: Bool { false }
    func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
        throw AgentFailure("This workspace does not support batch landing.")
    }
    func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
        throw AgentFailure("This workspace does not support batch landing.")
    }
    func requirementWorktree(for requirement: NodeIdentity) async throws -> URL {
        throw AgentFailure("This workspace does not support final requirement verification.")
    }
    func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool {
        throw AgentFailure("This workspace does not support requirement merge detection.")
    }
    func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? { nil }
    func catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String {
        throw AgentFailure("This workspace does not support requirement catch-up.")
    }
    func createSnapshot(for id: NodeID) async throws -> URL? { try await createSnapshot() }
    var updatableTestAreas: [String] { testArea.isEmpty ? [] : [testArea] }
    /// Whether `path` (relative to the repo's top folder) lies where other work's tests may be updated.
    func isInUpdatableTestArea(_ path: String) -> Bool {
        updatableTestAreas.contains { !$0.isEmpty && path.hasPrefix($0) }
    }
    func createWorktree(for id: NodeID, keeping paths: [String]) async throws -> URL { try await createWorktree(for: id) }
    func discardChanges(keeping paths: [String], in directory: URL) async throws {}
    func saveUnfinishedWork(_ directory: URL, for id: NodeID) async throws -> [String] { [] }
    func restoreUnfinishedWork(for id: NodeID, in directory: URL) async throws -> [String] { [] }
    func forgetUnfinishedWork(for id: NodeID) async throws {}
    func keepImplementation(_ directory: URL, for id: NodeID) async throws -> [String] { [] }
    func saveTestDraft(_ directory: URL, for id: NodeID) async throws -> [String] { [] }
    func restoreTestDraft(for id: NodeID, in directory: URL) async throws -> [String] { [] }
    func forgetTestDraft(for id: NodeID) async throws {}
}

extension Workspace {
    public func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
        throw AgentFailure("This workspace does not provide review context.")
    }
    public var designDocumentPaths: [String] { [] }
    public func userGitState() async throws -> [String] { [] }
    public func createSnapshot() async throws -> URL? { nil }
    public func removeSnapshot(_ directory: URL) async {}
    public func whyLandingMustWait(for id: NodeID) async throws -> String? { nil }
    /// Always true for simulation and test fakes: nobody merges their requirement branches into `main`, so
    /// checking would hold dependent work forever.
    public func branch(_ branch: String?, hasEverythingIn commit: String) async throws -> Bool { true }

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

    public func catchUpRequirements(in state: WorkingState, busy: Set<NodeID>) async throws -> [NodeID: ActiveLeavesCatchUpResult] {
        var results: [NodeID: ActiveLeavesCatchUpResult] = [:]
        for requirement in state.roots where !requirement.ticketClosed {
            let leaves = state.requirementLeaves(for: requirement.id)
            guard requirement.requirementBranch != nil || leaves.contains(where: { $0.testsDigest != nil }) else { continue }
            _ = try await prepareRequirementBranch(for: requirement.identity, leaves: leaves.map(\.id))
            _ = try await catchUpRequirementBranch(for: requirement.identity)
            let active = leaves.filter {
                $0.testsDigest != nil && $0.phase != .proven && !$0.ticketClosed &&
                    $0.activeRun == nil && !busy.contains($0.id)
            }
            results[requirement.id] = try await catchUpActiveLeaves(active.map(\.id))
        }
        return results
    }
}
