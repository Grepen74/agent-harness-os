// Expected API: AgentRunRecording.current?.record(credits: Double) reports incremental usage;
// EventKind.agentCreditsRecorded(run: RunID, credits: Double) persists a run's total.
// NodeState.recordedAICredits: Double and runsWithoutRecordedCost: Int are ledger-derived totals.
// EventKind.summary is the human-readable description displayed by LedgerPane.
// No acceptance criteria are documentation-, source-layout-, or build-setup-only.
import Foundation
import Testing
import AgentOSCore

@Suite struct GH_84Tests {
    @Test(arguments: [AgentRole.decomposer, .testAuthor, .implementer, .diagnoser], [false, true])
    func aFinishedRunRecordsOneSummedCostOnItsNodeEvenWhenTheAgentThrows(
        role: AgentRole, fails: Bool
    ) async throws {
        let fixture = try Fixture(role: role, credits: [0.25, 0.5, 0.75], fails: fails)
        defer { fixture.removeFiles() }
        try await fixture.seed()
        try await fixture.run()

        let records = await fixture.ledger.records(for: fixture.spec.id)
        let run = try Self.onlyRun(in: records, role: role)
        let finish = try #require(records.first { record in
            if case .runFinished(let finished, _) = record.event.kind { return finished == run }
            return false
        })
        if case .runFinished(_, let outcome) = finish.event.kind {
            #expect(outcome.contains("GH-84 reported failure") == fails)
        }
        let costs = Self.costs(in: await fixture.ledger.allRecords())
        #expect(costs.count == 1, "Several incremental reports must produce one durable cost event.")
        let cost = try #require(costs.first)
        #expect(cost.node == fixture.spec.id)
        #expect(cost.run == run)
        #expect(cost.credits == 1.5)
        #expect(await fixture.agents.calls == 1, "The fixture must exercise the requested agent role.")

        let restored = try await Self.replay(fixture.ledger)
        #expect(await restored.verifyChain().isIntact)
        let node = try #require(await restored.workingState().nodes[fixture.spec.id])
        #expect(node.recordedAICredits == 1.5)
        #expect(node.runsWithoutRecordedCost == 0)
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor, .implementer, .diagnoser], [false, true])
    func aRunWithoutCreditReportsHasNoCostEventAndRemainsUncosted(role: AgentRole, fails: Bool) async throws {
        let fixture = try Fixture(role: role, credits: [], fails: fails)
        defer { fixture.removeFiles() }
        try await fixture.seed()
        try await fixture.run()

        let records = await fixture.ledger.records(for: fixture.spec.id)
        _ = try Self.onlyRun(in: records, role: role)
        #expect(records.contains { if case .runFinished = $0.event.kind { return true }; return false })
        #expect(Self.costs(in: await fixture.ledger.allRecords()).isEmpty)
        #expect(await fixture.agents.calls == 1)
        let node = try #require(await fixture.ledger.workingState().nodes[fixture.spec.id])
        #expect(node.recordedAICredits == 0)
        #expect(node.runsWithoutRecordedCost == 1)
    }

    @Test(arguments: [false, true])
    func explicitlyReportedZeroIsAKnownCostRatherThanMissingUsage(fails: Bool) async throws {
        let fixture = try Fixture(role: .implementer, credits: [0], fails: fails)
        defer { fixture.removeFiles() }
        try await fixture.seed()
        try await fixture.run()

        let records = await fixture.ledger.records(for: fixture.spec.id)
        let run = try Self.onlyRun(in: records, role: .implementer)
        let costs = Self.costs(in: records)
        #expect(costs.count == 1)
        #expect(costs.first?.run == run)
        #expect(costs.first?.credits == 0)
        let node = try #require(await fixture.ledger.workingState().nodes[fixture.spec.id])
        #expect(node.recordedAICredits == 0)
        #expect(node.runsWithoutRecordedCost == 0)
    }

    @Test(arguments: [1.5, 2.75])
    func theLedgerDescriptionNamesTheRunAndItsAICredits(credits: Double) throws {
        let kind = EventKind.agentCreditsRecorded(run: "run-abc123", credits: credits)
        let restored = try JSONDecoder().decode(EventKind.self, from: JSONEncoder().encode(kind))
        #expect(restored.summary == "run-abc123 used \(credits) AI credits")
    }

    @Test
    func eachRetryRecordsItsOwnUsageRatherThanCarryingCreditsOverFromAnEarlierRun() async throws {
        let fixture = try Fixture(role: .implementer, credits: [0.25, 0.5, 0.75], fails: true)
        defer { fixture.removeFiles() }
        try await fixture.seed()
        try await fixture.run()
        try await fixture.run()

        let records = await fixture.ledger.records(for: fixture.spec.id)
        let started = records.compactMap { record -> RunID? in
            guard case .runStarted(let run, .implementer) = record.event.kind else { return nil }
            return run
        }
        #expect(started.count == 2, "The fixture must drive two separate implementer runs.")
        let costs = Self.costs(in: records)
        #expect(costs.count == 2)
        #expect(Set(costs.map(\.run)) == Set(started))
        #expect(costs.allSatisfy { $0.credits == 1.5 })
        let node = try #require(await fixture.ledger.workingState().nodes[fixture.spec.id])
        #expect(node.recordedAICredits == 3)
        #expect(node.runsWithoutRecordedCost == 0)
    }

    @Test
    func workingStateTotalsArePerNodeAndMatchCostsToStartedRunsAfterReplay() async throws {
        let ledger = try Ledger()
        let parent = Self.spec("parent", kind: .composite)
        var leaf = Self.spec("leaf")
        leaf.parent = parent.id
        let untouched = Self.spec("untouched")
        for spec in [parent, leaf, untouched] {
            try await ledger.append([Self.event(spec.id, .nodeCreated(spec: spec, ticket: spec.id))])
        }
        try await ledger.append([
            Self.event(parent.id, .runStarted(run: "parent-run", role: .decomposer)),
            Self.event(parent.id, .runFinished(run: "parent-run", outcome: "split")),
            Self.event(parent.id, .agentCreditsRecorded(run: "parent-run", credits: 4)),
            Self.event(leaf.id, .runStarted(run: "author", role: .testAuthor)),
            Self.event(leaf.id, .runFinished(run: "author", outcome: "tests")),
            Self.event(leaf.id, .runStarted(run: "failed-build", role: .implementer)),
            Self.event(leaf.id, .runFinished(run: "failed-build", outcome: "failed")),
            Self.event(leaf.id, .agentCreditsRecorded(run: "failed-build", credits: 1.5)),
            Self.event(leaf.id, .runStarted(run: "diagnosis", role: .diagnoser)),
            Self.event(leaf.id, .runFinished(run: "diagnosis", outcome: "diagnosed")),
            Self.event(leaf.id, .agentCreditsRecorded(run: "diagnosis", credits: 0.25)),
            Self.event(leaf.id, .runStarted(run: "known-zero", role: .implementer)),
            Self.event(leaf.id, .runFinished(run: "known-zero", outcome: "submitted")),
            Self.event(leaf.id, .agentCreditsRecorded(run: "known-zero", credits: 0)),
            Self.event(leaf.id, .runStarted(run: "checks", role: .verifier)),
            Self.event(leaf.id, .runFinished(run: "checks", outcome: "passed")),
            Self.event(leaf.id, .attemptsReset),
            Self.event(leaf.id, .runStarted(run: "still-running", role: .implementer)),
        ])

        let restored = try await Self.replay(ledger)
        let state = await restored.workingState()
        let parentState = try #require(state.nodes[parent.id])
        let leafState = try #require(state.nodes[leaf.id])
        let untouchedState = try #require(state.nodes[untouched.id])
        #expect(parentState.recordedAICredits == 4, "A parent's own runs must not include its children's costs.")
        #expect(parentState.runsWithoutRecordedCost == 0)
        #expect(leafState.recordedAICredits == 1.75)
        #expect(leafState.runsWithoutRecordedCost == 2, "The author and the still-running agent have no cost.")
        #expect(untouchedState.recordedAICredits == 0)
        #expect(untouchedState.runsWithoutRecordedCost == 0)

        try await restored.append([
            Self.event(leaf.id, .agentCreditsRecorded(run: "author", credits: 0.5)),
        ])
        let updated = try #require(await restored.workingState().nodes[leaf.id])
        #expect(updated.recordedAICredits == 2.25)
        #expect(updated.runsWithoutRecordedCost == 1, "A late cost resolves only its matching run.")
    }

    @Test
    func oldLedgersWithFinishedAndUnfinishedRunsStillReadWithZeroRecordedCredits() async throws {
        let store = InMemoryLedgerStore()
        store.append(try Self.legacyRecords())
        let ledger = try Ledger(store: store)
        #expect(await ledger.verifyChain().isIntact, "Old canonical records must still verify, not merely decode.")
        let state = await ledger.workingState()
        #expect(state.nodes.count == 2)
        for node in state.nodes.values {
            #expect(node.recordedAICredits == 0)
        }
        #expect(state.nodes["old-leaf"]?.activeRun?.run == "old-active")
    }

    @Test
    func fixtureDrivesTheExistingSuccessfulAgentLifecycle() async throws {
        let fixture = try Fixture(role: .implementer, credits: [], fails: false)
        defer { fixture.removeFiles() }
        try await fixture.seed()
        try await fixture.run()

        let records = await fixture.ledger.records(for: fixture.spec.id)
        let run = try Self.onlyRun(in: records, role: .implementer)
        #expect(await fixture.agents.calls == 1)
        #expect(records.contains {
            if case .runFinished(let finished, "submitted") = $0.event.kind { return finished == run }
            return false
        })
        #expect(records.contains {
            if case .changeSubmitted(let submitted, _) = $0.event.kind { return submitted == run }
            return false
        })
    }
}

