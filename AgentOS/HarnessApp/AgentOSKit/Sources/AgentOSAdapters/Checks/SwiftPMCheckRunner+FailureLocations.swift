import AgentOSCore
import Foundation

public extension SwiftPMCheckRunner {
    /// Parses reported failures without guessing ownership from a file's name.
    static func failureLocations(in log: String, checkout: URL) -> [CheckFailureLocation] {
        let root = checkout.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var filesByName: [String: [String]]?
        var locations: [CheckFailureLocation] = []

        func relativePath(_ url: URL) -> String? {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }

        func resolve(_ reported: String) -> (file: String?, outside: Bool) {
            if reported.contains("/") {
                let url = reported.hasPrefix("/")
                    ? URL(fileURLWithPath: reported)
                    : root.appending(path: reported)
                let file = relativePath(url)
                return (file, file == nil)
            }
            if filesByName == nil {
                var index: [String: [String]] = [:]
                if let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
                ) {
                    for case let url as URL in walker {
                        if [".git", ".build"].contains(url.lastPathComponent) {
                            walker.skipDescendants()
                            continue
                        }
                        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                              values.isRegularFile == true, let file = relativePath(url) else { continue }
                        index[url.lastPathComponent, default: []].append(file)
                    }
                }
                filesByName = index
            }
            let matches = filesByName?[reported] ?? []
            return (matches.count == 1 ? matches[0] : nil, false)
        }

        for rawLine in log.split(separator: "\n") {
            let line = String(rawLine).replacingOccurrences(
                of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            let suite = line.firstMatch(of: /-\[(?:\w+\.)?(\w+) \w+\]/).map { String($0.output.1) }
            let reported: String?
            if let issue = line.firstMatch(of: /recorded an issue.*? at (.+?\.swift):\d+/) {
                reported = String(issue.output.1)
            } else if let diagnostic = line.firstMatch(of: /^(.+?):\d+(?::\d+)?:\s*error:/) {
                reported = String(diagnostic.output.1)
            } else if line.firstMatch(of: /Test Case '-\[(?:\w+\.)?\w+ \w+\]' failed/) != nil {
                reported = nil
            } else {
                continue
            }
            var file: String?
            if let reported {
                let resolved = resolve(reported)
                guard !resolved.outside else { continue }
                file = resolved.file
            }
            let location = CheckFailureLocation(file: file, suite: suite)
            if !locations.contains(location) { locations.append(location) }
        }
        return locations
    }
}
