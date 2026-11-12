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
