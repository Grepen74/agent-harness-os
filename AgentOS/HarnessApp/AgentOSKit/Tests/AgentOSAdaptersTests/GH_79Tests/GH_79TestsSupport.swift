import Foundation
import Testing
import AgentOSCore

extension GH_79Tests {
    static var repository: URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { directory.deleteLastPathComponent() }
        return directory
    }

    static let conflictingFiles = [
        "Sources/Engine/One.swift", "Sources/Engine/Two.swift",
        "Sources/EngineExtra/Neighbor.swift", "README.md", "Sources/Engine/One.swift",
    ]

    enum PredictionShape: CaseIterable, Sendable {
        case absent, empty, directory, directoryWithoutSlash, exactFiles

        var paths: [String]? {
            switch self {
            case .absent: nil
            case .empty: []
            case .directory: ["Sources/Engine/", "README.md"]
            case .directoryWithoutSlash: ["Sources/Engine", "README.md"]
            case .exactFiles: ["Sources/Engine/One.swift", "README.md"]
            }
        }

        var additions: [String] {
            switch self {
            case .absent, .empty:
                ["Sources/Engine/One.swift", "Sources/Engine/Two.swift", "Sources/EngineExtra/Neighbor.swift", "README.md"]
            case .directory, .directoryWithoutSlash:
                ["Sources/EngineExtra/Neighbor.swift"]
            case .exactFiles:
                ["Sources/Engine/Two.swift", "Sources/EngineExtra/Neighbor.swift"]
            }
        }
    }

    enum ProgressStage: CaseIterable, Sendable {
        case building, checking, landing, review
    }

    static func replay(_ records: [RecordedEvent]) throws -> Ledger {
        let decoded = try JSONDecoder().decode([RecordedEvent].self, from: JSONEncoder().encode(records))
        let store = InMemoryLedgerStore()
        store.append(decoded)
        return try Ledger(store: store)
    }

    final class Fixture: Sendable {
        let directory: URL
        let ledger: Ledger
        let workspace: MemoryWorkspace
        let reconciler: Reconciler

        init() throws {
            directory = GH_79Tests.repository.appending(path: ".agentos/scratch/run-d455d5/GH-79-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = MemoryWorkspace(root: directory, ledger: ledger)
            let agents = Agents(workspace: workspace)
            var policy = Policy(maxParallelAgents: 4, guesswork: .autonomous)
            policy.avoidOverlappingWork = true
            reconciler = Reconciler(
                ledger: ledger, tracker: Tracker(), external: NoExternalDependencies(),
                workspace: workspace, artifacts: Artifacts(), checks: Checks(),
                team: AgentTeam(name: "GH-79", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy
            )
        }

        func leaf(
            _ key: String, predictions: [String]?, implementations: [[String]] = [["Sources/Implementation.swift"]],
            touches: [String] = ["Engine"],
            phase: Phase = .ready, buildAllowed: Bool = true,
            alreadySatisfied: Bool = false, includeTestInDiff: Bool = true
        ) async throws -> NodeSpec {
            var spec = NodeSpec(
                id: "wn-\(key)", parent: nil, kind: .leaf, title: key, intent: "GH-79 acceptance fixture",
                acceptanceCriteria: ["Changes are checked and landed"], touches: touches
            )
            spec.predictedPaths = predictions ?? []
            let folder = workspace.worktree(for: spec.id).appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "// GH-79 fixture acceptance tests\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            let test = workspace.testFolder(for: spec) + "/Acceptance.swift"
            await workspace.register(
                spec.id, files: implementations.map { (includeTestInDiff ? [test] : []) + $0 },
                alreadySatisfied: alreadySatisfied
            )
            var kinds: [EventKind] = [
                .nodeCreated(spec: spec, ticket: key),
                .testsFixed(digest: Hashing.digest(of: folder)),
            ]
            if phase == .landing {
                kinds.append(.changeSubmitted(run: "seed-\(key)", commit: "seed-candidate-\(key)"))
            }
            kinds.append(.phaseChanged(to: phase))
            try await ledger.append(kinds.map { LedgerEvent(node: spec.id, by: .reconciler, kind: $0) })
            if buildAllowed { try await openBuildGate(spec) }
            return spec
        }

        func openBuildGate(_ spec: NodeSpec) async throws {
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Reviewer"), kind: .gateOpened(.build)),
            ])
        }

        func until(waiting: Bool = true, _ predicate: (WorkingState) -> Bool) async throws -> WorkingState {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            repeat {
                let report = await reconciler.runRound(waitForAgents: waiting)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                await reconciler.waitForAgents()
                let state = await ledger.workingState()
                if predicate(state) { return state }
                if report.isIdle {
                    throw AgentFailure("Reconciliation became idle before the expected ledger outcome")
                }
            } while ContinuousClock.now < deadline
            throw AgentFailure("Timed out waiting for the expected ledger outcome")
        }

        func conflict(_ spec: NodeSpec, files: [String]) async throws {
            let count = await ledger.workingState().nodes[spec.id]?.reworks ?? 0
            await workspace.setConflict(files, for: spec.id)
            _ = try await until { ($0.nodes[spec.id]?.reworks ?? 0) > count }
        }

        func holdInProgress(_ spec: NodeSpec, at stage: ProgressStage) async throws {
            let phase: Phase
            switch stage {
            case .building: phase = .building
            case .checking: phase = .checking
            case .landing, .review: phase = .landing
            }
            var kinds: [EventKind] = [.phaseChanged(to: phase)]
            if stage == .review {
                let commit = try #require(await ledger.workingState().nodes[spec.id]?.lastSubmission?.commit)
                kinds.append(.humanReviewRequested(commit: commit))
            } else {
                kinds.append(.runStarted(
                    run: "in-progress-\(spec.id)", role: stage == .building ? .implementer : .verifier
                ))
            }
            try await ledger.append(kinds.map { LedgerEvent(node: spec.id, by: .reconciler, kind: $0) })
        }

        func finishInProgress(_ spec: NodeSpec) async throws {
            let node = try #require(await ledger.workingState().nodes[spec.id])
            var events: [LedgerEvent] = []
            if let run = node.activeRun {
                events.append(LedgerEvent(
                    node: spec.id, by: .reconciler, kind: .runFinished(run: run.run, outcome: "finished")
                ))
            }
            if let commit = node.pendingHumanReview {
                events.append(LedgerEvent(
                    node: spec.id, by: .human("Reviewer"), kind: .humanReviewApproved(commit: commit)
                ))
            }
            events.append(LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .proven)))
            try await ledger.append(events)
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-79 fixture files: \(error)") }
        }
    }

    actor MemoryWorkspace: Workspace {
        struct Branch: Sendable {
            var submissions: [[String]]
            var alreadySatisfied: Bool
            var starts = 0
            var commits = 0
            var files: [String] = []
        }

        nonisolated let root: URL
        private let ledger: Ledger
        private var branches: [NodeID: Branch] = [:]
        private var conflicts: [NodeID: [String]] = [:]
        private(set) var diffQueries: [URL] = []
        private(set) var resets: [NodeID] = []

        init(root: URL, ledger: Ledger) {
            self.root = root
            self.ledger = ledger
        }
        func register(_ id: NodeID, files: [[String]], alreadySatisfied: Bool) {
            branches[id] = Branch(submissions: files, alreadySatisfied: alreadySatisfied)
        }
        func starts(for id: NodeID) -> Int { branches[id]?.starts ?? 0 }
        func setFiles(_ files: [String], for id: NodeID) throws {
            try #require(branches[id] != nil)
            branches[id]?.files = files
        }
        func implement(_ id: NodeID) throws -> AgentReport {
            var branch = try #require(branches[id])
            try #require(!branch.submissions.isEmpty, "The fixture needs at least one branch diff")
            let index = min(branch.starts, branch.submissions.count - 1)
            branch.files = branch.submissions[index]
            branch.starts += 1
            branches[id] = branch
            return AgentReport(alreadySatisfied: branch.alreadySatisfied)
        }
        func setConflict(_ files: [String], for id: NodeID) { conflicts[id] = files }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let id = directory.lastPathComponent
            let branch = try #require(branches[id])
            if branch.alreadySatisfied { return nil }
            branches[id]?.commits += 1
            return try await head(of: directory)
        }
        func head(of directory: URL) async throws -> String {
            let branch = try #require(branches[directory.lastPathComponent])
            return "candidate-\(directory.lastPathComponent)-\(branch.commits)"
        }
        func changedFiles(in directory: URL) async throws -> [String] {
            diffQueries.append(directory)
            return try #require(branches[directory.lastPathComponent]).files
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            let id = directory.lastPathComponent
            if await ledger.workingState().nodes[id]?.phase == .landing,
               let files = conflicts.removeValue(forKey: id) {
                return .conflict(files: files)
            }
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            resets.append(directory.lastPathComponent)
            branches[directory.lastPathComponent]?.files = []
        }
        func landOnMain(_ id: NodeID) async throws -> String { "landed-\(id)" }
        nonisolated func existingComponents() -> [String] { ["Engine"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct Agents: Decomposer, TestAuthor, Implementer {
        let workspace: MemoryWorkspace
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-79 fixtures already have leaf specifications")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-79 fixtures already have fixed acceptance tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            try await workspace.implement(task.spec.id)
        }
    }

    actor Tracker: TrackerAdapter {
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("GH-79 fixtures do not create tracker tickets")
        }
        func comment(on key: String, _ text: String) {}
        func setStatus(of key: String, to status: String) {}
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "GH-79 fixture checks passed", log: "ok")
        }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
