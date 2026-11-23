import Foundation
import Testing

/// SwiftPM's incremental build only recompiles a target when a module it lists as a dependency changes. A module
/// that is only imported, and reached through another dependency, can change its types' layout without the
/// importing target being recompiled: the stale code reads fields at old offsets and the tests crash (signal 11).
@Suite("Package dependencies")
struct PackageDependencyTests {
    struct Target {
        let name: String
        let directory: URL
        let dependencies: Set<String>
        let excluded: [URL]
    }

    static let packageRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyTargetListsEveryPackageModuleItImports() throws {
        let targets = try Self.targets()
        #expect(targets.count > 5)
        let names = Set(targets.map(\.name))
        for target in targets {
            let others = targets.map(\.directory).filter { $0.path.hasPrefix(target.directory.path + "/") }
            let imported = try Self.imports(in: target.directory, skipping: target.excluded + others)
            let missing = imported.intersection(names).subtracting(target.dependencies).subtracting([target.name])
            #expect(missing.isEmpty, "\(target.name) imports \(missing.sorted()) without listing them in Package.swift")
        }
    }

    static func targets() throws -> [Target] {
        let manifest = try String(contentsOf: packageRoot.appending(path: "Package.swift"), encoding: .utf8)
        let declaration = /\.(target|testTarget|executableTarget)\(/
        let starts = manifest.matches(of: declaration)
        return try starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1].range.lowerBound : manifest.endIndex
            let text = String(manifest[starts[index].range.upperBound..<end])
            let name = try #require(strings(in: text, after: "name:").first)
            let folder = starts[index].output.1 == "testTarget" ? "Tests" : "Sources"
            let directory = packageRoot.appending(path: strings(in: text, after: "path:").first ?? "\(folder)/\(name)")
            return Target(name: name, directory: directory,
                          dependencies: Set(strings(in: text, after: "dependencies:")),
                          excluded: strings(in: text, after: "exclude:").map { directory.appending(path: $0) })
        }
    }

    /// The string literals right after `label`: one, or every one in the `[...]` list that follows it.
    static func strings(in text: String, after label: String) -> [String] {
        guard let start = text.range(of: label) else { return [] }
        let rest = text[start.upperBound...].drop { $0 == " " }
        let scope = rest.first == "[" ? rest[..<(rest.firstIndex(of: "]") ?? rest.endIndex)] : rest.prefix { $0 != "," }
        return scope.matches(of: /"([^"]*)"/).map { String($0.output.1) }
    }

    static func imports(in directory: URL, skipping skipped: [URL]) throws -> Set<String> {
        let walker = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var modules: Set<String> = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            if skipped.contains(where: { file.path.hasPrefix($0.path + "/") }) { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                if let match = line.firstMatch(of: /^\s*(?:@\w+\s+)*(?:public\s+|package\s+|internal\s+)?import\s+(\w+)/) {
                    modules.insert(String(match.output.1))
                }
            }
        }
        return modules
    }
}
