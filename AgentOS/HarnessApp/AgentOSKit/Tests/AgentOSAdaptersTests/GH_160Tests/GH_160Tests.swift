// Expected API: AgentOSCore.CheckFailureLocation has optional repository-relative `file` and
// optional `suite`; CheckOutput.failureLocations exposes [CheckFailureLocation].
// public static SwiftPMCheckRunner.failureLocations(in: String, checkout: URL)
// -> [CheckFailureLocation] parses logs against that checkout, and
// both real check runners populate the output on failure while retaining today's failingTargets.
// All six criteria are observable through these APIs; none are source/documentation/setup-only.
import Foundation
import Testing
import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSAdapters

@Suite struct GH_160Tests {
    @Test
    func commandRunnerReportsTheFailureFileAndSuiteFromItsOutput() async throws {
        let fixture = try Fixture(files: [
            "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift": "// support\n"
        ])
        defer { fixture.removeFiles() }
        let path = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let log = """
            \(fixture.checkout.appending(path: path).path):27: error: -[AppTests.RenamedSuite testValue] : XCTAssertEqual failed
            Test Case '-[AppTests.RenamedSuite testValue]' failed (0.001 seconds).
            """
        let output = try await Self.commandOutput(log, status: 1, fixture: fixture)

        #expect(!output.passed)
        #expect(output.log.contains(log))
        #expect(output.failureLocations.contains { $0.file == path && $0.suite == "RenamedSuite" })
        #expect(output.failureLocations.contains { $0.suite == "RenamedSuite" })
    }

