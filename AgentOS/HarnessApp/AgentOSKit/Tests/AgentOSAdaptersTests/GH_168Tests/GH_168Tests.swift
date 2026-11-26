// Expected API: existing NodeSpec.integration, ChildProposal.integration, Planner.childSpecs,
// Reconciler.replan/breakDown (@testable), Ledger.append/workingState/replay and TrackerAdapter.close.
// No new public entry point or event name is prescribed: approved order must survive ledger replay.
// All four criteria describe observable behaviour; none is source-only.
import Foundation
import Testing
@testable import AgentOSCore
import AgentOSTestSupport

@Suite struct GH_168Tests {
    @Test func anInitialApprovedBreakdownPreservesOrderAndTheFixtureRecordsTestsAndApprovals() async throws {
        let proposals = [Self.child("Store"), Self.child("Display"), Self.child("Audit")]
        try await Self.withFixture(proposals) { fixture in
            let state = await fixture.ledger.workingState()
            let children = try Self.children(in: state)
            #expect(children.map(\.spec.title) == proposals.map(\.title))
            #expect(children.map(\.ticket) == ["GH-168-child-1", "GH-168-child-2", "GH-168-child-3"])
            for child in children {
                #expect(child.id == "wn-\(child.ticket)")
                try Self.expectRecordedTestsAndApprovals(child)
            }
            #expect(await fixture.tracker.closed.isEmpty)
            try Self.expectOrder(proposals, in: await Self.replay(fixture.ledger))
        }
    }

    @Test func replanReordersKeptChildrenToTheApprovedBreakdownWithoutLosingTheirTests() async throws {
        let initial = [Self.child("Store"), Self.child("Display"), Self.child("Audit")]
        try await Self.withFixture(initial) { fixture in
            let before = try Self.children(in: await fixture.ledger.workingState())
            let approved = [initial[2], initial[0], initial[1]]
            try await fixture.replan(approved)
            let live = await fixture.ledger.workingState()
            let replayed = try await Self.replay(fixture.ledger)
            for state in [live, replayed] {
                try Self.expectOrder(approved, in: state)
                let children = try Self.children(in: state)
                #expect(children.map(\.id) == [before[2].id, before[0].id, before[1].id])
                for old in before {
                    let kept = try #require(state.nodes[old.id])
                    Self.expectKeptTestsAndApprovals(kept, from: old)
                }
            }
            #expect(await fixture.tracker.created.count == initial.count)
            #expect(await fixture.tracker.closed.isEmpty)
        }
    }

    @Test func replanInterleavesNewAndKeptChildrenInApprovedOrderAcrossSuccessiveReplays() async throws {
        let initial = [Self.child("Store"), Self.child("Display"), Self.child("Audit")]
        try await Self.withFixture(initial) { fixture in
            let before = try Self.children(in: await fixture.ledger.workingState())
            let approved = [
                Self.child("Validate"), initial[2], Self.child("Transform"), initial[0], Self.child("Export")
            ]
            try await fixture.replan(approved)
            let first = await fixture.ledger.workingState()
            for state in [first, try await Self.replay(fixture.ledger)] {
                try Self.expectOrder(approved, in: state)
                let children = try Self.children(in: state)
                #expect(children[1].id == before[2].id)
                #expect(children[3].id == before[0].id)
                #expect(Set(children.map(\.id)).count == approved.count)
                #expect(state.node(forTicket: before[1].ticket) == nil)
                for old in [before[0], before[2]] {
                    let kept = try #require(state.nodes[old.id])
                    Self.expectKeptTestsAndApprovals(kept, from: old)
                }
            }

            let firstChildren = try Self.children(in: first)
            let next = [approved[4], approved[3], approved[0], Self.child("Archive"), approved[1], approved[2]]
            try await fixture.replan(next)
            for state in [await fixture.ledger.workingState(), try await Self.replay(fixture.ledger)] {
                try Self.expectOrder(next, in: state)
                for old in firstChildren {
                    #expect(state.nodes[old.id]?.ticket == old.ticket)
                }
            }
        }
    }

