import AgentOSCore
import Foundation
import Testing

@Suite("Broken test routing")
struct BrokenTestRoutingTests {
    @Test func aConflictWithAnotherSuitesTestWaitsForAPersonAndRetryContinuesTheImplementation() async throws {
        let fixture = try await Fixture(reports: [
            BrokenTestReport(testName: "FlowTests.previewKeepsIDs", reason: "It expects the old IDs."),
        ])
        await fixture.rounds(2)

        let waiting = try #require(await fixture.node())
        #expect(waiting.phase == .ready)
        #expect(waiting.flags[.needsInput]?.contains("isn't one of this ticket's acceptance tests") == true)
        #expect(await fixture.testAuthor.runs == 1)
        let comment = try #require(await fixture.tracker.comments.last?.text)
        #expect(comment.contains("❓ Needs input"))
        #expect(comment.contains("harness:retry"))

        // The person fixed FlowTests on the default branch; a retry needs no comment.
        await fixture.tracker.add(.retry)
        await fixture.rounds(2)

        let resumed = try #require(await fixture.node())
        #expect(resumed.flags[.needsInput] == nil)
        #expect(await fixture.testAuthor.runs == 1)
        #expect(await fixture.implementer.runs == 2)
    }

    @Test func aRetestGivesTheRewrittenTestsAFirstBrokenReportBeforeAPersonIsAsked() async throws {
        let fixture = try await Fixture(reports: [
            BrokenTestReport(testName: "first", reason: "First problem."),
            BrokenTestReport(testName: "second", reason: "Second problem."),
            BrokenTestReport(testName: "third", reason: "Third problem."),
        ])
        await fixture.rounds(4)
        let waiting = try #require(await fixture.node())
        let reason = try #require(waiting.flags[.needsInput])
        #expect(reason.contains("Second problem."))

        await fixture.tracker.add(.retest)
        await fixture.rounds(3)

        let afterRetest = try #require(await fixture.node())
        #expect(afterRetest.flags[.needsInput] == nil)
        #expect(await fixture.tracker.comments.contains { $0.text.contains("third") && $0.text.contains("sent back to the test author") })
    }

    @Test func aWaitingReasonNamesOnlyTheReportsThatLedToIt() async throws {
        let fixture = try await Fixture(reports: [
            BrokenTestReport(testName: "old", reason: "Old problem."),
            BrokenTestReport(testName: "older", reason: "Older follow-up."),
            BrokenTestReport(testName: "first", reason: "First problem."),
            BrokenTestReport(testName: "second", reason: "Second problem."),
        ])
        await fixture.rounds(4)
        await fixture.tracker.add(.retest)
        await fixture.rounds(5)

        let reason = try #require(await fixture.node()?.flags[.needsInput])
        #expect(reason.contains("First problem.") && reason.contains("Second problem."))
        #expect(!reason.contains("Old problem."))
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

        init(reports: [BrokenTestReport]) async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-routing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory.appending(path: Stub.folder), withIntermediateDirectories: true)
            ledger = try Ledger()
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-9")),
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            ])
            implementer = Builder(reports: reports)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: Stub(directory: directory), workspace: Stub(directory: directory),
                artifacts: Stub(directory: directory), checks: Stub(directory: directory),
                team: AgentTeam(name: "routing", decomposer: Stub(directory: directory), testAuthor: testAuthor, implementer: implementer))
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
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            runs += 1
            let file = task.directory.appending(path: "\(task.testFolder)/Tests.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// revision \(runs)\n".write(to: file, atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    actor Builder: Implementer {
        private var reports: [BrokenTestReport]
        private(set) var runs = 0
        init(reports: [BrokenTestReport]) { self.reports = reports }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            runs += 1
            return reports.isEmpty ? AgentReport() : AgentReport(brokenTest: reports.removeFirst())
        }
    }

    struct Stub: Workspace, CheckRunner, ArtifactStore, ExternalDependencySource, Decomposer {
        static let folder = "Tests/AgentOSAdaptersTests/GH_9_1Tests"
        let directory: URL

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "commit-\(author)" }
        func head(of directory: URL) async throws -> String { "head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { Self.folder }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}

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
