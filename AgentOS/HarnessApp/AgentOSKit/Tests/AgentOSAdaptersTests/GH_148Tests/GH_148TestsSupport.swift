import AgentOSCore
@testable import AgentOSSimulation
import AgentOSTestSupport
import Foundation
import Testing

extension GH_148Tests {
    static let spec = NodeSpec(
        id: "wn-GH-148", parent: nil, kind: .leaf, title: "Record acceptance tests",
        intent: "Remember the candidate before checking it", acceptanceCriteria: ["Records its tests"],
        touches: ["Engine"]
    )
    static let folder = "Tests/AgentOSAdaptersTests/GH_148Tests"
    static let firstFile = "\(folder)/A.swift"
    static let lastFile = "\(folder)/Nested/Z.swift"
    static let otherFile = "Tests/AgentOSAdaptersTests/GH_OtherTests/Older.swift"
    static let firstSource = "import Testing\n@Test func returnsGreeting() {}\n"
    static let lastSource = "import Testing\n@Test func rejectsEmpty() {}\n"

    enum AuthorOutcome: CaseIterable, Sendable {
        case accepted, preflightReturn, reviewReturn
    }

    struct Draft: Sendable {
        let files: [String: String]
        var removed: [String] = []
    }

    struct Candidate {
        let node: NodeID?
        let position: Int
        let files: [String]
        let suite: String
    }

    static func recordedEvents(_ records: [RecordedEvent]) -> [Candidate] {
        records.compactMap {
            guard case .testsRecorded(let files, let suite) = $0.event.kind else { return nil }
            return Candidate(node: $0.event.node, position: $0.position, files: files, suite: suite)
        }
    }

    static func createNode(in ledger: Ledger) async throws {
        try await append([.nodeCreated(spec: spec, ticket: "GH-148")], to: ledger, by: .human("Alice"))
    }

    static func append(_ kinds: [EventKind], to ledger: Ledger, by participant: Participant = .reconciler) async throws {
        try await ledger.append(kinds.map { LedgerEvent(node: spec.id, by: participant, kind: $0) })
    }

