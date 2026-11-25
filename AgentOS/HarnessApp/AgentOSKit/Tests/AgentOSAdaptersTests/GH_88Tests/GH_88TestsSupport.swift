import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

private extension URL {
    var gh88Node: NodeID { lastPathComponent }
}

extension GH_88Tests {
    final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let workspace: RecordingWorkspace
        let checks: RecordingChecks
        let tracker = RecordingTracker()
        let reconciler: Reconciler

        init(diagnose: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-88-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = RecordingWorkspace(root: root)
            checks = RecordingChecks(workspace: workspace, diagnose: diagnose)
            let agents = Agents()
            var policy = Policy(maxParallelAgents: 4, guesswork: .autonomous)
            policy.landingBatchSize = 1
            policy.avoidOverlappingWork = false
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: External(),
                workspace: workspace, artifacts: Artifacts(), checks: checks,
                team: AgentTeam(name: "GH-88", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy
            )
        }

        func add(_ id: NodeID, ticket: String, parent: NodeID? = nil, kind: NodeKind = .leaf,
                 phase: Phase, build: Bool = true) async throws -> NodeSpec {
            let spec = NodeSpec(id: id, parent: parent, kind: kind, title: ticket, intent: "Requirement branch routing",
                                acceptanceCriteria: ["Work stays on its requirement branch"])
            var events = [LedgerEvent(node: id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: ticket))]
            if kind == .leaf && phase != .specified {
                let folder = workspace.worktree(for: id).appending(path: workspace.testFolder(for: spec))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "fixed acceptance fixture\n".write(to: folder.appending(path: "Acceptance.swift"),
                                                       atomically: true, encoding: .utf8)
                events.append(LedgerEvent(node: id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: folder))))
                await workspace.seedLeaf(id)
                if phase == .landing {
                    events.append(LedgerEvent(node: id, by: .reconciler,
                                              kind: .changeSubmitted(run: "old-builder", commit: "candidate-\(id)")))
                }
            }
            events.append(LedgerEvent(node: id, by: .reconciler, kind: .phaseChanged(to: phase)))
            try await ledger.append(events)
            if build { try await openBuild(id) }
            return spec
        }

        func openBuild(_ id: NodeID) async throws {
            try await ledger.append([LedgerEvent(node: id, by: .human("Developer"), kind: .gateOpened(.build))])
        }

        func round() async throws -> RoundReport {
            let report = await reconciler.runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            return report
        }

        func until(_ predicate: (WorkingState) -> Bool) async throws -> WorkingState {
            // Only turns a hang into a failure: under a loaded full suite these rounds can take many seconds.
            let deadline = ContinuousClock.now.advanced(by: HangGuard.timeout)
            repeat {
                let report = try await round()
                let state = await ledger.workingState()
                if predicate(state) { return state }
                if report.isIdle {
                    let comments = await tracker.comments.joined(separator: "\n")
                    throw AgentFailure("Idle before the expected requirement-branch outcome: \(comments)")
                }
            } while ContinuousClock.now < deadline
            throw AgentFailure("Timed out waiting for the requirement-branch outcome")
        }

        func cleanUp() {
            do { try FixtureFolder.remove(root) }
            catch { Issue.record("Could not remove the GH-88 fixture: \(error)") }
        }
    }

    actor RecordingWorkspace: Workspace {
        struct Creation: Sendable, Equatable {
            let branch: String
            let from: String
        }
        struct Operation: Sendable, Equatable {
            enum Action: Sendable { case start, rebase, land, snapshot, catchUp }
            let action: Action
            let node: NodeID
            let branch: String
        }
        struct Observation: Sendable {
            let node: NodeID
            let base: String
            let commit: String
            let snapshot: Bool
        }
        struct Preparation: Sendable {
            let requirement: NodeIdentity
            let leaves: [NodeID]
        }

        nonisolated let root: URL
        private var main = "main-0"
        private var bindings: [NodeID: String] = [:]
        private var branches: [String: [String]] = [:]
        private var heads: [NodeID: String] = [:]
        private var snapshots: [URL: Observation] = [:]
        private(set) var operations: [Operation] = []
        private(set) var starts: [Observation] = []
        private(set) var creations: [Creation] = []
        private(set) var preparations: [Preparation] = []
        private(set) var removedSnapshots: [URL] = []

        /// A breakdown reads `main` through an unscoped snapshot; nothing else may.
        private let allowsBreakdowns: Bool

        init(root: URL, allowsBreakdowns: Bool = false) {
            self.root = root
            self.allowsBreakdowns = allowsBreakdowns
        }
        func moveMain(to commit: String) { main = commit }
        func seedBranch(_ name: String, commits: [String]) { branches[name] = commits }
        func seedLeaf(_ id: NodeID) { heads[id] = "candidate-\(id)" }
        func commits(on branch: String) -> [String] { branches[branch] ?? [] }

        func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? {
            let branch = "agentos/\(requirement.ticketKey)"
            preparations.append(Preparation(requirement: requirement, leaves: leaves))
            for id in leaves { bindings[id] = branch }
            guard branches[branch] == nil else { return nil }
            branches[branch] = [main]
            creations.append(Creation(branch: branch, from: main))
            return main
        }

        func catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String {
            let branch = "agentos/\(requirement.ticketKey)"
            guard branches[branch] != nil else {
                throw AgentFailure("Catch-up requires an existing requirement branch: \(branch)")
            }
            operations.append(Operation(action: .catchUp, node: requirement.nodeID, branch: branch))
            if branches[branch]?.contains(main) != true { branches[branch, default: []].append(main) }
            return main
        }

        func observation(in directory: URL) throws -> Observation {
            if let snapshot = snapshots[directory] { return snapshot }
            return Observation(node: directory.gh88Node, base: try base(for: directory.gh88Node),
                               commit: heads[directory.gh88Node] ?? main, snapshot: false)
        }
        private func base(for id: NodeID) throws -> String {
            guard let branch = bindings[id] else {
                throw AgentFailure("Missing requirement binding for \(id); call prepareRequirementBranch before using a leaf")
            }
            return branch
        }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            let branch = try base(for: id)
            let tip = try #require(branches[branch]?.last, "A requirement branch must exist before its leaf starts")
            operations.append(Operation(action: .start, node: id, branch: branch))
            heads[id] = tip
            starts.append(try observation(in: worktree(for: id)))
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let commit = "candidate-\(directory.gh88Node)"
            heads[directory.gh88Node] = commit
            return commit
        }
        func head(of directory: URL) async throws -> String { try observation(in: directory).commit }
        func changedFiles(in directory: URL) async throws -> [String] {
            let folder = directory.appending(path: testArea)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return files.map { testArea + $0.lastPathComponent + "/Acceptance.swift" }
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            operations.append(Operation(action: .rebase, node: directory.gh88Node, branch: try base(for: directory.gh88Node)))
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            let branch = try base(for: id)
            operations.append(Operation(action: .land, node: id, branch: branch))
            let commit = heads[id] ?? "candidate-\(id)"
            branches[branch, default: []].append(commit)
            return commit
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func createSnapshot(for id: NodeID) async throws -> URL? {
            try makeSnapshot(for: id, branch: base(for: id))
        }
        func createSnapshot() async throws -> URL? {
            if allowsBreakdowns { return nil }
            Issue.record("Landing diagnosis must request its leaf's requirement snapshot, not an unscoped snapshot")
            throw AgentFailure("Unscoped snapshots have no requirement binding")
        }
        private func makeSnapshot(for id: NodeID, branch: String) throws -> URL {
            let tip = try #require(branches[branch]?.last, "A snapshot must read an existing requirement branch")
            let directory = root.appending(path: "snapshots/\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            operations.append(Operation(action: .snapshot, node: id, branch: branch))
            snapshots[directory] = Observation(node: id, base: branch, commit: tip, snapshot: true)
            return directory
        }
        func removeSnapshot(_ directory: URL) async {
            removedSnapshots.append(directory)
            snapshots[directory] = nil
        }
    }

    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let node: NodeID
            let base: String
            let commit: String
            let snapshot: Bool
            let only: String?
        }
        let workspace: RecordingWorkspace
        let diagnose: Bool
        private(set) var calls: [Call] = []
        init(workspace: RecordingWorkspace, diagnose: Bool) { self.workspace = workspace; self.diagnose = diagnose }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            let observation: RecordingWorkspace.Observation
            do { observation = try await workspace.observation(in: directory) }
            catch {
                Issue.record("Checks ran without a requirement binding: \(error)")
                return CheckOutput(passed: false, summary: "\(error)", log: "\(error)")
            }
            calls.append(Call(node: observation.node, base: observation.base, commit: observation.commit,
                              snapshot: observation.snapshot, only: testTarget))
            let failed = diagnose && !observation.snapshot && testTarget == nil
            return CheckOutput(passed: !failed, summary: failed ? "Existing behavior failed" : "passed",
                               log: failed ? "ExistingBehaviorTests.example failed" : "1 test passed",
                               failingTargets: failed ? ["ExistingBehaviorTests"] : [])
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private(set) var comments: [String] = []
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("This fixture must not decompose work")
        }
        func comment(on key: String, _ text: String) async { comments.append(text) }
        func setStatus(of key: String, to status: String) async {}
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct Agents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("The fixture supplies its hierarchy explicitly")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "fixed acceptance fixture\n".write(to: folder.appending(path: "Acceptance.swift"),
                                                   atomically: true, encoding: .utf8)
            return AgentReport()
        }
        func implement(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
    }
}
