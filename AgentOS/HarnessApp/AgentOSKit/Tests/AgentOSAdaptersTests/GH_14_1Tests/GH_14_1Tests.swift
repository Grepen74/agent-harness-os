// API contract: AgentQuestion carries an optional suggestion, agent JSON accepts strings or question/suggestion
// objects, and Reconciler posts ordered questions, inline suggestions, and context-specific reply instructions.

import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite
struct GH_14_1Tests {
    @Test(arguments: PostingContext.allCases)
    func questionsAreNumberedInPostingOrder(context: PostingContext) async throws {
        let fixture = try await QuestionFixture(context: context, questions: Self.mixedQuestions)
        defer { fixture.removeDirectory() }

        let comment = try await fixture.questionComment()
        let lines = Self.lines(in: comment)
        var previousIndex = -1
        for (offset, question) in Self.mixedQuestions.enumerated() {
            let index = try #require(lines.firstIndex(of: "\(offset + 1). \(question.question)"))
            #expect(index > previousIndex)
            #expect(lines.filter { $0 == "\(offset + 1). \(question.question)" }.count == 1)
            previousIndex = index
        }
    }

    @Test(arguments: PostingContext.allCases)
    func suggestionsAppearDirectlyUnderOnlyTheirOwnQuestions(context: PostingContext) async throws {
        let fixture = try await QuestionFixture(context: context, questions: Self.mixedQuestions)
        defer { fixture.removeDirectory() }

        let comment = try await fixture.questionComment()
        let lines = Self.lines(in: comment)
        for (offset, question) in Self.mixedQuestions.enumerated() {
            let index = try #require(lines.firstIndex(of: "\(offset + 1). \(question.question)"))
            let nextLine = try #require(lines.dropFirst(index + 1).first)
            if let suggestion = question.suggestion {
                #expect(nextLine == "Suggested answer: \(suggestion)")
            } else {
                #expect(!nextLine.hasPrefix("Suggested answer:"))
            }
        }
        #expect(lines.filter { $0.hasPrefix("Suggested answer:") }.count == 2)
    }

    @Test(arguments: PostingContext.allCases)
    func questionsWithoutSuggestionsHaveNoSuggestionPlaceholder(context: PostingContext) async throws {
        let questions: [AgentQuestion] = ["Which zone?", "Which audience?"]
        let fixture = try await QuestionFixture(context: context, questions: questions)
        defer { fixture.removeDirectory() }

        let comment = try await fixture.questionComment()
        #expect(Self.lines(in: comment).contains("1. Which zone?"))
        #expect(Self.lines(in: comment).contains("2. Which audience?"))
        #expect(!comment.localizedCaseInsensitiveContains("Suggested answer:"))
        #expect(!comment.contains("nil"))
        #expect(!comment.contains("Optional("))
    }

