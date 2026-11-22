import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

extension GH_105Tests {
    enum BatchMove: CaseIterable, Sendable {
        case landed, waiting, branchMoved
    }

    struct CheckCall: Sendable {
        let directory: URL
        let selection: String?
        let commit: String
        let members: [NodeID]
        let activeAgents: Int
    }

    actor ScriptedChecks: CheckRunner {
        let workspace: RecordingWorkspace
        let agents: RecordingAgents
        let full: [CheckOutput]
        let candidate: CheckOutput
        let baseline: CheckOutput
        let hold: HoldPoint?
        nonisolated let held = TestGate()
        nonisolated let release = TestGate()
        nonisolated let finished = TestGate()
        private(set) var calls: [CheckCall] = []
        private var fullCalls = 0

        init(workspace: RecordingWorkspace, agents: RecordingAgents, full: [CheckOutput], candidate: CheckOutput,
             baseline: CheckOutput, hold: HoldPoint?) {
            self.workspace = workspace
            self.agents = agents
            self.full = full
            self.candidate = candidate
            self.baseline = baseline
            self.hold = hold
        }

        func runChecks(in directory: URL, only selection: String?) async -> CheckOutput {
            let activeAgents = await agents.active
            let isBaseline = directory == workspace.snapshot
            let observation = await workspace.observation(in: directory)
            calls.append(CheckCall(directory: directory, selection: selection,
                                   commit: observation.commit, members: observation.members, activeAgents: activeAgents))
            let point: HoldPoint?
            if selection == nil && directory == workspace.candidate {
                fullCalls += 1
                point = fullCalls == 2 ? .fullRerun : nil
            } else if selection != nil {
                point = isBaseline ? .baselineSelection : .candidateSelection
            } else {
                point = nil
            }
            if let hold, point == hold {
                held.open()
                do { try await release.wait() }
                catch { return GH_105Tests.crash("cancelled-fixture-check") }
            }
            if directory == workspace.candidate && selection == nil {
                guard fullCalls <= full.count else {
                    Issue.record("Unexpected extra full batch check")
                    return GH_105Tests.failure("unexpected-full-check")
                }
                // The baseline must be current when diagnosis takes its snapshot, not the batch's old base.
                if fullCalls >= 2 && !full[fullCalls - 1].passed { await workspace.advanceRequirement() }
                return full[fullCalls - 1]
            }
            guard selection != nil && (isBaseline || directory == workspace.candidate) else {
                return GH_105Tests.failure("unexpected-singleton-check")
            }
            return isBaseline ? baseline : candidate
        }
    }

