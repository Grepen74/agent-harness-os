import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_106Tests {
    enum DecisionKind { case split, ownersRemoved }

    struct Decision {
        let record: RecordedEvent
        let kind: DecisionKind
        let batch: String
        let first: [NodeID]
        let second: [NodeID]

        init?(_ record: RecordedEvent) {
            self.record = record
            switch record.event.kind {
            case .landingBatchSplit(let batch, let first, let second):
                kind = .split
                self.batch = batch
                self.first = first
                self.second = second
            case .landingBatchOwnersRemoved(let batch, let removed, let remaining):
                kind = .ownersRemoved
                self.batch = batch
                first = removed
                second = remaining
            default: return nil
            }
        }
    }

    enum Mode: String, Sendable, CaseIterable {
        case passing, owners, unowned, underLoad, disturbs, mixedOwnership, mixedUnknownOwnership
        case memberOwnedUnderLoad, memberOwnedDisturbs
        case ownRework, ownWithoutPrecheck, ownRerun, attemptLimit
        case requirementsConflict, infrastructure, emptySelection, runnerCrash, retryPasses
        case batchInfrastructure, batchEmptySelection

        static let singletonCases: [Mode] = [
            .ownRework, .ownWithoutPrecheck, .ownRerun, .attemptLimit, .disturbs,
            .requirementsConflict, .mixedOwnership, .infrastructure, .emptySelection, .runnerCrash, .underLoad, .retryPasses,
        ]

        var commentMarkers: [String] {
            switch self {
            case .ownRework: ["own mistake", "rework the candidate"]
            case .mixedOwnership: ["own mistake", "rework the candidate"]
            case .ownWithoutPrecheck: ["Landing check failed", "own mistake"]
            case .ownRerun: ["Landing rerun failed", "own mistake"]
            case .attemptLimit: ["Landing rerun failed", "limit 1"]
            case .disturbs: ["own mistake", "disturbs them", "rework the candidate"]
            case .requirementsConflict: ["Requirements conflict:", "harness:retry"]
            case .infrastructure: ["Landing infrastructure problem:", "No failed attempt counted", "harness:retry"]
            case .emptySelection: ["Landing infrastructure problem:", "ran none of those tests", "harness:retry"]
            case .runnerCrash: ["Runner crash repeated after one retry:", "harness:retry"]
            case .underLoad: ["Unreliable tests or interference under load", "No failed attempt", "harness:retry"]
            case .retryPasses: ["Unreliable test:", "Landed"]
            default: []
            }
        }
    }

    final class Fixture: Sendable {
        static let requirementID = "wn-GH-106-requirement"
        static let provenID = "wn-Established-Behavior"
        static let badID = "wn-Candidate-Bad"
        let root: URL
        let ids: [NodeID]
        var bad: NodeID { Self.badID }
        let ledger: Ledger
        let tracker: RecordingTracker
        let workspace: RecordingWorkspace
        let checks: RecordingChecks
        let reconciler: Reconciler

        init(mode: Mode, count: Int, batchSize: Int = 8) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-106-\(UUID())")
            ids = (0..<(count - 1)).map { "wn-Candidate-\($0)" } + [Self.badID]
            ledger = try Ledger()
            tracker = RecordingTracker()
            workspace = RecordingWorkspace(root: root)
            checks = RecordingChecks(mode: mode, ids: ids, workspace: workspace, ledger: ledger, tracker: tracker)
            let unused = Unused()
            var policy = Policy(maxAttempts: mode == .attemptLimit ? 1 : 3, maxParallelAgents: 1,
                                guesswork: .autonomous)
            policy.landingBatchSize = batchSize
            policy.infrastructureRetryDelays = []
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: unused, workspace: workspace,
                artifacts: Artifacts(), checks: checks,
                team: AgentTeam(name: "GH-106", decomposer: unused, testAuthor: unused, implementer: unused),
                policy: policy
            )
            let requirement = NodeSpec(
                id: Self.requirementID, parent: nil, kind: .composite, title: "Batch requirement",
                intent: "Land independent candidates", acceptanceCriteria: ["Passing work lands"]
            )
            let proven = Self.spec(Self.provenID, parent: nil)
            try await ledger.append([
                LedgerEvent(node: requirement.id, by: .human("Developer"),
                            kind: .nodeCreated(spec: requirement, ticket: "GH-106-REQ")),
                LedgerEvent(node: requirement.id, by: .reconciler, kind: .phaseChanged(to: .split)),
                LedgerEvent(node: proven.id, by: .human("Developer"),
                            kind: .nodeCreated(spec: proven, ticket: proven.id)),
                LedgerEvent(node: proven.id, by: .reconciler, kind: .landed(commit: "established-commit")),
                LedgerEvent(node: proven.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            ])
            for id in ids {
                let spec = Self.spec(id, parent: requirement.id)
                try await workspace.seed(spec)
                let directory = workspace.worktree(for: id)
                let digest = Hashing.digest(of: directory.appending(path: workspace.testFolder(for: spec)))
                var events: [LedgerEvent] = [
                    LedgerEvent(node: id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: id)),
                    LedgerEvent(node: id, by: .human("Developer"), kind: .gateOpened(.build)),
                    LedgerEvent(node: id, by: .reconciler, kind: .testsFixed(digest: digest)),
                    LedgerEvent(node: id, by: .agent(run: "builder-\(id)", role: .implementer),
                                kind: .changeSubmitted(run: "builder-\(id)", commit: Self.commit(id))),
                ]
                if mode != .ownWithoutPrecheck {
                    let evidence = Self.evidence(spec)
                    events.append(LedgerEvent(node: id, by: .agent(run: evidence.checkedBy, role: .verifier),
                                              kind: .evidenceRecorded(evidence)))
                }
                if (mode == .ownRerun || mode == .attemptLimit) && id == Self.badID {
                    var failed = Self.evidence(spec)
                    failed.check = "all tests on latest agentos/GH-106-REQ (landing)"
                    failed.passed = false
                    failed.summary = "Previous landing failure"
                    failed.failureClassification = .ownMistake
                    events += [
                        LedgerEvent(node: id, by: .agent(run: failed.checkedBy, role: .verifier),
                                    kind: .landingReworkNeeded(failed)),
                        LedgerEvent(node: id, by: .reconciler, kind: .landingRerunRequested(run: "reworker")),
                    ]
                }
                events.append(LedgerEvent(node: id, by: .reconciler, kind: .phaseChanged(to: .landing)))
                try await ledger.append(events)
            }
        }

        static func spec(_ id: NodeID, parent: NodeID?) -> NodeSpec {
            NodeSpec(id: id, parent: parent, kind: .leaf, title: id, intent: "Candidate behavior",
                     acceptanceCriteria: ["The candidate preserves established behavior"],
                     touches: ["Component-\(id)"])
        }

        static func commit(_ id: NodeID) -> String { "commit-\(id)" }

        private static func evidence(_ spec: NodeSpec) -> Evidence {
            Evidence(check: "own acceptance tests on branch", passed: true, summary: "Own tests passed",
                     specHash: spec.specHash, builtBy: "builder-\(spec.id)", checkedBy: "prechecker",
                     artifactPath: "precheck.log", artifactSHA256: Hashing.sha256(Data()),
                     commit: commit(spec.id))
        }

        func round() async throws {
            let report = try await withHangGuard("the GH-106 landing round") {
                await self.reconciler.runRound(waitForAgents: true)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
        }

        func decisions(for batch: String, kind: DecisionKind) async -> [Decision] {
            await ledger.allRecords().compactMap(Decision.init).filter { $0.batch == batch && $0.kind == kind }
        }

        func batchCheck(for nodes: [NodeID]) async throws -> LandingBatchCheck {
            try #require(await ledger.allRecords().compactMap { $0.event.kind.landingBatchCheck }
                .first { $0.nodes == nodes }, "Record a check of the combined candidate \(nodes)")
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove the GH-106 fixture: \(error)") }
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var messages: [String: [String]] = [:]
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("Landing must not create child tickets")
        }
        func comment(on key: String, _ text: String) async { messages[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) async {}
        func comments(on key: String) -> [String] { messages[key, default: []] }
        func landedIDs() -> Set<NodeID> {
            Set(messages.compactMap { key, values in values.contains { $0.contains("Landed") } ? key : nil })
        }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct Unused: Decomposer, TestAuthor, AgentOSCore.Implementer, ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("The fixture supplies its hierarchy")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("The fixture starts with fixed tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("The landing round must not restart implementation")
        }
    }
}
