import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite("Acceptance test feedback")
struct AcceptanceTestFeedbackTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "agentos-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theCompileCheckFindsAPackageBelowTheRepoTop() throws {
        let root = try tempRoot()
        let package = root.appending(path: "App/Kit")
        let tests = "App/Kit/Tests/KitTests/GH_1Tests"
        try FileManager.default.createDirectory(at: package.appending(path: "Tests/KitTests/GH_1Tests"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9".write(to: package.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

        #expect(SwiftAcceptanceTestPreflight.packageRoot(for: tests, in: root)?.standardizedFileURL == package.standardizedFileURL)
        #expect(SwiftAcceptanceTestPreflight.packageRoot(for: "Other/Tests", in: root) == nil)
    }

    @Test func testsThatDependOnTimingOrComparePinnedCaseListsComeBackBeforeCompiling() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Tests/GH_1Tests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            "try await Task.sleep(for: .milliseconds(50))",                   // 1
            "DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done() }", // 2
            "@Test(.timeLimit(.minutes(1)))",                                 // 3
            "#expect(Date().timeIntervalSince(start) < 2)",                   // 4
            "#expect(EventKind.allCases == expected)",                        // 5
            "usleep(1000)",                                                   // 6
            "try await clock.sleep(until: deadline)",                         // 7
            "let log = root.appending(path: \".agentos/scratch/run-12/out.txt\")", // 8
            "// Task.sleep would make this flaky",
            "func sleep(for duration: Duration) async throws { slept.append(duration) }",
            "@Test(arguments: Guesswork.allCases)",
            "#expect(EventKind.allCases.contains(.landed))",
            "try await gate.wait(for: \"the agent\")",
            "#expect(Date(timeIntervalSince1970: 42) == decoded.createdAt)",
            "#expect(output.contains(\"try await Task.sleep(for: .seconds(1))\"))",
            "/* Task.sleep and asyncAfter",
            "   both make tests flaky: DispatchQueue.main.asyncAfter(deadline: .now()) */",
            "let prompt = \"\"\"",
            "    Never use Thread.sleep(forTimeInterval: 1) in tests.",
            "    \"\"\"",
        ]
        try lines.joined(separator: "\n").write(to: folder.appending(path: "GH_1Tests.swift"), atomically: true, encoding: .utf8)

        let findings = SwiftAcceptanceTestPreflight.testRuleFindings(in: root, testFolder: "Tests/GH_1Tests")

        #expect(findings.map(\.line) == Array(1...8))
        #expect(findings.allSatisfy { $0.file == "Tests/GH_1Tests/GH_1Tests.swift" })
        #expect(findings.allSatisfy { $0.breaksTestRules && $0.classification == .testAuthorMistake })
        guard case .diagnostics(let returned, _) = await SwiftAcceptanceTestPreflight()
            .compileTests(in: root, testFolder: "Tests/GH_1Tests", expectedAPI: []) else {
            Issue.record("Tests that break the rules must come back even without a package to compile")
            return
        }
        #expect(returned == findings)
    }

    @Test func clashingNamesAreTheTestsOwnMistake() throws {
        let root = try tempRoot()
        let file = root.appending(path: "Tests/GH_1Tests/GH_1Tests.swift").path
        let log = [
            "\(file):298:20: error: 'Comment' is ambiguous for type lookup in this context",
            "\(file):12:8: error: invalid redeclaration of 'Fixture'",
            "\(file):40:9: error: ambiguous use of 'make'",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(log: log, in: root, testFolder: "Tests/GH_1Tests", expectedAPI: [])

        #expect(result.diagnostics.count == 3)
        #expect(result.diagnostics.allSatisfy { $0.classification == .testAuthorMistake })
    }

    @Test func aMissingMemberIsExpectedEvenWhenTheTestsHaveALocalOfThatName() throws {
        let root = try tempRoot()
        let folder = root.appending(path: "Tests/GH_1Tests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "struct Fixture { let reviewer: Int }\nfunc f() { let reviews = 1 }\n"
            .write(to: folder.appending(path: "GH_1Tests.swift"), atomically: true, encoding: .utf8)
        let file = folder.appending(path: "GH_1Tests.swift").path
        let log = [
            "\(file):5:9: error: value of type 'Settings' has no member 'reviewer'",
            "\(file):6:9: error: value of type 'NodeState' has no member 'reviews'",
            "\(file):7:9: error: value of type 'Fixture' has no member 'missing'",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(log: log, in: root, testFolder: "Tests/GH_1Tests",
                                                           expectedAPI: ["Settings.reviewer: Int"])

        #expect(result.diagnostics.map(\.classification) == [.expected, .expected, .testAuthorMistake])
    }

    @Test func coloredDiagnosticsCountButFixtureTextTheCompilerQuotesDoesNot() throws {
        let root = try tempRoot()
        let folder = root.appending(path: "Tests/GH_1Tests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "struct Fixture {}\nfunc value() -> Int { 1 }\n"
            .write(to: folder.appending(path: "GH_1Tests.swift"), atomically: true, encoding: .utf8)
        let file = folder.appending(path: "GH_1Tests.swift").path
        let log = [
            "\(file):65:44: \u{1B}[1;31merror: \u{1B}[1;39mtype 'Runner' has no member 'failureLocations'\u{1B}[0;0m",
            " \u{1B}[0;36m80 |\u{1B}[0;0m             in: \"\\(path):18:2: error: cannot find 'value' in scope\")",
            "    \u{1B}[0;36m|\u{1B}[0;0m  `- \u{1B}[1;31merror: \u{1B}[1;39mtype 'Runner' has no member 'failureLocations'\u{1B}[0;0m",
            "\(file):12:8: \u{1B}[1;31merror: \u{1B}[1;39minvalid redeclaration of 'Fixture'\u{1B}[0;0m",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(
            log: log, in: root, testFolder: "Tests/GH_1Tests",
            expectedAPI: ["static func Runner.failureLocations(in log: String) -> [String]"])

        #expect(result.diagnostics.map(\.line) == [65, 12])
        #expect(result.diagnostics.map(\.message) == [
            "type 'Runner' has no member 'failureLocations'", "invalid redeclaration of 'Fixture'",
        ])
        #expect(result.diagnostics.map(\.classification) == [.expected, .testAuthorMistake])
    }

    @Test func aMemberExpectedOnAProtocolIsExpectedOnAConformingProductionType() throws {
        let root = try tempRoot()
        let sources = root.appending(path: "Kit/Sources/Adapters")
        let tests = root.appending(path: "Kit/Tests/KitTests/GH_88Tests")
        for folder in [sources, tests] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "// swift-tools-version:6.0".write(to: root.appending(path: "Kit/Package.swift"), atomically: true, encoding: .utf8)
        try "public actor RepositoryWorkspace: Workspace {}\n"
            .write(to: sources.appending(path: "RepositoryWorkspace.swift"), atomically: true, encoding: .utf8)
        let file = tests.appending(path: "GH_88Tests.swift").path
        let log = [
            "\(file):32:45: error: value of type 'RepositoryWorkspace' has no member 'prepareRequirementBranch'",
            "\(file):247:35: error: value of type 'RepositoryWorkspace' has no member 'catchUpRequirementBranch'",
            "\(file):250:35: error: value of type 'RepositoryWorkspace' has no member 'catchUp'",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(
            log: log, in: root, testFolder: "Kit/Tests/KitTests/GH_88Tests",
            expectedAPI: [
                "AgentOSCore.Workspace.prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String?",
                "AgentOSCore.Workspace.catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String",
            ])

        #expect(result.diagnostics.map(\.classification) == [.expected, .expected, .testAuthorMistake])
    }

    @Test func argumentLabelsNamedLikeATestLocalAreExpectedSignatureChanges() throws {
        let root = try tempRoot()
        let folder = root.appending(path: "Tests/GH_90Tests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "struct Fixture { let publisher = Spy(); let landingBranch = \"main\" }\n"
            .write(to: folder.appending(path: "GH_90TestsSupport.swift"), atomically: true, encoding: .utf8)
        let file = folder.appending(path: "GH_90TestsSupport.swift").path
        let log = [
            "\(file):123:44: error: extra argument 'publisher' in call",
            "\(file):19:99: error: missing argument for parameter 'landingBranch' in call",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(
            log: log, in: root, testFolder: "Tests/GH_90Tests",
            expectedAPI: ["AgentOSCore.Reconciler.init(ledger: Ledger, policy: Policy = Policy(), publisher: (any RequirementPublisher)? = nil)"])

        #expect(result.testAuthorMistakes.isEmpty)
        #expect(result.diagnostics.count == 2)
    }

    @Test func aTestNestedInAnotherTestIsTheTestsOwnMistake() throws {
        let root = try tempRoot()
        let file = root.appending(path: "Tests/GH_1Tests/GH_1Tests.swift").path
        let log = "\(file):6:5: error: Attribute 'Test' cannot be applied to a function within function 'outer()' (from macro 'Test ')"

        let result = SwiftAcceptanceTestPreflight.classify(log: log, in: root, testFolder: "Tests/GH_1Tests", expectedAPI: [])

        #expect(result.diagnostics.map(\.classification) == [.testAuthorMistake])
    }

    @Test func aFileNamedLikeAnotherInTheTargetIsTheTestsOwnMistakeOnlyWhenItIsTheirs() throws {
        let root = try tempRoot()
        let target = root.appending(path: "Kit/Tests/KitTests")
        for folder in ["GH_1Tests", "GH_2Tests", "GH_3Tests"] {
            try FileManager.default.createDirectory(at: target.appending(path: folder), withIntermediateDirectories: true)
        }
        try "// swift-tools-version:6.0".write(to: root.appending(path: "Kit/Package.swift"), atomically: true, encoding: .utf8)
        for file in ["GH_1Tests/Support.swift", "GH_2Tests/Support.swift", "GH_2Tests/Helpers.swift", "GH_3Tests/Helpers.swift"] {
            try "import Testing".write(to: target.appending(path: file), atomically: true, encoding: .utf8)
        }
        let log = ["Support", "Helpers"].map {
            "error: couldn't build \(root.path)/Kit/.build/debug/KitTests.build/\($0).swift.o because of multiple producers: "
                + "Compiling Swift Module 'KitTests' (4 sources), Compiling Swift Module 'KitTests' (4 sources)"
        }.joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(log: log, in: root, testFolder: "Kit/Tests/KitTests/GH_1Tests",
                                                           expectedAPI: [])

        let mistake = try #require(result.testAuthorMistakes.first)
        #expect(result.diagnostics.count == 1)
        #expect(mistake.file == "Kit/Tests/KitTests/GH_1Tests/Support.swift")
        #expect(mistake.message.contains("Kit/Tests/KitTests/GH_2Tests/Support.swift"))
    }

    @Test func theTestAuthorIsToldWhyItsTestsCameBack() {
        let directory = URL(filePath: "/worktrees/wn-GH-1", directoryHint: .isDirectory)
        let spec = NodeSpec(id: "wn-GH-1", parent: nil, kind: .leaf, title: "Greeting", intent: "Say hi",
                            acceptanceCriteria: ["Says hello"], touches: [])
        let first = AgentTask(spec: spec, run: "run-1", directory: directory, testFolder: "Tests/GH_1Tests",
                              scratchDirectory: directory.appending(path: ".agentos/scratch/run-1"))
        let again = AgentTask(spec: spec, run: "run-2", directory: directory, testFolder: "Tests/GH_1Tests",
                              scratchDirectory: directory.appending(path: ".agentos/scratch/run-2"),
                              previousFailure: "'Comment' is ambiguous between AgentOSCore.Comment and Testing.Comment")

        #expect(!CopilotTestAuthor.prompt(for: first).contains("Earlier work on this item"))
        let prompt = CopilotTestAuthor.prompt(for: again)
        #expect(prompt.contains("Earlier work on this item"))
        #expect(prompt.contains("'Comment' is ambiguous between AgentOSCore.Comment and Testing.Comment"))
        #expect(prompt.contains("`private`"))
        #expect(prompt.contains("smallest change"))
    }

    @Test func answersAreDatedOldestFirstAndTheLaterOneWins() throws {
        var later = Clarification(questions: ["Feedback on the acceptance tests"], answer: "Use the shared helper.")
        later.answeredAt = Date(timeIntervalSince1970: 2_000_000_000)
        var earlier = Clarification(questions: ["Which renderer?"], answer: "Use ImageRenderer.")
        earlier.answeredAt = Date(timeIntervalSince1970: 1_000_000_000)

        let block = CopilotCLI.answersBlock([later, earlier])

        let first = try #require(block.range(of: "1. (answered 2001-09-09T01:46:40Z)\nQ: Which renderer?\nA: Use ImageRenderer."))
        let second = try #require(block.range(of: "2. (answered 2033-05-18T03:33:20Z)\nQ: Feedback on the acceptance tests"))
        #expect(first.upperBound < second.lowerBound)
        #expect(block.contains("the later one wins"))
    }

    @Test(arguments: Guesswork.allCases)
    func questionsAreAskedWithSuggestedAnswersAtEveryLevel(guesswork: Guesswork) {
        #expect(CopilotCLI.guessingRules(guesswork, repositoryConventions: true).contains("\"suggestion\""))
    }

    @Test(arguments: Guesswork.allCases)
    func onlyAutonomousAgentsCarryOnWhenEveryQuestionHasASuggestion(guesswork: Guesswork) {
        let spec = NodeSpec(id: "wn-GH-1", parent: nil, kind: .leaf, title: "Greeting", intent: "Say hi",
                            acceptanceCriteria: ["Says hello"], touches: [])
        let directory = URL(filePath: "/worktrees/wn-GH-1", directoryHint: .isDirectory)
        let task = AgentTask(spec: spec, run: "run-1", directory: directory, testFolder: "Tests/GH_1Tests",
                             scratchDirectory: directory.appending(path: ".agentos/scratch/run-1"), guesswork: guesswork)

        let prompt = CopilotTestAuthor.prompt(for: task)

        #expect(prompt.contains("write only that report and no tests"))
        #expect(prompt.contains("don't stop: write the tests") == (guesswork == .autonomous))
    }
}
