import AgentOSCore
import Foundation

/// Leftovers of the `merge=union` aids older harness versions wrote for catch-up conflicts
/// (`.git/info/attributes` blocks and `branch.agentos/….mergeOptions = --no-commit`).
enum RequirementMergeAid {
    static let blockStart = "# agentos catch-up conflict "

    static func unmanagedAttributes(_ text: String) -> String {
        var end: String?
        var block: [String] = []
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let marker = end {
                block.append(line)
                if line == marker { end = nil; block = [] }
            } else if line.hasPrefix(blockStart) {
                end = line.replacingOccurrences(of: "# agentos", with: "# end agentos")
                block = [line]
            } else {
                lines.append(line)
            }
        }
        // Without its end marker a block isn't ours to remove: keep what follows the start.
        lines += block
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
}
