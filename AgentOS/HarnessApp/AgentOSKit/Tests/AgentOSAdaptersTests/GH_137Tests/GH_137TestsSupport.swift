import AgentOSSimulation
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

extension GH_137Tests {
    static let node = "wn-GH-137"
    static let other = "wn-GH-137-other"
    static let run = "run-being-observed"

    enum RunPoint: CaseIterable, Sendable {
        case breakdown, testAuthoring, implementation, ownChecks, landing, finalVerification

        var role: AgentRole {
            switch self {
            case .breakdown: .decomposer
            case .testAuthoring: .testAuthor
            case .implementation: .implementer
            case .ownChecks, .landing, .finalVerification: .verifier
            }
        }

        var stage: WorkflowStageID {
            switch self {
            case .breakdown: .breakdown
            case .testAuthoring: .testAuthoring
            case .implementation: .implementation
            case .ownChecks: .ownChecks
            case .landing: .landing
            case .finalVerification: .finalVerification
            }
        }
    }

    /// The reusable scenario ledgers both scenario tests replay, made once per test process. Each scenario is a real
    /// reconciler run with git; in a loaded full suite the six together took over two minutes, so each scenario has
    /// its own hang guard rather than one for all of them.
    static func scenarioLedgers() async throws -> [WorkflowScenarioLedger] {
        try await ScenarioLedgers.shared.value()
    }

    static var scenarios: [WorkflowScenario] {
        [.epicToProven, .smallTicketAsLeaf, .failureEscalationRetry, .catchUpConflict, .brokenTestReport, .batchSplit]
    }

    static func spec(_ id: NodeID = node, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(id: id, parent: nil, kind: kind, title: "Observable workflow",
                 intent: "Show current work without changing it",
                 acceptanceCriteria: ["The current stage follows the ledger"], touches: ["Feature"])
    }

    static func creation(_ id: NodeID = node, kind: NodeKind = .leaf) -> LedgerEvent {
        Self.event(.nodeCreated(spec: Self.spec(id, kind: kind), ticket: id), node: id)
    }

    static func event(_ kind: EventKind, node id: NodeID? = node) -> LedgerEvent {
        LedgerEvent(node: id, by: .reconciler, kind: kind, at: Date(timeIntervalSince1970: 1_000))
    }

    static func records(_ events: [LedgerEvent]) -> [RecordedEvent] {
        var previous = RecordedEvent.genesisHash
        return events.enumerated().map { position, event in
            let record = RecordedEvent(position: position, event: event, previousHash: previous)
            previous = record.hash
            return record
        }
    }

    static func state(after records: [RecordedEvent]) -> WorkingState {
        var state = WorkingState()
        for record in records { state.apply(record) }
        return state
    }

    static func runningRecords(at point: RunPoint) -> [RecordedEvent] {
        var events = [Self.creation(kind: point == .breakdown ? .composite : .leaf)]
        switch point {
        case .breakdown, .testAuthoring:
            break
        case .implementation:
            events += [Self.event(.testsFixed(digest: "tests")), Self.event(.phaseChanged(to: .building))]
        case .ownChecks:
            events += [
                Self.event(.changeSubmitted(run: "builder", commit: "candidate")),
                Self.event(.phaseChanged(to: .checking)),
            ]
        case .landing:
            events += [
                Self.event(.changeSubmitted(run: "builder", commit: "candidate")),
                Self.event(.phaseChanged(to: .landing)),
            ]
        case .finalVerification:
            events += [
                Self.event(.landed(commit: "requirement-tip")),
                Self.event(.phaseChanged(to: .proven)),
                Self.event(.requirementVerificationStarted),
            ]
        }
        events.append(Self.event(.runStarted(run: Self.run, role: point.role)))
        return Self.records(events)
    }

    static func review(_ stage: ReviewStage) -> ReviewRecord {
        ReviewRecord(stage: stage, result: ReviewResult(passed: true, findings: []),
                     commit: "candidate", uiEvidence: nil)
    }

    static var previewEvents: [LedgerEvent] {
        [
            Self.event(.previewStarted(ticket: "GH-137", node: Self.node, run: "preview"), node: nil),
            Self.event(.previewRecorded(ticket: "GH-137", number: 1,
                                        specHash: Self.spec().specHash, proposal: [Self.spec()]), node: nil),
            Self.event(.previewFinished(ticket: "GH-137", run: "preview", outcome: "posted"), node: nil),
        ]
    }

    static var batchEvents: [LedgerEvent] {
        [
            Self.event(.landingBatchChecked(LandingBatchCheck(
                name: "batch", branch: "batch-branch", nodes: [Self.node, Self.other],
                candidateCommit: "combined", passed: false, run: "batch-checker")), node: nil),
            Self.event(.landingBatchSplit(batch: "batch", first: [Self.node], second: [Self.other]), node: nil),
        ]
    }

    struct ReplayResult {
        var snapshots: [[NodeID: WorkflowStageID]] = []
        var problems: [String] = []
        var invalidPositions: [Int] = []
    }

