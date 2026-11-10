import AgentOSCore
import Foundation

/// Changes text prepared for display, retaining production times for lines that survive a refresh unchanged.
public struct ChangesOutput {
    private struct Line {
        let text: String
        let producedAt: Date
    }

    private let timeZone: TimeZone
    private var lines: [Line] = []

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public var text: String {
        let formatter = timestampFormatter()
        return lines.map { "[\(formatter.string(from: $0.producedAt))] \($0.text)" }.joined(separator: "\n")
    }

    public mutating func refresh(with text: String, producedAt: Date = Date()) {
        var existing: [String: [Line]] = Dictionary(grouping: lines, by: \.text)
        lines = Self.outputLines(in: text).map { text in
            if var matches = existing[text], !matches.isEmpty {
                let line = matches.removeFirst()
                existing[text] = matches.isEmpty ? nil : matches
                return line
            }
            return Line(text: text, producedAt: producedAt)
        }
    }

    private func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private static func outputLines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}

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
