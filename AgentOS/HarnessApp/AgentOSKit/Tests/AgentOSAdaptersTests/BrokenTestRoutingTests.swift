import AgentOSCore
import Foundation
import Testing

@Suite("Broken test routing")
struct BrokenTestRoutingTests {
    @Test func aConflictWithAnotherSuitesTestGoesToTheTestAuthorTwiceThenWaitsAndRetryContinues() async throws {
        let fixture = try await Fixture(reports: Array(repeating: BrokenTestReport(
            testName: "FlowTests.previewKeepsIDs", reason: "It expects the old IDs."), count: 3))
        await fixture.rounds(2)
        #expect(await fixture.node()?.phase == .specified)
        #expect(await fixture.tracker.comments.last?.text.contains("isn't one of this ticket's tests") == true)
        await fixture.rounds(4)

        let waiting = try #require(await fixture.node())
        #expect(waiting.phase == .ready)
        #expect(waiting.flags[.needsInput]?.contains("isn't one of this ticket's acceptance tests") == true)
        #expect(await fixture.testAuthor.runs == 3)
        let comment = try #require(await fixture.tracker.comments.last?.text)
        #expect(comment.contains("❓ Needs input"))
        #expect(comment.contains("harness:retry"))

        // The person fixed FlowTests on the default branch; a retry needs no comment.
        await fixture.tracker.add(.retry)
        await fixture.rounds(2)

        let resumed = try #require(await fixture.node())
        #expect(resumed.flags[.needsInput] == nil)
        #expect(await fixture.testAuthor.runs == 3)
        #expect(await fixture.implementer.runs == 4)
    }