    static func replay(
        _ records: [RecordedEvent],
        classify: (NodeID, WorkingState) -> WorkflowStageID?,
        permits: (WorkflowStageID, WorkflowStageID) -> Bool
    ) -> ReplayResult {
        var state = WorkingState()
        var previous: [NodeID: WorkflowStageID] = [:]
        var result = ReplayResult()
        for record in records {
            state.apply(record)
            var current: [NodeID: WorkflowStageID] = [:]
            // Deliberately visit all current nodes, including for preview and batch events with no node.
            for id in state.creationOrder {
                guard let stage = classify(id, state) else {
                    result.problems.append("event \(record.position) \(record.event.kind.summary): no stage for \(id)")
                    result.invalidPositions.append(record.position)
                    continue
                }
                current[id] = stage
                if let before = previous[id], before != stage, !permits(before, stage) {
                    result.problems.append("event \(record.position) \(record.event.kind.summary): \(id) \(before) -> \(stage)")
                    result.invalidPositions.append(record.position)
                }
            }
            result.snapshots.append(current)
            previous = current
        }
        return result
    }

    static func checkScenario(_ scenario: WorkflowScenario, records: [RecordedEvent]) throws {
        let final = Self.state(after: records)
        try #require(!final.nodes.isEmpty)
        switch scenario {
        case .epicToProven:
            let root = try #require(final.roots.first { $0.spec.kind == .composite })
            let descendants = final.subtree(of: root.id)
            #expect(descendants.contains { $0.spec.kind == .leaf })
            #expect(descendants.allSatisfy { $0.phase == .proven })
        case .smallTicketAsLeaf:
            let root = try #require(final.roots.first { $0.spec.kind == .leaf })
            #expect(root.children.isEmpty)
            #expect(root.testsDigest != nil)
            #expect(records.contains {
                guard $0.event.node == root.id else { return false }
                if case .becameLeaf = $0.event.kind { return true }
                return false
            })
        case .failureEscalationRetry:
            let escalation = try #require(records.first {
                if case .flagSet(.escalated, _) = $0.event.kind { return true }
                return false
            })
            let id = try #require(escalation.event.node)
            #expect(records.contains {
                guard $0.event.node == id, $0.position < escalation.position else { return false }
                switch $0.event.kind {
                case .attemptFailed: return true
                case .evidenceRecorded(let evidence): return !evidence.passed
                default: return false
                }
            })
            let retry = try #require(records.first {
                guard $0.event.node == id, $0.position > escalation.position, $0.event.by.isHuman else { return false }
                if case .signalAccepted(_, .retry, _) = $0.event.kind { return true }
                return false
            })
            #expect(records.contains {
                guard $0.event.node == id, $0.position > retry.position else { return false }
                if case .runStarted = $0.event.kind { return true }
                return false
            })
            #expect(final.nodes[id]?.flags[.escalated] == nil)
            #expect(final.nodes[id]?.phase == .proven)
        case .catchUpConflict:
            let conflict = try #require(records.first {
                switch $0.event.kind {
                case .requirementCatchUpConflicted, .catchUpConflicted: true
                default: false
                }
            })
            let held = Self.state(after: records.filter { $0.position <= conflict.position })
            #expect(held.catchUpConflict != nil || held.nodes.values.contains { $0.catchUpConflict != nil })
        case .brokenTestReport:
            let report = try #require(records.first {
                if case .brokenTestReported = $0.event.kind { return true }
                return false
            })
            let id = try #require(report.event.node)
            let routed = try #require(records.first {
                guard $0.event.node == id, $0.position > report.position else { return false }
                if case .brokenTestRouted(_, .sentBackToTestAuthor) = $0.event.kind { return true }
                return false
            })
            #expect(records.contains {
                guard $0.event.node == id, $0.position > routed.position else { return false }
                if case .runStarted(_, .testAuthor) = $0.event.kind { return true }
                return false
            })
        case .batchSplit:
            let split = try #require(records.first {
                if case .landingBatchSplit = $0.event.kind { return true }
                return false
            })
            if case .landingBatchSplit(let name, let first, let second) = split.event.kind {
                try #require(!first.isEmpty && !second.isEmpty)
                #expect(Set(first).isDisjoint(with: second))
                let failed = try #require(records.first {
                    guard $0.position < split.position,
                          case .landingBatchChecked(let check) = $0.event.kind else { return false }
                    return check.name == name && !check.passed && Set(check.nodes) == Set(first + second)
                })
                let state = Self.state(after: records.filter { $0.position <= failed.position })
                #expect((first + second).allSatisfy { state.nodes[$0]?.phase == .landing })
            }
        default:
            break
        }
    }
}

private actor ScenarioLedgers {
    static let shared = ScenarioLedgers()
    private var production: Task<[WorkflowScenarioLedger], Error>?

    func value() async throws -> [WorkflowScenarioLedger] {
        if let production { return try await production.value }
        // What `WorkflowScenarioFixtures.ledgers()` does, one guard per scenario so a hang is caught and named
        // within one budget however many scenarios there are.
        let task = Task {
            var ledgers: [WorkflowScenarioLedger] = []
            for scenario in WorkflowScenario.allCases {
                ledgers.append(try await withHangGuard("producing the \(scenario) workflow scenario ledger") {
                    try await WorkflowScenarioFixtures.ledger(for: scenario)
                })
            }
            return ledgers
        }
        production = task
        return try await task.value
    }
}
