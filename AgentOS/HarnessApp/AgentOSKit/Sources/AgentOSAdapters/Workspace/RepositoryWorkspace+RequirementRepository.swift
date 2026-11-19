import AgentOSCore
import Foundation

extension RepositoryWorkspace: RequirementBranchRepository {
    public func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }

    public func tip(of branch: String) async throws -> String? {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw AgentFailure("Could not read \(branch): \(result.output)") }
        return try await git(["rev-parse", "--verify", "refs/heads/\(branch)"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, descendant], in: root)
        guard result.status == 0 || result.status == 1 else {
            throw AgentFailure("Could not inspect ancestry of \(ancestor) and \(descendant): \(result.output)")
        }
        return result.status == 0
    }

    public func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult {
        switch try await mergeRequirementBranch(branch, main: main) {
        case .success: return .clean
        case .conflict(let files): return .conflict(files: files)
        }
    }

    public func changedFiles(in commit: String) async throws -> [String] {
        let files = try await git(
            ["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", commit], in: root)
            .split(separator: "\n").map(String.init)
        // A UI landing's last commit removes evidence; the actual work is in its parent.
        if !files.isEmpty, files.allSatisfy(Self.isUIEvidence) {
            return try await changedFiles(in: commit + "^")
        }
        return files
    }

    public func updateCatchUpMergeAid(for branch: String, files: [String]) async throws {
        try await mergeAidLock.withPermit {
            try await updateMergeAid(for: branch, files: files)
        }
    }

    private func updateMergeAid(for branch: String, files: [String]) async throws {
        let attributes = try await catchUpAttributesFile()
        let start = "# agentos catch-up conflict \(branch)"
        let end = "# end agentos catch-up conflict \(branch)"
        let existing = FileManager.default.fileExists(atPath: attributes.path)
            ? try String(contentsOf: attributes, encoding: .utf8) : ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.firstIndex(of: start), let last = lines[first...].firstIndex(of: end) {
            lines.removeSubrange(first...last)
        }
        while lines.last == "" { lines.removeLast() }
        if !files.isEmpty {
            lines.append(start)
            lines += files.sorted().map { "\($0) merge=union" }
            lines.append(end)
            _ = try await git(["config", "branch.\(branch).mergeOptions", "--no-commit"], in: root)
        } else {
            let result = try await ProcessRunner.run(
                "/usr/bin/env", ["git", "config", "--unset", "branch.\(branch).mergeOptions"], in: root)
            if result.status != 0 && result.status != 5 {
                throw AgentFailure("Could not clear catch-up merge options: \(result.output)")
            }
        }
        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        if contents != existing {
            try contents.write(to: attributes, atomically: true, encoding: .utf8)
        }
    }
}
