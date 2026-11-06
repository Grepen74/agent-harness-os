import AgentOSCore
import Foundation

/// What a leaf's working copy changed since it left `base`, committed or not, to look at while an agent works.
/// Read-only: `--no-optional-locks` keeps git from refreshing the index, so it never gets in an agent's way.
public enum WorkingChanges {
    public static func describe(_ directory: URL, since base: String, gitOptions: [String] = []) async throws -> String {
        guard FileManager.default.fileExists(atPath: directory.path) else { return "" }
        func git(_ arguments: [String]) async throws -> String {
            let result = try await ProcessRunner.run(
                "/usr/bin/env", ["git", "--no-optional-locks"] + gitOptions + arguments, in: directory, timeout: .seconds(60))
            guard result.status == 0 else { throw AgentFailure("git \(arguments.first ?? "") failed: \(result.output.suffix(300))") }
            return result.output
        }
        let start = try await git(["merge-base", "HEAD", base]).trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try await git(["diff", "--stat", start])
        let untracked = try await git(["ls-files", "--others", "--exclude-standard"])
            .split(separator: "\n").map { "  + \($0)" }
        let patch = try await git(["diff", start])
        guard !summary.isEmpty || !untracked.isEmpty else { return "No changes since \(base) yet." }
        var parts = [summary.isEmpty ? nil : summary,
                     untracked.isEmpty ? nil : "New files, not committed yet:\n" + untracked.joined(separator: "\n")]
        parts.append(patch.isEmpty ? nil : patch)
        return parts.compactMap { $0 }.joined(separator: "\n")
    }
}
