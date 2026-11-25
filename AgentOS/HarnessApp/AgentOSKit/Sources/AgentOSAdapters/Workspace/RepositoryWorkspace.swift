import AgentOSCore
import Foundation
import Synchronization

/// The workspace on an existing repo (real-repo mode, phase 4). Your checkout and default branch are never
/// touched; everything happens in harness-owned worktrees outside the repo folder:
///
///     <storage>/                       ~/Library/Application Support/AgentOS/repos/<repo-id>/
///       worktrees/<node>/              a leaf's branch `agentos/leaf/<node>`, where its agents work
///       trash/                         removed worktrees, deleted in the background
///       exclude                        build output never committed from a worktree
///
/// Work starts from and lands on its top-level requirement's branch, created from the default branch.
/// Landing moves only that branch ref (fast-forward, compare-and-swap); you merge it yourself.
/// A leaf's acceptance tests are a folder (and suite) of its own in the configured existing test target.
public struct RepositoryWorkspace: Workspace, MainTipRepository {
    public static let branchPrefix = "agentos/leaf/"

    public let root: URL
    public let storage: URL
    public let config: RepoConfig
    public let leafTests: RepoConfig.LeafTests
    public let landingBranch: String
    public let defaultBranch: String
    public let protectedPaths: [String]
    /// Worktrees share the repo's `.git`: adding, removing and pruning them one at a time avoids git's lock
    /// errors when leaves start side by side. Agents and checks still run in parallel.
    let worktreeLock = AsyncSemaphore(1)
    let mergeAidLock = AsyncSemaphore(1)
    let mainReferenceLock = AsyncSemaphore(1)
    let mainReference = MainReferenceSelection()
    private let requirementBranches = RequirementBranchBindings()
    /// "branchTip commit" pairs found not contained: the same until the branch moves.
    private let notContained = SeenPairs()

    public struct NotConfigured: Error, CustomStringConvertible {
        public let description = "\(RepoConfig.path) has no leafTests: leaves have nowhere to put their acceptance tests."
    }

    public init(root: URL, storage: URL, config: RepoConfig, landingBranch: String, defaultBranch: String,
                protectedPaths: [String] = []) throws {
        guard let leafTests = config.leafTests else { throw NotConfigured() }
        self.root = root
        self.storage = storage
        self.config = config
        self.leafTests = RepoConfig.LeafTests(target: leafTests.target, folder: Self.trimmed(leafTests.folder),
                                              updatable: leafTests.updatable?.map(Self.trimmed))
        self.landingBranch = landingBranch
        self.defaultBranch = defaultBranch
        self.protectedPaths = protectedPaths
    }

    public var worktreesDirectory: URL { storage.appending(path: "worktrees", directoryHint: .isDirectory) }
    public var artifactsDirectory: URL { storage.appending(path: "artifacts", directoryHint: .isDirectory) }
    var trashDirectory: URL { storage.appending(path: "trash", directoryHint: .isDirectory) }
    var excludeFile: URL { storage.appending(path: "exclude") }

    public func worktree(for id: NodeID) -> URL { worktreesDirectory.appending(path: id) }
    public func branch(for id: NodeID) -> String { Self.branchPrefix + id }