    @Test(arguments: [
        ("FlowTests", "Tests/AgentOSSimulationTests/FlowTests.swift", [String](), true),
        ("FlowTests", "Tests/AgentOSAdaptersTests/FlowTests.swift", [], false),
        ("HarnessFlow", "Tests/AgentOSSimulationTests/HarnessFlow.swift", [], true),
        // The repo lets the test author update the other test targets' tests too.
        ("FlowTests", "Tests/AgentOSSimulationTests/FlowTests.swift", ["Tests/"], false),
    ])
    func aConflictingTestNoAgentMayChangeGoesStraightToAPerson(
        suite: String, file: String, updatable: [String], outsideTestArea: Bool
    ) async throws {
        let fixture = try await Fixture(
            updatable: updatable,
            reports: Array(repeating: BrokenTestReport(testName: "\(suite).demoReworks", reason: "It expects a rework."), count: 3),
            files: [
                file: "@Suite(.serialized)\nfinal class \(suite) {}\n",
                // Only a declaration counts, not a suite named in a test's source text.
                "Tests/AgentOSAdaptersTests/Fixtures.swift": "let source = \"@Suite struct \(suite) {}\"\n",
            ])
        await fixture.rounds(6)

        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.needsInput])
        #expect(await fixture.testAuthor.runs == (outsideTestArea ? 1 : 3))
        #expect(reason.contains("lives in \(file), outside Tests/AgentOSAdaptersTests/") == outsideTestArea)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(node))
    }

    @Test(arguments: [false, true])
    func aRetryHandsAConflictingTestTheRepoNowLetsAgentsUpdateToTheTestAuthor(fixedOnLandingBranch: Bool) async throws {
        let file = "Tests/AgentOSSimulationTests/FlowTests.swift"
        let fixture = try await Fixture(
            reports: [BrokenTestReport(testName: "FlowTests.landsOnMain", reason: "It expects landing on main.")],
            files: [file: "struct FlowTests {}\n"])
        await fixture.rounds(2)
        #expect(await fixture.node()?.flags[.needsInput]?.contains("outside Tests/AgentOSAdaptersTests/") == true)
        #expect(await fixture.testAuthor.runs == 1)

        // The repo adds the other test targets to leafTests.updatable. Or a person fixed the test as well, which
        // catching up brought in before the retry was handled.
        fixture.areas.set(["Tests/"])
        if fixedOnLandingBranch {
            try "struct FlowTests { /* fixed */ }\n".write(to: fixture.directory.appending(path: file), atomically: true, encoding: .utf8)
        }
        await fixture.tracker.add(.retry)
        await fixture.rounds(1)

        let resumed = try #require(await fixture.node())
        #expect(resumed.flags[.needsInput] == nil)
        #expect(await fixture.testAuthor.runs == (fixedOnLandingBranch ? 1 : 2))
        // Either the test author settles the conflict with the report, or the implementer tries again straight away.
        #expect(await fixture.implementer.runs == (fixedOnLandingBranch ? 2 : 1))
        if !fixedOnLandingBranch {
            #expect(await fixture.testAuthor.feedback.last == "FlowTests.landsOnMain: It expects landing on main.")
        }
    }

    @Test func aRetestGivesTheRewrittenTestsAFirstBrokenReportBeforeAPersonIsAsked() async throws {
        let fixture = try await Fixture(reports: [
            BrokenTestReport(testName: "contract", reason: "First problem."),
            BrokenTestReport(testName: "contract", reason: "Second problem."),
            BrokenTestReport(testName: "contract", reason: "Third problem."),
            BrokenTestReport(testName: "contract", reason: "Fourth problem."),
        ])
        await fixture.rounds(6)
        let waiting = try #require(await fixture.node())
        let reason = try #require(waiting.flags[.needsInput])
        #expect(reason.contains("Third problem."))

        await fixture.tracker.add(.retest)
        await fixture.rounds(3)

        let afterRetest = try #require(await fixture.node())
        #expect(afterRetest.flags[.needsInput] == nil)
        #expect(await fixture.tracker.comments.contains { $0.text.contains("Fourth problem.") && $0.text.contains("sent back to the test author") })
    }

    @Test func aWaitingReasonNamesOnlyTheReportsThatLedToIt() async throws {
        let fixture = try await Fixture(reports: [
            BrokenTestReport(testName: "contract", reason: "Old problem."),
            BrokenTestReport(testName: "contract", reason: "Older follow-up."),
            BrokenTestReport(testName: "contract", reason: "Oldest follow-up."),
            BrokenTestReport(testName: "contract", reason: "First problem."),
            BrokenTestReport(testName: "contract", reason: "Second problem."),
            BrokenTestReport(testName: "contract", reason: "Third problem."),
        ])
        await fixture.rounds(6)
        await fixture.tracker.add(.retest)
        await fixture.rounds(7)

        let reason = try #require(await fixture.node()?.flags[.needsInput])
        #expect(reason.contains("First problem.") && reason.contains("Second problem.") && reason.contains("Third problem."))
        #expect(!reason.contains("Old problem."))
    }

    /// GH-117: the implementer could only pass the tests outside its scope, reported that as a broken test twice, and
    /// the test author, who can't widen the scope, rewrote the tests twice before a person was asked.
    @Test func codeOutsideTheScopeIsAPersonsCallNotTheTestAuthorsAndTheAnswerReachesTheImplementer() async throws {
        let request = ScopeRequest(paths: ["Sources/AgentOSCore/Reconciler.swift"], reason: "The bot check lives there.")
        let fixture = try await Fixture(
            implementerReports: [AgentReport(
                questions: [AgentQuestion(question: "Which login?", suggestion: "The authenticated one.")],
                scopeRequest: request)],
            // Even agents that go on with their own suggestions don't widen their scope.
            policy: Policy(guesswork: .autonomous))
        await fixture.rounds(3)

        let waiting = try #require(await fixture.node())
        #expect(waiting.phase == .ready)
        #expect(waiting.flags[.needsInput] != nil)
        #expect(waiting.openQuestions.map(\.question) == [
            "Which login?",
            "May the implementer change Sources/AgentOSCore/Reconciler.swift, outside what this work item touches "
                + "(\(Fixture.spec.touches.joined(separator: ", ")))? The bot check lives there.",
        ])
        #expect(waiting.brokenTestReports.isEmpty)
        #expect(await fixture.testAuthor.runs == 1)
        #expect(await fixture.implementer.runs == 1)
        #expect(fixture.unfinishedWork.recorded == ["saved"])

        await fixture.tracker.reply("1. Answer: ok, 2. Answer: Yes, change it there.")
        await fixture.tracker.add(.retry)
        await fixture.rounds(2)

        #expect(await fixture.node()?.flags[.needsInput] == nil)
        #expect(await fixture.testAuthor.runs == 1)
        #expect(await fixture.implementer.runs == 2)
        let answers = try #require(await fixture.implementer.answers.last)
        #expect(answers.contains { $0.questions.first?.hasPrefix("May the implementer change") == true
            && $0.answer == "Yes, change it there." })
    }
}

private extension BrokenTestRoutingTests {
    final class Fixture: Sendable {
        static let spec = NodeSpec(id: "wn-GH-9.1", parent: nil, kind: .leaf, title: "Ticket IDs",
                                   intent: "Children use ticket IDs", acceptanceCriteria: ["IDs come from tickets"])
        let ledger: Ledger
        let tracker = Tracker()
        let testAuthor = Author()
        let implementer: Builder
        let reconciler: Reconciler

