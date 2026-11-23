// API contract: WorkflowCatalog.standard.currentStage(of:in:) maps a node in WorkingState
// to WorkflowNodeStage (stage: WorkflowStageID, interrupted: Bool), without a ledger dependency.
// Catalog transitions expose from/to stage IDs. WorkflowScenarioFixtures.ledgers() exposes
// named scenario records through AgentOSSimulation, shared with AgentOSSimulationTests.
// Source-only part of criterion 4: fixture placement/reuse in AgentOSSimulationTests and the
// organization of simulation scripting are reviewed in the diff, not by reading source text.
import AgentOSSimulation
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

@Suite struct GH_137Tests {
    @Test(arguments: RunPoint.allCases)
    func currentCatalogStageComesFromTheReplayedWorkingState(point: RunPoint) throws {
        let state = Self.state(after: Self.runningRecords(at: point))
        let current = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: state))
        #expect(current.stage == point.stage)
        #expect(!current.interrupted)
    }

    @Test
    func computingStagesForSeveralNodesNeverAppendsLedgerEvents() async throws {
        let ledger = try Ledger()
        try await ledger.append([
            Self.creation(),
            Self.event(.phaseChanged(to: .building)),
            Self.event(.runStarted(run: "builder", role: .implementer)),
            Self.creation(Self.other),
            Self.event(.phaseChanged(to: .checking), node: Self.other),
            Self.event(.runStarted(run: "checker", role: .verifier), node: Self.other),
        ])
        let before = await ledger.allRecords()
        let state = await ledger.workingState()
        for _ in 0..<3 {
            let building = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: state))
            let checking = try #require(WorkflowCatalog.standard.currentStage(of: Self.other, in: state))
            #expect(building.stage == .implementation)
            #expect(checking.stage == .ownChecks)
        }
        #expect(await ledger.allRecords().map(\.hash) == before.map(\.hash))
        #expect(await ledger.workingState().asOf == state.asOf)
        #expect(await ledger.workingState().nodes[Self.node]?.version == state.nodes[Self.node]?.version)
        #expect(await ledger.workingState().nodes[Self.other]?.version == state.nodes[Self.other]?.version)
    }

    @Test
    func aRunningAcceptanceReviewIsStillTestAuthoring() throws {
        // Re-authoring may already have an earlier tests digest. No review-start event exists.
        let records = Self.records([
            Self.creation(),
            Self.event(.testsFixed(digest: "earlier-tests")),
            Self.event(.runStarted(run: Self.run, role: .testAuthor)),
        ])
        var state = Self.state(after: records)
        let duringReview = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: state))
        #expect(duringReview.stage == .testAuthoring)
        #expect(!duringReview.interrupted)

        let completedReview = Self.records(records.map(\.event) + [
            Self.event(.reviewRecorded(Self.review(.acceptanceTests))),
        ])
        state = Self.state(after: completedReview)
        #expect(WorkflowCatalog.standard.currentStage(of: Self.node, in: state)?.stage == .testAuthoring)
    }

    @Test
    func aRunningChangeReviewIsStillLanding() throws {
        let records = Self.runningRecords(at: .landing)
        var state = Self.state(after: records)
        let duringReview = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: state))
        #expect(duringReview.stage == .landing)
        #expect(!duringReview.interrupted)

        state = Self.state(after: Self.records(records.map(\.event) + [
            Self.event(.reviewRecorded(Self.review(.change))),
        ]))
        #expect(WorkflowCatalog.standard.currentStage(of: Self.node, in: state)?.stage == .landing)
    }

    @Test(arguments: RunPoint.allCases)
    func anAbandonedRunRetainsItsStageUntilThisNodeStartsAnotherRun(point: RunPoint) throws {
        var events = Self.runningRecords(at: point).map(\.event)
        events.append(Self.event(.runFinished(run: Self.run, outcome: "abandoned: claim expired (harness restarted)")))
        if point == .implementation {
            // This is the durable recovery sequence, not a phase invented by the test.
            events.append(Self.event(.phaseChanged(to: .ready)))
        }
        events += [
            Self.event(.actualChangedFilesRecorded(files: ["Sources/Feature.swift"])),
            Self.creation(Self.other),
            Self.event(.runStarted(run: "unrelated-run", role: .implementer), node: Self.other),
        ]
        let recovered = Self.state(after: Self.records(events))
        #expect(recovered.nodes[Self.node]?.activeRun == nil)
        let interrupted = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: recovered))
        #expect(interrupted.stage == point.stage)
        #expect(interrupted.interrupted)

        events.append(Self.event(.runStarted(run: "replacement-run", role: point.role)))
        let restarted = Self.state(after: Self.records(events))
        let current = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: restarted))
        #expect(!current.interrupted, "A new run on this node retires the old interruption")

        events.append(Self.event(.runFinished(run: "replacement-run", outcome: "completed")))
        let completed = Self.state(after: Self.records(events))
        #expect(WorkflowCatalog.standard.currentStage(of: Self.node, in: completed)?.interrupted == false,
                "The old abandoned run must not become current again when its replacement finishes")
    }

    @Test(arguments: ["completed", "failed: agent exited"])
    func aRunThatWasNotAbandonedIsNotMarkedInterrupted(outcome: String) throws {
        let records = Self.records(Self.runningRecords(at: .implementation).map(\.event) + [
            Self.event(.runFinished(run: Self.run, outcome: outcome)),
            Self.event(.phaseChanged(to: .ready)),
        ])
        let current = try #require(WorkflowCatalog.standard.currentStage(of: Self.node, in: Self.state(after: records)))
        #expect(!current.interrupted)
    }

    @Test
    func reusableScenarioLedgersContainTheRequiredSuccessAndRecoveryPaths() async throws {
        let fixtures = try await withHangGuard("producing reusable workflow scenario ledgers") {
            try await WorkflowScenarioFixtures.ledgers()
        }
        for scenario in Self.scenarios {
            let fixture = try #require(fixtures.first { $0.scenario == scenario },
                                       "Missing reusable scenario: \(scenario)")
            try #require(!fixture.records.isEmpty, "A scenario must expose the events that actually ran")
            try Self.checkScenario(scenario, records: fixture.records)
        }
    }

    @Test
    func everyScenarioStageChangeHasADirectedCatalogTransition() async throws {
        let fixtures = try await withHangGuard("producing scenario ledgers for catalog replay") {
            try await WorkflowScenarioFixtures.ledgers()
        }
        for scenario in Self.scenarios {
            try #require(fixtures.contains { $0.scenario == scenario }, "Missing replay scenario: \(scenario)")
        }
        let catalog = WorkflowCatalog.standard
        for fixture in fixtures {
            try #require(!fixture.records.isEmpty)
            let replay = Self.replay(fixture.records, classify: { node, state in
                catalog.currentStage(of: node, in: state)?.stage
            }, permits: { from, to in
                catalog.transitions.contains { $0.from == from && $0.to == to }
            })
            #expect(replay.problems.isEmpty, "\(fixture.scenario): \(replay.problems.joined(separator: "; "))")
            #expect(replay.snapshots.count == fixture.records.count)
        }
    }

    @Test
    func previewsAreNotInventedNodesAndBatchEventsStillProjectEveryMember() throws {
        let events = Self.previewEvents + [
            Self.creation(),
            Self.event(.phaseChanged(to: .landing)),
            Self.event(.changeSubmitted(run: "builder-a", commit: "candidate-a")),
            Self.creation(Self.other),
            Self.event(.phaseChanged(to: .landing), node: Self.other),
            Self.event(.changeSubmitted(run: "builder-b", commit: "candidate-b"), node: Self.other),
        ] + Self.batchEvents
        let records = Self.records(events)
        let catalog = WorkflowCatalog.standard
        // This focused prefix checks non-node events; the full scenario replay checks their edges.
        var state = WorkingState()
        for record in records {
            state.apply(record)
            switch record.event.kind {
            case .previewStarted, .previewRecorded, .previewFinished:
                #expect(state.nodes.isEmpty)
                #expect(catalog.currentStage(of: Self.node, in: state) == nil)
            case .landingBatchChecked, .landingBatchSplit:
                #expect(record.event.node == nil, "The members are in the payload, not event.node")
                for id in [Self.node, Self.other] {
                    let current = try #require(catalog.currentStage(of: id, in: state))
                    #expect(current.stage == .landing)
                    #expect(!current.interrupted)
                }
            default:
                break
            }
        }
    }

    @Test
    func replayHelperAcceptsUnchangedStagesAndDetectsARemovedDirectedEdge() {
        // Validate the replay oracle against existing WorkingState, independently of the new API.
        let records = Self.records(Self.previewEvents + [
            Self.creation(),
            Self.creation(Self.other),
            Self.event(.phaseChanged(to: .building)),
            Self.event(.runStarted(run: Self.run, role: .implementer)),
            Self.event(.phaseChanged(to: .checking)),
            Self.event(.phaseChanged(to: .landing)),
            Self.event(.phaseChanged(to: .landing), node: Self.other),
        ] + Self.batchEvents)
        let classify: (NodeID, WorkingState) -> WorkflowStageID? = { id, state in
            switch state.nodes[id]?.phase {
            case .building: .implementation
            case .checking: .ownChecks
            case .landing: .landing
            case .some: .testAuthoring
            case .none: nil
            }
        }
        let valid = Self.replay(records, classify: classify, permits: { $0 != $1 })
        #expect(valid.problems.isEmpty, "No self-edge is required when an event leaves the stage unchanged")
        #expect(valid.snapshots.prefix(Self.previewEvents.count).allSatisfy { $0.isEmpty })
        #expect(valid.snapshots.last?[Self.node] == .landing)
        #expect(valid.snapshots.last?[Self.other] == .landing)

        let missingEdge = Self.replay(records, classify: classify, permits: { from, to in
            from != to && !(from == .implementation && to == .ownChecks)
        })
        #expect(missingEdge.problems.count == 1, "Removing a real directed edge must fail the replay")
        let checkingPosition = records.first { record in
            if case .phaseChanged(to: .checking) = record.event.kind { return true }
            return false
        }?.position
        #expect(missingEdge.invalidPositions == checkingPosition.map { [$0] })
    }
}
