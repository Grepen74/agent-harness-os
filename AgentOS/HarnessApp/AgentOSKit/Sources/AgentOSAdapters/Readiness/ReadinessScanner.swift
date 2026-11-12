import AgentOSCore
import Foundation

/// A scanned repo: the scan, plus where the repo lives and how the harness recognises it again.
public struct ScannedRepository: Sendable {
    /// Top folder of the git repo, if it is one.
    public let root: URL?
    /// Stable name for the harness's own storage of this repo (`RepositoryStorage`).
    public let identity: String?
    public let scan: ReadinessScan
    /// The repo's config, if it has a valid one on the default branch.
    public var config: RepoConfig?
    /// What applies to this repo: the harness settings combined with its config.
    public var policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: nil)
    /// A suggested config, as JSON, when the repo has none.
    public var draft: String?
    /// Where the repo's tickets live, from its config.
    public var tracker = TrackerChoice.local
}

/// Which tracker a repo uses (its config's `tracker`).
public enum TrackerChoice: Sendable, Equatable {
    /// The app's own tracker, private to this Mac.
    case local
    /// GitHub Issues of `owner/name`, through the GitHub CLI; with a board, its status field shows the status.
    case githubIssues(repo: String, project: RepoConfig.Tracker.Project? = nil)

    /// What the config asks for, with what's missing to use it as findings (blockers: agents would work on
    /// tickets nobody sees). `remote` is the `origin` remote URL; `hasGitHubCLI`, whether `gh` is installed.
    public static func resolve(_ config: RepoConfig.Tracker?, remote: String?, hasGitHubCLI: Bool) -> (TrackerChoice, [Finding]) {
        guard let config, config.type != RepoConfig.Tracker.local else { return (.local, []) }
        guard config.type == RepoConfig.Tracker.githubIssues else {
            return (.local, [Finding(
                check: "tracker", severity: .blocker, title: "Unknown tracker \"\(config.type)\"",
                detail: "The harness knows `\(RepoConfig.Tracker.githubIssues)` and `\(RepoConfig.Tracker.local)`.",
                suggestion: "Fix `tracker.type` in .agentos/config.json.")])
        }
        guard let repo = config.repo ?? remote.flatMap(GitHubIssuesTracker.repo(fromRemote:)) else {
            return (.local, [Finding(
                check: "tracker", severity: .blocker, title: "Which GitHub repo has the issues?",
                detail: "The config asks for GitHub Issues, and the `origin` remote isn't on GitHub.",
                suggestion: "Set `tracker.repo` to `owner/name` in .agentos/config.json.")])
        }
        guard hasGitHubCLI else {
            return (.githubIssues(repo: repo, project: config.project), [Finding(
                check: "tracker", severity: .blocker, title: "GitHub CLI not found",
                detail: "The harness reads and writes GitHub Issues with your `gh` login.",
                suggestion: "`brew install gh`, then `gh auth login`.")])
        }
        return (.githubIssues(repo: repo, project: config.project), [Finding(
            check: "tracker", severity: .info, title: "Tickets are GitHub issues of \(repo)",
            detail: "Add harness: labels to issues there; the harness answers as your `gh` login (Settings → GitHub account).")])
    }
}

/// A git repo with commits on a default branch: enough to find the harness's storage for it.
public struct RepositoryLocation: Sendable, Equatable {
    public let root: URL
    public let identity: String
    public let branch: String
    public let commit: String
}

/// The readiness scan (doc 01, "Onboarding a repo"). Read-only: it reads the default branch through git
/// (`ls-tree`, `show`, `grep`) and never writes to the repo, its index or your working copy.
public struct ReadinessScanner: Sendable {
    public init() {}

    public enum Located: Sendable {
        case repo(RepositoryLocation)
        /// Not something the harness can work on; the finding says why.
        case blocked(ScannedRepository)
    }

    public func scan(_ url: URL, harness: HarnessSettings = HarnessSettings(), baseline: Baseline? = nil) async -> ScannedRepository {
        switch await locate(url) {
        case .repo(let location): await scan(location, harness: harness, baseline: baseline)
        case .blocked(let scanned): scanned
        }
    }

