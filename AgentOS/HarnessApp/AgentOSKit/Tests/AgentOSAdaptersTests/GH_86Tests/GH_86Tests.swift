// Contract: GH-86 must provide AgentOSCore.EventKind.runCostRecorded(run: RunID, aiCredits: Double).
// Its enclosing LedgerEvent.node associates the run's credits with that node; sum recorded
// runs across roles, retries, and replans. No new public cost model or per-node accessor is required.
// Reconcile ledger-backed composites and observe TrackerAdapter comments, once per transition
// to proven, including a re-prove with a revised breakdown. All fixture runs report a cost.
// Reviewer-only criterion: README.md and docs/real-repo-mode.md describe the cost comment.
import AgentOSCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GH_86Tests {
    @Test func fixtureObservesExistingProvenCommentsAndReadsCreditRows() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.prove("GH-899", "GH-898")
        try await fixture.settle()

        #expect(await fixture.ledger.workingState().nodes["wn-GH-860"]?.phase == .proven)
        #expect(await fixture.tracker.comments("GH-860").contains { $0.hasPrefix("✅ Proven") })
        let probe = "**Breakdown:** 1.5 AI credits\n| Total | **3 AI credits** |"
        await fixture.tracker.comment(on: "GH-999", probe)
        let observed = try #require(await fixture.tracker.comments("GH-999").first)
        #expect(try Self.rows(in: observed).map(\.amount) == ["1.5", "3"])
    }

    @Test func aParentPostsExactlyOneCostCommentAfterProvenAndNotAgainAfterRestart() async throws {
        let fixture = try Fixture()
        let running = fixture.runner(ledger: fixture.ledger)
        try await fixture.pair()
        try await fixture.settle(using: running)
        #expect(await fixture.tracker.costComments("GH-860").isEmpty)

        try await fixture.prove("GH-899")
        try await fixture.settle(using: running)
        #expect(await fixture.ledger.workingState().nodes["wn-GH-860"]?.phase == .split)
        #expect(await fixture.tracker.costComments("GH-860").isEmpty)

        try await fixture.prove("GH-898")
        try await fixture.settle(using: running)
        let comments = await fixture.tracker.comments("GH-860")
        let provenIndex = try #require(comments.firstIndex { $0.hasPrefix("✅ Proven") })
        let costIndex = try #require(comments.firstIndex { $0.contains("AI credits") },
                                    "A newly proven composite must receive a cost comment")
        #expect(costIndex > provenIndex)
        #expect(await fixture.tracker.costComments("GH-860").count == 1)

        try await fixture.settle(using: running)
        let replayed = try Ledger(store: fixture.store)
        let restarted = fixture.runner(ledger: replayed)
        try await fixture.settle(using: restarted)
        #expect(await fixture.tracker.costComments("GH-860").count == 1)
        #expect(await fixture.tracker.costComments("GH-899").isEmpty)
        #expect(await fixture.tracker.costComments("GH-898").isEmpty)
    }

    @Test func leavesAtEveryDepthAppearOnceInBreakdownOrderWithAllRecordedRunCredits() async throws {
        let fixture = try Fixture()
        try await fixture.deepTree()
        try await fixture.settle()

        let comment = try await fixture.costComment("GH-860")
        let rows = try Self.rows(in: comment)
        #expect(rows.count == 7, "Five leaf lines, Breakdown, and Total; no composite leaf lines")
        let leaves = Array(rows.prefix(5))
        let tickets = ["GH-899", "GH-898", "GH-897", "GH-896", "GH-863"]
        #expect(leaves.map(\.amount) == ["3", "2", "1", "0", "4"])
        for (row, ticket) in zip(leaves, tickets) {
            #expect(row.text.contains(Self.link(ticket)),
                    "Each line must link its leaf's name in depth-first breakdown order")
        }
        #expect(!comment.contains(Self.link("GH-861")))
        #expect(!comment.contains(Self.link("GH-862")))
        #expect(!comment.contains(Self.link("GH-999")), "Unrelated work must not enter this parent's cost")
    }

    @Test func breakdownIncludesEveryCompositeAndTotalIncludesLeavesWithoutDoubleCounting() async throws {
        let fixture = try Fixture()
        try await fixture.deepTree()
        try await fixture.settle()

        for (ticket, breakdown, total) in [
            ("GH-860", "4", "14"),
            ("GH-861", "2", "5"),
            ("GH-862", "1.5", "2.5"),
        ] {
            let rows = try Self.rows(in: await fixture.costComment(ticket))
            let lastTwo = Array(rows.suffix(2))
            try #require(lastTwo.count == 2)
            #expect(lastTwo[0].text.contains("Breakdown"))
            #expect(lastTwo[0].amount == breakdown)
            #expect(lastTwo[1].text.contains("Total"))
            #expect(lastTwo[1].amount == total)
        }
    }

    @Test(arguments: [
        (0.0, "0"), (1.5, "1.5"), (3.0, "3"),
        (1.234, "1.23"), (1.236, "1.24"), (12.999, "13"),
    ])
    func amountsUseAtMostTwoDecimalsWithoutTrailingZeros(credits: Double, displayed: String) async throws {
        let fixture = try Fixture()
        try await fixture.pair(parentCredits: 0, firstCredits: credits, secondCredits: 0)
        try await fixture.prove("GH-899", "GH-898")
        try await fixture.settle()

        let rows = try Self.rows(in: await fixture.costComment("GH-860"))
        let leaf = try #require(rows.first { $0.text.contains(Self.link("GH-899")) })
        let breakdown = try #require(rows.first { $0.text.contains("Breakdown") })
        #expect(leaf.amount == displayed)
        #expect(breakdown.amount == "0")
        let total = try #require(rows.first { $0.text.contains("Total") })
        #expect(total.amount == displayed)
    }

    @Test func aReplanOmitsRemovedLeavesButKeepsRecordedCostsOfRetainedNodes() async throws {
        let fixture = try Fixture()
        let parent = try await fixture.add("GH-860", kind: .composite)
        let kept = try await fixture.add("GH-899", parent: parent.id)
        let removed = try await fixture.add("GH-897", parent: parent.id)
        let otherKept = try await fixture.add("GH-898", parent: parent.id)
        try await fixture.cost("GH-860", credits: 0.25, role: .decomposer)
        try await fixture.cost("GH-899", credits: 1.5, role: .testAuthor)
        try await fixture.cost("GH-897", credits: 40, role: .testAuthor)
        try await fixture.cost("GH-898", credits: 0.75, role: .testAuthor)

        try await fixture.ledger.append([
            LedgerEvent(node: parent.id, by: .human("Planner"), kind: .replanned(spec: parent)),
            LedgerEvent(node: parent.id, by: .reconciler,
                        kind: .breakdownRevised(kept: [kept, otherKept], dropped: [removed.id])),
            LedgerEvent(node: parent.id, by: .reconciler, kind: .phaseChanged(to: .split)),
        ])
        _ = try await fixture.add("GH-896", parent: parent.id)
        try await fixture.cost("GH-860", credits: 0.75, role: .decomposer)
        try await fixture.cost("GH-896", credits: 2, role: .testAuthor)
        try #require(await fixture.ledger.workingState().nodes[removed.id] == nil)
        try await fixture.prove("GH-899", "GH-898", "GH-896")
        try await fixture.settle()

        let comment = try await fixture.costComment("GH-860")
        #expect(!comment.contains("GH-897"), "A removed leaf's name and cost must not be reported")
        let rows = try Self.rows(in: comment)
        #expect(rows.count == 5)
        #expect(rows.map(\.amount) == ["1.5", "0.75", "2", "1", "5.25"])
        for (row, ticket) in zip(rows, ["GH-899", "GH-898", "GH-896"]) {
            #expect(row.text.contains(Self.link(ticket)))
        }
        #expect(rows.dropLast().last?.text.contains("Breakdown") == true)
        #expect(rows.last?.text.contains("Total") == true)
    }

    @Test func aParentProvenAgainPostsOneNewCostCommentForItsRevisedBreakdown() async throws {
        let fixture = try Fixture()
        let running = fixture.runner(ledger: fixture.ledger)
        try await fixture.pair()
        let initial = await fixture.ledger.workingState()
        let parent = try #require(initial.nodes["wn-GH-860"]?.spec)
        let kept = try #require(initial.nodes["wn-GH-899"]?.spec)

        try await fixture.prove("GH-899", "GH-898")
        try await fixture.settle(using: running)
        let first = try await fixture.costComment("GH-860")
        #expect(try Self.rows(in: first).map(\.amount) == ["1", "2", "0.5", "3.5"])

        // Seed the revised ledger state without changing the existing replan signal's permissions.
        try await fixture.ledger.append([
            LedgerEvent(node: parent.id, by: .human("Planner"), kind: .replanned(spec: parent)),
            LedgerEvent(node: parent.id, by: .reconciler,
                        kind: .breakdownRevised(kept: [kept], dropped: ["wn-GH-898"])),
            LedgerEvent(node: parent.id, by: .reconciler, kind: .phaseChanged(to: .split)),
        ])
        _ = try await fixture.add("GH-896", parent: parent.id)
        try await fixture.cost("GH-860", credits: 0.75, role: .decomposer)
        try await fixture.cost("GH-899", credits: 0.5)
        try await fixture.cost("GH-896", credits: 4)
        try await fixture.settle(using: running)
        #expect(await fixture.ledger.workingState().nodes[parent.id]?.phase == .split)
        #expect(await fixture.tracker.costComments("GH-860").count == 1)

        try await fixture.prove("GH-896")
        try await fixture.settle(using: running)
        #expect(await fixture.ledger.workingState().nodes[parent.id]?.phase == .proven)
        let costs = await fixture.tracker.costComments("GH-860")
        try #require(costs.count == 2, "Every new transition to proven needs its own cost comment")
        #expect(costs[0] == first, "The original proof's cost comment remains historical")
        let rows = try Self.rows(in: costs[1])
        try #require(rows.count == 4)
        #expect(rows.map(\.amount) == ["1.5", "4", "1.25", "6.75"])
        #expect(rows[0].text.contains(Self.link("GH-899")))
        #expect(rows[1].text.contains(Self.link("GH-896")))
        #expect(rows[2].text.contains("Breakdown"))
        #expect(rows[3].text.contains("Total"))
        #expect(!costs[1].contains("GH-898"))

        let comments = await fixture.tracker.comments("GH-860")
        let provenIndices = comments.indices.filter { comments[$0].hasPrefix("✅ Proven") }
        let costIndices = comments.indices.filter { comments[$0].contains("AI credits") }
        try #require(provenIndices.count == 2)
        try #require(costIndices.count == 2)
        #expect(provenIndices[0] < costIndices[0])
        #expect(costIndices[0] < provenIndices[1])
        #expect(provenIndices[1] < costIndices[1])

        try await fixture.settle(using: running)
        let replayed = try Ledger(store: fixture.store)
        try await fixture.settle(using: fixture.runner(ledger: replayed))
        #expect(await fixture.tracker.costComments("GH-860").count == 2)
    }
}