extension GH_84Tests {
    struct Cost {
        let node: NodeID?
        let run: RunID
        let credits: Double
    }

    static func costs(in records: [RecordedEvent]) -> [Cost] {
        records.compactMap {
            guard case .agentCreditsRecorded(let run, let credits) = $0.event.kind else { return nil }
            return Cost(node: $0.event.node, run: run, credits: credits)
        }
    }

    static func onlyRun(in records: [RecordedEvent], role: AgentRole) throws -> RunID {
        let runs = records.compactMap { record -> RunID? in
            guard case .runStarted(let run, let startedRole) = record.event.kind, startedRole == role else { return nil }
            return run
        }
        #expect(runs.count == 1)
        return try #require(runs.first)
    }

    static func event(_ node: NodeID, _ kind: EventKind) -> LedgerEvent {
        LedgerEvent(node: node, by: .reconciler, kind: kind)
    }

    static func spec(_ id: String, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(id: id, parent: nil, kind: kind, title: id, intent: "Record run credits",
                 acceptanceCriteria: ["Credits are recorded"], touches: ["Engine"])
    }

    static func replay(_ ledger: Ledger) async throws -> Ledger {
        let records = await ledger.allRecords()
        let store = InMemoryLedgerStore()
        store.append(try Hashing.decoder().decode([RecordedEvent].self, from: Hashing.canonicalJSON(records)))
        return try Ledger(store: store)
    }
}
