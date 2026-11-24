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

    public func removeCatchUpMergeAids() async throws {
        try await mergeAidLock.withPermit {
            let attributes = try await catchUpAttributesFile()
            if FileManager.default.fileExists(atPath: attributes.path) {
                let text = try String(contentsOf: attributes, encoding: .utf8)
                let unmanaged = RequirementMergeAid.unmanagedAttributes(text)
                if text.contains(RequirementMergeAid.blockStart), unmanaged != text {
                    try unmanaged.write(to: attributes, atomically: true, encoding: .utf8)
                }
            }
            // Only the repository's own config: that's where the harness wrote them and where `--unset` acts.
            let listed = try await ProcessRunner.run(
                "/usr/bin/env",
                ["git", "config", "--local", "--no-includes", "--get-regexp", #"^branch\.agentos/.*\.mergeoptions$"#],
                in: root)
            // Status 1: no such settings.
            guard listed.status == 0 else {
                if listed.status == 1 { return }
                throw AgentFailure("Could not read catch-up merge options: \(listed.output)")
            }
            var keys: [String] = []
            for line in listed.output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "--no-commit",
                      !keys.contains(parts[0]) else { continue }
                keys.append(parts[0])
            }
            for key in keys {
                _ = try await git(["config", "--local", "--unset-all", key, "^--no-commit$"], in: root)
            }
        }
    }
}
