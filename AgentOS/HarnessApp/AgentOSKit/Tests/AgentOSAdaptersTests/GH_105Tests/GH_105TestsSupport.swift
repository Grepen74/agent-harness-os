import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

extension GH_105Tests {
    enum FailureOwner: CaseIterable, Sendable {
        case batchMember, otherSuite, unknown
        var targets: Set<String> {
            switch self {
            case .batchMember: ["GH_105_ATests"]
            case .otherSuite: ["ExistingBehaviorTests"]
            case .unknown: []
            }
        }
    }

    enum HoldPoint: CaseIterable, Sendable {
        case fullRerun, candidateSelection, baselineSelection
    }

    enum InfrastructureProblem: CaseIterable, Sendable {
        case rerunCrash, candidateCrash, baselineCrash, candidateEmpty, baselineEmpty, baselineFailure

        var full: [CheckOutput] {
            let failed = GH_105Tests.failure("initial-fail")
            return self == .rerunCrash
                ? [failed, GH_105Tests.crash("rerun-crash"), GH_105Tests.crash("rerun-crash-again")]
                : [failed, GH_105Tests.failure("full-fail-again")]
        }
        var candidate: CheckOutput {
            switch self {
            case .candidateCrash: GH_105Tests.crash("candidate-crash")
            case .candidateEmpty: CheckOutput(passed: true, summary: "empty-candidate", log: "Test run with 0 tests passed.")
            default: GH_105Tests.failure("candidate-fail")
            }
        }
        var baseline: CheckOutput {
            switch self {
            case .baselineCrash: GH_105Tests.crash("baseline-crash")
            case .baselineEmpty: CheckOutput(passed: true, summary: "empty-baseline", log: "Executed 0 tests")
            case .baselineFailure: GH_105Tests.failure("baseline-fail")
            default: GH_105Tests.pass("baseline-pass")
            }
        }
        var explanation: String {
            switch self {
            case .rerunCrash, .candidateCrash, .baselineCrash: "runner"
            case .candidateEmpty, .baselineEmpty: "tests"
            case .baselineFailure: "without"
            }
        }
    }

    static func pass(_ marker: String) -> CheckOutput {
        CheckOutput(passed: true, summary: marker, log: "\(marker)\nTest run with 1 test passed.")
    }
    static func failure(_ marker: String, targets: Set<String> = ["ExistingBehaviorTests"]) -> CheckOutput {
        CheckOutput(passed: false, summary: marker,
                    log: marker + "\n" + targets.sorted().map {
                        "Test Case '-[\($0) preservesBehavior]' failed"
                    }.joined(separator: "\n"),
                    failingTargets: targets)
    }
    static func crash(_ marker: String) -> CheckOutput {
        CheckOutput(passed: false, summary: marker, log: "\(marker): runner terminated by signal 5",
                    failureKind: .runnerCrash(signal: 5))
    }

    struct Fixture: Sendable {
        static let requirement = "wn-GH-105-requirement"
        static let memberIDs = ["GH-105-A", "GH-105-B", "GH-105-C"]
        static let latestRequirement = "latest-requirement-without-batch"
        let root: URL
        let store: FileLedgerStore
        let ledger: Ledger
        let tracker = RecordingTracker()
        let agents = RecordingAgents()
        let artifacts = RecordingArtifacts()
        let workspace: RecordingWorkspace
        let checks: ScriptedChecks
        let reconciler: Reconciler
        let batch: LandingBatchWorkspace
        let priorAttempts = ["GH-105-A": 0, "GH-105-B": 1, "GH-105-C": 2]
        init(
            full: [CheckOutput], selectedCandidate: CheckOutput = GH_105Tests.failure("candidate-fail"),
            selectedBaseline: CheckOutput = GH_105Tests.pass("baseline-pass"),
            hold: HoldPoint? = nil, seedBatch: Bool = true,
            move: BatchMove = .landed
        ) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH105-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = FileLedgerStore(fileURL: root.appending(path: "ledger.jsonl"))
            ledger = try Ledger(store: store)
            batch = LandingBatchWorkspace(
                directory: root.appending(path: "batch"), branch: "agentos/GH-105-requirement",
                baseCommit: "requirement-before-batch",
                candidateCommit: "member-C-in-batch", members: [
                    LandingBatchMember(node: Self.memberIDs[0], commit: "member-A-in-batch",
                                       changedFiles: ["Sources/A.swift"]),
                    LandingBatchMember(node: Self.memberIDs[1], commit: "member-B-in-batch",
                                       changedFiles: ["Sources/B.swift"]),
                    LandingBatchMember(node: Self.memberIDs[2], commit: "member-C-in-batch",
                                       changedFiles: ["Sources/C.swift"]),
                ]
            )
            workspace = RecordingWorkspace(root: root, batch: batch, move: move)
            checks = ScriptedChecks(
                workspace: workspace, agents: agents, full: full,
                candidate: selectedCandidate, baseline: selectedBaseline, hold: hold
            )
            var policy = Policy(maxAttempts: 8, maxParallelAgents: 6, guesswork: .autonomous)
            policy.avoidOverlappingWork = false
            policy.landingBatchSize = 4
            policy.infrastructureRetryDelays = []
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(), workspace: workspace, artifacts: artifacts,
                checks: checks,
                team: AgentTeam(name: "GH-105", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy
            )
            if seedBatch { try await self.seedBatch() }
        }

