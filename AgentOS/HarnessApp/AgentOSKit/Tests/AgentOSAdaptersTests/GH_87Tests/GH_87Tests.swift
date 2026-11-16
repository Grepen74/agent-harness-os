// Expected API: EventKind.runCostRecorded(run: RunID, credits: Double) records a
// run's reported cost. Reconciler.runRound(waitForAgents:) posts the per-leaf
// cost comment to TrackerAdapter when a split parent becomes proven.
// AC4 is reviewer-only: docs/real-repo-mode.md must explain the missing-cost
// marker and the "at least" total; documentation is not inspected by these tests.
import AgentOSCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GH_87Tests {
    @Test
    func fixtureObservesExistingParentProofAndTrackerComments() async throws {
        let fixture = try Fixture()
        try await fixture.seed()
        try await fixture.proveParent()

        let state = await fixture.ledger.workingState()
        let parent = try #require(state.nodes[Fixture.parentID])
        #expect(parent.phase == .proven)
        #expect(await fixture.tracker.ticket(Fixture.parentTicket)?.status == state.status(of: parent))
        let comments = await fixture.tracker.comments(on: Fixture.parentTicket)
        #expect(comments.contains {
            Self.lines(in: $0).contains { !$0.isEmpty }
        }, "The fixture must observe the existing proof comment before testing new cost output.")
    }

    @Test("AC1/AC2: a leaf's missing-cost count is local, with singular/plural wording",
          arguments: [1, 3])
    func leafLineMarksOnlyItsOwnUnreportedRuns(missingCount: Int) async throws {
        let fixture = try Fixture()
        try await fixture.seed()
        try await fixture.recordKnownCosts()
        for index in 0..<missingCount {
            try await fixture.run(
                on: Fixture.firstLeafID, id: "unreported-leaf-\(index)",
                role: .implementer, credits: nil,
                outcome: index == 0 ? "failed" : "stopped"
            )
        }
        try await fixture.proveParent()

        let comment = try await fixture.costComment()
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.firstLeafTicket, title: Fixture.firstLeafTitle),
            amount: 2.25, missing: missingCount
        )
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.secondLeafTicket, title: Fixture.secondLeafTitle),
            amount: 1.5, missing: 0
        )
        try Self.expectCredits(Self.breakdownLine(in: comment), amount: 0.75, missing: 0)
        try Self.expectTotal(in: comment, amount: 4.5, lowerBound: true)
    }

    @Test("AC1/AC2: missing parent decomposition costs mark Breakdown, not the leaves",
          arguments: [1, 2])
    func breakdownLineMarksItsOwnUnreportedRuns(missingCount: Int) async throws {
        let fixture = try Fixture()
        try await fixture.seed()
        try await fixture.recordKnownCosts()
        for index in 0..<missingCount {
            try await fixture.run(
                on: Fixture.parentID, id: "unreported-breakdown-\(index)",
                role: .decomposer, credits: nil, outcome: "failed"
            )
        }
        try await fixture.proveParent()

        let comment = try await fixture.costComment()
        try Self.expectCredits(Self.breakdownLine(in: comment), amount: 0.75, missing: missingCount)
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.firstLeafTicket, title: Fixture.firstLeafTitle),
            amount: 2.25, missing: 0
        )
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.secondLeafTicket, title: Fixture.secondLeafTitle),
            amount: 1.5, missing: 0
        )
        try Self.expectTotal(in: comment, amount: 4.5, lowerBound: true)
    }

    @Test("AC2: entirely unreported costs are a zero lower bound, not a known zero total")
    func entirelyUnreportedRunsStillHaveMarkersAndALowerBoundTotal() async throws {
        let fixture = try Fixture()
        try await fixture.seed()
        try await fixture.run(on: Fixture.parentID, id: "unknown-breakdown", role: .decomposer, credits: nil)
        try await fixture.run(on: Fixture.firstLeafID, id: "unknown-tests", role: .testAuthor, credits: nil)
        try await fixture.run(on: Fixture.firstLeafID, id: "unknown-build", role: .implementer, credits: nil)
        try await fixture.run(on: Fixture.secondLeafID, id: "unknown-second", role: .implementer, credits: nil)
        try await fixture.proveParent()

        let comment = try await fixture.costComment()
        try Self.expectCredits(Self.breakdownLine(in: comment), amount: 0, missing: 1)
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.firstLeafTicket, title: Fixture.firstLeafTitle),
            amount: 0, missing: 2
        )
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.secondLeafTicket, title: Fixture.secondLeafTitle),
            amount: 0, missing: 1
        )
        try Self.expectTotal(in: comment, amount: 0, lowerBound: true)
    }

    @Test("AC3: complete costs, including explicit zero, have no missing-cost or lower-bound wording")
    func everyReportedRunProducesAnExactUnmarkedTotal() async throws {
        let fixture = try Fixture()
        try await fixture.seed()
        try await fixture.recordKnownCosts()
        try await fixture.proveParent()

        let comment = try await fixture.costComment()
        #expect(!comment.contains("without a reported cost"))
        #expect(!comment.contains("at least"))
        try Self.expectCredits(Self.breakdownLine(in: comment), amount: 0.75, missing: 0)
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.firstLeafTicket, title: Fixture.firstLeafTitle),
            amount: 2.25, missing: 0
        )
        try Self.expectCredits(
            Self.leafLine(in: comment, ticket: Fixture.secondLeafTicket, title: Fixture.secondLeafTitle),
            amount: 1.5, missing: 0
        )
        try Self.expectTotal(in: comment, amount: 4.5, lowerBound: false)
    }

    private static func lines(in comment: String) -> [String] {
        comment.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func leafLine(in comment: String, ticket: String, title: String) throws -> String {
        try #require(Self.lines(in: comment).first {
            $0.contains("AI credits") && ($0.contains(ticket) || $0.contains(title))
        }, "The parent's cost comment must identify the leaf \(ticket).")
    }

    private static func breakdownLine(in comment: String) throws -> String {
        try #require(Self.lines(in: comment).first {
            $0.contains("Breakdown") && $0.contains("AI credits")
        }, "The parent's cost comment must include its Breakdown costs.")
    }

    private static func expectCredits(_ line: String, amount: Double, missing: Int) throws {
        let range = try #require(line.range(
            of: #"[0-9]+(?:\.[0-9]+)?(?= AI credits)"#, options: .regularExpression
        ), "The line must show a numeric amount in AI credits: \(line)")
        #expect(Double(line[range]) == amount)
        let marker = missing == 0 ? "" :
            " (\(missing) \(missing == 1 ? "run" : "runs") without a reported cost)"
        #expect(line.hasSuffix(" AI credits" + marker),
                "The marker must follow the credits and end the line, with the node's exact missing-run count.")
    }

    private static func expectTotal(in comment: String, amount: Double, lowerBound: Bool) throws {
        let line = try #require(Self.lines(in: comment).first { $0.contains("Total:") },
                                "The parent's cost comment must contain a Total line.")
        let start = try #require(line.range(of: "Total:"))
        let total = String(line[start.lowerBound...])
        #expect(total.hasPrefix(lowerBound ? "Total: at least " : "Total: "))
        #expect(total.contains("at least") == lowerBound)
        try Self.expectCredits(total, amount: amount, missing: 0)
    }
}
