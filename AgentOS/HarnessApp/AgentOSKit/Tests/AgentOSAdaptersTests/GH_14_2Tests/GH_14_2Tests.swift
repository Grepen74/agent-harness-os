// API contract: Reconciler resolves a human's "ok" plus preview/retry into suggested Clarification
// answers, records questionsAnswered on adoption/resumption, and passes them to later agents and
// descendants. Autonomous suggestion-only reports retain GH_30_4's proceed-as-assumptions behavior.

import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_14_2Tests {
    @Test(arguments: Entry.allCases, [Guesswork.ask, .assumeAndReport])
    func suggestionsWaitForBothAHumanReplyAndTheIndicatedSignal(
        entry: Entry, guesswork: Guesswork
    ) async throws {
        let fixture = try await Fixture(entry: entry, guesswork: guesswork)
        defer { fixture.removeDirectory() }
        try await fixture.ask()

        let initialCalls = await fixture.agents.callCount()
        try await fixture.advance(rounds: 3)
        try await fixture.expectStopped()
        #expect(await fixture.agents.callCount() == initialCalls)
        #expect(await fixture.recordedAnswers().isEmpty)

        await fixture.tracker.comment(on: Fixture.ticket, "ok")
        await fixture.tracker.signal(entry.answerSignal)
        try await fixture.advance(rounds: 2)
        try await fixture.expectStopped()
        #expect(await fixture.recordedAnswers().isEmpty)

        let callsBeforeReply = await fixture.agents.callCount()
        await fixture.tracker.reply("ok")
        try await fixture.advance(rounds: 3)
        try await fixture.expectStopped()
        #expect(await fixture.agents.callCount() == callsBeforeReply)
        #expect(await fixture.recordedAnswers().isEmpty)

        try await fixture.resume()
        try await fixture.expectAccepted(Self.suggestedAnswers)
    }

    @Test(arguments: Entry.allCases, [Guesswork.ask, .assumeAndReport])
    func okRecordsEverySuggestionAsAHumanAnswerAndSuppliesTheNextAgents(
        entry: Entry, guesswork: Guesswork
    ) async throws {
        let fixture = try await Fixture(entry: entry, guesswork: guesswork)
        defer { fixture.removeDirectory() }
        try await fixture.ask()
        await fixture.tracker.reply("ok")

        try await fixture.resume()

        try await fixture.expectAccepted(Self.suggestedAnswers)
        let task = try #require(await fixture.agents.testTasks().last)
        Self.expectAnswers(Self.suggestedAnswers, in: task.clarifications)
        #expect(task.spec.id == Fixture.id)
        if entry != .testAuthor {
            let request = try #require(await fixture.agents.breakdownRequests().last)
            Self.expectAnswers(Self.suggestedAnswers, in: request.clarifications)
        }

        await fixture.tracker.signal(.build)
        try await fixture.advance()
        let implementation = try #require(await fixture.agents.implementationTasks().last)
        #expect(implementation.spec.id == Fixture.id)
        Self.expectAnswers(Self.suggestedAnswers, in: implementation.clarifications)
    }

    @Test(arguments: Entry.allCases)
    func autonomousMixedQuestionsRequireAReplyAndSignalToAcceptSuggestions(entry: Entry) async throws {
        let plain = AgentQuestion(question: "Which audience is allowed to see the results?")
        let fixture = try await Fixture(
            entry: entry, guesswork: .autonomous,
            questions: Self.suggestedQuestions + [plain]
        )
        defer { fixture.removeDirectory() }
        try await fixture.ask()
        try await fixture.advance(rounds: 2)
        try await fixture.expectStopped()
        #expect(await fixture.recordedAnswers().isEmpty)

        await fixture.tracker.signal(entry.answerSignal)
        try await fixture.advance()
        try await fixture.expectStopped()
        #expect(await fixture.recordedAnswers().isEmpty)

        // The plain question still needs a written answer; "ok" accepts only the suggestions.
        await fixture.tracker.reply("ok")
        await fixture.tracker.reply("3. Answer: Only the signed-in user")
        let callsBeforeSignal = await fixture.agents.callCount()
        try await fixture.advance(rounds: 2)
        try await fixture.expectStopped()
        #expect(await fixture.agents.callCount() == callsBeforeSignal)
        #expect(await fixture.recordedAnswers().isEmpty)

        try await fixture.resume()

        let expected = Self.suggestedAnswers + [
            Clarification(questions: [plain.question], answer: "Only the signed-in user"),
        ]
        try await fixture.expectAccepted(expected)
        let task = try #require(await fixture.agents.testTasks().last)
        Self.expectAnswers(expected, in: task.clarifications)
    }

    @Test(arguments: [Entry.preview, .decomposer], [Guesswork.ask, .assumeAndReport])
    func acceptedSuggestionsSurviveReconstructionAndReachDescendantAgents(
        entry: Entry, guesswork: Guesswork
    ) async throws {
        let fixture = try await Fixture(entry: entry, guesswork: guesswork, split: true)
        defer { fixture.removeDirectory() }
        try await fixture.ask()
        await fixture.tracker.reply("ok")

        try await fixture.resume()
        try await fixture.expectAccepted(Self.suggestedAnswers)

        let rebuilt = try Ledger(store: fixture.store)
        let state = await rebuilt.workingState()
        let root = try #require(state.nodes[Fixture.id])
        #expect(root.children.count == 2)
        Self.expectAnswers(Self.suggestedAnswers, in: root.clarifications)
        let tasks = await fixture.agents.testTasks()
        for id in root.children {
            let child = try #require(state.nodes[id])
            #expect(child.phase == .ready)
            #expect(child.flags[.needsInput] == nil)
            Self.expectAnswers(Self.suggestedAnswers, in: state.clarifications(for: id))
            let task = try #require(tasks.first { $0.spec.id == id })
            Self.expectAnswers(Self.suggestedAnswers, in: task.clarifications)
        }

        await fixture.tracker.signal(.build)
        try await fixture.advance(rounds: 3)
        let implementations = await fixture.agents.implementationTasks()
        for id in root.children {
            let task = try #require(implementations.first { $0.spec.id == id })
            Self.expectAnswers(Self.suggestedAnswers, in: task.clarifications)
        }
    }

    private static let suggestedQuestions = [
        AgentQuestion(question: "Which time zone should results use?", suggestion: "UTC"),
        AgentQuestion(question: "Which date format should results use?", suggestion: "ISO 8601"),
    ]

    private static let suggestedAnswers = suggestedQuestions.map {
        Clarification(questions: [$0.question], answer: $0.suggestion!)
    }

    private static func expectAnswers(_ expected: [Clarification], in actual: [Clarification]) {
        for answer in expected {
            for question in answer.questions {
                let matches = actual.filter { $0.questions.contains(question) }
                #expect(matches.count == 1)
                #expect(matches.first?.answer == answer.answer)
            }
        }
        #expect(!actual.contains { $0.answer == "ok" })
    }

    enum Entry: CaseIterable, Sendable {
        case preview, decomposer, testAuthor

        var answerSignal: HarnessCommand { self == .preview ? .preview : .retry }
    }

    private final class Fixture: Sendable {
        static let id = "wn-GH-46"
        static let ticket = "GH-46"
        let entry: Entry
        let split: Bool
        let directory: URL
        let store: InMemoryLedgerStore
        let ledger: Ledger
        let tracker: MemoryTracker
        let agents: RecordingAgents
        let reconciler: Reconciler

        init(
            entry: Entry, guesswork: Guesswork,
            questions: [AgentQuestion] = GH_14_2Tests.suggestedQuestions, split: Bool = false
        ) async throws {
            self.entry = entry
            self.split = split
            directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-14-2-\(UUID().uuidString)")
            store = InMemoryLedgerStore()
            ledger = try Ledger(store: store)
            tracker = MemoryTracker()
            agents = RecordingAgents(entry: entry, questions: questions, split: split)
            let services = StubServices(root: directory)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "Suggestion acceptance", decomposer: agents,
                                testAuthor: agents, implementer: agents),
                policy: Policy(guesswork: guesswork)
            )
            if entry != .preview {
                let spec = NodeSpec(
                    id: Self.id, parent: nil, kind: entry == .decomposer ? .composite : .leaf,
                    title: "Configure result dates", intent: "Use the human's accepted answers",
                    acceptanceCriteria: ["Display dates as agreed"], touches: ["Results"]
                )
                try await ledger.append([
                    LedgerEvent(node: spec.id, by: .human("Developer"),
                                kind: .nodeCreated(spec: spec, ticket: Self.ticket)),
                    LedgerEvent(node: spec.id, by: .human("Developer"), kind: .gateOpened(.breakdown)),
                ])
            }
        }

        func ask() async throws {
            if entry == .preview { await tracker.signal(.preview) }
            try await advance()
            let comments = await tracker.comments()
            #expect(comments.contains {
                $0.contains(GH_14_2Tests.suggestedQuestions[0].question)
                    && $0.contains(GH_14_2Tests.suggestedQuestions[1].question)
                    && $0.contains(entry.answerSignal.label)
            })
            try await expectStopped()
        }

        func advance(rounds: Int = 1) async throws {
            for _ in 0..<rounds {
                let report = await reconciler.runRound()
                #expect(report.safeStop == nil)
                let state = await ledger.workingState()
                #expect(!state.nodes.values.contains { $0.flags[.escalated] != nil })
            }
        }

        func resume() async throws {
            await tracker.signal(entry.answerSignal)
            try await advance()
            if entry == .preview {
                #expect(await ledger.workingState().previews[Self.ticket] != nil)
                #expect(await ledger.workingState().nodes.isEmpty)
                await tracker.signal(.breakdown)
            }
            try await advance(rounds: 5)
        }

        func recordedAnswers() async -> [Clarification] {
            await ledger.allRecords().compactMap {
                guard case .questionsAnswered(let answer) = $0.event.kind else { return nil }
                return answer
            }
        }

        func expectStopped() async throws {
            let state = await ledger.workingState()
            if entry == .preview {
                #expect(state.previews[Self.ticket] == nil)
                #expect(state.nodes.isEmpty)
                #expect(await agents.testTasks().isEmpty)
            } else {
                let node = try #require(state.nodes[Self.id])
                #expect(node.flags[.needsInput] != nil)
                #expect(node.phase == .specified)
                #expect(node.testsDigest == nil)
                #expect(!node.openQuestions.isEmpty)
                #expect(node.children.isEmpty)
                #expect(node.clarifications.isEmpty)
                #expect(node.allAssumptions.isEmpty)
                #expect(await agents.testTasks().count == (entry == .testAuthor ? 1 : 0))
            }
            #expect(await agents.implementationTasks().isEmpty)
        }

        func expectAccepted(_ expected: [Clarification]) async throws {
            let state = await ledger.workingState()
            let node = try #require(state.nodes[Self.id])
            #expect(node.phase == (split ? .split : .ready))
            #expect(node.flags[.needsInput] == nil)
            #expect(node.openQuestions.isEmpty)
            #expect(node.allAssumptions.isEmpty)
            #expect(!state.hasGate(.build, at: node.id))
            GH_14_2Tests.expectAnswers(expected, in: node.clarifications)
            let records = await ledger.allRecords()
            for answer in expected {
                for question in answer.questions {
                    let matching = records.filter {
                        guard $0.event.node == Self.id,
                              case .questionsAnswered(let value) = $0.event.kind else { return false }
                        return value.questions.contains(question)
                    }
                    #expect(matching.count == 1)
                    #expect(matching.first?.event.by == .human("Developer"))
                    #expect(matching.contains {
                        guard case .questionsAnswered(let value) = $0.event.kind else { return false }
                        return value.answer == answer.answer
                    })
                }
            }
            let rebuilt = try Ledger(store: store)
            let rebuiltNode = try #require(await rebuilt.workingState().nodes[Self.id])
            GH_14_2Tests.expectAnswers(expected, in: rebuiltNode.clarifications)
        }

        func removeDirectory() {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private actor MemoryTracker: TrackerAdapter {
        private var values: [String: Ticket] = [
            Fixture.ticket: Ticket(
                key: Fixture.ticket, title: "Configure result dates",
                description: "Use the human's accepted answers",
                acceptanceCriteria: ["Display dates as agreed"], createdBy: .human("Developer")
            ),
        ]
        private var pending: [Signal] = []
        private var childCount = 0

        func reply(_ text: String) {
            values[Fixture.ticket]?.comments.append(
                AgentOSCore.Comment(author: .human("Developer"), text: text)
            )
        }
        func signal(_ command: HarnessCommand) {
            pending.append(Signal(ticket: Fixture.ticket, command: command, setBy: .human("Developer")))
        }
        func pendingSignals() -> [Signal] { pending }
        func ticket(_ key: String) -> Ticket? { values[key] }
        func contextTickets() -> [Ticket] { Array(values.values) }
        func comments() -> [String] { values[Fixture.ticket]?.comments.map(\.text) ?? [] }
        func consume(_ signal: Signal, reply: String) {
            pending.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comment(on: signal.ticket, reply)
        }
        func comment(on key: String, _ text: String) {
            values[key]?.comments.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { values[key]?.status = status }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) -> String {
            childCount += 1
            let key = "GH-46-\(childCount)"
            values[key] = Ticket(
                key: key, title: spec.title, description: spec.intent,
                acceptanceCriteria: spec.acceptanceCriteria, createdBy: by
            )
            return key
        }
    }

    private actor RecordingAgents: Decomposer, TestAuthor, Implementer {
        let entry: Entry
        let questions: [AgentQuestion]
        let split: Bool
        private var requests: [BreakdownRequest] = []
        private var tests: [AgentTask] = []
        private var implementations: [AgentTask] = []

        init(entry: Entry, questions: [AgentQuestion], split: Bool) {
            self.entry = entry
            self.questions = questions
            self.split = split
        }

        func callCount() -> Int { requests.count + tests.count + implementations.count }
        func breakdownRequests() -> [BreakdownRequest] { requests }
        func testTasks() -> [AgentTask] { tests }
        func implementationTasks() -> [AgentTask] { implementations }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            requests.append(request)
            if entry != .testAuthor && request.clarifications.isEmpty {
                return Breakdown(children: [], report: AgentReport(questions: questions))
            }
            let children = split ? [
                ChildProposal(title: "Display dates", acceptanceCriteria: ["Format dates as agreed"],
                              touches: ["Results"]),
                ChildProposal(title: "Export dates", acceptanceCriteria: ["Export dates as agreed"],
                              touches: ["Export"]),
            ] : []
            return Breakdown(children: children)
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            tests.append(task)
            if entry == .testAuthor && task.clarifications.isEmpty {
                return AgentReport(questions: questions)
            }
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                import Testing
                @Test func datesUseTheAgreedFormat() { #expect(true) }
                """.write(to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8)
            return AgentReport()
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            implementations.append(task)
            // Stop after observing the input; these acceptance tests never run checks or land work.
            return AgentReport(questions: ["Which additional export formats are required?"])
        }
    }

    private struct StubServices: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner {
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
            "accepted-answer-tests"
        }
        func head(of directory: URL) async throws -> String { "fixture-main" }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/\(directory.lastPathComponent)/Acceptance.swift"]
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("This fixture must stop before landing")
        }
        func existingComponents() -> [String] { ["Results", "Export"] }
        func prepareBuild(in directory: URL) async throws {}
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Testing.Issue.record("Answer propagation must stop before running checks")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
    }
}