    @Test
    func swiftPMRunnerReportsTheRepositoryRelativeSupportFileForACompileFailure() async throws {
        let fixture = try Fixture(files: Self.packageFiles(testSource: """
            import Testing
            @Test func broken() {
                _ = missingGH160Symbol
            }
            """))
        defer { fixture.removeFiles() }
        let output = try await withHangGuard("SwiftPM fixture compile failure", timeout: .seconds(300)) {
            await SwiftPMCheckRunner().runChecks(in: fixture.checkout, only: nil)
        }

        #expect(!output.passed)
        #expect(output.log.contains("missingGH160Symbol"),
                "The fixture must fail in the compiler, not while launching SwiftPM.")
        #expect(output.failingTargets == ["AppTests"])
        #expect(output.failureLocations.contains {
            $0.file == "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        })
    }

    @Test(arguments: ["compile", "xctest"])
    func absoluteInCheckoutDiagnosticsKeepTheirEntireRelativePath(kind: String) throws {
        let path = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let fixture = try Fixture(files: [path: "// support\n"])
        defer { fixture.removeFiles() }
        let absolute = fixture.checkout.appending(path: path).path
        let log = kind == "compile"
            ? "\(absolute):9:4: error: cannot find 'value' in scope"
            : "\(absolute):9: error: -[AppTests.GH_53Tests testValue] : XCTAssertTrue failed"

        let locations = SwiftPMCheckRunner.failureLocations(in: log, checkout: fixture.checkout)
        #expect(locations.contains { $0.file == path })
        if kind == "xctest" {
            #expect(locations.contains { $0.file == path && $0.suite == "GH_53Tests" })
        }
        #expect(!locations.contains { $0.file == "GH_53TestsSupport.swift" })
        #expect(!locations.contains { $0.file == absolute })
    }

    @Test
    func relativeCompilerDiagnosticsStayRelativeToTheCheckout() throws {
        let path = "Sources/App/Feature.swift"
        let fixture = try Fixture(files: [path: "// source\n"])
        defer { fixture.removeFiles() }
        let locations = SwiftPMCheckRunner.failureLocations(
            in: "\(path):18:2: error: cannot find 'value' in scope", checkout: fixture.checkout)

        #expect(locations.contains { $0.file == path })
    }

    @Test(arguments: ["Module.Suite", "Suite"])
    func failedXCTestCasesReportTheSuiteEvenWithoutAFile(qualifiedSuite: String) throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let log = "Test Case '-[\(qualifiedSuite) testValue]' failed (0.001 seconds)."
        let locations = SwiftPMCheckRunner.failureLocations(in: log, checkout: fixture.checkout)

        #expect(locations.contains { $0.suite == "Suite" && $0.file == nil })
        #expect(!locations.contains { $0.suite == qualifiedSuite && qualifiedSuite != "Suite" })
    }

    @Test(arguments: [
        "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift",
        "Sources/App/FailureSupport.swift"
    ])
    func swiftTestingIssuesResolveAUniqueBasenameAnywhereInTheCheckout(path: String) throws {
        let fixture = try Fixture(files: [path: "// support\n"])
        defer { fixture.removeFiles() }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let log = "Test value() recorded an issue at \(basename):12:3: Expectation failed: (value == 1)"
        let locations = SwiftPMCheckRunner.failureLocations(in: log, checkout: fixture.checkout)

        #expect(locations.contains { $0.file == path })
    }

    @Test(arguments: [false, true])
    func swiftTestingIssuesHaveNoFileWhenTheBasenameIsMissingOrAmbiguous(ambiguous: Bool) throws {
        let files = ambiguous ? [
            "Tests/AppTests/First/SharedSupport.swift": "// first\n",
            "Tests/AppTests/Second/SharedSupport.swift": "// second\n"
        ] : [:]
        let fixture = try Fixture(files: files)
        defer { fixture.removeFiles() }
        let locations = SwiftPMCheckRunner.failureLocations(
            in: "Test value() recorded an issue at SharedSupport.swift:12:3: Expectation failed",
            checkout: fixture.checkout)

        #expect(!locations.isEmpty, "The issue still has a location, but its file is unknown.")
        #expect(locations.allSatisfy { $0.file == nil })
    }

    @Test
    func anAbsoluteDiagnosticIdentifiesItsFileEvenWhenItsBasenameIsDuplicated() throws {
        let path = "Tests/AppTests/First/SharedSupport.swift"
        let fixture = try Fixture(files: [
            path: "// first\n",
            "Tests/AppTests/Second/SharedSupport.swift": "// second\n"
        ])
        defer { fixture.removeFiles() }
        let locations = SwiftPMCheckRunner.failureLocations(
            in: "\(fixture.checkout.appending(path: path).path):12:3: error: cannot find 'value' in scope",
            checkout: fixture.checkout)

        #expect(locations.contains { $0.file == path })
        #expect(!locations.contains { $0.file == "Tests/AppTests/Second/SharedSupport.swift" })
    }

    @Test(arguments: ["absolute", "prefixSibling", "relativeEscape", "swiftTesting"])
    func diagnosticsOutsideTheCheckoutNeverBecomeFileLocations(kind: String) throws {
        let fixture = try Fixture(files: [
            "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift": "// in checkout\n"
        ])
        defer { fixture.removeFiles() }
        let relative = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let outside = fixture.base.appending(path: kind == "prefixSibling" ? "checkout with spaces-other" : "external")
            .appending(path: relative)
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "// external\n".write(to: outside, atomically: true, encoding: .utf8)
        let reported = kind == "relativeEscape" ? "../external/\(relative)" : outside.path
        let log = kind == "swiftTesting"
            ? "Test value() recorded an issue at \(reported):15:2: Expectation failed"
            : "\(reported):15:2: error: cannot find 'value' in scope"

        let locations = SwiftPMCheckRunner.failureLocations(in: log, checkout: fixture.checkout)
        #expect(locations.isEmpty, "An outside diagnostic must not fall back to the matching inside basename.")
    }

    @Test
    func passingLogLinesDoNotCreateFailureLocations() throws {
        let path = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let fixture = try Fixture(files: [path: "// support\n"])
        defer { fixture.removeFiles() }
        let log = """
            \(fixture.checkout.appending(path: path).path):3:2: warning: unused value
            Test Case '-[AppTests.GH_53Tests testValue]' passed (0.001 seconds).
            Test value() passed after 0.001 seconds.
            Test run with 1 test passed.
            """
        #expect(SwiftPMCheckRunner.failureLocations(in: log, checkout: fixture.checkout).isEmpty)
    }

    @Test(arguments: [false, true])
    func passingCommandOutputHasNoLocationsOrFailingTargetsEvenWithFailureShapedText(
        failureShaped: Bool
    ) async throws {
        let path = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let fixture = try Fixture(files: [path: "// support\n"])
        defer { fixture.removeFiles() }
        let log = failureShaped ? """
            \(fixture.checkout.appending(path: path).path):27: error: example diagnostic
            Test Case '-[AppTests.GH_53Tests testValue]' failed (0.001 seconds).
            Test value() recorded an issue at GH_53TestsSupport.swift:27:3: Expectation failed
            """ : """
            Test Case '-[AppTests.GH_53Tests testValue]' passed (0.001 seconds).
            Test run with 1 test passed.
            """
        let output = try await Self.commandOutput(log, status: 0, fixture: fixture)

        #expect(output.passed)
        #expect(output.log.contains(log))
        #expect(output.failureLocations.isEmpty)
        #expect(output.failingTargets.isEmpty)
    }

    @Test
    func passingSwiftPMOutputHasNoFailureLocationsOrFailingTargets() async throws {
        let fixture = try Fixture(files: Self.packageFiles(testSource: """
            import Testing
            @Test func valueIsAvailable() {
                #expect(1 + 1 == 2)
            }
            """))
        defer { fixture.removeFiles() }
        let output = try await withHangGuard("SwiftPM fixture passing tests", timeout: .seconds(300)) {
            await SwiftPMCheckRunner().runChecks(in: fixture.checkout, only: nil)
        }

        #expect(output.passed, "\(output.summary)\n\(output.log)")
        #expect(output.log.contains("valueIsAvailable"))
        #expect(output.failureLocations.isEmpty)
        #expect(output.failingTargets.isEmpty)
    }

    @Test
    func failureLocationsDoNotChangeLegacyTargetInferenceForTheSameLogs() async throws {
        let path = "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift"
        let fixture = try Fixture(files: [path: "// support\n"])
        defer { fixture.removeFiles() }
        let cases: [(String, Set<String>)] = [
            ("\(fixture.checkout.appending(path: path).path):6:2: error: missing symbol", ["AppTests"]),
            ("Test value() recorded an issue at GH_53Tests.swift:7:3: Expectation failed", ["GH_53Tests"]),
            ("Test value() recorded an issue at GH_53TestsSupport.swift:7:3: Expectation failed", []),
            ("Test Case '-[Module.RenamedSuite testValue]' failed (0.001 seconds).", []),
            ("Tests/OneTests/Support.swift:1: error: missing\n"
                + "Test value() recorded an issue at TwoTests.swift:2:3: Expectation failed", ["OneTests", "TwoTests"]),
            ("Test value() recorded an issue at RepeatTests.swift:2:3: Expectation failed\n"
                + "Test other() recorded an issue at RepeatTests.swift:3:3: Expectation failed", ["RepeatTests"]),
            ("ordinary output with no recognized failure", [])
        ]
        for (log, expected) in cases {
            #expect(SwiftPMCheckRunner.failingTargets(in: log) == expected)
            let output = try await Self.commandOutput(log, status: 1, fixture: fixture)
            #expect(!output.passed)
            #expect(output.failingTargets == expected, "Legacy target inference changed for: \(log)")
        }
    }

    @Test
    func theLogFixtureReallyCreatesFilesAndReturnsTheRequestedLogAndExitStatus() async throws {
        let path = "Tests/AppTests/SharedSupport.swift"
        let fixture = try Fixture(files: [path: "// fixture sentinel\n"])
        defer { fixture.removeFiles() }
        #expect(try String(contentsOf: fixture.checkout.appending(path: path), encoding: .utf8)
            == "// fixture sentinel\n")
        let log = "fixture sentinel with 'quotes' and $literal text\nsecond line"
        let passed = try await Self.commandOutput(log, status: 0, fixture: fixture)
        let failed = try await Self.commandOutput(log, status: 1, fixture: fixture)
        #expect(passed.passed)
        #expect(!failed.passed)
        #expect(passed.log.contains(log))
        #expect(failed.log.contains(log))
    }

    private static func commandOutput(_ log: String, status: Int, fixture: Fixture) async throws -> CheckOutput {
        try log.write(to: fixture.checkout.appending(path: "check-output.log"), atomically: true, encoding: .utf8)
        let runner = CommandCheckRunner(config: RepoConfig(test: .init(
            command: "cat check-output.log; exit \(status)")))
        return try await withHangGuard("command log fixture") {
            await runner.runChecks(in: fixture.checkout, only: nil)
        }
    }

    private static func packageFiles(testSource: String) -> [String: String] {
        [
            "Package.swift": """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(
                    name: "GH160Fixture",
                    targets: [
                        .target(name: "App"),
                        .testTarget(name: "AppTests", dependencies: ["App"])
                    ]
                )
                """,
            "Sources/App/App.swift": "public let value = 1\n",
            "Tests/AppTests/GH_53Tests/GH_53TestsSupport.swift": testSource
        ]
    }

    private struct Fixture: Sendable {
        let base: URL
        let checkout: URL

        init(files: [String: String] = [:]) throws {
            base = FileManager.default.temporaryDirectory.appending(path: "GH-160-\(UUID().uuidString)")
            checkout = base.appending(path: "checkout with spaces")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            for (path, contents) in files {
                let url = checkout.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        func removeFiles() {
            do {
                try FileManager.default.removeItem(at: base)
            } catch {
                Issue.record("Could not remove GH-160 fixture: \(error)")
            }
        }
    }
}