    public func locate(_ url: URL) async -> Located {
        guard let top = await git(["rev-parse", "--show-toplevel"], in: url) else {
            return .blocked(blocked(root: nil, Finding(
                check: "repo.git", severity: .blocker, title: "Not a git repository",
                detail: "\(url.path) isn't inside a git repo. The harness tracks every change through git.",
                suggestion: "Choose the repo's folder, or run `git init` and commit.")))
        }
        let root = URL(filePath: top, directoryHint: .isDirectory)

        guard await git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root) != nil else {
            return .blocked(blocked(root: root, Finding(
                check: "repo.git", severity: .blocker, title: "No commits yet",
                detail: "The harness works from the default branch, and there's nothing on it.",
                suggestion: "Commit what's there first.")))
        }
        // The remote names the default branch but this clone has no local copy (common after cloning with another
        // branch checked out): read the remote-tracking branch rather than a stale local main/master. Read-only;
        // it's as fresh as the last fetch, which the scan reports.
        if let remote = await remoteDefaultBranch(in: root),
           await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(remote)"], in: root) == nil,
           let commit = await git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(remote)"], in: root) {
            let branch = "origin/\(remote)"
            return .repo(RepositoryLocation(root: root, identity: await identity(of: root, branch: branch), branch: branch, commit: commit))
        }
        guard let branch = await defaultBranch(in: root),
              let commit = await git(["rev-parse", "refs/heads/\(branch)"], in: root) else {
            return .blocked(blocked(root: root, Finding(
                check: "repo.git", severity: .blocker, title: "No default branch found",
                detail: "Looked for the branch origin/HEAD points to, then main and master.",
                suggestion: "Create a local main branch.")))
        }
        return .repo(RepositoryLocation(root: root, identity: await identity(of: root, branch: branch), branch: branch, commit: commit))
    }

    /// - `baseline`: the latest baseline run, from the repo's ledger.
    public func scan(_ location: RepositoryLocation, harness: HarnessSettings = HarnessSettings(),
                     baseline: Baseline? = nil) async -> ScannedRepository {
        let (root, branch) = (location.root, location.branch)
        var snapshot = RepositorySnapshot(branch: branch, commit: location.commit, files: await trackedFiles(on: branch, in: root))
        for path in RepositorySnapshot.interestingPaths(of: snapshot.files) {
            snapshot.contents[path] = await git(["show", "\(branch):\(path)"], in: root, trim: false)
        }
        let lines = await git(["grep", "-c", "-z", "-I", "", branch, "--"] + RepositorySnapshot.sourcePatterns, in: root, trim: false)
        snapshot.sourceLines = RepositorySnapshot.lineCounts(fromGitGrep: lines ?? "", branch: branch)
        snapshot.swiftTestingFiles = await filesImporting("Testing", on: branch, in: root)
        snapshot.xctestFiles = await filesImporting("XCTest", on: branch, in: root)
        snapshot.checkoutBranch = await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        if branch.hasPrefix("origin/"),
           let entry = await git(["log", "-g", "-1", "--date=unix", "--format=%gd", "refs/remotes/\(branch)"], in: root),
           let seconds = entry.split(separator: "{").last?.dropLast().description, let time = TimeInterval(seconds) {
            snapshot.lastFetched = Date(timeIntervalSince1970: time)
        }
        // --no-optional-locks: don't even refresh the index.
        snapshot.uncommittedChanges = (await git(["--no-optional-locks", "status", "--porcelain"], in: root) ?? "")
            .split(separator: "\n").count
        snapshot.checkoutConfig = try? String(contentsOf: RepoConfigFile.url(in: root), encoding: .utf8)
        // Only ask for simulators when something will need one: it takes a moment.
        let mentionsSimulator = snapshot.contents.contains { $0.key.hasPrefix(".agentos/") && $0.value.contains("Simulator") }
            || snapshot.contents.values.contains { $0.contains("iphoneos") || $0.contains("platform: iOS") }
        if mentionsSimulator { snapshot.simulators = await Self.installedSimulators() }

        let assessment = ReadinessRules.assess(snapshot, harness: harness, baseline: baseline)
        let (tracker, trackerFindings) = TrackerChoice.resolve(
            assessment.config?.tracker, remote: await git(["remote", "get-url", "origin"], in: root),
            hasGitHubCLI: GhCLITransport.locate() != nil)
        var boardFindings: [Finding] = []
        if case .githubIssues(let repo, let project?) = tracker, let gh = GhCLITransport.locate() {
            boardFindings = await GitHubProjectBoard.findings(
                config: project, repo: repo, transport: GhCLITransport(executable: gh, account: harness.githubAccount),
                account: harness.githubAccount)
        }
        return ScannedRepository(root: root, identity: location.identity,
                                 scan: ReadinessScan(branch: branch, commit: location.commit, findings: assessment.findings + trackerFindings + boardFindings),
                                 config: assessment.config, policy: assessment.policy, draft: assessment.draft?.json, tracker: tracker)
    }

    /// `xcrun simctl list devices available -j`, as runtime name → device names; nil if it can't be read.
    static func installedSimulators() async -> [String: Set<String>]? {
        guard let result = try? await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"],
                                                        in: FileManager.default.temporaryDirectory, timeout: .seconds(60)),
              result.status == 0 else { return nil }
        return parseSimulators(result.output)
    }

    static func parseSimulators(_ json: String) -> [String: Set<String>]? {
        struct List: Decodable {
            struct Device: Decodable { let name: String }
            let devices: [String: [Device]]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: Data(json.utf8)) else { return nil }
        var result: [String: Set<String>] = [:]
        for (runtime, devices) in list.devices where !devices.isEmpty {
            // com.apple.CoreSimulator.SimRuntime.iOS-18-6 → iOS 18.6
            let id = runtime.split(separator: ".").last.map(String.init) ?? runtime
            let parts = id.split(separator: "-")
            let name = parts.count > 1 ? "\(parts[0]) " + parts.dropFirst().joined(separator: ".") : id
            result[name, default: []].formUnion(devices.map(\.name))
        }
        return result
    }

    private func blocked(root: URL?, _ finding: Finding) -> ScannedRepository {
        ScannedRepository(root: root, identity: nil, scan: ReadinessScan(branch: nil, commit: nil, findings: [finding]))
    }

    private func remoteDefaultBranch(in root: URL) async -> String? {
        await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)
            .map { String($0.dropFirst("origin/".count)) }
    }

    private func defaultBranch(in root: URL) async -> String? {
        var candidates: [String] = []
        if let remote = await remoteDefaultBranch(in: root) { candidates.append(remote) }
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
