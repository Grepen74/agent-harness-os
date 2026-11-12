import Foundation

/// What the readiness scan knows about a repo: the files on its default branch and the contents of the
/// few that matter. Gathered by `ReadinessScanner`, judged by `ReadinessRules`.
struct RepositorySnapshot: Sendable {
    var branch: String
    var commit: String
    /// Every tracked path on `branch`.
    var files: [String]
    /// Contents of the files in `interestingPaths(of:)`.
    var contents: [String: String] = [:]
    /// Line counts of tracked source files (`sourcePatterns`), vendored folders left out.
    var sourceLines: [String: Int] = [:]
    var swiftTestingFiles = 0
    var xctestFiles = 0
    /// The branch your own checkout is on, if any.
    var checkoutBranch: String?
    var uncommittedChanges = 0
    /// The repo config in your checkout (nil if there's none), to tell you when it isn't the one on `branch`.
    var checkoutConfig: String?
    /// Installed simulators by runtime, e.g. `"iOS 18.6": ["iPhone 14"]`; nil if not looked up.
    var simulators: [String: Set<String>]?
    /// When `branch` is a remote-tracking branch (`origin/…`): when it was last updated by a fetch or the clone.
    var lastFetched: Date?

    private static let vendored: Set<String> = [".build", "Pods", "Carthage", "DerivedData", "SourcePackages", "node_modules"]

    /// Paths the rules read: docs that steer agents, build descriptions, the repo config.
    static func interestingPaths(of files: [String]) -> [String] {
        files.filter { path in
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            if isVendored(path) { return false }
            if ["Package.swift", "project.yml", "Project.swift"].contains(name) { return true }
            if path.hasSuffix(".xcodeproj/project.pbxproj") || path.hasPrefix(".agentos/") { return true }
            if path == ".github/copilot-instructions.md" { return true }
            let upper = name.uppercased()
            if folder.isEmpty, upper.hasPrefix("README") || upper == "AGENTS.MD" { return true }
            if ["", ".github", "docs"].contains(folder), upper.hasPrefix("CONTRIBUTING") || upper == "CODEOWNERS" { return true }
            return false
        }
    }

    /// Pathspecs of the source files whose size the scan looks at.
    static let sourcePatterns = ["swift", "m", "mm", "h", "c", "cc", "cpp", "kt", "java", "ts", "tsx", "js", "jsx", "py",
                                 "go", "rs", "cs", "rb", "php", "scala", "dart"].map { "*.\($0)" }

    /// `git grep -c -z '' <branch>` output (`<branch>:<path>\0<count>\n` per file) as path → line count.
    static func lineCounts(fromGitGrep output: String, branch: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\0", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            let path = parts[0].hasPrefix("\(branch):") ? String(parts[0].dropFirst(branch.count + 1)) : String(parts[0])
            if !isVendored(path) { counts[path] = count }
        }
        return counts
    }

    static func isVendored(_ path: String) -> Bool {
        path.split(separator: "/").contains { vendored.contains(String($0)) }
    }

    /// First file in one of `folders` whose name matches, ignoring case and extension.
    func file(named name: String, in folders: [String] = [""]) -> String? {
        for folder in folders {
            let match = contents.keys.sorted().first { path in
                (path as NSString).deletingLastPathComponent == folder
                    && ((path as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased() == name.uppercased()
            }
            if let match { return match }
        }
        return nil
    }

    func paths(named name: String) -> [String] {
        contents.keys.filter { ($0 as NSString).lastPathComponent == name }.sorted()
    }
}

extension String {
    /// The folder a repo path is in, `.` for the root.
    var folder: String {
        let folder = (self as NSString).deletingLastPathComponent
        return folder.isEmpty ? "." : folder
    }

    func inFolder(_ folder: String) -> String { folder == "." ? self : "\(folder)/\(self)" }
}
