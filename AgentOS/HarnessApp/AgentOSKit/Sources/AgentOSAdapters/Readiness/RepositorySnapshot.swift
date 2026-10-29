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
    var swiftTestingFiles = 0
    var xctestFiles = 0
    /// The branch your own checkout is on, if any.
    var checkoutBranch: String?
    var uncommittedChanges = 0

    private static let vendored: Set<String> = [".build", "Pods", "Carthage", "DerivedData", "SourcePackages", "node_modules"]

    /// Paths the rules read: docs that steer agents, build descriptions, the repo config.
    static func interestingPaths(of files: [String]) -> [String] {
        files.filter { path in
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            if isVendored(path) { return false }
            if ["Package.swift", "project.yml", "Project.swift"].contains(name) { return true }
            if path.hasSuffix(".xcodeproj/project.pbxproj") || path == ".agentos/config" { return true }
            if path == ".github/copilot-instructions.md" { return true }
            let upper = name.uppercased()
            if folder.isEmpty, upper.hasPrefix("README") || upper == "AGENTS.MD" { return true }
            if ["", ".github", "docs"].contains(folder), upper.hasPrefix("CONTRIBUTING") || upper == "CODEOWNERS" { return true }
            return false
        }
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
