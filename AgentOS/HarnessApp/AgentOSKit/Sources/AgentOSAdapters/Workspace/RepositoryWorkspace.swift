import AgentOSCore
import Foundation

/// The workspace on an existing repo (real-repo mode, phase 4). Your checkout and default branch are never
/// touched; everything happens in harness-owned worktrees outside the repo folder:
///
///     <storage>/                       ~/Library/Application Support/AgentOS/repos/<repo-id>/
///       worktrees/<node>/              a leaf's branch `agentos/leaf/<node>`, where its agents work
///       exclude                        build output never committed from a worktree
///
/// Work is based on, and lands on, the landing branch (`agentos/main`), created from the default branch the
/// first time. Landing moves only that branch ref (fast-forward, compare-and-swap); you merge it yourself.
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
    private let worktreeLock = AsyncSemaphore(1)

    public struct NotConfigured: Error, CustomStringConvertible {
        public let description = "\(RepoConfig.path) has no leafTests: leaves have nowhere to put their acceptance tests."
    }

    public init(root: URL, storage: URL, config: RepoConfig, landingBranch: String, defaultBranch: String,
                protectedPaths: [String] = []) throws {
        guard let leafTests = config.leafTests else { throw NotConfigured() }
        self.root = root
        self.storage = storage
        self.config = config
        self.leafTests = RepoConfig.LeafTests(target: leafTests.target, folder: Self.trimmed(leafTests.folder))
        self.landingBranch = landingBranch
        self.defaultBranch = defaultBranch
        self.protectedPaths = protectedPaths
    }

    public var worktreesDirectory: URL { storage.appending(path: "worktrees", directoryHint: .isDirectory) }
    public var artifactsDirectory: URL { storage.appending(path: "artifacts", directoryHint: .isDirectory) }
    var excludeFile: URL { storage.appending(path: "exclude") }

    public func worktree(for id: NodeID) -> URL { worktreesDirectory.appending(path: id) }
    public func branch(for id: NodeID) -> String { Self.branchPrefix + id }

    /// Creates the landing branch from the default branch if it doesn't exist yet. Only adds a branch ref.
    public func prepare() async throws {
        try await git(["rev-parse", "--git-dir"], in: root)
        if try await !branchExists(landingBranch) {
            try await git(["branch", "--no-track", landingBranch, defaultBranch], in: root)
        }
        try FileManager.default.createDirectory(at: worktreesDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: excludeFile.path) {
            try Self.buildOutput.joined(separator: "\n").write(to: excludeFile, atomically: true, encoding: .utf8)
        }
        try await worktreeLock.withPermit { try await git(["worktree", "prune"], in: root) }
    }

    /// Never committed from a worktree, even if the repo's .gitignore misses them.
    static let buildOutput = [".build/", "DerivedData/", "xcuserdata/", ".swiftpm/", "*.xcuserstate", ".DS_Store", ""]

    // MARK: Branch per leaf

    public func createWorktree(for id: NodeID) async throws -> URL {
        try await createWorktree(for: id, keepingFolder: nil)
    }

    public func createWorktree(for id: NodeID, keeping folder: String) async throws -> URL {
        try await createWorktree(for: id, keepingFolder: Self.trimmed(folder))
    }

    private func createWorktree(for id: NodeID, keepingFolder folder: String?) async throws -> URL {
        let directory = worktree(for: id)
        try await worktreeLock.withPermit {
            // Read before -B moves the branch back to the landing branch.
            let previous = folder == nil ? nil : (try? await git(["rev-parse", "--verify", "--quiet",
                                                                  branch(for: id) + "^{commit}"], in: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? await removeWorktreeNow(for: id)
            try FileManager.default.createDirectory(at: worktreesDirectory, withIntermediateDirectories: true)
            try await git(["worktree", "add", "-q", "-B", branch(for: id), directory.path, landingBranch], in: root)
            if let folder, let previous, !previous.isEmpty,
               !(try await git(["ls-tree", "--name-only", previous, "--", folder], in: root)).isEmpty {
                _ = try await git(["checkout", previous, "--", folder], in: directory)
            }
        }
        return directory
    }

    public func removeWorktree(for id: NodeID) async throws {
        try await worktreeLock.withPermit { try await removeWorktreeNow(for: id) }
    }

    private func removeWorktreeNow(for id: NodeID) async throws {
        try await git(["worktree", "remove", "--force", worktree(for: id).path], in: root)
        try await git(["worktree", "prune"], in: root)
    }

    // MARK: Read-only snapshot

    public var snapshotsDirectory: URL { storage.appending(path: "snapshots", directoryHint: .isDirectory) }

    /// A detached worktree of the landing branch: no branch of its own, so nothing in it can land.
    public func createSnapshot() async throws -> URL? {
        let directory = snapshotsDirectory.appending(path: UUID().uuidString)
        try await worktreeLock.withPermit {
            try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            try await git(["worktree", "add", "-q", "--detach", directory.path, landingBranch], in: root)
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

    public func head(of directory: URL) async throws -> String {
        try await git(["rev-parse", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func changedFiles(in directory: URL) async throws -> [String] {
        // Both sides of a rename, and raw (unquoted) names, so a moved or oddly named protected file can't slip by.
        try await git(["diff", "--name-only", "--no-renames", "-z", "\(landingBranch)...HEAD"], in: directory)
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
        let evidenceFile = directory.appending(path: ".agentos-ui-evidence.json")
        var evidence = FileManager.default.fileExists(atPath: evidenceFile.path)
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
        lines.append("Don't run git commands, don't install packages and don't use the network.")
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
        try await discardUncommitted(directory)
        let result = try await ProcessRunner.run("/usr/bin/env", ["git", "rebase", "-q", landingBranch], in: directory)
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
        try await discardUncommitted(directory)
        let commits = try await git(["rev-list", "--reverse", "\(landingBranch)..HEAD"], in: directory).split(separator: "\n")
        guard let testsCommit = commits.first else { return }
        try await git(["reset", "-q", "--hard", String(testsCommit)], in: directory)
        try await git(["rebase", "-q", landingBranch], in: directory)
    }

    /// Fast-forwards the landing branch to the leaf's branch by moving the ref only (compare-and-swap), so no
    /// checkout is involved. Refuses if a checkout has the landing branch checked out: it would fall out of step.
    public func landOnMain(_ id: NodeID) async throws -> String {
        let tip = try await revision(branch(for: id))
        let old = try await revision(landingBranch)
        let ancestor = try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", "--is-ancestor", old, tip], in: root)
        guard ancestor.status == 0 else { throw AgentFailure("\(branch(for: id)) is not a fast-forward of \(landingBranch)") }
        if let checkout = try await checkout(of: landingBranch) {
            throw AgentFailure("\(landingBranch) is checked out in \(checkout.path). Switch that checkout to another " +
                               "branch so the harness can move \(landingBranch).")
        }
        try await git(["update-ref", "-m", "agentos: land \(id)", "refs/heads/\(landingBranch)", tip, old], in: root)
        return tip
    }

    // MARK: Repo

    public func existingComponents() -> [String] { config.components ?? [] }

    public func localMainTip() async throws -> String {
        try await revision(defaultBranch)
    }

    /// Nothing to do: the check runner runs the config's `build.prepare` before building.
    public func prepareBuild(in directory: URL) async throws {}

    // MARK: Your repo state

    /// Tags, remote-tracking refs, the stash and other refs by commit; which local branches exist (a branch you
    /// commit to while agents work moves, so only creating or deleting one counts); and the content of the shared
    /// git config, hooks and `info/` files, which affect every checkout of the repo.
    public func userGitState() async throws -> [String] {
        var state: [String] = []
        for line in try await git(["for-each-ref", "--format=%(objectname) %(refname)"], in: root).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let ref = String(line[line.index(after: space)...])
            if ref.hasPrefix("refs/heads/agentos/") || ref == "refs/heads/\(landingBranch)" { continue }
            state.append(ref.hasPrefix("refs/heads/") ? "branch \(ref)" : String(line))
        }
        let common = URL(filePath: try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
        var files = ["config"]
        for folder in ["hooks", "info"] {
            let names = (try? FileManager.default.subpathsOfDirectory(atPath: common.appending(path: folder).path)) ?? []
            files += names.map { "\(folder)/\($0)" }
        }
        for file in files.sorted() {
            if let data = FileManager.default.contents(atPath: common.appending(path: file).path) {
                state.append("\(Hashing.sha256(data)) \(file)")
            }
        }
        return state
    }

    // MARK: Helpers

    private func branchExists(_ name: String) async throws -> Bool {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git", "show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: root)
        return result.status == 0
    }

    private func revision(_ name: String) async throws -> String {
        try await git(["rev-parse", "--verify", "refs/heads/\(name)"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
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
        try await WorkingChanges.describe(worktree(for: id), since: landingBranch,
                                          gitOptions: ["-c", "core.excludesFile=\(excludeFile.path)"])
    }

    private func discardUncommitted(_ directory: URL) async throws {
        try await git(["reset", "-q", "--hard"], in: directory)
        try await git(["clean", "-fdq"], in: directory)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await GitLocks.retryingAfterStaleLock {
            try await ProcessRunner.run(
                "/usr/bin/env", ["git", "-c", "core.excludesFile=\(excludeFile.path)"] + arguments, in: directory, timeout: .seconds(120))
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
