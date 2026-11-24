import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

extension GH_145Tests {
    private static let testArea = "Tests/AgentOSAdaptersTests/"
    private static let ownFolder = testArea + "GH_145Tests"
    static let ownFile = ownFolder + "/Contract.swift"
    static let placeholderFile = "Sources/Feature.swift"
    static let originalPlaceholder = "struct Feature {}\n"
    static let reportedTest = "GH_9Tests.oldContract"
    static let originalTest = "struct GH_9Tests { let expected = 1 }\n"
    static let updatedTest = "struct GH_9Tests { let expected = 2 }\n"
    static let newOwnTest = "struct GH_145Tests { let expected = 2 }\n"
    static let spec = NodeSpec(
        id: "wn-GH-145", parent: nil, kind: .leaf, title: "Use the new identifier",
        intent: "Adopt the new contract", acceptanceCriteria: ["The new identifier is used"])

    enum NotWaiting: Sendable { case noInput, unrelatedQuestions, ownBrokenTest }

    final class Fixture: Sendable {
        let directory: URL
        let file: String
        let ledger: Ledger
        let tracker = Tracker()
        let author = Author()
        let workspace: TestWorkspace
        let reconciler: Reconciler

        init(file: String = "Tests/AgentOSAdaptersTests/GH_9Tests/Contract.swift",
             extraAreas: [String] = [], protected: [String] = []) async throws {
            self.file = file
            directory = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-145-\(UUID().uuidString)")
            let files = [
                file: GH_145Tests.originalTest,
                GH_145Tests.ownFile: "struct GH_145Tests { let expected = 1 }\n",
                GH_145Tests.placeholderFile: GH_145Tests.originalPlaceholder,
            ]
            for (path, text) in files {
                try GH_145Tests.write(text, to: directory.appending(path: path))
            }
            workspace = TestWorkspace(directory: directory, baseline: files, extraAreas: extraAreas)
            ledger = try Ledger()
            try await ledger.append([
                LedgerEvent(node: GH_145Tests.spec.id, by: .human("Pat"),
                            kind: .nodeCreated(spec: GH_145Tests.spec, ticket: "GH-145")),
                LedgerEvent(node: GH_145Tests.spec.id, by: .reconciler,
                            kind: .testsFixed(digest: Hashing.digest(of: directory.appending(path: GH_145Tests.ownFolder)))),
                LedgerEvent(node: GH_145Tests.spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            ])
            let stubs = Stubs()
            var policy = Policy(protectedPaths: protected)
            policy.review.level = .none
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: stubs, workspace: workspace,
                artifacts: stubs, checks: stubs,
                team: AgentTeam(name: "GH-145", decomposer: stubs, testAuthor: author, implementer: stubs),
                policy: policy)
        }

