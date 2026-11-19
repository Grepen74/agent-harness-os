import AgentOSCore
import Foundation

enum RequirementMergeAid {
    static func unmanagedAttributes(_ text: String) -> String {
        var end: String?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let marker = end {
                if line == marker { end = nil }
            } else if line.hasPrefix("# agentos catch-up conflict ") {
                end = line.replacingOccurrences(of: "# agentos", with: "# end agentos")
            } else {
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func unmanagedConfiguration(_ text: String) -> String {
        var sections: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") { sections.append([]) }
            sections[sections.count - 1].append(line)
        }
        return sections.flatMap { section -> [String] in
            guard section.first?.hasPrefix("[branch \"agentos/") == true else { return section }
            let kept = section.filter {
                $0.trimmingCharacters(in: .whitespaces).lowercased() != "mergeoptions = --no-commit"
            }
            return kept.dropFirst().allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? [] : kept
        }.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

extension RepositoryWorkspace {
    func catchUpAttributesFile() async throws -> URL {
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: common).appending(path: "info/attributes")
    }

    /// Manual union drivers are shared by all worktrees. Never let one requirement's aid resolve
    /// another requirement's automatic merge.
    func withoutCatchUpMergeAids<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await mergeAidLock.withPermit {
            let file = try await catchUpAttributesFile()
            guard FileManager.default.fileExists(atPath: file.path) else { return try await operation() }
            let original = try String(contentsOf: file, encoding: .utf8)
            let unmanaged = RequirementMergeAid.unmanagedAttributes(original)
            guard unmanaged != original else { return try await operation() }
            try unmanaged.write(to: file, atomically: true, encoding: .utf8)
            do {
                let result = try await operation()
                try original.write(to: file, atomically: true, encoding: .utf8)
                return result
            } catch {
                try original.write(to: file, atomically: true, encoding: .utf8)
                throw error
            }
        }
    }
}