        let areas: Areas
        let unfinishedWork = UnfinishedWork()
        let directory: URL

        convenience init(updatable: [String] = [], reports: [BrokenTestReport], files: [String: String] = [:]) async throws {
            try await self.init(updatable: updatable, implementerReports: reports.map { AgentReport(brokenTest: $0) },
                                files: files)
        }

        init(updatable: [String] = [], implementerReports: [AgentReport], files: [String: String] = [:],
             policy: Policy? = nil) async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "agentos-routing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory.appending(path: Stub.folder), withIntermediateDirectories: true)
            for (path, text) in files {
                let url = directory.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            ledger = try Ledger()
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-9")),
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            ])
            implementer = Builder(reports: implementerReports)
            areas = Areas(updatable)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: Stub(directory: directory),
                workspace: Stub(directory: directory, areas: areas, unfinishedWork: unfinishedWork),
                artifacts: Stub(directory: directory), checks: Stub(directory: directory),
                team: AgentTeam(name: "routing", decomposer: Stub(directory: directory), testAuthor: testAuthor, implementer: implementer),
                policy: policy)
        }

        func rounds(_ count: Int) async {
            for _ in 0..<count { _ = await reconciler.runRound(waitForAgents: true) }
        }

        func node() async -> NodeState? { await ledger.workingState().nodes[Self.spec.id] }
    }

    actor Tracker: TrackerAdapter {
        private(set) var comments: [AgentOSCore.Comment] = []
        private var signals: [Signal] = []

        func add(_ command: HarnessCommand) { signals.append(Signal(ticket: "GH-9", command: command, setBy: .human("Alice"))) }
        func reply(_ text: String) { comments.append(AgentOSCore.Comment(author: .human("Alice"), text: text)) }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            var ticket = Ticket(key: key, title: "Ticket IDs", description: "Children use ticket IDs",
                                acceptanceCriteria: ["IDs come from tickets"], createdBy: .human("Alice"))
            ticket.comments = comments
            return ticket
        }
        func consume(_ signal: Signal, reply: String) { signals.removeAll { $0.command == signal.command } }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unused" }
        func comment(on key: String, _ text: String) { comments.append(AgentOSCore.Comment(author: .reconciler, text: text)) }
        func setStatus(of key: String, to status: String) {}
    }

    actor Author: TestAuthor {
        private(set) var runs = 0
        private(set) var feedback: [String?] = []
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            runs += 1
            feedback.append(task.previousFailure)
            let file = task.directory.appending(path: "\(task.testFolder)/Tests.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// revision \(runs)\n".write(to: file, atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    actor Builder: Implementer {
        private var reports: [AgentReport]
        private(set) var runs = 0
        private(set) var answers: [[Clarification]] = []
        init(reports: [AgentReport]) { self.reports = reports }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            runs += 1
            answers.append(task.clarifications)
            return reports.isEmpty ? AgentReport() : reports.removeFirst()
        }
    }

    /// What the harness did with an implementer's uncommitted work.
    final class UnfinishedWork: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }
        var recorded: [String] { lock.withLock { events } }
    }

    /// The repo's further updatable test folders, which its config may change.
    final class Areas: @unchecked Sendable {
        private let lock = NSLock()
        private var updatable: [String]
        init(_ updatable: [String]) { self.updatable = updatable }

        func set(_ updatable: [String]) { lock.withLock { self.updatable = updatable } }
        var current: [String] { lock.withLock { updatable } }
    }

    struct Stub: Workspace, CheckRunner, ArtifactStore, ExternalDependencySource, Decomposer {
        static let folder = "Tests/AgentOSAdaptersTests/GH_9_1Tests"
        let directory: URL
        var areas = Areas([])
        var unfinishedWork = UnfinishedWork()

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "commit-\(author)" }
        func head(of directory: URL) async throws -> String { "head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        var updatableTestAreas: [String] { [testArea] + areas.current }
        func testFolder(for spec: NodeSpec) -> String { Self.folder }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func saveUnfinishedWork(_ directory: URL, for id: NodeID) async throws -> [String] {
            unfinishedWork.record("saved")
            return ["Sources/AgentOSCore/Reconciler.swift"]
        }
        func forgetUnfinishedWork(for id: NodeID) async throws { unfinishedWork.record("forgot") }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: false, summary: "not run", log: "")
        }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown { Breakdown(children: []) }
    }
}