    @Test(arguments: PostingContext.allCases, [true, false])
    func everyQuestionCommentExplainsAcceptAllCorrectionsAndTheNextSignal(
        context: PostingContext, includesSuggestions: Bool
    ) async throws {
        let questions = includesSuggestions
            ? Self.mixedQuestions
            : Self.mixedQuestions.map { AgentQuestion(question: $0.question) }
        let fixture = try await QuestionFixture(context: context, questions: questions)
        defer { fixture.removeDirectory() }

        let comment = try await fixture.questionComment()
        let instructions = comment.replacingOccurrences(of: "`", with: "").lowercased()
        #expect(instructions.range(of: #"\bok\b"#, options: .regularExpression) != nil)
        #expect(instructions.contains("accept"))
        #expect(instructions.contains("all"))
        #expect(instructions.contains("suggest"))
        #expect(instructions.contains("1. answer:"))
        #expect(instructions.contains("2. answer:"))
        #expect(instructions.range(
            of: #"\b(rest|remaining|others|other|uncorrected)\b"#,
            options: .regularExpression
        ) != nil, "Numbered corrections must explain that uncorrected suggestions are accepted.")
        #expect(instructions.contains(context == .preview ? "harness:preview" : "harness:retry"))
    }

    @Test
    func decomposerOutputAcceptsSuggestionsAlongsideLegacyStringQuestions() throws {
        let breakdown = try #require(CopilotDecomposer.parse("""
        {
          "questions": [
            {"question": "Which zone?", "suggestion": "UTC"},
            "Which audience?",
            {"question": "Which format?", "suggestion": "ISO 8601"}
          ],
          "children": []
        }
        """))
        #expect(breakdown.report.questions == Self.mixedQuestions)

        let legacy = try #require(CopilotDecomposer.parse("""
        {"questions": ["Which zone?", "Which audience?"], "children": []}
        """))
        #expect(legacy.report.questions == ["Which zone?", "Which audience?"])
        #expect(legacy.report.questions.allSatisfy { $0.suggestion == nil })
    }

    @Test
    func leafAgentReportAcceptsSuggestionsWithoutChangingPlainQuestions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-14-1-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appending(path: ".agentos-report.json")
        try Data("""
        {
          "questions": [
            {"question": "Which zone?", "suggestion": "UTC"},
            "Which audience?",
            {"question": "Which format?", "suggestion": "ISO 8601"}
          ]
        }
        """.utf8).write(to: reportURL)

        let report = try AgentReportFile.take(from: directory)
        #expect(report.questions == Self.mixedQuestions)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        let questions = try #require(encoded["questions"] as? [Any])
        #expect(questions.count == 3)
        let suggested = try #require(questions.first as? [String: String])
        #expect(suggested == ["question": "Which zone?", "suggestion": "UTC"])
        #expect(questions.dropFirst().first as? String == "Which audience?")

        try Data(#"{"questions":["Which zone?","Which audience?"]}"#.utf8).write(to: reportURL)
        let legacy = try AgentReportFile.take(from: directory)
        #expect(legacy.questions == ["Which zone?", "Which audience?"])
        #expect(legacy.questions.allSatisfy { $0.suggestion == nil })
    }

    private static let mixedQuestions: [AgentQuestion] = [
        AgentQuestion(question: "Which zone?", suggestion: "UTC"),
        "Which audience?",
        AgentQuestion(question: "Which format?", suggestion: "ISO 8601"),
    ]

    private static func lines(in comment: String) -> [String] {
        comment.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    enum PostingContext: String, CaseIterable, Sendable {
        case preview, decomposer, testAuthor, implementer
    }

    private struct QuestionFixture {
        let directory: URL
        let context: PostingContext
        let tracker: QuestionTracker
        let reconciler: Reconciler

        init(context: PostingContext, questions: [AgentQuestion]) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-14-1-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            self.context = context
            let ledger = try Ledger()
            let tracker = QuestionTracker()
            self.tracker = tracker
            let stub = QuestionServices(directory: directory)
            let agents = QuestionAgents(report: AgentReport(questions: questions))
            if context == .preview {
                await tracker.requestPreview()
            } else {
                let spec = NodeSpec(
                    id: "wn-GH-14.1", parent: nil,
                    kind: context == .decomposer ? .composite : .leaf,
                    title: "Question presentation", intent: "Review suggested answers",
                    acceptanceCriteria: ["Questions explain how to reply"]
                )
                var events: [LedgerEvent] = [
                    LedgerEvent(node: spec.id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: "GH-45")),
                    LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
                ]
                if context == .implementer {
                    events += [
                        LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
                        LedgerEvent(node: spec.id, by: .reconciler, kind: .testsFixed(digest: "fixed-tests")),
                        LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
                    ]
                }
                try await ledger.append(events)
            }
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: stub, workspace: stub,
                artifacts: stub, checks: stub,
                team: AgentTeam(name: "questions", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: Policy(guesswork: .assumeAndReport)
            )
        }

        func questionComment() async throws -> String {
            let result = await reconciler.runRound()
            #expect(result.safeStop == nil)
            let marker = context == .preview
                ? "The decomposer has questions before it can propose a breakdown"
                : "Needs input"
            let comments = await tracker.comments
            return try #require(comments.first { $0.contains(marker) })
        }

        func removeDirectory() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor QuestionTracker: TrackerAdapter {
        private(set) var comments: [String] = []
        private var signals: [Signal] = []

        func requestPreview() {
            signals.append(Signal(ticket: "GH-45", command: .preview, setBy: .human("Alice")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            Ticket(key: key, title: "Question presentation", description: "Review suggested answers",
                   acceptanceCriteria: ["Questions explain how to reply"], createdBy: .human("Alice"))
        }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.command == signal.command }
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("Question-only reports must not create child tickets.")
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    private struct QuestionAgents: Decomposer, TestAuthor, Implementer {
        let report: AgentReport
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [], report: report)
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { report }
        func implement(_ task: AgentTask) async throws -> AgentReport { report }
    }

    private struct QuestionServices: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner {
        let directory: URL

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Question-only reports must stop before committing.")
        }
        func head(of directory: URL) async throws -> String { "unchanged" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_14_1Tests" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("Question-only reports must not land changes.")
        }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: false, summary: "Unexpected check while waiting for answers", log: "")
        }
    }
}
