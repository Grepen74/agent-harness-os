// Expected API: existing CommandCheckRunner.steps(only:) / runChecks(in:only:),
// SwiftPMCheckRunner.runChecks(in:only:), and @testable ReadinessRules.findings(for:)
// / assess(_:harness:baseline:). SwiftPMCheckRunner.init(runCommand:) accepts an async
// (executable: String, arguments: [String], directory: URL) -> ProcessRunner.Result
// executor, defaulting to real process execution. Only that injection API needs a placeholder.
// Criterion 5's specified ReadinessTests fixture/expectation edits, and criterion 6's
// agent instructions and real-repo-mode.md explanations, also require diff review.
import Foundation
import Testing
import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSAdapters

@Suite struct GH_158Tests {
    @Test(arguments: ["GH_4_2Tests", "TestFeedbackTests", "Dot.Name+Tests"])
    func suiteRegexAppendsASingleQuotedEscapedAndAnchoredFilter(suite: String) throws {
        let runner = CommandCheckRunner(config: Self.config(
            command: "cd Package && swift test --build-system native", only: "--filter {suiteRegex}"
        ))
        let test = try #require(runner.steps(only: suite).first { $0.name == "test" })
        let escaped = suite == "Dot.Name+Tests" ? #"Dot\.Name\+Tests"# : suite
        #expect(test.command == "cd Package && swift test --build-system native --filter '\\.\(escaped)(/|$)'")
    }

    @Test
    func suiteRegexTreatsEveryRegexMetacharacterInTheSuiteNameLiterally() async throws {
        let control = try NSRegularExpression(pattern: #"\.GH_4_2Tests(/|$)"#)
        try #require(Self.matches(control, "Fixture.GH_4_2Tests/test()"))
        try #require(!Self.matches(control, "Fixture.GH_14_2Tests/test()"))
        let suite = #"Odd.+*?()[]{}^$\Tests"#
        let runner = CommandCheckRunner(config: Self.config(command: "printf '%s\\n'", only: "{suiteRegex}"))
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = try await withHangGuard("expanding and shell-quoting suiteRegex") {
            await runner.runChecks(in: folder, only: suite)
        }
        try #require(output.passed, "\(output.summary)\n\(output.log)")
        let pattern = try #require(output.log.split(separator: "\n").last.map(String.init))
        try #require(pattern.hasPrefix(#"\."#), "suiteRegex must start with an escaped suite separator.")
        try #require(pattern.hasSuffix("(/|$)"), "suiteRegex must end at the suite boundary.")
        let regex = try NSRegularExpression(pattern: pattern)
        #expect(Self.matches(regex, "Fixture.\(suite)/test()"))
        #expect(Self.matches(regex, "Fixture.\(suite)"))
        #expect(!Self.matches(regex, "Fixture.\(suite)Extra/test()"))
        #expect(!Self.matches(regex, "Fixture.Prefix\(suite)/test()"))
        #expect(!Self.matches(regex, "Fixture.OddXTests/test()"))
        for character in ".+*?()[]{}^$\\" {
            let different = suite.replacingOccurrences(of: String(character), with: "X")
            #expect(!Self.matches(regex, "Fixture.\(different)/test()"),
                    "The suite's \(character) must be literal, not a regex operator.")
        }
    }

    @Test
    func commandRunnerRunsOnlyTheRequestedSuiteWithSwiftTest() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.proveTheFixtureRunsAllFourSuites()
        let runner = CommandCheckRunner(config: Self.config(
            command: "swift test --build-system native", only: "--filter {suiteRegex}"
        ))