    @Test func replacingAnOrdinarySiblingKeepsTheIntegrationChildLastWithItsOriginalTicketAndTests() async throws {
        let initial = [Self.child("Store"), Self.child("Display"), Self.child("Combined flow", integration: true)]
        try await Self.withFixture(initial) { fixture in
            let before = try Self.children(in: await fixture.ledger.workingState())
            let integration = before[2]
            let approved = [initial[0], Self.child("Present"), initial[2]]
            try await fixture.replan(approved)
            for state in [await fixture.ledger.workingState(), try await Self.replay(fixture.ledger)] {
                try Self.expectOrder(approved, in: state)
                let children = try Self.children(in: state)
                let last = try #require(children.last)
                #expect(last.id == integration.id)
                #expect(last.ticket == integration.ticket)
                #expect(last.spec.integration)
                let kept = try #require(state.nodes[integration.id])
                Self.expectKeptTestsAndApprovals(kept, from: integration)
                #expect(children[1].id != before[1].id)
                #expect(state.node(forTicket: before[1].ticket) == nil)
            }
        }
    }

    @Test(arguments: [false, true])
    func switchingBetweenOrdinaryAndIntegrationSupersedesTheEarlierTicketAndStartsWithoutItsTestsOrApprovals(
        wasIntegration: Bool
    ) async throws {
        let initial = [
            Self.child("Store"), Self.child("Display"), Self.child("Combined flow", integration: wasIntegration)
        ]
        try await Self.withFixture(initial) { fixture in
            let before = try Self.children(in: await fixture.ledger.workingState())
            let earlier = before[2]
            try Self.expectRecordedTestsAndApprovals(earlier)
            var changed = initial[2]
            changed.integration = !wasIntegration
            let approved = [initial[0], initial[1], changed]
            try await fixture.replan(approved)

            for state in [await fixture.ledger.workingState(), try await Self.replay(fixture.ledger)] {
                try Self.expectOrder(approved, in: state)
                let replacement = try #require(try Self.children(in: state).last)
                #expect(replacement.id != earlier.id)
                #expect(replacement.ticket != earlier.ticket)
                #expect(replacement.spec.integration == !wasIntegration)
                #expect(replacement.spec.specHash != earlier.spec.specHash)
                #expect(replacement.spec.title == earlier.spec.title)
                #expect(replacement.spec.intent == earlier.spec.intent)
                #expect(replacement.spec.acceptanceCriteria == earlier.spec.acceptanceCriteria)
                #expect(state.nodes[earlier.id] == nil)
                #expect(state.node(forTicket: earlier.ticket) == nil)
                #expect(state.superseded[earlier.ticket] == Self.ticket.key)
                #expect(replacement.phase == .specified)
                #expect(replacement.recordedTests == nil)
                #expect(replacement.testsDigest == nil)
                #expect(replacement.gates.isEmpty)
                #expect(replacement.approvedTestUpdates.isEmpty)
                #expect(replacement.updatedOtherTests.isEmpty)
                #expect(replacement.updatedOtherTestsDigest == nil)
                #expect(replacement.reviews.isEmpty)
                #expect(replacement.approvedReviewCommit == nil)
                for old in before.prefix(2) {
                    let kept = try #require(state.nodes[old.id])
                    Self.expectKeptTestsAndApprovals(kept, from: old)
                }
            }
            #expect(await fixture.tracker.isClosed(earlier.ticket))
            #expect(await fixture.tracker.statuses[earlier.ticket] == "Superseded")
            let comments = await fixture.tracker.comments[earlier.ticket] ?? []
            #expect(comments.contains { $0.contains("Superseded") && $0.contains(Self.ticket.key) })
        }
    }

