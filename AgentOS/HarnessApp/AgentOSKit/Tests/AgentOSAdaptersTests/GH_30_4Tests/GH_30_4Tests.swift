// API contract: AgentQuestion preserves an optional suggested answer in AgentReport, ledger events, and
// reconstructed NodeState; autonomous reconciliation turns suggestions into assumptions unless any question
// has no suggestion.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_30_4Tests {
    @Test
    func reportsDecodePlainAndSuggestedQuestionsWhileOldReportsRemainValid() throws {
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(#"""
        {
          "questions": [
            "Which screen shows the result?",
            {
              "question": "How many results appear?",
              "suggestion": "Show the first ten"
            }
          ],
          "assumptions": ["The existing result row is reused"],
          "expectedAPI": []
        }
        """#.utf8))

        #expect(report.questions == [
            AgentQuestion(question: "Which screen shows the result?"),
            AgentQuestion(question: "How many results appear?", suggestion: "Show the first ten"),
        ])

        let oldReport = try JSONDecoder().decode(AgentReport.self, from: Data(#"""
        {"questions":["Which screen shows the result?"],"assumptions":[],"expectedAPI":[]}
        """#.utf8))
        #expect(oldReport.questions == [AgentQuestion(question: "Which screen shows the result?")])
    }

    @Test
    func autonomousSuggestedQuestionsBecomeAssumptionsAndDoNotStopTheNode() async throws {
        let testAuthor = try await Fixture(
            flow: .testAuthor,
            report: AgentReport(questions: [
                AgentQuestion(question: "Which layout should tests use?", suggestion: "Use the compact layout"),
                AgentQuestion(question: "What is the empty label?", suggestion: "No results"),
            ])
        )

        _ = await testAuthor.reconciler.runRound(waitForAgents: true)

        let node = try #require(await testAuthor.node())
        #expect(node.phase == .ready)
        #expect(node.flags[.needsInput] == nil)
        #expect(node.openQuestions.isEmpty)
        #expect(node.assumptions[.testAuthor] == [
            "Use the compact layout (suggested answer to: Which layout should tests use?)",
            "No results (suggested answer to: What is the empty label?)",
        ])

        let breakdown = try await Fixture(
            flow: .breakdown,
            report: AgentReport(questions: [
                AgentQuestion(question: "How should this be split?", suggestion: "Keep it as one leaf"),
            ])
        )
        _ = await breakdown.reconciler.runRound(waitForAgents: true)
        let breakdownNode = try #require(await breakdown.node())
        #expect(breakdownNode.flags[.needsInput] == nil)
        #expect(breakdownNode.assumptions[.decomposer] == [
            "Keep it as one leaf (suggested answer to: How should this be split?)",
        ])

        let preview = try await Fixture(
            flow: .preview,
            report: AgentReport(questions: [
                AgentQuestion(question: "How should this be split?", suggestion: "Keep it as one leaf"),
            ])
        )
        _ = await preview.reconciler.runRound(waitForAgents: true)
        #expect(await preview.ledger.workingState().previews["GH-30.4"] != nil)
    }

    @Test
    func proceedingOnSuggestionsPostsNumberedAnswersAndCorrectionInstructions() async throws {
        for flow in [Fixture.Flow.preview, .breakdown, .testAuthor] {
            let fixture = try await Fixture(
                flow: flow,
                report: AgentReport(questions: [
                    AgentQuestion(question: "Which layout should tests use?", suggestion: "Use the compact layout"),
                    AgentQuestion(question: "What is the empty label?", suggestion: "No results"),
                ])
            )

            _ = await fixture.reconciler.runRound(waitForAgents: true)

            let comment = try #require(await fixture.tracker.postedComments().first {
                $0.contains("Proceeding on suggested answers")
            })
            #expect(comment.contains("1."))
            #expect(comment.contains("Which layout should tests use?"))
            #expect(comment.contains("Use the compact layout"))
            #expect(comment.contains("2."))
            #expect(comment.contains("What is the empty label?"))
            #expect(comment.contains("No results"))
            #expect(comment.localizedCaseInsensitiveContains("comment"))
            #expect(comment.localizedCaseInsensitiveContains("number"))
            #expect(comment.contains("harness:retry"))
        }
    }

    @Test
    func plainQuestionsStopPreviewBreakdownAndTestAuthorHandling() async throws {
        let question = AgentQuestion(question: "Which screen should show the result?")

        let preview = try await Fixture(flow: .preview, report: AgentReport(questions: [question]))
        _ = await preview.reconciler.runRound(waitForAgents: true)
        #expect(await preview.ledger.workingState().previews["GH-30.4"] == nil)
        #expect(await preview.tracker.postedComments().contains {
            $0.contains(question.question) && $0.localizedCaseInsensitiveContains("answer")
        })

        let breakdown = try await Fixture(flow: .breakdown, report: AgentReport(questions: [question]))
        _ = await breakdown.reconciler.runRound(waitForAgents: true)
        let breakdownNode = try #require(await breakdown.node())
        #expect(breakdownNode.flags[.needsInput] != nil)
        #expect(breakdownNode.openQuestions == [question])

        let testAuthor = try await Fixture(flow: .testAuthor, report: AgentReport(questions: [question]))
        _ = await testAuthor.reconciler.runRound(waitForAgents: true)
        let testAuthorNode = try #require(await testAuthor.node())
        #expect(testAuthorNode.flags[.needsInput] != nil)
        #expect(testAuthorNode.openQuestions == [question])
        #expect(testAuthorNode.phase == .specified)
    }

    @Test
    func mixedQuestionsStopAndShowSuggestedAnswersForHumanDecision() async throws {
        let suggested = AgentQuestion(
            question: "Which layout should tests use?",
            suggestion: "Use the compact layout"
        )
        let plain = AgentQuestion(question: "Which screen should show the result?")
        let fixture = try await Fixture(
            flow: .testAuthor,
            report: AgentReport(questions: [suggested, plain])
        )

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.flags[.needsInput] != nil)
        #expect(node.openQuestions == [suggested, plain])
        #expect(node.assumptions[.testAuthor] == nil)
        let comment = try #require(await fixture.tracker.postedComments().last)
        #expect(comment.contains(suggested.question))
        #expect(comment.contains("Use the compact layout"))
        #expect(comment.contains(plain.question))
        #expect(comment.localizedCaseInsensitiveContains("accept"))
        #expect(comment.localizedCaseInsensitiveContains("correct"))
    }

    @Test
    func suggestedAssumptionsAndStoppingQuestionsSurviveLedgerReconstruction() async throws {
        let suggestedFixture = try await Fixture(
            flow: .testAuthor,
            report: AgentReport(questions: [
                AgentQuestion(question: "Which layout?", suggestion: "Use compact"),
            ]),
            persistentLedger: true
        )
        _ = await suggestedFixture.reconciler.runRound(waitForAgents: true)

        let expectedAssumption = "Use compact (suggested answer to: Which layout?)"
        #expect(await suggestedFixture.eventKinds().contains {
            if case .assumptionsReported(.testAuthor, let assumptions) = $0 {
                assumptions == [expectedAssumption]
            } else {
                false
            }
        })
        let rebuiltSuggested = try suggestedFixture.reconstructedLedger()
        #expect(await rebuiltSuggested.workingState().nodes[Fixture.specID]?
            .assumptions[.testAuthor] == [expectedAssumption])

        let questions = [
            AgentQuestion(question: "Which layout?", suggestion: "Use compact"),
            AgentQuestion(question: "Which screen?"),
        ]
        let stoppingFixture = try await Fixture(
            flow: .breakdown,
            report: AgentReport(questions: questions),
            persistentLedger: true
        )
        _ = await stoppingFixture.reconciler.runRound(waitForAgents: true)

        #expect(await stoppingFixture.eventKinds().contains {
            if case .questionsRaised(.decomposer, let recorded) = $0 {
                recorded == questions
            } else {
                false
            }
        })
        let rebuiltStopping = try stoppingFixture.reconstructedLedger()
        #expect(await rebuiltStopping.workingState().nodes[Fixture.specID]?.openQuestions == questions)
    }
}

private final class Fixture: @unchecked Sendable {
    enum Flow: Equatable {
        case preview
        case breakdown
        case testAuthor
    }

    static let specID = "wn-GH-30.4"

    let directory: URL
    let ledgerURL: URL?
    let ledger: Ledger
    let tracker: RecordingTracker
    let reconciler: Reconciler

    init(flow: Flow, report: AgentReport, persistentLedger: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-30-4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if persistentLedger {
            let url = directory.appending(path: "ledger.jsonl")
            ledgerURL = url
            ledger = try Ledger(store: FileLedgerStore(fileURL: url))
        } else {
            ledgerURL = nil
            ledger = try Ledger()
        }

        let ticket = Ticket(
            key: "GH-30.4",
            title: "Proceed on suggested answers",
            description: "Let autonomous agents follow a suggested answer",
            acceptanceCriteria: ["Suggested answers do not stop autonomous work"],
            createdBy: .human("Alice")
        )
        tracker = RecordingTracker(
            ticket: ticket,
            signal: flow == .preview
                ? Signal(ticket: ticket.key, command: .preview, setBy: .human("Alice"))
                : nil
        )

        if flow != .preview {
            let spec = NodeSpec(
                id: Self.specID,
                parent: nil,
                kind: flow == .breakdown ? .composite : .leaf,
                title: ticket.title,
                intent: ticket.description,
                acceptanceCriteria: ticket.acceptanceCriteria,
                touches: ["AgentOSCore"]
            )
            try await ledger.append([
                LedgerEvent(
                    node: spec.id,
                    by: .human("Alice"),
                    kind: .nodeCreated(spec: spec, ticket: ticket.key)
                ),
                LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
            ])
        }

        let workspace = StubWorkspace(directory: directory)
        reconciler = Reconciler(
            ledger: ledger,
            tracker: tracker,
            external: NoExternalDependencies(),
            workspace: workspace,
            artifacts: MemoryArtifacts(),
            checks: PassingChecks(),
            team: AgentTeam(
                name: "GH-30.4",
                decomposer: ReportingDecomposer(report: report),
                testAuthor: ReportingTestAuthor(report: report),
                implementer: NoopImplementer()
            ),
            policy: Policy(guesswork: .autonomous)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func node() async -> NodeState? {
        await ledger.workingState().nodes[Self.specID]
    }

    func eventKinds() async -> [EventKind] {
        await ledger.allRecords().map(\.event.kind)
    }

    func reconstructedLedger() throws -> Ledger {
        try Ledger(store: FileLedgerStore(fileURL: ledgerURL!))
    }
}

private actor RecordingTracker: TrackerAdapter {
    private var storedTicket: Ticket
    private var pendingSignal: Signal?
    private var comments: [String] = []

    init(ticket: Ticket, signal: Signal?) {
        storedTicket = ticket
        pendingSignal = signal
    }

    func pendingSignals() -> [Signal] {
        pendingSignal.map { [$0] } ?? []
    }

    func ticket(_ key: String) -> Ticket? {
        key == storedTicket.key ? storedTicket : nil
    }

    func consume(_ signal: Signal, reply: String) {
        pendingSignal = nil
        comments.append(reply)
    }

    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
        "\(parent)-1"
    }

    func comment(on key: String, _ text: String) {
        comments.append(text)
        storedTicket.comments.append(Comment(author: .reconciler, text: text))
    }

    func setStatus(of key: String, to status: String) {
        storedTicket.status = status
    }

    func postedComments() -> [String] {
        comments
    }
}

private struct ReportingDecomposer: Decomposer {
    let report: AgentReport

    func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
        Breakdown(
            children: [
                ChildProposal(
                    title: request.spec.title,
                    acceptanceCriteria: request.spec.acceptanceCriteria,
                    touches: ["AgentOSCore"]
                ),
            ],
            report: report
        )
    }
}

private struct ReportingTestAuthor: TestAuthor {
    let report: AgentReport

    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
        let folder = task.directory.appending(path: task.testFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        import Testing
        @Test func suggestedAnswerContract() {}
        """.write(
            to: folder.appending(path: "SuggestedAnswerTests.swift"),
            atomically: true,
            encoding: .utf8
        )
        return report
    }
}