        func seedBatch() async throws {
            let requirement = NodeSpec(
                id: Self.requirement, parent: nil, kind: .composite, title: "Batch requirement",
                intent: "Land together", acceptanceCriteria: ["Diagnose quietly"]
            )
            try await ledger.append([
                LedgerEvent(node: requirement.id, by: .human("Developer"),
                            kind: .nodeCreated(spec: requirement, ticket: "GH-105-requirement")),
                LedgerEvent(node: requirement.id, by: .reconciler, kind: .requirementBranchCreated(
                    branch: batch.branch, from: batch.baseCommit
                )),
                LedgerEvent(node: requirement.id, by: .reconciler, kind: .phaseChanged(to: .split)),
            ])
            for member in batch.members {
                let spec = NodeSpec(
                    id: member.node, parent: requirement.id, kind: .leaf, title: member.node,
                    intent: "Land a finished change", acceptanceCriteria: ["Keep all members together"]
                )
                let folder = batch.directory.appending(path: workspace.testFolder(for: spec))
                for directory in [batch.directory, workspace.worktree(for: member.node)] {
                    let tests = directory.appending(path: workspace.testFolder(for: spec))
                    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
                    try "fixed acceptance fixture".write(
                        to: tests.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
                    )
                }
                var kinds: [EventKind] = [
                    .nodeCreated(spec: spec, ticket: member.node), .gateOpened(.build),
                    .testsFixed(digest: Hashing.digest(of: folder)),
                    .changeSubmitted(run: "builder-\(member.node)", commit: "original-\(member.node)"),
                    .phaseChanged(to: .landing),
                ]
                for index in 0..<(priorAttempts[member.node] ?? 0) {
                    kinds.append(.attemptFailed(summary: "prior failure \(index)"))
                }
                for kind in kinds {
                    let by: Participant
                    switch kind {
                    case .nodeCreated, .gateOpened: by = .human("Developer")
                    default: by = .reconciler
                    }
                    try await ledger.append([LedgerEvent(node: member.node, by: by, kind: kind)])
                }
            }
        }

        func addAgentNode(_ id: NodeID) async throws {
            let spec = NodeSpec(id: id, parent: nil, kind: .leaf, title: id, intent: "Other work",
                                acceptanceCriteria: ["May run outside diagnosis"])
            try await ledger.append([
                LedgerEvent(node: id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: id)),
                LedgerEvent(node: id, by: .human("Developer"), kind: .gateOpened(.build)),
            ])
        }

        func checkAndLand() async throws {
            defer { checks.finished.open() }
            try await withHangGuard("checking and diagnosing the batch through the landing queue") {
                var report = RoundReport()
                try await reconciler.drainLandingQueue(&report)
            }
        }

        func batchName() async throws -> String {
            try #require(await ledger.allRecords().compactMap(\.event.kind.landingBatchCheck).first?.name)
        }

        func drainingAgents(_ operation: () async throws -> Void) async throws {
            do {
                try await operation()
            } catch {
                agents.release.open()
                checks.release.open()
                await reconciler.shutdown(reason: "GH-105 fixture cleanup")
                throw error
            }
            agents.release.open()
            checks.release.open()
            await reconciler.shutdown(reason: "GH-105 fixture cleanup")
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH-105 fixture \(root.path): \(error)") }
        }
    }
}
