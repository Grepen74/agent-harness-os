// API contract: Reconciler.runRound(waitForAgents: true) resolves "N. Answer: text" ticket replies on preview/retry,
// preserves unresolved original question numbers across replies, and records Clarification values
// through EventKind.questionsAnswered for subsequent BreakdownRequest and AgentTask runs.

import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_14_3Tests {
    @Test(arguments: Entry.allCases)
    func numberedCorrectionsUseDeveloperTextAndAcceptEveryUnlistedSuggestion(entry: Entry) async throws {
        let fixture = try await Fixture(entry: entry, questions: Self.suggestedQuestions)
        try await fixture.ask()
        await fixture.tracker.reply(
            "1. Answer: Use wide rows, with room for descriptions, 3. Answer: Nothing matched"
        )

        try await fixture.resume()

        let expected = [
            Clarification(questions: [Self.suggestedQuestions[0].question],
                          answer: "Use wide rows, with room for descriptions"),
            Clarification(questions: [Self.suggestedQuestions[1].question], answer: "Show ten results"),
            Clarification(questions: [Self.suggestedQuestions[2].question], answer: "Nothing matched"),
            Clarification(questions: [Self.suggestedQuestions[3].question], answer: "Sort by name"),
        ]
        try await fixture.expectResolved(expected)
    }

    @Test(arguments: Entry.allCases)
    func anUnlistedQuestionWithoutASuggestionKeepsWorkStoppedAndNamesItsNumber(entry: Entry) async throws {
        let fixture = try await Fixture(entry: entry, questions: Self.mixedQuestions)
        try await fixture.ask()
        await fixture.tracker.reply("2. Answer: Show all matching results")
        await fixture.tracker.signal(entry.answerSignal)

        try await fixture.advance(rounds: 3)

        try await fixture.expectStopped()
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.range(of: #"\b3\b"#, options: .regularExpression) != nil)
        #expect(response.range(of: #"\b4\b"#, options: .regularExpression) != nil)
        #expect(response.localizedCaseInsensitiveContains("open")
                || response.localizedCaseInsensitiveContains("unanswered")
                || response.localizedCaseInsensitiveContains("answer"))
        #expect(response.contains(entry.answerSignal.label))
    }

    @Test(arguments: Entry.allCases)
    func remainingAnswersKeepOriginalNumbersAndReachTheLedgerAndLaterAgentsOnlyAfterTheSignal(
        entry: Entry
    ) async throws {
        let fixture = try await Fixture(entry: entry, questions: Self.mixedQuestions)
        try await fixture.ask()
        await fixture.tracker.reply("2. Answer: Show all matching results")
        await fixture.tracker.signal(entry.answerSignal)
        try await fixture.advance()
        try await fixture.expectStopped()

        await fixture.tracker.reply("3. Answer: Nothing matched")
        await fixture.tracker.signal(entry.answerSignal)
        try await fixture.advance()
        try await fixture.expectStopped()
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.range(of: #"\b4\b"#, options: .regularExpression) != nil)
        #expect(response.contains(entry.answerSignal.label))

        await fixture.tracker.reply("4. Answer: Sort by newest first")
        try await fixture.advance(rounds: 2)
        try await fixture.expectStopped()

        try await fixture.resume()

        let expected = [
            Clarification(questions: [Self.mixedQuestions[0].question], answer: "Use compact rows"),
            Clarification(questions: [Self.mixedQuestions[1].question], answer: "Show all matching results"),
            Clarification(questions: [Self.mixedQuestions[2].question], answer: "Nothing matched"),
            Clarification(questions: [Self.mixedQuestions[3].question], answer: "Sort by newest first"),
        ]
        try await fixture.expectResolved(expected)
        let records = await fixture.ledger.allRecords()
        for answer in expected {
            #expect(records.contains {
                guard $0.event.node == Fixture.id, $0.event.by.isHuman,
                      case .questionsAnswered(let recorded) = $0.event.kind else { return false }
                return recorded.questions.contains(answer.questions[0]) && recorded.answer == answer.answer
            })
        }
    }

    @Test(arguments: Entry.allCases)
    func freeTextWithoutNumberedCorrectionsRemainsTheAnswerToTheCompleteBatch(entry: Entry) async throws {
        let fixture = try await Fixture(entry: entry, questions: Self.mixedQuestions)
        try await fixture.ask()
        let text = "Use wide rows and show 20 results. Say Nothing matched when empty.\nSort newest first."
        await fixture.tracker.reply(text)

        try await fixture.resume()

        let expected = Clarification(questions: Self.mixedQuestions.map(\.question), answer: text)
        let node = try #require(await fixture.node())
        #expect(node.clarifications == [expected])
        let records = await fixture.ledger.allRecords()
        #expect(records.contains {
            guard $0.event.node == Fixture.id, $0.event.by.isHuman,
                  case .questionsAnswered(let recorded) = $0.event.kind else { return false }
            return recorded == expected
        })
        #expect(await fixture.testAuthor.tasks().last?.clarifications == [expected])
        #expect(node.flags[.needsInput] == nil)
        #expect(node.phase == .ready)
    }

    private static let suggestedQuestions = [
        AgentQuestion(question: "Which layout should results use?", suggestion: "Use compact rows"),
        AgentQuestion(question: "How many results should appear?", suggestion: "Show ten results"),
        AgentQuestion(question: "What is the empty message?", suggestion: "No results"),
        AgentQuestion(question: "How should results be ordered?", suggestion: "Sort by name"),
    ]

    private static let mixedQuestions = [
        suggestedQuestions[0],
        suggestedQuestions[1],
        AgentQuestion(question: "What is the empty message?"),
        AgentQuestion(question: "How should results be ordered?"),
    ]

    enum Entry: CaseIterable, Sendable {
        case preview, decomposer, testAuthor

        var answerSignal: HarnessCommand { self == .preview ? .preview : .retry }
    }

    private final class Fixture: Sendable {
        static let id = "wn-GH-47"
        static let ticket = "GH-47"
        let entry: Entry
        let questions: [AgentQuestion]
        let directory: URL
        let ledger: Ledger
        let tracker: MemoryTracker
        let decomposer: QuestioningDecomposer
        let testAuthor: QuestioningTestAuthor
        let reconciler: Reconciler

        init(entry: Entry, questions: [AgentQuestion]) async throws {
            self.entry = entry
            self.questions = questions
            directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-14-3-\(UUID().uuidString)")
            ledger = try Ledger()
            tracker = MemoryTracker()
            decomposer = QuestioningDecomposer(questions: entry == .testAuthor ? [] : questions)
            testAuthor = QuestioningTestAuthor(questions: entry == .testAuthor ? questions : [])
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: StubWorkspace(root: directory), artifacts: MemoryArtifacts(),
                checks: UnexpectedChecks(),
                team: AgentTeam(name: "Numbered answers", decomposer: decomposer,
                                testAuthor: testAuthor, implementer: UnexpectedImplementer()),
                policy: Policy(guesswork: .ask)
            )
            if entry == .testAuthor {
                let spec = NodeSpec(
                    id: Self.id, parent: nil, kind: .leaf, title: "Configure results",
                    intent: "Resolve questions before writing tests",
                    acceptanceCriteria: ["Results follow the developer's answers"], touches: ["Results"]
                )
                try await ledger.append([
                    LedgerEvent(node: Self.id, by: .human("Developer"),
                                kind: .nodeCreated(spec: spec, ticket: Self.ticket)),
                    LedgerEvent(node: Self.id, by: .human("Developer"), kind: .gateOpened(.breakdown)),
                ])
            }
        }

        deinit {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        func ask() async throws {
            if entry != .testAuthor {
                await tracker.signal(entry == .preview ? .preview : .breakdown)
            }
            try await advance()
            let comments = await tracker.comments()
            #expect(comments.contains { text in questions.allSatisfy { text.contains($0.question) } })
            try await expectStopped()
        }

        func advance(rounds: Int = 1) async throws {
            for _ in 0..<rounds {
                let report = await reconciler.runRound(waitForAgents: true)
                #expect(report.safeStop == nil)
            }
        }

        func resume() async throws {
            await tracker.signal(entry.answerSignal)
            try await advance()
            if entry == .preview {
                #expect(await ledger.workingState().previews[Self.ticket] != nil)
                await tracker.signal(.breakdown)
            }
            try await advance(rounds: 3)
        }

        func node() async -> NodeState? {
            await ledger.workingState().nodes[Self.id]
        }

        func expectStopped() async throws {
            if entry == .preview {
                #expect(await ledger.workingState().previews[Self.ticket] == nil)
                #expect(await node() == nil)
            } else {
                let node = try #require(await node())
                #expect(node.flags[.needsInput] != nil)
                #expect(node.phase == .specified)
                #expect(node.testsDigest == nil)
            }
            #expect(await testAuthor.tasks().count == (entry == .testAuthor ? 1 : 0))
        }

        func expectResolved(_ expected: [Clarification]) async throws {
            let node = try #require(await node())
            #expect(node.flags[.needsInput] == nil)
            #expect(node.openQuestions.isEmpty)
            #expect(node.phase == .ready)
            #expect(!node.gates.contains(.build))
            let received = try #require(await testAuthor.tasks().last)
            for answer in expected {
                let question = try #require(answer.questions.first)
                let recorded = node.clarifications.filter { $0.questions.contains(question) }
                #expect(recorded.count == 1)
                #expect(recorded.first?.answer == answer.answer)
                #expect(received.clarifications.contains {
                    $0.questions.contains(question) && $0.answer == answer.answer
                })
                if entry != .testAuthor {
                    let request = try #require(await decomposer.requests().last)
                    #expect(request.clarifications.contains {
                        $0.questions.contains(question) && $0.answer == answer.answer
                    })
                }
            }
        }
    }

    private actor MemoryTracker: TrackerAdapter {
        private var value = Ticket(
            key: Fixture.ticket, title: "Configure results",
            description: "Resolve questions before writing tests",
            acceptanceCriteria: ["Results follow the developer's answers"], createdBy: .human("Developer")
        )
        private var pending: [Signal] = []
        private var consumed: [String] = []

        func reply(_ text: String) {
            value.comments.append(AgentOSCore.Comment(author: .human("Developer"), text: text))
        }
        func signal(_ command: HarnessCommand) {
            pending.append(Signal(ticket: Fixture.ticket, command: command, setBy: .human("Developer")))
        }
        func pendingSignals() -> [Signal] { pending }
        func ticket(_ key: String) -> Ticket? { key == value.key ? value : nil }
        func contextTickets() -> [Ticket] { [value] }
        func comments() -> [String] { value.comments.map(\.text) }
        func replies() -> [String] { consumed }
        func consume(_ signal: Signal, reply: String) {
            pending.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            consumed.append(reply)
            value.comments.append(AgentOSCore.Comment(author: .reconciler, text: reply))
        }
        func comment(on key: String, _ text: String) {
            value.comments.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { value.status = status }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("This fixture must remain one leaf")
        }
    }

    private actor QuestioningDecomposer: Decomposer {
        let questions: [AgentQuestion]
        private var received: [BreakdownRequest] = []

        init(questions: [AgentQuestion]) { self.questions = questions }
        func requests() -> [BreakdownRequest] { received }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            received.append(request)
            return Breakdown(children: [], report: AgentReport(
                questions: request.clarifications.isEmpty ? questions : []
            ))
        }
    }

    private actor QuestioningTestAuthor: TestAuthor {
        let questions: [AgentQuestion]
        private var received: [AgentTask] = []

        init(questions: [AgentQuestion]) { self.questions = questions }
        func tasks() -> [AgentTask] { received }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            received.append(task)
            if task.clarifications.isEmpty && !questions.isEmpty {
                return AgentReport(questions: questions)
            }
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                import Testing
                @Test func resultsFollowResolvedAnswers() { #expect(true) }
                """.write(to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    private struct StubWorkspace: Workspace {
        let root: URL
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.id)" }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {
            let directory = worktree(for: id)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "acceptance-tests"
        }
        func head(of directory: URL) async throws -> String { "fixture-main" }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/\(directory.lastPathComponent)/Acceptance.swift"]
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("Answering questions must not trigger implementation rework")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("These tests do not approve building or landing")
        }
        func existingComponents() -> [String] { ["Results"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    private struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct UnexpectedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Testing.Issue.record("These tests do not approve implementation checks")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
    }

    private struct UnexpectedImplementer: Implementer {
        func implement(_ task: AgentTask) async throws {
            throw AgentFailure("These tests do not approve starting an implementation")
        }
    }
}