    /// Prepares storage without creating any branches.
    public func prepare() async throws {
        try await git(["rev-parse", "--git-dir"], in: root)
        try FileManager.default.createDirectory(at: worktreesDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: excludeFile.path) {
            try Self.buildOutput.joined(separator: "\n").write(to: excludeFile, atomically: true, encoding: .utf8)
        }
        try await worktreeLock.withPermit { try await git(["worktree", "prune"], in: root) }
        // Left over when the app quit before deleting them.
        for item in (try? FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)) ?? [] {
            Self.deleteInBackground(item)
        }
    }

    public func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? {
        let branch = "agentos/\(requirement.ticketKey)"
        let from: String? = try await worktreeLock.withPermit {
            guard try await !branchExists(branch) else { return nil }
            let main = try await localMainTip()
            try await git(["branch", "--no-track", branch, main], in: root)
            return main
        }
        requirementBranches.bind(leaves, to: branch)
        return from
    }

    func landingBranch(for id: NodeID) throws -> String {
        try requirementBranches.branch(for: id)
    }

    /// Never committed from a worktree, even if the repo's .gitignore misses them.
    static let buildOutput = [".build/", "DerivedData/", "xcuserdata/", ".swiftpm/", "*.xcuserstate", ".DS_Store", ""]

    // MARK: Branch per leaf

    public func createWorktree(for id: NodeID) async throws -> URL {
        try await createWorktree(for: id, keepingPaths: [])
    }

    public func createWorktree(for id: NodeID, keeping paths: [String]) async throws -> URL {
        try await createWorktree(for: id, keepingPaths: paths.map(Self.trimmed).filter { !$0.isEmpty })
    }

    private func createWorktree(for id: NodeID, keepingPaths paths: [String]) async throws -> URL {
        let landingBranch = try landingBranch(for: id)
        let directory = worktree(for: id)
        try await worktreeLock.withPermit {
            // Read before -B moves the branch back to the landing branch.
            let previous = paths.isEmpty ? nil : (try? await git(["rev-parse", "--verify", "--quiet",
                                                                  branch(for: id) + "^{commit}"], in: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await removeWorktreeNow(for: id)
            try FileManager.default.createDirectory(at: worktreesDirectory, withIntermediateDirectories: true)
            try await git(["worktree", "add", "-q", "-B", branch(for: id), directory.path, landingBranch], in: root)
            if let previous, !previous.isEmpty {
                for path in paths where !(try await git(["ls-tree", "--name-only", previous, "--", path], in: root)).isEmpty {
                    _ = try await git(["checkout", previous, "--", path], in: directory)
                }
            }
        }
        return directory
    }

    public func removeWorktree(for id: NodeID) async throws {
        try await worktreeLock.withPermit {
            // Removed for good (retested, replanned, landed): a kept implementation no longer applies either.
            _ = try? await git(["update-ref", "-d", keptImplementationRef(for: id)], in: root)
            try await removeWorktreeNow(for: id)
        }
    }

    private func removeWorktreeNow(for id: NodeID) async throws {
        // A new or removed worktree means the work starts over: unfinished work from before no longer applies.
        _ = try? await git(["update-ref", "-d", unfinishedRef(for: id)], in: root)
        let directory = worktree(for: id)
        // Moved aside rather than `git worktree remove`d: deleting a worktree's build output can outlast git's time
        // limit on a busy machine, leaving it half deleted and still holding the leaf's branch. Once moved, prune
        // forgets it, and the files are deleted without a time limit.
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let trash = trashDirectory.appending(path: "\(id)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: directory, to: trash)
            Self.deleteInBackground(trash)
        }
        try await git(["worktree", "prune"], in: root)
    }

    private static func deleteInBackground(_ item: URL) {
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: item) }
    }

    // MARK: Read-only snapshot

    public var snapshotsDirectory: URL { storage.appending(path: "snapshots", directoryHint: .isDirectory) }

    /// A detached worktree of the landing branch: no branch of its own, so nothing in it can land.
    public func createSnapshot() async throws -> URL? {
        try await createSnapshot(at: localMainTip())
    }

    public func createSnapshot(for id: NodeID) async throws -> URL? {
        try await createSnapshot(at: landingBranch(for: id))
    }

    func createSnapshot(at branch: String) async throws -> URL {
        let directory = snapshotsDirectory.appending(path: UUID().uuidString)
        try await worktreeLock.withPermit {
            try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            try await git(["worktree", "add", "-q", "--detach", directory.path, branch], in: root)
        }
        return directory
    }

    public func removeSnapshot(_ directory: URL) async {
        try? await worktreeLock.withPermit {
            _ = try? await git(["worktree", "remove", "--force", directory.path], in: root)
            _ = try? await git(["worktree", "prune"], in: root)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    public func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
        try await git(["add", "-A"], in: directory)
        guard try await !git(["diff", "--cached", "--name-only"], in: directory).isEmpty else { return nil }
        try await git(["-c", "user.name=\(author)", "-c", "user.email=\(author)@agents.agentos.local",
                       "commit", "-q", "--no-verify", "-m", message], in: directory)
        return try await head(of: directory)
    }

    public func discardChanges(keeping paths: [String], in directory: URL) async throws {
        let kept = paths.map(Self.trimmed).filter { !$0.isEmpty }
        let outside = ["."] + kept.map { ":(exclude)\($0)" }
        try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + outside, in: directory)
        // Staged first: clean takes a wholly untracked parent folder (say a first `Tests/`) as one, tests and all.
        let existing = kept.filter { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        if !existing.isEmpty {
            try await git(["add", "-A", "--"] + existing, in: directory)
        }
        // Without -x: ignored build output stays, so the next build in this working copy is quick.
        try await git(["clean", "-fdq", "--"] + outside, in: directory)
    }

    public func head(of directory: URL) async throws -> String {
        try await git(["rev-parse", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func changedFiles(in directory: URL) async throws -> [String] {
        let landingBranch = try landingBranch(for: directory.lastPathComponent)
        let base = try await leafBase(in: directory, landingBranch: landingBranch)
        // Both sides of a rename, and raw (unquoted) names, so a moved or oddly named protected file can't slip by.
        return try await git(["diff", "--name-only", "--no-renames", "-z", "\(base)...HEAD"], in: directory)
            .split(separator: "\0").map(String.init)
    }

    public func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
        guard try await git(["status", "--porcelain"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure("Review requires a clean committed candidate. Check the worktree, then add harness:retry.")
        }
        let commit = try await head(of: directory)
        let files = try await changedFiles(in: directory)
        let diff = try await git(["diff", "--no-ext-diff", "--no-color", "\(branch)...HEAD"], in: directory)
        let history = files.isEmpty ? "" : try await git(
            ["log", "-20", "--format=%H%x09%s", branch, "--"] + files, in: directory)
        let recent = history.split(separator: "\n").compactMap { line -> LandedWorkItem? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let title = String(parts[1])
            let node = String(title.split(separator: ":").first ?? parts[1])
            return LandedWorkItem(ticket: node.hasPrefix("wn-") ? String(node.dropFirst(3)) : node,
                                  title: title, commit: String(parts[0]))
        }
        // Only this leaf's own evidence: a file it didn't change came from other work.
        let evidenceFile = directory.appending(path: Self.uiEvidenceFile)
        var evidence = files.contains(Self.uiEvidenceFile) && FileManager.default.fileExists(atPath: evidenceFile.path)
            ? try JSONDecoder().decode(UIReviewEvidence.self, from: Data(contentsOf: evidenceFile)) : nil
        if var ui = evidence {
            func preserve(_ path: String, named name: String) throws -> String {
                let file = (path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path))
                    .resolvingSymlinksInPath().standardizedFileURL
                let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard file.path.hasPrefix(root) else {
                    throw AgentFailure("UI evidence must be inside the candidate worktree: \(path)")
                }
                return try FileArtifactStore(directory: artifactsDirectory).put(
                    named: "\(commit)-\(name)-\(file.lastPathComponent)", contents: Data(contentsOf: file)).path
            }
            ui.snapshotPaths = try ui.snapshotPaths.enumerated().map {
                try preserve($0.element, named: "snapshot-\($0.offset)")
            }
            ui.beforeScreenshot = try ui.beforeScreenshot.map { try preserve($0, named: "before") }
            ui.afterScreenshot = try ui.afterScreenshot.map { try preserve($0, named: "after") }
            evidence = ui
        }
        return ReviewContext(baseBranch: branch, commit: commit, fullDiff: diff,
                             changedFiles: files, recentChanges: recent, uiEvidence: evidence)
    }

    // MARK: Tests

    public var testArea: String { leafTests.folder.isEmpty ? "" : leafTests.folder + "/" }

    /// The test area, then the repo's further folders. The repo's top folder, absolute paths and paths with ".."
    /// never count: other work's tests must be somewhere agents can tell apart from everything else.
    public var updatableTestAreas: [String] {
        var areas: [String] = testArea.isEmpty ? [] : [testArea]
        for folder in leafTests.updatable ?? [] where !folder.isEmpty && folder != "." && !folder.hasPrefix("/")
            && !folder.split(separator: "/").contains("..") && !areas.contains(folder + "/") {
            areas.append(folder + "/")
        }
        return areas
    }

    /// A folder per leaf in the existing test target; its suite has the same name, so `test.only` can select it.
    public func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }

    public var agentContext: String {
        var lines = [
            "The current directory is a git working copy of an existing repo, on a branch of its own for one work item.",
            "Run commands from this top folder.",
        ]
        if let prepare = config.build?.prepare { lines.append("Before building, run: `\(prepare)`.") }
        if let build = config.build?.command { lines.append("Build: `\(build)`.") }
        lines.append("Run all tests: `\(config.test.command)`.")
        if let only = config.test.only {
            lines.append("Run one test suite: `\(config.test.command) \(only)`, with {suite} replaced by the suite name.")
        }
        lines.append("Acceptance tests of work items live in the test target \(leafTests.target), folder \(testArea), " +
                     "one subfolder and one suite per work item.")
        let others = updatableTestAreas.filter { $0 != testArea }
        if !others.isEmpty {
            lines.append("Other work items' existing tests also live in \(others.joined(separator: ", ")).")
        }
        lines.append("Use git only to read history (git log, git show, git diff, git status); never change branches, " +
                     "commits or the index. Don't install packages and don't use the network.")
        if !protectedPaths.isEmpty {
            lines.append("Never change these protected paths: \(protectedPaths.joined(separator: ", ")).")
        }
        let documents = designDocumentPaths
        if !documents.isEmpty {
            lines.append("Read these design documents where relevant: \(documents.joined(separator: ", ")).")
        }
        return lines.joined(separator: " ")
    }

    public var designDocumentPaths: [String] {
        (config.agents ?? RepoConfig.Agents()).contextFiles(in: trackedFiles())
    }

    private func trackedFiles() -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "ls-tree", "-r", "--name-only", "-z", defaultBranch]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        } catch {
            return []
        }
    }

    // MARK: Landing

    public func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
        let landingBranch = try landingBranch(for: directory.lastPathComponent)
        let base = try await leafBase(in: directory, landingBranch: landingBranch)
        try await discardUncommitted(directory)
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "rebase", "-q", "--onto", landingBranch, base], in: directory
        )
        guard result.status != 0 else { return .clean }
        let files = (try? await git(["diff", "--name-only", "--diff-filter=U"], in: directory))?
            .split(separator: "\n").map(String.init) ?? []
        try await abortRebase(directory)
        return .conflict(files: files)
    }

    public func abortRebase(_ directory: URL) async throws {
        _ = try await ProcessRunner.run("/usr/bin/env", ["git", "rebase", "--abort"], in: directory)
    }

    public func resetForRework(_ directory: URL) async throws {
        let landingBranch = try landingBranch(for: directory.lastPathComponent)
        let base = try await leafBase(in: directory, landingBranch: landingBranch)
        try await discardUncommitted(directory)
        let commits = try await git(["rev-list", "--reverse", "\(base)..HEAD"], in: directory).split(separator: "\n")
        guard let testsCommit = commits.first else { return }
        try await git(["reset", "-q", "--hard", String(testsCommit)], in: directory)
        try await git(["rebase", "-q", "--onto", landingBranch, base], in: directory)
    }

    // MARK: Unfinished work

    public static let unfinishedPrefix = "agentos/unfinished/"
    private func unfinishedRef(for id: NodeID) -> String { "refs/heads/" + Self.unfinishedPrefix + id }

    private func keptImplementationRef(for id: NodeID) -> String { "refs/heads/agentos/kept-implementation/" + id }

    public func saveUnfinishedWork(_ directory: URL, for id: NodeID) async throws -> [String] {
        let paths = try await save(directory, to: unfinishedRef(for: id), message: "agentos: unfinished work on \(id)")
        // What it saved started from the kept implementation, if there was one. Nothing saved (a run that failed
        // before getting it back, say) leaves the kept implementation for the next run.
        if !paths.isEmpty {
            _ = try? await git(["update-ref", "-d", keptImplementationRef(for: id)], in: root)
        }
        return paths
    }

    public func keepImplementation(_ directory: URL, for id: NodeID) async throws -> [String] {
        let landingBranch = try landingBranch(for: id)
        let base = try await leafBase(in: directory, landingBranch: landingBranch)
        let ref = keptImplementationRef(for: id)
        let commits = try await git(["rev-list", "--reverse", "\(base)..HEAD"], in: directory)
            .split(separator: "\n").map(String.init)
        guard let tests = commits.first else {
            _ = try? await git(["update-ref", "-d", ref], in: root)
            return []
        }
        // Uncommitted work counts too (an implementer reporting a broken test hasn't submitted), but not changes to
        // tests: those are the test author's to make, and would clash with its fixes.
        let areas = updatableTestAreas.map(Self.trimmed).filter { !$0.isEmpty }
        let tree: String
        do {
            // From the branch as committed, so changes staged earlier don't slip past the exclusions.
            try await git(["reset", "-q"], in: directory)
            try await git(["add", "-A", "--", ".", ":(top,exclude,literal).agentos/scratch",
                           ":(top,exclude,literal).agentos-report.json"]
                          + areas.map { ":(top,exclude,literal)" + $0 }, in: directory)
            // Tests as the test author committed them, also where later commits changed them.
            if !areas.isEmpty {
                try await git(["reset", "-q", tests, "--"] + areas.map { ":(top,literal)" + $0 }, in: directory)
            }
            tree = try await git(["write-tree"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
            try await git(["reset", "-q"], in: directory)
        } catch {
            _ = try? await git(["reset", "-q"], in: directory)
            throw error
        }
        let testsTree = try await git(["rev-parse", tests + "^{tree}"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree != testsTree else {
            _ = try? await git(["update-ref", "-d", ref], in: root)
            return []
        }
        let commit = try await git(["-c", "user.name=agentos", "-c", "user.email=agentos@agents.agentos.local",
                                    "commit-tree", tree, "-p", tests, "-m", "agentos: implementation kept for \(id)"],
                                   in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["update-ref", ref, commit], in: root)
        return try await git(["diff", "--name-only", "--no-renames", "-z", tests, commit], in: root)
            .split(separator: "\0").map(String.init)
    }

    /// Commits the working copy's uncommitted changes to `ref` without moving the branch; deletes `ref` when
    /// there are none (the run undid what an earlier attempt left: that's not to come back).
    private func save(_ directory: URL, to ref: String, message: String) async throws -> [String] {
        // Not the run's scratch folder or report: they belong to that run only.
        try await git(["add", "-A", "--", ".", ":(exclude).agentos/scratch", ":(exclude).agentos-report.json"], in: directory)
        do {
            let paths = try await git(["diff", "--cached", "--name-only", "--no-renames", "-z"], in: directory)
                .split(separator: "\0").map(String.init)
            if !paths.isEmpty {
                let tree = try await git(["write-tree"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
                let commit = try await git(["-c", "user.name=agentos", "-c", "user.email=agentos@agents.agentos.local",
                                            "commit-tree", tree, "-p", "HEAD", "-m", message],
                                           in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
                try await git(["update-ref", ref, commit], in: root)
            } else {
                try await git(["update-ref", "-d", ref], in: root)
            }
            try await git(["reset", "-q"], in: directory)
            return paths
        } catch {
            _ = try? await git(["reset", "-q"], in: directory)
            throw error
        }
    }

    public func forgetUnfinishedWork(for id: NodeID) async throws {
        try await git(["update-ref", "-d", unfinishedRef(for: id)], in: root)
        try await git(["update-ref", "-d", keptImplementationRef(for: id)], in: root)
    }

    public func restoreUnfinishedWork(for id: NodeID, in directory: URL) async throws -> [String] {
        let unfinished = unfinishedRef(for: id)
        let hasUnfinished = (try? await git(["rev-parse", "--verify", "--quiet", unfinished + "^{commit}"], in: root)) != nil
        let ref = hasUnfinished ? unfinished : keptImplementationRef(for: id)
        guard let commit = (try? await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !commit.isEmpty else { return [] }
        let applied = try await ProcessRunner.run("/usr/bin/env", ["git", "cherry-pick", "--no-commit", commit], in: directory)
        guard applied.status == 0 else {
            // It no longer fits the branch (the tests or main changed under it): start over.
            _ = try? await ProcessRunner.run("/usr/bin/env", ["git", "cherry-pick", "--abort"], in: directory)
            try await discardUncommitted(directory)
            try await git(["update-ref", "-d", ref], in: root)
            return []
        }
        try await git(["reset", "-q"], in: directory)
        return try await git(["diff", "--name-only", "--no-renames", "-z", commit + "^", commit], in: root)
            .split(separator: "\0").map(String.init)
    }

    // MARK: Test drafts

    public static let draftPrefix = "agentos/drafts/"
    private func draftRef(for id: NodeID) -> String { "refs/heads/" + Self.draftPrefix + id }

    public func saveTestDraft(_ directory: URL, for id: NodeID) async throws -> [String] {
        try await save(directory, to: draftRef(for: id), message: "agentos: test draft of \(id)")
    }

    public func forgetTestDraft(for id: NodeID) async throws {
        try await git(["update-ref", "-d", draftRef(for: id)], in: root)
    }

    public func restoreTestDraft(for id: NodeID, in directory: URL) async throws -> [String] {
        let ref = draftRef(for: id)
        guard let commit = (try? await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !commit.isEmpty else { return [] }
        let paths = try await git(["diff", "--name-only", "--no-renames", "-z", commit + "^", commit], in: root)
            .split(separator: "\0").map(String.init)
        let applied = try await ProcessRunner.run("/usr/bin/env", ["git", "cherry-pick", "--no-commit", commit], in: directory)
        if applied.status == 0 {
            try await git(["reset", "-q"], in: directory)
            return paths
        }
        // The landing branch changed under the placeholders: the tests themselves are what's worth keeping.
        _ = try? await ProcessRunner.run("/usr/bin/env", ["git", "cherry-pick", "--abort"], in: directory)
        try await discardUncommitted(directory)
        let areas = updatableTestAreas
        guard !areas.isEmpty else { return [] }
        let changed = Set(paths)
        let tests = try await git(["ls-tree", "-r", "-z", "--name-only", commit, "--"] + areas, in: root)
            .split(separator: "\0").map(String.init).filter { changed.contains($0) }
        guard !tests.isEmpty else { return [] }
        _ = try await git(["checkout", commit, "--"] + tests, in: directory)
        try await git(["reset", "-q"], in: directory)
        return tests
    }

    /// Fast-forwards the landing branch to the leaf's branch by moving the ref only (compare-and-swap), so no
    /// checkout is involved. Refuses if a checkout has the landing branch checked out: it would fall out of step.
    public func landOnMain(_ id: NodeID) async throws -> String {
        let landingBranch = try landingBranch(for: id)
        let reviewed = try await revision(branch(for: id))
        let old = try await revision(landingBranch)
        let ancestor = try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", "--is-ancestor", old, reviewed], in: root)
        guard ancestor.status == 0 else { throw AgentFailure("\(branch(for: id)) is not a fast-forward of \(landingBranch)") }
        if let reason = try await whyLandingMustWait(for: id) { throw AgentFailure(reason) }
        let tip = try await withoutUIEvidence(reviewed, id: id)
        try await git(["update-ref", "-m", "agentos: land \(id)", "refs/heads/\(landingBranch)", tip, old], in: root)
        return tip
    }

    public func whyLandingMustWait(for id: NodeID) async throws -> String? {
        let landingBranch = try landingBranch(for: id)
        guard let checkout = try await checkout(of: landingBranch) else { return nil }
        return "\(landingBranch) is checked out in \(checkout.path). Switch that checkout to another branch so the " +
            "harness can move \(landingBranch)"
    }

    /// UI evidence is committed with the leaf so it is reviewed, reset and retried like its code. It never lands:
    /// on main it would be read as every later leaf's evidence. A child commit without it lands instead, so the
    /// leaf's branch and worktree keep the reviewed (and approved) commit.
    private func withoutUIEvidence(_ commit: String, id: NodeID) async throws -> String {
        let paths = [Self.uiEvidenceFile, Self.uiEvidenceFolder]
        guard !(try await git(["ls-tree", "--name-only", commit, "--"] + paths, in: root))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return commit }
        let index = FileManager.default.temporaryDirectory.appending(path: "agentos-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        try await git(["read-tree", commit], in: root, environment: environment)
        try await git(["rm", "-r", "-q", "-f", "--cached", "--ignore-unmatch", "--"] + paths, in: root, environment: environment)
        let tree = try await git(["write-tree"], in: root, environment: environment).trimmingCharacters(in: .whitespacesAndNewlines)
        return try await git(["-c", "user.name=AgentOS", "-c", "user.email=harness@agents.agentos.local",
                              "commit-tree", tree, "-p", commit, "-m", "\(id): remove UI evidence before landing"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let uiEvidenceFile = ".agentos-ui-evidence.json"
    static let uiEvidenceFolder = ".agentos-ui-evidence"
    static func isUIEvidence(_ path: String) -> Bool {
        path == uiEvidenceFile || path.hasPrefix(uiEvidenceFolder + "/")
    }

    // MARK: Repo

    public func existingComponents() -> [String] { config.components ?? [] }

    public func localMainTip() async throws -> String {
        if let commit = mainReference.commit { return commit }
        return try await revision(defaultBranch)
    }

    /// Also true for a commit that's gone from the repository (its branch deleted and cleaned up): there's nothing
    /// left to check or to merge. Squashed or rebased work counts once any commit on the branch since it forked had
    /// it, so later changes to the same lines don't hide it again.
    public func branch(_ branch: String?, hasEverythingIn commit: String) async throws -> Bool {
        let target: String
        if let branch { target = try await revision(branch) }
        else { target = try await localMainTip() }
        let exists = try await ProcessRunner.run("/usr/bin/env", ["git", "cat-file", "-e", commit + "^{commit}"], in: root)
        guard exists.status == 0 else { return true }
        let ancestor = try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", "--is-ancestor", commit, target],
                                                   in: root)
        if ancestor.status == 0 { return true }
        if notContained.contains("\(target) \(commit)") { return false }
        let base = try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", target, commit], in: root)
        guard base.status == 0 else { return false }
        let since = base.output.trimmingCharacters(in: .whitespacesAndNewlines) + ".." + target
        for line in try await git(["log", "--first-parent", "--format=%H %T", since], in: root).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            // Merging it there would change nothing.
            let merged = try await ProcessRunner.run(
                "/usr/bin/env", ["git", "merge-tree", "--write-tree", String(parts[0]), commit], in: root)
            if merged.status == 0, merged.output.split(whereSeparator: \.isNewline).first == parts[1] { return true }
        }
        notContained.insert("\(target) \(commit)")
        return false
    }

    /// Nothing to do: the check runner runs the config's `build.prepare` before building.
    public func prepareBuild(in directory: URL) async throws {}

    // MARK: Your repo state

    /// Tags, remote-tracking refs, the stash and other refs by commit; which local branches exist (a branch you
    /// commit to while agents work moves, so only creating or deleting one counts); and the content of the shared
    /// git config, hooks and `info/` files (except `info/refs`), which affect every checkout of the repo.
    /// The harness's own branches don't count, nor do origin's tracking refs for them (where its fetch refspec puts
    /// them): publishing a requirement pushes its branch, which moves that ref while other agents may be at work.
    public func userGitState() async throws -> [String] {
        var state: [String] = []
        let originFetch = ((try? await git(["config", "--get-all", "remote.origin.fetch"], in: root)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        for line in try await watchedRefs().split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let ref = String(line[line.index(after: space)...])
            if ref.hasPrefix("refs/heads/agentos/") || Self.tracksHarnessBranch(ref, refspecs: originFetch) { continue }
            state.append(ref.hasPrefix("refs/heads/") ? "branch \(ref)" : String(line))
        }
        let common = URL(filePath: try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
        var files = ["config"]
        for folder in ["hooks", "info"] {
            let names = (try? FileManager.default.subpathsOfDirectory(atPath: common.appending(path: folder).path)) ?? []
            files += names.map { "\(folder)/\($0)" }
        }
        // Written by `git update-server-info`, which git's own housekeeping (`gc --auto`, repack) runs after
        // any commit: a list of the refs already watched above, not a setting.
        files.removeAll { $0 == "info/refs" }
        for file in files.sorted() {
            if var data = FileManager.default.contents(atPath: common.appending(path: file).path) {
                // Leftover merge aids from older harness versions, removed while another agent may be running.
                if let text = String(data: data, encoding: .utf8) {
                    if file == "config" {
                        data = Data(RequirementMergeAid.unmanagedConfiguration(text).utf8)
                    } else if file == "info/attributes" {
                        let unmanaged = RequirementMergeAid.unmanagedAttributes(text)
                        if unmanaged.isEmpty { continue }
                        data = Data(unmanaged.utf8)
                    }
                }
                state.append("\(Hashing.sha256(data)) \(file)")
            }
        }
        return state
    }

    /// Whether a fetch refspec (`+refs/heads/*:refs/remotes/origin/*`) maps an `agentos/` branch to `ref`.
    static func tracksHarnessBranch(_ ref: String, refspecs: [String]) -> Bool {
        refspecs.contains { refspec in
            guard !refspec.hasPrefix("^") else { return false }
            let parts = refspec.drop { $0 == "+" }.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let (source, destination) = (parts[0], parts[1])
            let sourceParts = source.split(separator: "*", omittingEmptySubsequences: false)
            let destinationParts = destination.split(separator: "*", omittingEmptySubsequences: false)
            guard sourceParts.count == destinationParts.count, sourceParts.count <= 2 else { return false }
            if sourceParts.count == 1 { return destination == ref && source.hasPrefix("refs/heads/agentos/") }
            let (prefix, suffix) = (destinationParts[0], destinationParts[1])
            guard ref.count >= prefix.count + suffix.count, ref.hasPrefix(prefix), ref.hasSuffix(suffix) else { return false }
            let branch = sourceParts[0] + ref.dropFirst(prefix.count).dropLast(suffix.count) + sourceParts[1]
            return branch.hasPrefix("refs/heads/agentos/")
        }
    }

    // MARK: Helpers

    private func branchExists(_ name: String) async throws -> Bool {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git", "show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: root)
        return result.status == 0
    }

    private func revision(_ name: String) async throws -> String {
        let ref = name.hasPrefix("origin/") ? "refs/remotes/\(name)" : "refs/heads/\(name)"
        return try await git(["rev-parse", "--verify", ref], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The working copy (your checkout or a worktree) that has `branch` checked out, if any.
    func checkout(of branch: String) async throws -> URL? {
        var path: String?
        for line in try await git(["worktree", "list", "--porcelain"], in: root).split(separator: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)", let path { return URL(filePath: path) }
        }
        return nil
    }

    /// Check byproducts (generated projects, logs) left in a worktree after its work was committed.
    /// Everything the leaf's working copy changed since it left the landing branch, committed or not.
    public func changes(for id: NodeID) async throws -> String {
        try await WorkingChanges.describe(worktree(for: id), since: landingBranch(for: id),
                                          gitOptions: ["-c", "core.excludesFile=\(excludeFile.path)"])
    }

    private func discardUncommitted(_ directory: URL) async throws {
        try await git(["reset", "-q", "--hard"], in: directory)
        try await git(["clean", "-fdq"], in: directory)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> String {
        let result = try await GitLocks.retryingAfterStaleLock {
            try await ProcessRunner.run(
                "/usr/bin/env", ["git", "-c", "core.excludesFile=\(excludeFile.path)"] + arguments, in: directory,
                timeout: .seconds(120), environment: environment)
        }
        guard result.status == 0 else {
            throw AgentFailure("git \(arguments.first ?? "") failed: \(result.output.suffix(300))")
        }
        return result.output
    }

    private static func trimmed(_ folder: String) -> String {
        var folder = folder
        while folder.hasPrefix("./") { folder.removeFirst(2) }
        while folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }
}

/// For repos whose tickets don't wait on other systems yet: nothing is ever delivered.
public struct NoExternalSystem: ExternalDependencySource {
    public init() {}
    public func deliveredKeys() async -> Set<String> { [] }
}

private final class SeenPairs: Sendable {
    private let pairs = Mutex<Set<String>>([])
    func contains(_ pair: String) -> Bool { pairs.withLock { $0.contains(pair) } }
    func insert(_ pair: String) { _ = pairs.withLock { $0.insert(pair) } }
}
