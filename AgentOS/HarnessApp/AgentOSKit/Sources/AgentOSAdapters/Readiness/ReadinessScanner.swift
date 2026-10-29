import AgentOSCore
import Foundation

/// A scanned repo: the scan, plus where the repo lives and how the harness recognises it again.
public struct ScannedRepository: Sendable {
    /// Top folder of the git repo, if it is one.
    public let root: URL?
    /// Stable name for the harness's own storage of this repo (`RepositoryStorage`).
    public let identity: String?
    public let scan: ReadinessScan
}

/// The readiness scan (doc 01, "Onboarding a repo"). Read-only: it reads the default branch through git
/// (`ls-tree`, `show`, `grep`) and never writes to the repo, its index or your working copy.
public struct ReadinessScanner: Sendable {
    public init() {}

    public func scan(_ url: URL) async -> ScannedRepository {
        guard let top = await git(["rev-parse", "--show-toplevel"], in: url) else {
            return blocked(root: nil, Finding(
                check: "repo.git", severity: .blocker, title: "Not a git repository",
                detail: "\(url.path) isn't inside a git repo. The harness tracks every change through git.",
                suggestion: "Choose the repo's folder, or run `git init` and commit."))
        }
        let root = URL(filePath: top, directoryHint: .isDirectory)

        guard await git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root) != nil else {
            return blocked(root: root, Finding(
                check: "repo.git", severity: .blocker, title: "No commits yet",
                detail: "The harness works from the default branch, and there's nothing on it.",
                suggestion: "Commit what's there first."))
        }
        guard let branch = await defaultBranch(in: root),
              let commit = await git(["rev-parse", "refs/heads/\(branch)"], in: root) else {
            return blocked(root: root, Finding(
                check: "repo.git", severity: .blocker, title: "No default branch found",
                detail: "Looked for the branch origin/HEAD points to, then main and master.",
                suggestion: "Create a local main branch."))
        }

        var snapshot = RepositorySnapshot(branch: branch, commit: commit, files: await trackedFiles(on: branch, in: root))
        for path in RepositorySnapshot.interestingPaths(of: snapshot.files) {
            snapshot.contents[path] = await git(["show", "\(branch):\(path)"], in: root, trim: false)
        }
        snapshot.swiftTestingFiles = await filesImporting("Testing", on: branch, in: root)
        snapshot.xctestFiles = await filesImporting("XCTest", on: branch, in: root)
        snapshot.checkoutBranch = await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        // --no-optional-locks: don't even refresh the index.
        snapshot.uncommittedChanges = (await git(["--no-optional-locks", "status", "--porcelain"], in: root) ?? "")
            .split(separator: "\n").count

        return ScannedRepository(root: root, identity: await identity(of: root, branch: branch),
                                 scan: ReadinessScan(branch: branch, commit: commit, findings: ReadinessRules.findings(for: snapshot)))
    }

    private func blocked(root: URL?, _ finding: Finding) -> ScannedRepository {
        ScannedRepository(root: root, identity: nil, scan: ReadinessScan(branch: nil, commit: nil, findings: [finding]))
    }

    private func defaultBranch(in root: URL) async -> String? {
        var candidates: [String] = []
        if let remoteHead = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root) {
            candidates.append(String(remoteHead.dropFirst("origin/".count)))
        }
        candidates += ["main", "master"]
        for candidate in candidates where await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: root) != nil {
            return candidate
        }
        return nil
    }

    private func trackedFiles(on branch: String, in root: URL) async -> [String] {
        (await git(["ls-tree", "-r", "--name-only", "-z", branch], in: root, trim: false) ?? "")
            .split(separator: "\0").map(String.init)
    }

    private func filesImporting(_ module: String, on branch: String, in root: URL) async -> Int {
        let output = await git(["grep", "-l", "-z", "-E", "^[[:space:]]*(@testable )?import \(module)$", branch, "--", "*.swift"],
                               in: root, trim: false) ?? ""
        return output.split(separator: "\0").count
    }

    /// Folder name plus a hash of the first commit and the path: the same repo in two clones gets two
    /// identities, so they never share harness state by accident.
    private func identity(of root: URL, branch: String) async -> String {
        let firstCommits = await git(["rev-list", "--max-parents=0", branch], in: root) ?? ""
        let first = firstCommits.split(separator: "\n").sorted().first.map(String.init) ?? ""
        let name = root.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(name)-\(Hashing.sha256(first + "\n" + root.standardizedFileURL.path).prefix(12))"
    }

    /// Output of a git command, or nil if it failed.
    private func git(_ arguments: [String], in directory: URL, trim: Bool = true) async -> String? {
        guard let result = try? await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory, timeout: .seconds(60)),
              result.status == 0 else { return nil }
        return trim ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : result.output
    }
}

/// Where the harness keeps its own state for a repo: outside the repo, private to this Mac.
/// `~/Library/Application Support/AgentOS/repos/<identity>/` holds `ledger.jsonl`, and later the local
/// tracker's tickets, artifacts and worktrees.
public enum RepositoryStorage {
    public static var root: URL {
        URL.applicationSupportDirectory.appending(path: "AgentOS/repos", directoryHint: .isDirectory)
    }

    public static func directory(for identity: String, in root: URL = root) -> URL {
        root.appending(path: identity, directoryHint: .isDirectory)
    }

    public static func ledgerStore(for identity: String, in root: URL = root) -> FileLedgerStore {
        FileLedgerStore(fileURL: directory(for: identity, in: root).appending(path: "ledger.jsonl"))
    }
}
