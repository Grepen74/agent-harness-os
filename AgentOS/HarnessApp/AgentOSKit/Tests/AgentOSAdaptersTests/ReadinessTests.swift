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
        ".agentos/config.json": #"{"test": {"command": "swift test", "only": "--filter {suite}"}, "leafTests": {"target": "AppTests", "folder": "Tests/AppTests"}}"#,
        "Package.swift": "targets: [.target(name: \"App\"), .testTarget(name: \"AppTests\")]",
    ]

    let passed = Baseline(commit: "abc1234567", passed: true, summary: "test passed", seconds: 4, log: nil)

    @Test func aWellPreparedRepoHasNoBlockersOrWarnings() {
        var repo = snapshot(wellPrepared)
        repo.swiftTestingFiles = 2
        let findings = ReadinessRules.findings(for: repo, baseline: passed)
        #expect(titles(findings, .blocker).isEmpty)
        #expect(titles(findings, .warning).isEmpty)
        #expect(titles(findings, .info).contains("Tests use Swift Testing"))
        #expect(titles(findings, .info).contains("Baseline passes on main"))
    }

    @Test func missingConfigBlocksAndNamesEveryTestEntryPoint() throws {
        var files = wellPrepared
        files[".agentos/config.json"] = nil
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

    @Test func theBaselineMustPassAtTheCurrentCommit() {
        func baseline(_ result: Baseline?) -> Finding? {
            ReadinessRules.findings(for: snapshot(wellPrepared), baseline: result).first { $0.check == "baseline" }
        }
        #expect(baseline(nil)?.severity == .blocker)
        #expect(baseline(passed)?.severity == .info)
        let failed = Baseline(commit: "abc1234567", passed: false, summary: "test failed", seconds: 4, log: nil)
        #expect(baseline(failed)?.title == "Baseline fails on main")
        let old = Baseline(commit: "0ld", passed: true, summary: "", seconds: 4, log: nil)
        #expect(baseline(old)?.title == "Baseline is out of date")
    }

    @Test func badConfigFilesAreReported() {
        func configFindings(_ files: [String: String]) -> [String] {
            var contents = wellPrepared
            contents[".agentos/config.json"] = nil
            return ReadinessRules.findings(for: snapshot(contents.merging(files) { $1 }), baseline: passed)
                .filter { $0.check.hasPrefix("config") && $0.check != "config.leafTests" && $0.severity != .info }.map(\.title)
        }
        let leafTests = ReadinessRules.findings(for: snapshot(wellPrepared.merging(
            [".agentos/config.json": #"{"test": {"command": "x"}}"#]) { $1 }), baseline: passed).filter { $0.check == "config.leafTests" }
        #expect(leafTests.map(\.severity) == [.blocker, .warning])
        #expect(configFindings([".agentos/config.json": "{"]) == [".agentos/config.json can't be read"])
        #expect(configFindings([".agentos/config.json": #"{"test": {"command": "x"}, "limts": {}}"#])
            == ["Unknown keys in .agentos/config.json: limts"])
        #expect(configFindings([".agentos/config.json": #"{"test": {"command": "x"}, "limits": {"maxAttempts": 9}}"#])
            == ["Repo config raises max attempts per leaf from 3 to 9"])
        #expect(configFindings([".agentos/config.yml": "test: x"]) == ["Unsupported config file: .agentos/config.yml", "No repo config"])
    }

    @Test func aPrepareStepThatRegeneratesTheProjectDefusesTheHotspot() throws {
        var files = wellPrepared
        files["Gen/project.yml"] = ""
        files["Gen/Gen.xcodeproj/project.pbxproj"] = "PBXGroup"
        let before = try #require(ReadinessRules.findings(for: snapshot(files)).first { $0.check == "xcode.hotspot" })
        files[".agentos/config.json"] = #"{"build": {"prepare": "cd Gen && xcodegen generate"}, "test": {"command": "swift test"}}"#
        let after = try #require(ReadinessRules.findings(for: snapshot(files)).first { $0.check == "xcode.hotspot" })
        #expect(before.severity == .warning)
        #expect(after.severity == .info)
    }

    @Test func simulatorsNamedInTheConfigMustBeInstalled() throws {
        let installed = try #require(ReadinessScanner.parseSimulators(#"""
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-6": [{"name": "iPhone 14"}],
                         "com.apple.CoreSimulator.SimRuntime.iOS-17-0": []}}
            """#))
        #expect(installed == ["iOS 18.6": ["iPhone 14"]])

        func warnings(_ destination: String) -> [String] {
            var repo = snapshot(wellPrepared.merging([".agentos/config.json": """
                {"test": {"command": "xcodebuild test -scheme App -destination '\(destination)'"}}
                """]) { $1 })
            repo.simulators = installed
            return ReadinessRules.findings(for: repo).filter { $0.check == "config.simulator" }.map(\.title)
        }
        #expect(warnings("platform=iOS Simulator,name=iPhone 14,OS=18.6").isEmpty)
        #expect(warnings("platform=iOS Simulator,name=iPhone 14").isEmpty)
        #expect(warnings("platform=iOS Simulator,name=iPhone 14,OS=17.0") == ["Simulator not installed: iPhone 14, 17.0"])
        #expect(warnings("platform=iOS Simulator,name=iPhone 99") == ["Simulator not installed: iPhone 99"])
        #expect(warnings("platform=macOS").isEmpty)
    }

    @Test func aRepoWithoutConfigGetsADraft() throws {
        var files = wellPrepared
        files[".agentos/config.json"] = nil
        files["App/project.yml"] = "name: Demo\noptions:\n  platform: iOS\n"
        let repo = snapshot(files, extraFiles: ["Sources/App/A.swift", "Tests/AppTests/ATests.swift"])
        let draft = try #require(ReadinessRules.assess(repo, harness: HarnessSettings(), baseline: nil).draft)
        #expect(draft.test == .init(command: "swift test", only: "--filter {suite}"))
        #expect(draft.build?.prepare == "cd App && xcodegen generate")
        #expect(draft.checks?.map(\.command) == [
            "xcodebuild -project App/Demo.xcodeproj -scheme Demo -destination 'platform=iOS Simulator,name=iPhone 16' "
                + "-derivedDataPath .build/agentos-xcode -quiet build",
        ])
        #expect(draft.leafTests == .init(target: "AppTests", folder: "Tests/AppTests"))
        #expect(draft.components == ["Sources/App"])
        // A draft is a valid config.
        #expect(try RepoConfig.parse(draft.json).config == draft)
    }

    @Test func aConfigChangedOnlyInTheCheckoutIsAWarning() {
        var repo = snapshot(wellPrepared)
        repo.checkoutConfig = wellPrepared[RepoConfig.path]
        #expect(!ReadinessRules.checkout(repo).contains { $0.check == "checkout.config" })

        repo.checkoutConfig = #"{"tracker": {"type": "github-issues"}}"#
        let finding = ReadinessRules.checkout(repo).first { $0.check == "checkout.config" }
        #expect(finding?.severity == .warning)
        #expect(finding?.title == ".agentos/config.json in your checkout isn't the one on main")
    }

    @Test func openingTheConfigWritesTheDraftOnlyWhenThereIsNone() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agentos-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try RepoConfigFile.prepare(in: root, draft: #"{"test": {"command": "swift test"}}"#)
        #expect(first.created)
        #expect(first.url.path.hasSuffix(".agentos/config.json"))
        #expect(try String(contentsOf: first.url, encoding: .utf8) == #"{"test": {"command": "swift test"}}"# + "\n")

        try "edited".write(to: first.url, atomically: true, encoding: .utf8)
        let second = try RepoConfigFile.prepare(in: root, draft: "other draft")
        #expect(!second.created)
        #expect(try String(contentsOf: second.url, encoding: .utf8) == "edited")
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

    @Test func checksRunInOrderAndStopAtTheFirstFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agentos-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = RepoConfig(build: .init(prepare: "echo prepared > prepared.txt", command: "test -f prepared.txt"),
                                test: .init(command: "echo testing", only: "{suite}-only"),
                                checks: [.init(name: "lint", command: "false"), .init(name: "never", command: "echo never")])
        let runner = CommandCheckRunner(config: config)
        #expect(runner.steps(only: "AppTests").map(\.command)
            == ["echo prepared > prepared.txt", "test -f prepared.txt", "echo testing AppTests-only"])

        let output = await runner.runChecks(in: folder, only: nil)
        #expect(!output.passed)
        #expect(output.summary.hasPrefix("lint failed"))
        #expect(output.log.contains("$ echo testing\ntesting\n"))
        #expect(!output.log.contains("never\n"))
        #expect(await runner.runChecks(in: folder, only: "X").passed)
    }

    @Test func baselineRunsOnTheCommittedBranchOutsideTheCheckout() async throws {
        let config = #"{"test": {"command": "test -f README.md && test ! -f scratch.txt"}}"#
        let repo = try await makeRepo(["README.md": "# App", ".agentos/config.json": config])
        try "uncommitted".write(to: repo.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        guard case .repo(let location) = await ReadinessScanner().locate(repo) else {
            Issue.record("not located")
            return
        }
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let scanned = await ReadinessScanner().scan(location)
        let baseline = await BaselineRunner(storage: storage)
            .run(config: try #require(scanned.config), commit: location.commit, repo: location.root)
        #expect(baseline.passed, "\(baseline.summary)")
        #expect(baseline.commit == location.commit)
        let log = try #require(baseline.log)
        #expect(try String(contentsOfFile: log.path, encoding: .utf8).contains("$ test -f README.md"))

        let rescanned = await ReadinessScanner().scan(location, baseline: baseline)
        #expect(rescanned.scan.findings.contains { $0.title == "Baseline passes on main" })
    }

    @Test("Without a local copy of the remote's default branch, the scan reads origin/<branch> and says so")
    func aRemoteDefaultBranchWithoutALocalCopyIsReadFromTheRemote() async throws {
        let repo = try await makeRepo(["README.md": "# App"])
        for arguments in [["update-ref", "refs/remotes/origin/develop", "HEAD"],
                          ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"]] {
            _ = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: repo)
        }
        // Not the stale local main, and nothing created in your repo.
        let result = await ReadinessScanner().scan(repo)
        #expect(result.scan.branch == "origin/develop")
        let finding = try #require(result.scan.findings.first { $0.title.hasPrefix("Reads the remote's develop as of your last fetch") })
        #expect(finding.title.contains("last fetched"), "has a fetch date from the reflog: \(finding.title)")
        let branches = try await ProcessRunner.run("/usr/bin/env", ["git", "branch", "--list", "develop"], in: repo).output
        #expect(branches.isEmpty)

        _ = try await ProcessRunner.run("/usr/bin/env", ["git", "branch", "develop", "origin/develop"], in: repo)
        let local = await ReadinessScanner().scan(repo)
        #expect(local.scan.branch == "develop")
        #expect(local.identity == result.identity, "same repo either way")
    }

    private func makeRepo(_ files: [String: String]) async throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"]] {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: repo)
            try #require(result.status == 0, "\(result.output)")
        }
        return repo
    }
}