private struct StubWorkspace: Workspace {
    let directory: URL

    func prepare() async throws {}
    func branch(for id: NodeID) -> String { "agentos/\(id)" }
    func worktree(for id: NodeID) -> URL { directory }
    func createWorktree(for id: NodeID) async throws -> URL { directory }
    func removeWorktree(for id: NodeID) async throws {}
    func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
        "acceptance-tests"
    }
    func head(of directory: URL) async throws -> String { "acceptance-tests" }
    func changedFiles(in directory: URL) async throws -> [String] {
        ["Tests/AgentOSAdaptersTests/GH_30_4Tests/SuggestedAnswerTests.swift"]
    }
    var testArea: String { "Tests/AgentOSAdaptersTests/" }
    func testFolder(for spec: NodeSpec) -> String {
        "Tests/AgentOSAdaptersTests/GH_30_4Tests"
    }
    var agentContext: String { "" }
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
    func abortRebase(_ directory: URL) async throws {}
    func resetForRework(_ directory: URL) async throws {}
    func landOnMain(_ id: NodeID) async throws -> String { "landed" }
    func existingComponents() -> [String] { [] }
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

private struct PassingChecks: CheckRunner {
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        CheckOutput(passed: true, summary: "Passed", log: "Passed")
    }
}

private struct NoopImplementer: Implementer {
    func implement(_ task: AgentTask) async throws {}
}
