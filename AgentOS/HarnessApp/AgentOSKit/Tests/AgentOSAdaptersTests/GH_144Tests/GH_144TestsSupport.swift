@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_144Tests {
    final class Fixture: Sendable {
        static let older = "Tests/Acceptance/OlderTests/Greeting.swift"
        static let unit = "Tests/Unit/GreetingTests.swift"
        static let unchanged = "Tests/Unit/UnchangedTests.swift"
        static let outside = "Examples/Tests/GreetingTests.swift"
        static let protectedFile = "Tests/Unit/LockedGreetingTests.swift"
        static let protectedFolderFile = "Tests/Unit/Protected/HelperTests.swift"
        static let own = "Tests/Acceptance/GH_144Tests/GH_144Tests.swift"
        static let original = "expects hi\n"
        static let ownContents = "acceptance test expects hello\n"
        static let originals = Dictionary(uniqueKeysWithValues:
            [older, unit, unchanged, outside, protectedFile, protectedFolderFile].map { ($0, original) })

        let root: URL
        let ledger: Ledger
        let workspace: WorkspaceFake
        let checks = ChecksFake()
        let reviewer = ReviewerFake()
        let reconciler: Reconciler

        init(approved: [String] = [], edits: [String: String] = [:], reported: [String] = [],
             criteria: [String] = ["The greeting returns hello"]) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH144-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = WorkspaceFake(root: root)
            let unused = UnusedAgents()
            var team = AgentTeam(
                name: "GH144", decomposer: unused,
                testAuthor: AuthorFake(edits: edits, reported: reported), implementer: unused
            )
            team.reviewer = reviewer
            var policy = Policy(
                protectedPaths: ["Tests/Unit/Locked*.swift", "Tests/Unit/Protected/"],
                guesswork: .autonomous
            )
            policy.review.level = .none
            reconciler = Reconciler(
                ledger: ledger, tracker: TrackerFake(), external: NoExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: checks, team: team, policy: policy
            )
            let spec = NodeSpec(
                id: "wn-GH-144", parent: nil, kind: .leaf, title: "Greet callers",
                intent: "Use the new greeting", acceptanceCriteria: criteria, touches: ["App"]
            )
            try await record([.nodeCreated(spec: spec, ticket: "GH-144")])
            if !approved.isEmpty {
                try await record([.testUpdatesApproved(tests: approved)], by: .human("Developer"))
            }
        }

        func node() async -> NodeState? { await ledger.workingState().nodes["wn-GH-144"] }

        func record(_ kinds: [EventKind], by: Participant = .reconciler) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: "wn-GH-144", by: by, kind: $0) })
        }

        func authorTests() async throws {
            let node = try #require(await node())
            _ = try await withHangGuard("GH144 test author") { try await self.reconciler.authorTests(node) }
        }

        func submitAndPreCheck() async throws {
            _ = try await workspace.commitAll(in: root, message: "implementation", author: "implementer")
            let commit = await workspace.head(of: root)
            try await record([
                .changeSubmitted(run: "implementer", commit: commit), .phaseChanged(to: .checking),
            ], by: .agent(run: "implementer", role: .implementer))
            let node = try #require(await node())
            _ = try await withHangGuard("GH144 pre-check") { try await self.reconciler.preCheck(node) }
        }

        func reviewRequest(stage: ReviewStage) async throws -> ReviewRequest {
            let node = try #require(await node())
            let context = try await workspace.reviewContext(in: root, against: "main")
            _ = try await withHangGuard("GH144 review") {
                try await self.reconciler.review(node, stage: stage, context: context, in: self.root, run: "review")
            }
            return try #require(await reviewer.requests.last)
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Cannot remove the GH144 fixture: \(error)") }
        }
    }

    struct AuthorFake: TestAuthor {
        let edits: [String: String]
        let reported: [String]

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            try GH_144Tests.write(Fixture.ownContents, to: Fixture.own, in: task.directory)
            for (file, text) in edits { try GH_144Tests.write(text, to: file, in: task.directory) }
            return AgentReport(updatedTests: reported)
        }
    }

    actor WorkspaceFake: Workspace {
        nonisolated let root: URL
        nonisolated let testArea = "Tests/Acceptance/"
        nonisolated let updatableTestAreas = ["Tests/Acceptance/", "Tests/Unit/"]
        nonisolated let agentContext = ""
        private var committed = Fixture.originals
        private var commits = 0

        init(root: URL) { self.root = root }
        nonisolated func branch(for id: NodeID) -> String { "agentos/GH-144" }
        nonisolated func worktree(for id: NodeID) -> URL { root }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/Acceptance/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { ["App"] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL {
            for (path, text) in Fixture.originals { try GH_144Tests.write(text, to: path, in: root) }
            return root
        }
        func removeWorktree(for id: NodeID) async throws {
            throw AgentFailure("GH144 does not expect the test author's worktree to be removed")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let files = try currentFiles()
            guard files != committed else { return nil }
            committed = files
            commits += 1
            return "commit-\(commits)"
        }
        func discardChanges(keeping paths: [String], in directory: URL) async throws {
            for path in Set(try currentFiles().keys).union(Fixture.originals.keys)
                where !paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                if let original = Fixture.originals[path] {
                    try GH_144Tests.write(original, to: path, in: root)
                } else {
                    try FileManager.default.removeItem(at: root.appending(path: path))
                }
            }
        }
        func head(of directory: URL) -> String { "commit-\(commits)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            let files = try currentFiles()
            return Set(files.keys).union(Fixture.originals.keys).filter {
                files[$0] != Fixture.originals[$0]
            }.sorted()
        }
        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
            let changed = try await changedFiles(in: directory)
            let diff = try changed.map { path in
                "diff --git a/\(path) b/\(path)\n+\(try text(at: path) ?? "")"
            }.joined(separator: "\n")
            return ReviewContext(
                baseBranch: branch, commit: head(of: directory), fullDiff: diff,
                changedFiles: changed, recentChanges: [], uiEvidence: nil
            )
        }
        func committedText(at path: String) -> String? { committed[path] }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("GH144 does not expect implementation rework")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("GH144 stops before landing")
        }
        func prepareBuild(in directory: URL) async throws {}

        private func currentFiles() throws -> [String: String] {
            var files: [String: String] = [:]
            for path in Set(Fixture.originals.keys).union([Fixture.own]) {
                files[path] = try text(at: path)
            }
            return files
        }
        private func text(at path: String) throws -> String? {
            let file = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    actor ChecksFake: CheckRunner {
        private(set) var calls = 0
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            calls += 1
            return CheckOutput(passed: true, summary: "Greeting tests passed", log: "Greeting tests passed")
        }
    }

    actor ReviewerFake: Reviewer {
        private(set) var requests: [ReviewRequest] = []
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            requests.append(request)
            return ReviewResult(passed: true, findings: [])
        }
    }

    actor TrackerFake: TrackerAdapter {
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH144 supplies the leaf")
        }
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
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
            throw AgentFailure("GH144 supplies the leaf")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH144 supplies an implementer's submitted test edit")
        }
    }
}