    actor RecordingWorkspace: Workspace {
        enum Mutation: Sendable, Equatable {
            case landBatch([NodeID]), landSingle(NodeID), rebase, reset, commit
        }
        struct Snapshot: Sendable {
            let requirement: NodeID
            let commit: String
        }
        nonisolated let root: URL
        nonisolated let batch: LandingBatchWorkspace
        let move: BatchMove
        nonisolated var candidate: URL { batch.directory }
        nonisolated var snapshot: URL { root.appending(path: "latest-requirement") }
        private var requirementTip: String
        private var snapshotTip = ""
        private(set) var mutations: [Mutation] = []
        private(set) var snapshots: [Snapshot] = []
        private(set) var prepared: Set<URL> = []
        private(set) var removedSnapshots: Set<URL> = []
        private(set) var batchCreations: [[NodeID]] = []

        init(root: URL, batch: LandingBatchWorkspace, move: BatchMove) {
            self.root = root
            self.batch = batch
            self.move = move
            requirementTip = batch.baseCommit
        }
        func advanceRequirement() { requirementTip = Fixture.latestRequirement }
        func observation(in directory: URL) -> (commit: String, members: [NodeID]) {
            if directory == snapshot { return (snapshotTip, []) }
            if directory == candidate { return (batch.candidateCommit, batch.members.map(\.node)) }
            if let member = batch.members.first(where: { worktree(for: $0.node) == directory }) {
                return ("original-\(member.node)", [member.node])
            }
            return ("unrelated-work", [])
        }
        func prepare() async throws {}
        nonisolated var supportsLandingBatches: Bool { true }
        func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
            batchCreations.append(nodes)
            let members = batch.members.filter { nodes.contains($0.node) }
            guard let last = members.last else { throw AgentFailure("Cannot create an empty fixture batch") }
            return LandingBatchWorkspace(
                directory: candidate, branch: batch.branch, baseCommit: requirementTip,
                candidateCommit: last.commit, members: members
            )
        }
        func createLandingBatch(
            for nodes: [NodeID], validating: @escaping LandingBatchValidation
        ) async throws -> LandingBatchWorkspace {
            let candidate = try await createLandingBatch(for: nodes)
            for member in candidate.members { try await validating(candidate, member) }
            return candidate
        }
        func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
            mutations.append(.landBatch(batch.members.map(\.node)))
            switch move {
            case .landed:
                guard batch.baseCommit == requirementTip else { return .branchMoved }
                requirementTip = batch.candidateCommit
                return .landed
            case .waiting: return .waiting("The requirement branch is checked out in another working copy")
            case .branchMoved: return .branchMoved
            }
        }
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL {
            root.appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            mutations.append(.commit)
            return nil
        }
        func head(of directory: URL) async throws -> String { observation(in: directory).commit }
        func changedFiles(in directory: URL) async throws -> [String] { ["Sources/MemberChange.swift"] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            if directory == candidate { mutations.append(.rebase) }
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws { mutations.append(.reset) }
        func landOnMain(_ id: NodeID) async throws -> String {
            mutations.append(.landSingle(id))
            return "original-\(id)"
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws { prepared.insert(directory) }
        func createSnapshot(for id: NodeID) async throws -> URL? {
            snapshots.append(Snapshot(requirement: id, commit: requirementTip))
            snapshotTip = requirementTip
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            return snapshot
        }
        func createSnapshot() async throws -> URL? { nil }
        func removeSnapshot(_ directory: URL) async { removedSnapshots.insert(directory) }
    }

    actor RecordingTracker: TrackerAdapter {
        private var signals: [Signal] = []
        private var posted: [String: [String]] = [:]
        func requestPreview(_ ticket: String) {
            signals.append(Signal(ticket: ticket, command: .preview, setBy: .human("Developer")))
        }
        func pendingSignals() async -> [Signal] { signals }
        func ticket(_ key: String) async -> Ticket? {
            Ticket(key: key, title: key, description: key, acceptanceCriteria: ["Behavior"],
                   createdBy: .human("Developer"))
        }
        func consume(_ signal: Signal, reply: String) async {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            posted[signal.ticket, default: []].append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("The GH-105 fixture must not create child tickets")
        }
        func comment(on key: String, _ text: String) async { posted[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) async {}
        func comments(on key: String) -> [String] { posted[key, default: []] }
    }

    actor RecordingAgents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        nonisolated let stepStarted = TestGate()
        nonisolated let previewStarted = TestGate()
        nonisolated let release = TestGate()
        private(set) var started: Set<String> = []
        private(set) var active = 0
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            started.insert(request.identity.ticketKey)
            active += 1
            defer { active -= 1 }
            previewStarted.open()
            try await release.wait()
            throw AgentFailure("Fixture preview finished without adopting any work")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            started.insert(task.spec.id)
            active += 1
            defer { active -= 1 }
            stepStarted.open()
            try await release.wait()
            throw AgentFailure("Fixture step finished without submitting any work")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("No implementer is needed in a prebuilt batch fixture")
        }
    }

    final class RecordingArtifacts: ArtifactStore, Sendable {
        private let stored = Mutex<[String: Data]>([:])
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            stored.withLock { $0[name] = contents }
            return StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func contents(at path: String) -> Data? { stored.withLock { $0[path] } }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