        func remove() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Couldn't remove GH-145 fixture \(directory.path): \(error)") }
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[GH_145Tests.spec.id])
        }

        func history() async -> [RecordedEvent] { await ledger.records(for: GH_145Tests.spec.id) }

        func append(_ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map {
                LedgerEvent(node: GH_145Tests.spec.id, by: .reconciler, kind: $0)
            })
        }

        func waitForConflict() async throws {
            // Exhaust both the same-test and total-return budgets without running or scheduling agents.
            for index in 0..<Reconciler.automaticTestReturnsInAll {
                let name = index < Reconciler.automaticTestReturns ? GH_145Tests.reportedTest : "EarlierTests.case\(index)"
                try await append([
                    .brokenTestReported(.init(testName: name, reason: "An earlier conflicting expectation")),
                    .brokenTestRouted(testName: name, outcome: .sentBackToTestAuthor),
                ])
            }
            try await route(GH_145Tests.reportedTest)
            #expect(try await node().flags[.needsInput] != nil)
            #expect(await reconciler.isWaitingOnOtherTest(try await node()))
        }

        func route(_ test: String) async throws {
            try await withHangGuard("routing a conflicting test") {
                _ = try await self.reconciler.routeBrokenTest(
                    BrokenTestReport(testName: test, reason: "It expects the old identifier."),
                    from: try await self.node(), run: "reporting-builder",
                    author: .agent(run: "reporting-builder", role: .implementer), directory: self.directory)
            }
        }

        func send(_ command: HarnessCommand) async throws {
            await tracker.add(command)
            try await withHangGuard("handling \(command.label)") {
                var report = RoundReport()
                await self.reconciler.intakeSignals(&report)
                #expect(report.safeStop == nil)
                #expect(await self.tracker.pendingSignals().isEmpty)
            }
        }

        func authorTests() async throws {
            try await withHangGuard("restarting the test author") {
                _ = try await self.reconciler.authorTests(try await self.node())
            }
        }

        func addOwner(phase: Phase, landed: Bool) async throws {
            let owner = NodeSpec(id: "wn-GH-9", parent: nil, kind: .leaf, title: "Earlier contract",
                                 intent: "The test's owner", acceptanceCriteria: ["An identifier is returned"])
            var kinds: [EventKind] = [.nodeCreated(spec: owner, ticket: "GH-9"), .phaseChanged(to: phase)]
            if landed { kinds.append(.landed(commit: "landed-GH-9")) }
            try await ledger.append(kinds.map {
                LedgerEvent(node: owner.id, by: .reconciler, kind: $0)
            })
        }

        func rejection() async throws -> (reason: String, guidance: String) {
            let records = await history()
            let rejected = try #require(records.last {
                if case .signalRejected(_, .updateTest, _) = $0.event.kind { return true }
                return false
            })
            let reason: String
            if case .signalRejected(_, _, let text) = rejected.event.kind { reason = text }
            else { throw AgentFailure("Expected a rejected harness:update-test signal") }
            #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let reply = try #require(await tracker.replies.last)
            #expect(reply.contains(reason))
            let guidance = try #require(reply.components(separatedBy: "What you can do now:").dropFirst().first)
            #expect(!guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!records.contains {
                if case .testUpdatesApproved = $0.event.kind { return true }
                return false
            })
            return (reason, guidance)
        }
    }

    actor Tracker: TrackerAdapter {
        private(set) var comments: [AgentOSCore.Comment] = []
        private(set) var replies: [String] = []
        private var signals: [Signal] = []

        func add(_ command: HarnessCommand) {
            signals.append(Signal(ticket: "GH-145", command: command, setBy: .human("Pat")))
        }
        func reply(_ text: String) { comments.append(AgentOSCore.Comment(author: .human("Pat"), text: text)) }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            var ticket = Ticket(key: key, title: GH_145Tests.spec.title, description: GH_145Tests.spec.intent,
                                acceptanceCriteria: GH_145Tests.spec.acceptanceCriteria, createdBy: .human("Pat"))
            ticket.comments = comments
            return ticket
        }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            replies.append(reply)
            comments.append(AgentOSCore.Comment(author: .reconciler, text: reply))
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("These tests do not create child tickets")
        }
        func comment(on key: String, _ text: String) {
            comments.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) {}
    }

    actor Author: TestAuthor {
        private var updatedFile: String?
        private(set) var tasks: [AgentTask] = []
        func update(_ file: String) { updatedFile = file }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            tasks.append(task)
            try GH_145Tests.write(GH_145Tests.newOwnTest, to: task.directory.appending(path: GH_145Tests.ownFile))
            try GH_145Tests.write("struct Feature { let placeholder = true }\n",
                                 to: task.directory.appending(path: GH_145Tests.placeholderFile))
            if let updatedFile {
                try GH_145Tests.write(GH_145Tests.updatedTest, to: task.directory.appending(path: updatedFile))
            }
            return AgentReport(updatedTests: updatedFile.map { [$0] } ?? [])
        }
    }

    actor TestWorkspace: Workspace {
        nonisolated let directory: URL
        nonisolated let extraAreas: [String]
        private let baseline: [String: String]
        private var committed: [String: String]

        init(directory: URL, baseline: [String: String], extraAreas: [String]) {
            self.directory = directory
            self.baseline = baseline
            self.committed = baseline
            self.extraAreas = extraAreas
        }
        nonisolated var testArea: String { GH_145Tests.testArea }
        nonisolated var updatableTestAreas: [String] { [testArea] + extraAreas }
        nonisolated var agentContext: String { "" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id.dropFirst(3))" }
        nonisolated func worktree(for id: NodeID) -> URL { directory }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated func existingComponents() -> [String] { [] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let files = try snapshot()
            guard files != committed else { return nil }
            committed = files
            return "commit-\(author)"
        }
        func discardChanges(keeping paths: [String], in directory: URL) async throws {
            for (file, _) in try snapshot() where !paths.contains(where: { file == $0 || file.hasPrefix($0 + "/") }) {
                if let original = committed[file] {
                    try GH_145Tests.write(original, to: directory.appending(path: file))
                } else {
                    try FileManager.default.removeItem(at: directory.appending(path: file))
                }
            }
        }
        func committedText(_ file: String) -> String? { committed[file] }
        func head(of directory: URL) async throws -> String { "branch-tip" }
        func changedFiles(in directory: URL) async throws -> [String] {
            let files = try snapshot()
            return Set(files.keys).union(baseline.keys).filter { files[$0] != baseline[$0] }.sorted()
        }
        private func snapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            // All fixture inputs and agent outputs are known; no git process or shared repository is involved.
            for path in Set(baseline.keys).union([GH_145Tests.ownFile, GH_145Tests.placeholderFile]) {
                let url = directory.appending(path: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    result[path] = try String(contentsOf: url, encoding: .utf8)
                }
            }
            return result
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("This fixture never lands work") }
        func prepareBuild(in directory: URL) async throws {}
    }

    private struct Stubs: ExternalDependencySource, ArtifactStore, CheckRunner, Decomposer, Implementer {
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture checks passed", log: "")
        }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("This fixture never decomposes work")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Approval must restart the test author, not the implementer")
        }
    }

    private static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
