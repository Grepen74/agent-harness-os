import AgentOSCore
import Foundation

/// The repo config in your checkout, for editing. The harness reads it from the default branch once you commit it.
public enum RepoConfigFile {
    public static func url(in root: URL) -> URL { root.appending(path: RepoConfig.path) }

    /// The file to open: the one in your checkout or, when there's none, a new one with `draft` (or an empty
    /// object) in it. Only on your request: the scan itself never writes to the checkout.
    public static func prepare(in root: URL, draft: String?) throws -> (url: URL, created: Bool) {
        let file = url(in: root)
        if FileManager.default.fileExists(atPath: file.path) { return (file, false) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = draft ?? "{\n}"
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (file, true)
    }
}