    static func scratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "GH_148Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func cleanUp(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove GH148 fixture \(root.path): \(error)") }
    }

    static func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let workspace: WorkspaceFake
        let probe: Checkpoints
        let tracker = TrackerFake()
        let reconciler: Reconciler

        init(outcomes: [AuthorOutcome], drafts: [Draft]? = nil) async throws {
            root = try GH_148Tests.scratchDirectory()
            ledger = try Ledger()
            workspace = WorkspaceFake(root: root)
            probe = Checkpoints(ledger: ledger, workspace: workspace, outcomes: outcomes)
            let author = AuthorFake(drafts: drafts ?? [Draft(files: [
                GH_148Tests.lastFile: GH_148Tests.lastSource,
                GH_148Tests.firstFile: GH_148Tests.firstSource,
            ])])
            let unused = UnusedAgents()
            var team = AgentTeam(name: "GH148", decomposer: unused, testAuthor: author, implementer: unused)
            team.reviewer = probe
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: ScriptedChecks(), team: team,
                policy: Policy(guesswork: .autonomous), acceptanceTestPreflight: probe
            )
            try await GH_148Tests.createNode(in: ledger)
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[GH_148Tests.spec.id])
        }

        func authorTests() async throws {
            let current = try await node()
            _ = try await withHangGuard("GH148 test author") { try await self.reconciler.authorTests(current) }
        }

        func cleanUp() { GH_148Tests.cleanUp(root) }
    }

    actor AuthorFake: TestAuthor {
        private var drafts: [Draft]

        init(drafts: [Draft]) { self.drafts = drafts }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            guard !drafts.isEmpty else { throw AgentFailure("Unexpected extra GH148 test-author attempt") }
            let draft = drafts.removeFirst()
            for path in draft.removed { try FileManager.default.removeItem(at: task.directory.appending(path: path)) }
            for (path, text) in draft.files { try GH_148Tests.write(text, to: path, in: task.directory) }
            try GH_148Tests.write("updated older test", to: GH_148Tests.otherFile, in: task.directory)
            try GH_148Tests.write("placeholder implementation", to: "Sources/Placeholder.swift", in: task.directory)
            return AgentReport(updatedTests: [GH_148Tests.otherFile])
        }
    }

    actor WorkspaceFake: Workspace {
        nonisolated let root: URL
        nonisolated let testArea = "Tests/AgentOSAdaptersTests/"
        nonisolated let agentContext = ""
        private(set) var committedFiles: [String: String] = [:]
        private(set) var commitCount = 0

        init(root: URL) { self.root = root }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { ["Engine"] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL { root }
        func removeWorktree(for id: NodeID) async throws {
            throw AgentFailure("GH148 does not expect its candidate worktree to be removed")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let files = try currentFiles()
            guard files != committedFiles else { return nil }
            committedFiles = files
            commitCount += 1
            return head(of: directory)
        }
        func discardChanges(keeping paths: [String], in directory: URL) async throws {
            for path in try currentFiles().keys where !paths.contains(where: {
                path == $0 || path.hasPrefix($0 + "/")
            }) {
                try FileManager.default.removeItem(at: root.appending(path: path))
            }
        }
        func head(of directory: URL) -> String { "candidate-\(commitCount)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            // Deliberately not sorted: the ledger's public record must be sorted, not just this adapter's output.
            committedFiles.keys.sorted().reversed()
        }
        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
            ReviewContext(
                baseBranch: branch, commit: head(of: directory), fullDiff: "committed candidate \(commitCount)",
                changedFiles: try await changedFiles(in: directory), recentChanges: [], uiEvidence: nil
            )
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("GH148 authoring fixture does not expect implementation rework")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("GH148 authoring fixture stops before landing")
        }
        func prepareBuild(in directory: URL) async throws {}

        private func currentFiles() throws -> [String: String] {
            var files: [String: String] = [:]
            for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
                let file = root.appending(path: path)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                files[path] = try String(contentsOf: file, encoding: .utf8)
            }
            return files
        }
    }

    struct Observation: Sendable {
        let stage: String
        let history: [RecordedEvent]
        let node: NodeState?
        let commitCount: Int
    }

    actor Checkpoints: AcceptanceTestPreflight, Reviewer {
        let ledger: Ledger
        let workspace: WorkspaceFake
        let outcomes: [AuthorOutcome]
        private var attempt = -1
        private(set) var observations: [Observation] = []

        init(ledger: Ledger, workspace: WorkspaceFake, outcomes: [AuthorOutcome]) {
            self.ledger = ledger
            self.workspace = workspace
            self.outcomes = outcomes
        }

        func compileTests(in directory: URL, testFolder: String, expectedAPI: [String]) async -> AcceptanceTestPreflightResult {
            attempt += 1
            await observe("preflight")
            guard outcomes.indices.contains(attempt) else {
                Issue.record("Unexpected extra GH148 preflight")
                return .compiled
            }
            if outcomes[attempt] == .preflightReturn {
                return .diagnostics([CompilerDiagnostic(
                    file: GH_148Tests.firstFile, line: 2, message: "expected expression",
                    classification: .testAuthorMistake
                )], fullLog: "expected expression")
            }
            return .compiled
        }

        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            await observe("review")
            guard outcomes.indices.contains(attempt) else { throw AgentFailure("Unexpected extra GH148 review") }
            let passed = outcomes[attempt] != .reviewReturn
            return ReviewResult(passed: passed, findings: passed ? [] : ["Add the missing rejection case"])
        }

        private func observe(_ stage: String) async {
            observations.append(Observation(
                stage: stage, history: await ledger.records(for: GH_148Tests.spec.id),
                node: await ledger.workingState().nodes[GH_148Tests.spec.id],
                commitCount: await workspace.commitCount
            ))
        }
    }

    actor TrackerFake: TrackerAdapter {
        private(set) var comments: [String] = []
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH148 supplies its leaf")
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) async {}
    }

    struct ScriptedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            do {
                let tests = directory.appending(path: "Tests")
                let targets = try FileManager.default.contentsOfDirectory(atPath: tests.path)
                var failing: Set<String> = []
                for target in targets where testTarget == nil || testTarget == target {
                    let file = tests.appending(path: "\(target)/\(target).swift")
                    let text = try String(contentsOf: file, encoding: .utf8)
                    for match in text.matches(of: /#expect\((\w+)\.facts\["([^"]*)"\] == "([^"]*)"\)/) {
                        let component = String(match.output.1)
                        let facts = ScriptedFacts.read(ScriptedFacts.sourceFile(component, in: directory))
                        if facts[String(match.output.2)]?.value != String(match.output.3) { failing.insert(target) }
                    }
                }
                return CheckOutput(
                    passed: failing.isEmpty, summary: failing.isEmpty ? "Scripted facts match" : "Scripted facts missing",
                    log: failing.sorted().joined(separator: "\n"), failingTargets: failing
                )
            } catch {
                Issue.record("Could not read the scripted acceptance tests: \(error)")
                return CheckOutput(passed: false, summary: "Could not read scripted tests", log: "\(error)")
            }
        }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct UnusedAgents: Decomposer, AgentOSCore.Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH148 supplies its leaf")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH148 authoring fixture must not run an implementer")
        }
    }
}
