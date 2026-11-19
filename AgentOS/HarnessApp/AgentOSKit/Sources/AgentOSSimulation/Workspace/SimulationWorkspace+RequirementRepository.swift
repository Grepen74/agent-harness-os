import AgentOSAdapters
import AgentOSCore
import Foundation

extension SimulationWorkspace: RequirementBranchRepository {
    public var defaultBranch: String { "main" }
    public func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }

    public func tip(of branch: String) async throws -> String? {
        let exists = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoDirectory)
        if exists.status == 1 { return nil }
        guard exists.status == 0 else { throw AgentFailure("Could not inspect \(branch): \(exists.output)") }
        return try await requirementGit(["rev-parse", "refs/heads/\(branch)"])
    }

    public func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, descendant], in: repoDirectory)
        guard result.status == 0 || result.status == 1 else {
            throw AgentFailure("Could not inspect ancestry: \(result.output)")
        }
        return result.status == 0
    }

    public func changedFiles(in commit: String) async throws -> [String] {
        try await requirementGit(["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", commit])
            .split(separator: "\n").map(String.init)
    }

    public func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult {
        guard let old = try await tip(of: branch) else { throw AgentFailure("Missing requirement branch \(branch).") }
        if try await isAncestor(main, of: old) { return .clean }
        let directory = root.appending(path: "snapshots/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await requirementGit(["worktree", "add", "-q", "--detach", directory.path, old])
        do {
            let merge = try await ProcessRunner.run("/usr/bin/env", [
                "git", "-c", "user.name=AgentOS", "-c", "user.email=harness@agents.agentos.local",
                "merge", "-q", "--no-edit", "--no-verify", main,
            ], in: directory)
            if merge.status != 0 {
                let result = try await ProcessRunner.run(
                    "/usr/bin/env", ["git", "diff", "--name-only", "--diff-filter=U"], in: directory)
                guard result.status == 0 else { throw AgentFailure("Could not read merge conflicts: \(result.output)") }
                let files = result.output.split(separator: "\n").map(String.init)
                guard !files.isEmpty else { throw AgentFailure("Catch-up of \(branch) failed: \(merge.output)") }
                await removeSnapshot(directory)
                return .conflict(files: files)
            }
            let tip = try await head(of: directory)
            _ = try await requirementGit(["update-ref", "refs/heads/\(branch)", tip, old])
            await removeSnapshot(directory)
            return .clean
        } catch {
            await removeSnapshot(directory)
            throw error
        }
    }

    private func requirementGit(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: repoDirectory)
        guard result.status == 0 else { throw AgentFailure("git \(arguments.first ?? "") failed: \(result.output)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