    @Test func aPreChangeLedgerReplaysEachParentsCreationOrderEvenAfterALegacyReplan() async throws {
        let records = try Self.legacyLedger.split(separator: "\n").map {
            try Hashing.decoder().decode(RecordedEvent.self, from: Data($0.utf8))
        }
        let store = InMemoryLedgerStore()
        store.append(records)
        let ledger = try Ledger(store: store)
        let chain = await ledger.verifyChain()
        try #require(chain.isIntact, "\(chain.problem?.reason ?? "")")
        #expect(chain.checked == records.count)

        for state in [await ledger.workingState(), try await Self.replay(ledger)] {
            let parent = try #require(state.nodes["wn-OLD-168"])
            let nested = try #require(state.nodes["wn-OLD-168.90"])
            #expect(parent.phase == .split)
            #expect(parent.children == ["wn-OLD-168.90", "wn-OLD-168.4", "wn-OLD-168.1"],
                    "The legacy kept array is reversed, but old ledgers retain creation order.")
            #expect(nested.children == ["wn-OLD-168.90.8", "wn-OLD-168.90.2"],
                    "Interleaved node creation must preserve each parent's own order, not sort IDs.")
            #expect(state.nodes["wn-OLD-168.70"] == nil)
            #expect(state.superseded["OLD-168.70"] == "OLD-168")
        }
    }
}

private extension GH_168Tests {
    static func children(in state: WorkingState) throws -> [NodeState] {
        let parent = try #require(state.node(forTicket: Self.ticket.key))
        return try parent.children.map { try #require(state.nodes[$0]) }
    }

    static func expectOrder(_ approved: [ChildProposal], in state: WorkingState) throws {
        let parent = try #require(state.node(forTicket: Self.ticket.key))
        #expect(parent.phase == .split)
        let children = try Self.children(in: state)
        try #require(children.count == approved.count)
        #expect(children.map(\.spec.title) == approved.map(\.title))
        #expect(children.map(\.spec.acceptanceCriteria) == approved.map(\.acceptanceCriteria))
        #expect(children.map(\.spec.integration) == approved.map { $0.integration == true })
    }

    static func expectRecordedTestsAndApprovals(_ child: NodeState) throws {
        let tests = try #require(child.recordedTests)
        #expect(!tests.files.isEmpty)
        #expect(tests.suite == child.spec.testTarget)
        #expect(child.testsDigest != nil)
        #expect(child.gates.contains(.build))
        #expect(!child.approvedTestUpdates.isEmpty)
        #expect(child.reviews.contains { $0.stage == .acceptanceTests && $0.result.passed })
    }

    static func expectKeptTestsAndApprovals(_ kept: NodeState, from old: NodeState) {
        #expect(kept.ticket == old.ticket)
        #expect(kept.recordedTests?.files == old.recordedTests?.files)
        #expect(kept.recordedTests?.suite == old.recordedTests?.suite)
        #expect(kept.testsDigest == old.testsDigest)
        #expect(kept.gates == old.gates)
        #expect(kept.approvedTestUpdates == old.approvedTestUpdates)
        #expect(kept.reviews.map(\.stage) == old.reviews.map(\.stage))
        #expect(kept.reviews.map(\.result) == old.reviews.map(\.result))
        #expect(kept.reviews.map(\.commit) == old.reviews.map(\.commit))
    }

    static func replay(_ ledger: Ledger) async throws -> WorkingState {
        let records = try Hashing.decoder().decode(
            [RecordedEvent].self, from: Hashing.canonicalJSON(await ledger.allRecords()))
        let store = InMemoryLedgerStore()
        store.append(records)
        let reopened = try Ledger(store: store)
        let chain = await reopened.verifyChain()
        try #require(chain.isIntact, "\(chain.problem?.reason ?? "")")
        return await reopened.workingState()
    }

    static func withFixture(
        _ initial: [ChildProposal], body: @escaping @Sendable (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture()
        do {
            try await withHangGuard("GH-168 approved breakdown and replay") {
                try await fixture.start(initial)
                try await body(fixture)
            }
        } catch {
            await fixture.reconciler.shutdown(reason: "GH-168 fixture cleanup")
            throw error
        }
        await fixture.reconciler.shutdown(reason: "GH-168 fixture cleanup")
    }
}
