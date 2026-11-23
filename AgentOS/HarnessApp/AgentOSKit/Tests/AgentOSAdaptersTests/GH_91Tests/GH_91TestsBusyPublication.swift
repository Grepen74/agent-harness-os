import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_91Tests {
    /// GH-109 waited in review for hours: a verified requirement was published only when no agent was at work.
    @Test
    func aVerifiedRequirementIsPublishedWhileAnotherRequirementsAgentIsAtWork() async throws {
        let fixture = try await Self.roundFixture()
        defer { fixture.removeFiles() }
        let other = NodeSpec(
            id: "wn-GH-92", parent: nil, kind: .composite, title: "Print invoices",
            intent: "Print an invoice for every order.", acceptanceCriteria: ["Every order has an invoice."],
            touches: ["Invoice"]
        )
        try await fixture.base.ledger.append([
            LedgerEvent(node: other.id, by: .human("Reviewer"), kind: .nodeCreated(spec: other, ticket: "GH-92")),
            LedgerEvent(node: other.id, by: .human("Reviewer"), kind: .gateOpened(.breakdown)),
        ])
        let decomposer = HeldDecomposer()
        let reconciler = fixture.makeReconciler(decomposer: decomposer)
        try await fixture.proveLastLeaf()

        try await withHangGuard("GH-91 published while GH-92's breakdown runs") {
            defer {
                fixture.checks.release.open()
                decomposer.release.open()
            }
            // Rounds run until GH-91 is published; its final checks are held until GH-92's breakdown is at work.
            let publishing = Task {
                try await eventually("GH-91 published while GH-92's breakdown is at work") {
                    let report = await reconciler.runRound(waitForAgents: false)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    return await !fixture.publisher.calls.isEmpty
                }
            }
            defer { publishing.cancel() }
            try await decomposer.started.wait(for: "GH-92's breakdown starting")
            #expect(await fixture.publisher.calls.isEmpty)
            fixture.checks.release.open()
            try await publishing.value
            decomposer.release.open()
            while true {
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                if report.isIdle { break }
            }
        }

        _ = try await fixture.expectFinalVerification(passed: true)
        #expect(await fixture.base.git.commands.count == 1)
        let pr = try #require(Self.single(await fixture.base.github.pullRequests))
        #expect(pr.head == fixture.base.branch)
        let root = try #require(await fixture.base.ledger.workingState().nodes[fixture.identity.nodeID])
        #expect(root.flags.isEmpty, "\(root.flags)")
    }

    /// A breakdown that stays at work until released, then gives up.
    struct HeldDecomposer: Decomposer {
        let started = TestGate()
        let release = TestGate()
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            started.open()
            try await release.wait()
            throw AgentFailure("Released")
        }
    }
}
