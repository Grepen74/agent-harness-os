import AgentOSCore
import Foundation

enum RequirementCatchUpResult {
    case success(String)
    case conflict([String])
}

extension RepositoryWorkspace {
    public func requirementWorktree(for requirement: NodeIdentity) async throws -> URL {
        try await createSnapshot(at: requirementBranch(for: requirement.ticketKey))
    }

    public func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool {
        let branch = requirementBranch(for: requirement.ticketKey)
        guard let commit = try await tip(of: branch) else {
            throw AgentFailure("Could not detect the merge: restore \(branch) and \(defaultBranch), then run again.")
        }
        let main = try await localMainTip()
        return try await isAncestor(commit, of: main)
    }

    /// Old leaf branches can include retired landing work. Their own reflog identifies the original
    /// starting commit without consulting the retired branch or migrating its other commits.
    func leafBase(in directory: URL, landingBranch: String) async throws -> String {
        let result = try await ProcessRunner.run(
            "/usr/bin/env",
            ["git", "reflog", "show", "--format=%H%x09%gs", branch(for: directory.lastPathComponent)], in: root
        )
        guard result.status == 0 else { throw AgentFailure("Could not read the leaf's starting commit: \(result.output)") }
        let origin = result.output.split(separator: "\n").first { line in
            line.contains("\tbranch: Created from ") || line.contains("\tbranch: Reset to ")
        }?.split(separator: "\t", maxSplits: 1).first.map(String.init)
        guard let origin else { return landingBranch }
        func contains(_ tip: String) async throws -> Bool {
            let result = try await ProcessRunner.run(
                "/usr/bin/env", ["git", "merge-base", "--is-ancestor", origin, tip], in: directory
            )
            guard result.status == 0 || result.status == 1 else {
                throw AgentFailure("Could not inspect the leaf's starting commit: \(result.output)")
            }
            return result.status == 0
        }
        if try await contains("HEAD"), try await !contains(landingBranch) { return origin }
        return landingBranch
    }

    public func catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String {
        let branch = "agentos/\(requirement.ticketKey)"
        switch try await mergeRequirementBranch(branch, main: localMainTip()) {
        case .success(let tip): return tip
        case .conflict(let files):
            throw AgentFailure("Catch-up of \(branch) conflicts in \(files.joined(separator: ", ")). Resolve the conflict, then retry catch-up.")
        }
    }

    func mergeRequirementBranch(_ branch: String, main: String) async throws -> RequirementCatchUpResult {
        // A leftover union aid would resolve this merge's conflicts by keeping both sides.
        try await removeCatchUpMergeAids()
        return try await mergeRequirementBranchWithoutAids(branch, main: main)
    }

    private func mergeRequirementBranchWithoutAids(_ branch: String, main: String) async throws -> RequirementCatchUpResult {
        guard try await checkout(of: branch) == nil else {
            throw AgentFailure("\(branch) is checked out. Switch that checkout to another branch, then retry catch-up.")
        }
        let directory = snapshotsDirectory.appending(path: "catch-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let old = try await git(["rev-parse", "refs/heads/\(branch)"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contains = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge-base", "--is-ancestor", main, old], in: root
        )
        if contains.status == 0 { return .success(old) }
        guard contains.status == 1 else { throw AgentFailure("Could not inspect \(branch): \(contains.output)") }
        try await worktreeLock.withPermit {
            try await git(["worktree", "add", "-q", "--detach", directory.path, old], in: root)
        }
        do {
            let merge = try await ProcessRunner.run("/usr/bin/env", [
                "git", "-c", "user.name=AgentOS", "-c", "user.email=agentos@agents.agentos.local",
                "merge", "-q", "--no-edit", "--no-verify", main,
            ], in: directory)
            guard merge.status == 0 else {
                let files = try await git(["diff", "--name-only", "--diff-filter=U"], in: directory)
                    .split(separator: "\n").map(String.init)
                guard !files.isEmpty else { throw AgentFailure("Catch-up of \(branch) failed: \(merge.output)") }
                await removeSnapshot(directory)
                return .conflict(files)
            }
            let tip = try await head(of: directory)
            _ = try await git(["update-ref", "refs/heads/\(branch)", tip, old], in: root)
            await removeSnapshot(directory)
            return .success(tip)
        } catch {
            await removeSnapshot(directory)
            throw error
        }
    }
}
