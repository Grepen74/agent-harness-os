// API contract: Reconciler persists ticket-derived IDs for new children, but reuses persisted legacy IDs
// in Workspace calls and AgentTask values. RepositoryWorkspace maps those IDs to branch names and paths.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_27_4Tests {
    @Test
    func newlyCreatedChildUsesItsOwnTicketInTheBranchAndWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let parent = Self.spec(id: "wn-GH-15", kind: .composite)
        try await fixture.ledger.append([
            LedgerEvent(node: parent.id, by: .human("Alice"), kind: .nodeCreated(spec: parent, ticket: "GH-15")),
            LedgerEvent(node: parent.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
        ])
        let reconciler = fixture.reconciler()

        let breakdown = await reconciler.runRound()
        #expect(breakdown.safeStop == nil)
        let state = await fixture.ledger.workingState()
        let child = try #require(state.node(forTicket: "GH-18"))
        #expect(child.id == "wn-GH-18")
        #expect(child.spec.parent == parent.id)
        #expect(state.nodes[parent.id]?.children.contains(child.id) == true)

        let authoring = await reconciler.runRound()
        #expect(authoring.safeStop == nil)
        let task = try #require(await fixture.trace.authored.first { $0.identity.ticketKey == "GH-18" })
        let expectedDirectory = fixture.directory.appending(path: "storage/worktrees/wn-GH-18")
        #expect(task.spec.id == "wn-GH-18")
        #expect(task.identity.nodeID == "wn-GH-18")
        #expect(task.directory == expectedDirectory)
        #expect(fixture.mapping.worktree(for: child.id) == expectedDirectory)
        #expect(fixture.mapping.branch(for: child.id) == "agentos/leaf/wn-GH-18")
        #expect(await fixture.trace.calls.contains(.create("wn-GH-18")))
        #expect(await fixture.ledger.workingState().nodes[child.id]?.phase == .ready)
        #expect(await fixture.tracker.comments.contains {
            $0.key == "GH-18" && $0.text.contains("branch agentos/leaf/wn-GH-18")
        })
    }

    @Test(arguments: [false, true])
    func reloadedLegacyChildKeepsItsPositionalWorkspaceThroughAgentExecutionAndLanding(
        alreadyHasAcceptanceTests: Bool
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let parent = Self.spec(id: "wn-GH-15", kind: .composite)
        let legacy = Self.spec(id: "wn-GH-15.1", parent: parent.id)
        let legacyDirectory = fixture.mapping.worktree(for: legacy.id)
        let testDirectory = legacyDirectory.appending(path: fixture.mapping.testFolder(for: legacy))
        var events = [
            LedgerEvent(node: parent.id, by: .human("Alice"), kind: .nodeCreated(spec: parent, ticket: "GH-15")),
            LedgerEvent(node: parent.id, by: .reconciler, kind: .phaseChanged(to: .split)),
            LedgerEvent(node: legacy.id, by: .human("Alice"), kind: .nodeCreated(spec: legacy, ticket: "GH-18")),
            LedgerEvent(node: legacy.id, by: .human("Alice"), kind: .gateOpened(.build)),
        ]
        if alreadyHasAcceptanceTests {
            try Self.writeAcceptanceFile(in: testDirectory)
            events += [
                LedgerEvent(
                    node: legacy.id, by: .reconciler,
                    kind: .testsFixed(digest: Hashing.digest(of: testDirectory))
                ),
                LedgerEvent(node: legacy.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            ]
        }
        try await fixture.ledger.append(events)
        let reloaded = try Ledger(store: FileLedgerStore(fileURL: fixture.ledgerURL))
        let reconciler = fixture.reconciler(ledger: reloaded)

        for _ in 0..<4 {
            let report = await reconciler.runRound()
            #expect(report.safeStop == nil)
            if await reloaded.workingState().nodes[legacy.id]?.phase == .proven { break }
        }

        let state = await reloaded.workingState()
        let node = try #require(state.node(forTicket: "GH-18"))
        #expect(node.id == legacy.id)
        #expect(node.phase == .proven)
        #expect(node.landedCommit == "landed-\(legacy.id)")
        #expect(state.nodes["wn-GH-18"] == nil)
        #expect(fixture.mapping.branch(for: node.id) == "agentos/leaf/wn-GH-15.1")
        #expect(legacyDirectory == fixture.directory.appending(path: "storage/worktrees/wn-GH-15.1"))

        let implemented = await fixture.trace.implemented
        #expect(implemented.count == 1)
        let task = try #require(implemented.first)
        #expect(task.spec.id == legacy.id)
        #expect(task.identity.ticketKey == "GH-18")
        #expect(task.identity.nodeID == legacy.id)
        #expect(task.directory == legacyDirectory)
        #expect(task.testFolder == fixture.mapping.testFolder(for: legacy))

        let authored = await fixture.trace.authored
        let calls = await fixture.trace.calls
        if alreadyHasAcceptanceTests {
            #expect(authored.isEmpty)
            #expect(!calls.contains {
                if case .create = $0 { return true }
                return false
            })
        } else {
            #expect(authored.count == 1)
            #expect(authored.first?.spec.id == legacy.id)
            #expect(authored.first?.directory == legacyDirectory)
            #expect(calls.contains(.create(legacy.id)))
            #expect(await fixture.tracker.comments.contains {
                $0.key == "GH-18" && $0.text.contains("branch agentos/leaf/wn-GH-15.1")
            })
        }
        #expect(calls.contains(.check(legacyDirectory, legacy.testTarget)))
        #expect(calls.contains(.check(legacyDirectory, nil)))
        #expect(calls.contains(.rebase(legacyDirectory)))
        #expect(calls.contains(.land(legacy.id)))
        #expect(calls.contains(.remove(legacy.id)))
        #expect(!calls.contains(.create("wn-GH-18")))
        #expect(!calls.contains(.land("wn-GH-18")))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appending(path: "storage/worktrees/wn-GH-18").path
        ))
        #expect(try String(contentsOf: testDirectory.appending(path: "acceptance.txt"), encoding: .utf8)
            == "fixed acceptance tests\n")
    }

    private static func spec(id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(
            id: id, parent: parent, kind: kind, title: "Ticket-derived workspaces",
            intent: "Keep each node in its own workspace",
            acceptanceCriteria: ["Use the node's persisted ID"]
        )
    }

    private static func writeAcceptanceFile(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixed acceptance tests\n".write(
            to: directory.appending(path: "acceptance.txt"), atomically: true, encoding: .utf8
        )
    }

    private struct Fixture {
        let directory: URL
        let ledgerURL: URL
        let ledger: Ledger
        let mapping: RepositoryWorkspace
        let trace = Trace()
        let tracker = ChildTicketTracker()

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-27-4-\(UUID())")
            ledgerURL = directory.appending(path: "ledger.jsonl")
            ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerURL))
            mapping = try RepositoryWorkspace(
                root: directory.appending(path: "repo"),
                storage: directory.appending(path: "storage"),
                config: RepoConfig(
                    test: .init(command: "unused"),
                    leafTests: .init(target: "AppTests", folder: "Tests/AppTests")
                ),
                landingBranch: "agentos/main",
                defaultBranch: "main"
            )
        }

        func reconciler(ledger: Ledger? = nil) -> Reconciler {
            Reconciler(
                ledger: ledger ?? self.ledger,
                tracker: tracker,
                external: NoExternalSystem(),
                workspace: WorkspaceDouble(mapping: mapping, trace: trace),
                artifacts: Artifacts(),
                checks: Checks(trace: trace),
                team: AgentTeam(
                    name: "GH-27.4",
                    decomposer: TwoChildren(),
                    testAuthor: AcceptanceAuthor(trace: trace),
                    implementer: RecordingBuilder(trace: trace)
                )
            )
        }

        func removeFiles() {
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    Testing.Issue.record("Could not remove GH-27.4 fixture: \(error)")
                }
            }
        }
    }

    private enum WorkspaceCall: Equatable, Sendable {
        case create(NodeID)
        case remove(NodeID)
        case rebase(URL)
        case land(NodeID)
        case check(URL, String?)
    }

    private actor Trace {
        var authored: [AgentTask] = []
        var implemented: [AgentTask] = []
        var calls: [WorkspaceCall] = []

        func author(_ task: AgentTask) { authored.append(task) }
        func implement(_ task: AgentTask) { implemented.append(task) }
        func record(_ call: WorkspaceCall) { calls.append(call) }
    }

    private actor ChildTicketTracker: TrackerAdapter {
        struct PostedComment: Sendable {
            let key: String
            let text: String
        }

        var comments: [PostedComment] = []
        private var nextNumber = 18

        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key, title: "Ticket-derived workspaces", description: "",
                acceptanceCriteria: ["Use the node's persisted ID"], createdBy: .human("Alice")
            )
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            defer { nextNumber += 1 }
            return "GH-\(nextNumber)"
        }
        func comment(on key: String, _ text: String) {
            comments.append(PostedComment(key: key, text: text))
        }
        func setStatus(of key: String, to status: String) {}
    }

    private struct TwoChildren: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [
                ChildProposal(title: "First child", acceptanceCriteria: ["First behaviour"]),
                ChildProposal(title: "Second child", acceptanceCriteria: ["Second behaviour"]),
            ])
        }
    }

    private struct AcceptanceAuthor: TestAuthor {
        let trace: Trace
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            await trace.author(task)
            try GH_27_4Tests.writeAcceptanceFile(in: task.directory.appending(path: task.testFolder))
            return AgentReport()
        }
    }

    private struct RecordingBuilder: AgentOSCore.Implementer {
        let trace: Trace
        func implement(_ task: AgentTask) async throws -> AgentReport {
            await trace.implement(task)
            return AgentReport()
        }
    }

    // Keep real branch/path mapping while avoiding git, processes, and external services.
    private struct WorkspaceDouble: Workspace {
        let mapping: RepositoryWorkspace
        let trace: Trace

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { mapping.branch(for: id) }
        func worktree(for id: NodeID) -> URL { mapping.worktree(for: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            await trace.record(.create(id))
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {
            await trace.record(.remove(id))
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "candidate-\(directory.lastPathComponent)"
        }
        func head(of directory: URL) async throws -> String { "candidate-\(directory.lastPathComponent)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            [testFolder(for: GH_27_4Tests.spec(id: directory.lastPathComponent)) + "/acceptance.txt"]
        }
        var testArea: String { mapping.testArea }
        func testFolder(for spec: NodeSpec) -> String { mapping.testFolder(for: spec) }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            await trace.record(.rebase(directory))
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            await trace.record(.land(id))
            return "landed-\(id)"
        }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    private struct Checks: CheckRunner {
        let trace: Trace
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            await trace.record(.check(directory, testTarget))
            return CheckOutput(passed: true, summary: "Passed", log: "Passed")
        }
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
