import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_104Tests {
    enum Tampering: CaseIterable, Sendable {
        case ownTests, otherTests, updatedOtherTests

        var position: Int {
            switch self {
            case .ownTests: 0
            case .otherTests: 1
            case .updatedOtherTests: 2
            }
        }

        var summary: String {
            switch self {
            case .ownTests: "Acceptance tests were changed after they were fixed"
            case .otherTests: "Changed other nodes' tests"
            case .updatedOtherTests: "Other work's tests the acceptance tests updated were changed afterwards"
            }
        }
    }

    final class Fixture: Sendable {
        static let parent = "wn-GH104"
        static let branch = "agentos/GH104"
        static let conflictFiles = ["Sources/Shared/Known.swift", "Sources/Unpredicted.swift"]
        let ids: [NodeID]
        let root: URL
        let ledger: Ledger
        let audit = Audit()
        let workspace: WorkspaceFake
        let tracker = TrackerFake()
        let checks: ChecksFake
        let reviewer: ReviewerFake
        let reconciler: Reconciler

        init(count: Int = 3, batchSize: Int = 4, review: ReviewLevel = .none,
             rejected: NodeID? = nil, human: NodeID? = nil, conflicting: NodeID? = nil,
             tampering: Tampering? = nil, authorizedUpdates: Bool = false) async throws {
            ids = Array(["wn-GH104-A", "wn-GH104-B", "wn-GH104-C", "wn-GH104-D"].prefix(count))
            root = FileManager.default.temporaryDirectory.appending(path: "GH104-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = WorkspaceFake(root: root, audit: audit, conflicting: conflicting)
            checks = ChecksFake(workspace: workspace, audit: audit)
            reviewer = ReviewerFake(rejected: rejected, audit: audit)
            var policy = Policy(maxParallelAgents: 4, guesswork: .autonomous, avoidOverlappingWork: false)
            policy.landingBatchSize = batchSize
            policy.review.level = review
            if let human { policy.review.areas["Sources/\(human).swift"] = .agentAndHuman }
            policy.infrastructureRetryDelays = []
            let unused = NoAgents()
            var team = AgentTeam(name: "GH104", decomposer: unused, testAuthor: unused, implementer: unused)
            team.reviewer = reviewer
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: checks,
                team: team,
                policy: policy
            )
            let parent = NodeSpec(id: Self.parent, parent: nil, kind: .composite, title: "Batch landing",
                                  intent: "Land independent changes together", acceptanceCriteria: ["Safe batch"])
            try await record(parent.id, [.nodeCreated(spec: parent, ticket: "GH104"), .phaseChanged(to: .split)])
            for (index, id) in ids.enumerated() {
                let spec = NodeSpec(
                    id: id, parent: parent.id, kind: .leaf, title: Self.ticket(id),
                    intent: "Independently landable change", acceptanceCriteria: ["Change is correct"],
                    touches: ["Sources/\(id).swift"], predictedPaths: ["Sources/Shared"]
                )
                let mode = tampering?.position == index ? tampering : nil
                let updatesOther = authorizedUpdates || mode == .updatedOtherTests
                try await workspace.seed(spec, tampering: mode, updatesOther: updatesOther)
                let directory = workspace.worktree(for: id)
                let digest = Hashing.digest(of: directory.appending(path: workspace.testFolder(for: spec)))
                var kinds: [EventKind] = [
                    .nodeCreated(spec: spec, ticket: Self.ticket(id)),
                    .testsFixed(digest: digest),
                ]
                if updatesOther {
                    let path = WorkspaceFake.otherPath(id)
                    kinds.append(.otherTestsUpdated(files: [path], digest: Hashing.digest(ofFiles: [path], in: directory)))
                }
                kinds += [.changeSubmitted(run: "builder", commit: "candidate-\(id)"), .phaseChanged(to: .landing)]
                try await record(id, kinds)
                let evidence = Evidence(
                    check: "own acceptance tests on branch", passed: true, summary: "Own acceptance tests passed",
                    specHash: spec.specHash, builtBy: "builder", checkedBy: "pre-checker",
                    artifactPath: "\(id)-precheck.log", artifactSHA256: Hashing.sha256(Data()),
                    commit: "candidate-\(id)"
                )
                try await record(id, [.evidenceRecorded(evidence)], by: .agent(run: "pre-checker", role: .verifier))
                try await record(id, [.gateOpened(.build)], by: .human("Developer"))
                await tracker.seed(spec)
            }
        }

        static func ticket(_ id: NodeID) -> String { String(id.dropFirst(3)) }

        func record(_ id: NodeID, _ kinds: [EventKind], by: Participant = .reconciler) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: by, kind: $0) })
        }

        func node(_ id: NodeID) async -> NodeState? { await ledger.workingState().nodes[id] }

        func round() async throws {
            let report = try await withHangGuard("GH104 landing round") {
                await self.reconciler.runRound(waitForAgents: true)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
        }

        func expectPassingBatch(_ members: [NodeID], allowingSingles: Bool = false) async throws {
            let calls = await checks.calls.filter { !allowingSingles || $0.batch }
            #expect(calls.count == 1, "The remaining nodes must be checked together once in this round")
            #expect(calls.first?.batch == true)
            #expect(calls.first?.nodes == members)
            #expect(calls.first?.only == nil)
            #expect(await workspace.batchLandings.contains(members))
            for id in members {
                let node = try #require(await node(id))
                #expect(node.phase == .proven)
                #expect(node.failedAttempts == 0)
                #expect(node.landedCommit != nil)
                #expect(await tracker.comments(on: Self.ticket(id)).contains { $0.contains("🛬 Landed") })
            }
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Cannot remove the GH104 fixture: \(error)") }
        }
    }

    actor Audit {
        private(set) var entries: [String] = []
        func record(_ entry: String) { entries.append(entry) }
    }

    actor ReviewerFake: Reviewer {
        static let finding = "Handle a missing queue entry before indexing it."
        let rejected: NodeID?
        let audit: Audit
        private(set) var requests: [ReviewRequest] = []

        init(rejected: NodeID?, audit: Audit) { self.rejected = rejected; self.audit = audit }

        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            requests.append(request)
            await audit.record("review:\(request.spec.id)")
            return ReviewResult(passed: request.spec.id != rejected,
                                findings: request.spec.id == rejected ? [Self.finding] : [])
        }
    }

    actor ChecksFake: CheckRunner {
        struct Call: Sendable {
            let batch: Bool
            let nodes: [NodeID]
            let only: String?
        }
        let workspace: WorkspaceFake
        let audit: Audit
        private(set) var calls: [Call] = []

        init(workspace: WorkspaceFake, audit: Audit) { self.workspace = workspace; self.audit = audit }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            do {
                let tree = try await workspace.tree(in: directory)
                calls.append(Call(batch: tree.batch, nodes: tree.nodes, only: testTarget))
                await audit.record("check:\(tree.nodes.joined(separator: ","))")
                return CheckOutput(passed: true, summary: "All candidate tests passed", log: "Test run with 3 tests passed")
            } catch {
                Issue.record("Checks used an unknown fixture directory: \(error)")
                return CheckOutput(passed: false, summary: "Unknown fixture directory", log: "\(error)")
            }
        }
    }

    actor TrackerFake: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var signals: [Signal] = []

        func seed(_ spec: NodeSpec) {
            let ticket = Fixture.ticket(spec.id)
            tickets[ticket] = Ticket(key: ticket, title: spec.title, description: spec.intent,
                                     acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Developer"))
        }
        func sendBuild(on ticket: String) {
            signals.append(Signal(ticket: ticket, command: .build, setBy: .human("Developer")))
        }
        func pendingSignals() async -> [Signal] { signals }
        func ticket(_ key: String) async -> Ticket? { tickets[key] }
        func consume(_ signal: Signal, reply: String) async {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            await comment(on: signal.ticket, reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH104 supplies its work tree")
        }
        func comment(on key: String, _ text: String) async {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func comments(on key: String) -> [String] { tickets[key]?.comments.map(\.text) ?? [] }
        func setStatus(of key: String, to status: String) async { tickets[key]?.status = status }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct NoAgents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH104 must not decompose work")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH104 starts with fixed tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH104 must inspect rework before another implementation starts")
        }
    }
}