        for suite in ["GH_4_2Tests", "TestFeedbackTests"] {
            try fixture.clearResults()
            let output = try await withHangGuard("CommandCheckRunner selecting \(suite)", timeout: .seconds(300)) {
                await runner.runChecks(in: fixture.root, only: suite)
            }
            #expect(output.passed, "\(output.summary)\n\(output.log)")
            #expect(try fixture.ranSuites() == [suite],
                    "Must run \(suite), not zero tests or another suite.\n\(output.log)")
        }
    }

    @Test(arguments: ["--filter {suite}", "-only-testing:AppTests/{suite}", "{suite}:{suite}"])
    func suiteStillSubstitutesTheBareName(only: String) throws {
        let suite = "TestFeedbackTests"
        let runner = CommandCheckRunner(config: Self.config(command: "test-command", only: only))
        let test = try #require(runner.steps(only: suite).first { $0.name == "test" })
        #expect(test.command == "test-command " + only.replacingOccurrences(of: "{suite}", with: suite))
    }

    @Test
    func bothPlaceholdersCanBeUsedWithoutChangingTheBareSuiteMeaning() throws {
        let runner = CommandCheckRunner(config: Self.config(
            command: "test-command", only: "--label {suite} --filter {suiteRegex}"
        ))
        let test = try #require(runner.steps(only: "Dot.Name+Tests").first { $0.name == "test" })
        #expect(test.command == #"test-command --label Dot.Name+Tests --filter '\.Dot\.Name\+Tests(/|$)'"#)
    }

    @Test
    func aFullRunDoesNotAppendEitherSuiteSelector() throws {
        let runner = CommandCheckRunner(config: Self.config(command: "swift test", only: "--filter {suiteRegex}"))
        let test = try #require(runner.steps(only: nil).first { $0.name == "test" })
        #expect(test.command == "swift test")
    }

    @Test
    func swiftPMRunnerRunsOnlyTheRequestedSuiteWithTheSameAnchoredFilter() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.proveTheFixtureRunsAllFourSuites()
        let recorder = CommandRecorder()
        let runner = SwiftPMCheckRunner(runCommand: { executable, arguments, directory in
            try await recorder.run(executable, arguments, in: directory)
        })

        try fixture.clearResults()
        let baseline = try await withHangGuard("validating the injected command executor", timeout: .seconds(300)) {
            try await recorder.run("/usr/bin/env", ["swift", "test"], in: fixture.root)
        }
        try #require(baseline.status == 0, "\(baseline.output)")
        try #require(try fixture.ranSuites() == Set(fixture.suites), "The executor must run the real fixture tests.")

        for suite in ["GH_4_2Tests", "TestFeedbackTests"] {
            try fixture.clearResults()
            await recorder.clear()
            let output = try await withHangGuard("SwiftPMCheckRunner selecting \(suite)", timeout: .seconds(300)) {
                await runner.runChecks(in: fixture.root, only: suite)
            }
            let commands = await recorder.commands
            let command = try #require(commands.first, "SwiftPMCheckRunner must execute swift test with the anchored filter.")
            #expect(commands.count == 1)
            #expect(command.executable == "/usr/bin/env")
            #expect(command.arguments == ["swift", "test", "--filter", "\\.\(suite)(/|$)"])
            #expect(command.directory == fixture.root)
            #expect(output.passed, "\(output.summary)\n\(output.log)")
            #expect(try fixture.ranSuites() == [suite],
                    "Must run \(suite), not zero tests or another suite.\n\(output.log)")
        }
    }

    @Test(arguments: [
        "--filter {suite}", "--filter={suite}", "--filter {suiteRegex} --label {suite}"
    ])
    func readinessWarnsAboutTheBareSuiteWithFilterAndSuggestsSuiteRegex(only: String) throws {
        let findings = ReadinessRules.findings(for: Self.snapshot(only: only))
        let warning = try #require(findings.first { $0.check == "config.leafTests" && $0.severity == .warning })
        #expect(warning.suggestion?.contains("{suiteRegex}") == true)
    }

    @Test(arguments: ["--filter {suiteRegex}", "-only-testing:AppTests/{suite}", "{suite}"])
    func readinessDoesNotWarnAboutAnExactFilterOrABareSuiteWithoutFilter(only: String) {
        let findings = ReadinessRules.findings(for: Self.snapshot(only: only))
        #expect(!findings.contains { $0.check == "config.leafTests" && $0.severity == .warning })
    }

    @Test
    func aWellPreparedRepoUsingSuiteRegexHasNoBlockersOrWarnings() {
        var repo = Self.snapshot(only: "--filter {suiteRegex}")
        repo.swiftTestingFiles = 2
        let baseline = Baseline(commit: repo.commit, passed: true, summary: "tests passed", seconds: 0, log: nil)
        let findings = ReadinessRules.findings(for: repo, baseline: baseline)
        #expect(!findings.contains { $0.severity == .blocker || $0.severity == .warning })
    }

    @Test
    func aSwiftPMRepoWithoutConfigGetsAnExactSuiteRegexDraft() throws {
        var repo = Self.snapshot(only: "--filter {suiteRegex}")
        repo.contents[RepoConfig.path] = nil
        repo.files.removeAll { $0 == RepoConfig.path }
        repo.files += ["Sources/App/App.swift", "Tests/AppTests/Acceptance.swift"]
        let draft = try #require(ReadinessRules.assess(repo, harness: HarnessSettings(), baseline: nil).draft)
        #expect(draft.test.command == "swift test")
        #expect(draft.test.only == "--filter {suiteRegex}")
    }

    private static func config(command: String = "swift test", only: String) -> RepoConfig {
        RepoConfig(test: .init(command: command, only: only),
                   leafTests: .init(target: "AppTests", folder: "Tests/AppTests"))
    }

    private static func snapshot(only: String) -> RepositorySnapshot {
        let contents = [
            "README.md": "# App",
            "AGENTS.md": "Build with swift build; test with swift test.",
            "CONTRIBUTING.md": "## Definition of Done\nTests pass.",
            ".github/CODEOWNERS": "* @team",
            RepoConfig.path: Self.config(only: only).json,
            "Package.swift": #"targets: [.target(name: "App"), .testTarget(name: "AppTests")]"#,
        ]
        return RepositorySnapshot(branch: "main", commit: "GH158-commit",
                                  files: Array(contents.keys), contents: contents)
    }

    private static func matches(_ regex: NSRegularExpression, _ identifier: String) -> Bool {
        regex.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)) != nil
    }

    private static func makeFolder() throws -> URL {
        let temporary = ProcessInfo.processInfo.environment["GH158_TEST_TEMP_DIRECTORY"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? FileManager.default.temporaryDirectory
        let root = temporary.appending(path: "GH158-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private actor CommandRecorder {
        struct Command: Sendable {
            let executable: String
            let arguments: [String]
            let directory: URL
        }

        private(set) var commands: [Command] = []

        func run(_ executable: String, _ arguments: [String], in directory: URL) async throws -> ProcessRunner.Result {
            commands.append(Command(executable: executable, arguments: arguments, directory: directory))
            return try await ProcessRunner.run(executable, arguments + ["--build-system", "native"],
                                               in: directory, timeout: .seconds(300))
        }

        func clear() { commands = [] }
    }

    private struct Fixture: Sendable {
        let root: URL
        let suites = ["GH_4_2Tests", "GH_14_2Tests", "TestFeedbackTests", "AcceptanceTestFeedbackTests"]

        init() throws {
            root = try GH_158Tests.makeFolder()
            do {
                try """
                    // swift-tools-version: 6.0
                    import PackageDescription
                    let package = Package(
                        name: "GH158Fixture",
                        platforms: [.macOS(.v15)],
                        targets: [.testTarget(name: "FixtureTests")]
                    )
                    """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
                let tests = root.appending(path: "Tests/FixtureTests")
                try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
                for suite in suites {
                    try """
                        import Foundation
                        import Testing
                        @Suite struct \(suite) {
                            @Test func recordsThatThisSuiteRan() throws {
                                let result = URL(filePath: #filePath).deletingLastPathComponent()
                                    .appending(path: "\(suite).ran")
                                try "\(suite)".write(to: result, atomically: true, encoding: .utf8)
                            }
                        }
                        """.write(to: tests.appending(path: "\(suite).swift"), atomically: true, encoding: .utf8)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func proveTheFixtureRunsAllFourSuites() async throws {
            let result = try await withHangGuard("building and validating the four-suite fixture", timeout: .seconds(300)) {
                try await ProcessRunner.run("/usr/bin/env", ["swift", "test", "--build-system", "native"],
                                            in: root, timeout: .seconds(300))
            }
            try #require(result.status == 0, "\(result.output)")
            try #require(try ranSuites() == Set(suites), "The fixture must observe all four real suites.\n\(result.output)")
        }

        func ranSuites() throws -> Set<String> {
            let folder = root.appending(path: "Tests/FixtureTests")
            return Set(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "ran" }.map { $0.deletingPathExtension().lastPathComponent })
        }

        func clearResults() throws {
            for suite in try ranSuites() {
                try FileManager.default.removeItem(at: root.appending(path: "Tests/FixtureTests/\(suite).ran"))
            }
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
