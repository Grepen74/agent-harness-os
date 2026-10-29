import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite("Readiness scan")
struct ReadinessTests {
    func snapshot(_ contents: [String: String], extraFiles: [String] = []) -> RepositorySnapshot {
        RepositorySnapshot(branch: "main", commit: "abc1234567", files: Array(contents.keys) + extraFiles, contents: contents)
    }

    func titles(_ findings: [Finding], _ severity: Finding.Severity) -> [String] {
        findings.filter { $0.severity == severity }.map(\.title)
    }

    let wellPrepared: [String: String] = [
        "README.md": "# App",
        "AGENTS.md": "Build with `swift build`, test with `swift test`.",
        "CONTRIBUTING.md": "## Definition of Done\nTests pass.",
        ".github/CODEOWNERS": "* @team",
        ".agentos/config": "test: swift test",
        "Package.swift": "targets: [.target(name: \"App\"), .testTarget(name: \"AppTests\")]",
    ]

    @Test func aWellPreparedRepoHasNoBlockersOrWarnings() {
        var repo = snapshot(wellPrepared)
        repo.swiftTestingFiles = 2
        let findings = ReadinessRules.findings(for: repo)
        #expect(titles(findings, .blocker).isEmpty)
        #expect(titles(findings, .warning).isEmpty)
        #expect(titles(findings, .info).contains("Tests use Swift Testing"))
    }

    @Test func missingConfigBlocksAndNamesEveryTestEntryPoint() throws {
        var files = wellPrepared
        files[".agentos/config"] = nil
        files["App/project.yml"] = "targets: { AppTests: { type: bundle.unit-test } }"
        let config = try #require(ReadinessRules.findings(for: snapshot(files)).first { $0.check == "config" })
        #expect(config.severity == .blocker)
        #expect(config.detail.contains("2 test entry points"))
    }

    @Test func gapsInTheFilesThatSteerAgentsAreWarnings() {
        let findings = ReadinessRules.findings(for: snapshot([
            "AGENTS.md": "Be nice.",
            "CONTRIBUTING.md": "Open a PR.",
            "Package.swift": "",
        ]))
        #expect(Set(titles(findings, .warning)) == [
            "Agent instructions don't say how to build or test",
            "CONTRIBUTING.md has no Definition of Done",
            "No README",
            "Swift package in . has no test target",
        ])
    }

    @Test func projectFilesThatEveryNewFileChangesAreHotspots() {
        let classic = "App.xcodeproj/project.pbxproj"
        let generated = "Gen/Gen.xcodeproj/project.pbxproj"
        let findings = ReadinessRules.findings(for: snapshot([
            classic: "PBXGroup",
            generated: "PBXGroup",
            "Gen/project.yml": "",
            "Synced.xcodeproj/project.pbxproj": "PBXFileSystemSynchronizedRootGroup",
        ]))
        let hotspots = findings.filter { $0.check == "xcode.hotspot" }
        #expect(Set(hotspots.filter { $0.severity == .warning }.map(\.title)) == [
            "Project file is a merge hotspot: \(classic)",
            "Generated project file is committed: \(generated)",
        ])
        #expect(hotspots.contains { $0.severity == .info && $0.title == "Synced.xcodeproj uses synchronized folders" })
    }

    @Test func vendoredPackagesAreIgnored() {
        #expect(RepositorySnapshot.interestingPaths(of: ["Package.swift", "Pods/X/Package.swift", ".build/y/Package.swift"])
            == ["Package.swift"])
    }

    // MARK: Against a real git repo

    @Test func scanReadsTheDefaultBranchNotTheWorkingCopy() async throws {
        let repo = try await makeRepo(["README.md": "# App", "Package.swift": "// .testTarget("])
        try "Build and test with swift test".write(to: repo.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

        let result = await ReadinessScanner().scan(repo)
        #expect(result.scan.branch == "main")
        #expect(result.identity?.hasPrefix(repo.lastPathComponent) == true)
        #expect(result.scan.findings.contains { $0.title == "No instructions for agents" })
        #expect(result.scan.findings.contains { $0.title == "1 uncommitted change in your checkout" })
        #expect(!result.scan.isReady)
    }

    @Test func aFolderThatIsNotARepoIsABlocker() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agentos-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await ReadinessScanner().scan(folder)
        #expect(result.scan.findings.map(\.title) == ["Not a git repository"])
        #expect(result.identity == nil)
    }

    private func makeRepo(_ files: [String: String]) async throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (path, text) in files { try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8) }
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"]] {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: repo)
            try #require(result.status == 0, "\(result.output)")
        }
        return repo
    }
}
