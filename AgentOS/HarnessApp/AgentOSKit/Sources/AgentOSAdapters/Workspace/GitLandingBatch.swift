import AgentOSCore
import Foundation

/// Replays each leaf's history into a disposable checkout, without publishing review artifacts.
public struct GitLandingBatch: Sendable {
    public struct Source: Sendable {
        let node: NodeID
        let branch: String
        let base: String

        public init(node: NodeID, branch: String, base: String) {
            self.node = node
            self.branch = branch
            self.base = base
        }
    }

    let root: URL

    public init(root: URL) { self.root = root }

    public func build(in directory: URL, branch: String, sources: [Source]) async throws -> LandingBatchWorkspace {
        let base = try await git(["rev-parse", "HEAD"], in: directory)
        var members: [LandingBatchMember] = []
        for source in sources {
            let fork = try await git(["merge-base", source.base, source.branch], in: root)
            let changed = try await git(["diff", "--name-only", "--no-renames", "-z",
                                         "\(fork)..\(source.branch)"], in: root)
                .split(separator: "\0").map(String.init)
            let commits = try await git(["rev-list", "--reverse", "--first-parent",
                                         "\(fork)..\(source.branch)"], in: root)
                .split(separator: "\n").map(String.init)
            for commit in commits {
                let parent = try await git(["rev-parse", "\(commit)^"], in: root)
                let tree = try await cleanTree(of: commit, in: directory)
                let parentTree = try await cleanTree(of: parent, in: directory)
                let metadata = try await git(["show", "-s", "--format=%an%x00%ae%x00%aI%x00%B", commit], in: root)
                    .split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard metadata.count == 4 else { throw AgentFailure("Could not read commit metadata for \(commit).") }
                let environment = [
                    "GIT_AUTHOR_NAME": metadata[0], "GIT_AUTHOR_EMAIL": metadata[1], "GIT_AUTHOR_DATE": metadata[2],
                    "GIT_COMMITTER_NAME": "AgentOS", "GIT_COMMITTER_EMAIL": "harness@agents.agentos.local",
                ]
                let cleanParent = try await git(["commit-tree", parentTree, "-m", "batch source base"],
                                                in: root, environment: environment)
                let cleanCommit = try await git(["commit-tree", tree, "-p", cleanParent, "-m", metadata[3]],
                                                in: root, environment: environment)
                let pick = try await ProcessRunner.run("/usr/bin/env",
                    ["git", "-c", "core.hooksPath=/dev/null", "cherry-pick", "--allow-empty",
                     "--keep-redundant-commits", cleanCommit],
                    in: directory, environment: environment)
                guard pick.status == 0 else {
                    let files = try await git(["diff", "--name-only", "--diff-filter=U"], in: directory)
                        .split(separator: "\n").map(String.init)
                    guard !files.isEmpty else { throw AgentFailure("Could not apply \(source.node): \(pick.output)") }
                    throw LandingBatchConflict(node: source.node, files: files)
                }
            }
            members.append(LandingBatchMember(node: source.node, commit: try await git(["rev-parse", "HEAD"], in: directory),
                                               changedFiles: changed))
        }
        return LandingBatchWorkspace(directory: directory, branch: branch, baseCommit: base,
                                     candidateCommit: try await git(["rev-parse", "HEAD"], in: directory), members: members)
    }

    public func move(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
        let result = try await ProcessRunner.run("/usr/bin/env", [
            "git", "update-ref", "-m", "agentos: land batch", "refs/heads/\(batch.branch)",
            batch.candidateCommit, batch.baseCommit,
        ], in: root)
        if result.status == 0 { return .landed }
        let current = try await git(["rev-parse", "refs/heads/\(batch.branch)"], in: root)
        if current != batch.baseCommit { return .branchMoved }
        throw AgentFailure("Could not move \(batch.branch) to the checked batch: \(result.output)")
    }

    private func cleanTree(of commit: String, in directory: URL) async throws -> String {
        let paths = [RepositoryWorkspace.uiEvidenceFile, RepositoryWorkspace.uiEvidenceFolder]
        if try await git(["ls-tree", "--name-only", commit, "--"] + paths, in: root).isEmpty {
            return try await git(["rev-parse", "\(commit)^{tree}"], in: root)
        }
        let index = directory.deletingLastPathComponent().appending(path: "batch-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        _ = try await git(["read-tree", commit], in: root, environment: environment)
        _ = try await git(["rm", "-r", "-q", "-f", "--cached", "--ignore-unmatch", "--"] + paths,
                          in: root, environment: environment)
        return try await git(["write-tree"], in: root, environment: environment)
    }

    private func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory, environment: environment)
        guard result.status == 0 else { throw AgentFailure("git \(arguments.first ?? ""): \(result.output)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
