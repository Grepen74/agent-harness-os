import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_91Tests {
    /// GH-133's final verification failed twice on scenario tests slowed down by other requirements' agents, and
    /// waited for a person each time, while a landing check would have been run again with no other work running.
    @Test
    func aFailedFinalVerificationIsCheckedAgainOnceNoOtherAgentIsAtWork() async throws {
        let fixture = try await Self.roundFixture()
        defer { fixture.removeFiles() }
        let other = try await Self.addRequirementReadyForBreakdown(to: fixture)
        let decomposer = HeldDecomposer()
        let checks = ScriptedChecks(ledger: fixture.base.ledger, other: other, otherStarted: decomposer.started,
                                    results: [false, true])
        let reconciler = fixture.makeReconciler(decomposer: decomposer, checks: checks)
        try await fixture.proveLastLeaf()

        try await withHangGuard("GH-91's final verification checked again after GH-92's breakdown") {
            defer { decomposer.release.open() }
            let verifying = Task {
                try await eventually("GH-91's final verification recorded") {
                    let report = await reconciler.runRound(waitForAgents: false)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    return await fixture.base.ledger.workingState()
                        .nodes[fixture.identity.nodeID]?.requirementVerification != nil
                }
            }
            defer { verifying.cancel() }
            try await checks.firstReturned.wait(for: "the first final check failing while GH-92's breakdown runs")
            #expect(await checks.calls.count == 1, "The check must wait for GH-92's breakdown to finish.")
            decomposer.release.open()
            try await verifying.value
        }

        let calls = await checks.calls
        try #require(calls.count == 2, "\(calls)")
        #expect(calls[0].otherAtWork)
        #expect(!calls[1].otherAtWork, "The second check must start only after GH-92's breakdown has finished.")
        #expect(calls.allSatisfy { $0.suite == nil }, "Both checks must run the full configured checks.")
        let evidence = try #require(await fixture.base.ledger.workingState()
            .nodes[fixture.identity.nodeID]?.requirementVerification)
        #expect(evidence.passed)
        #expect(evidence.summary.contains("passed when checked again with no other work running"))
        #expect(evidence.summary.contains("check 1 failed"))
        let log = try String(contentsOf: URL(fileURLWithPath: evidence.artifactPath), encoding: .utf8)
        #expect(log.contains("log of check 1"))
        #expect(log.contains("log of check 2"))
    }

    @Test
    func aFinalVerificationFailingTwiceWaitsForAPersonWithBothLogs() async throws {
        let fixture = try await Self.roundFixture()
        defer { fixture.removeFiles() }
        let checks = ScriptedChecks(ledger: fixture.base.ledger, other: nil, otherStarted: nil,
                                    results: [false, false])
        let reconciler = fixture.makeReconciler(checks: checks)
        try await fixture.proveLastLeaf()

        try await fixture.settle(using: reconciler)

        #expect(await checks.calls.count == 2)
        let evidence = try #require(await fixture.base.ledger.workingState()
            .nodes[fixture.identity.nodeID]?.requirementVerification)
        #expect(!evidence.passed)
        #expect(evidence.summary == "check 2 failed")
        let log = try String(contentsOf: URL(fileURLWithPath: evidence.artifactPath), encoding: .utf8)
        #expect(log.contains("First check, while other work was running:\nlog of check 1"))
        #expect(log.contains("The whole check again with no other work running:\nlog of check 2"))
        #expect(await fixture.publisher.calls.isEmpty)
    }

    @Test
    func stoppingAFinalVerificationWaitingToCheckAgainDoesNotWaitForOtherWork() async throws {
        let fixture = try await Self.roundFixture()
        defer { fixture.removeFiles() }
        let other = try await Self.addRequirementReadyForBreakdown(to: fixture)
        let decomposer = HeldDecomposer()
        let checks = ScriptedChecks(ledger: fixture.base.ledger, other: other, otherStarted: decomposer.started,
                                    results: [false, true])
        let reconciler = fixture.makeReconciler(decomposer: decomposer, checks: checks)
        try await fixture.proveLastLeaf()
        let root = fixture.identity.nodeID

        try await withHangGuard("Stopping GH-91's final verification while GH-92's breakdown runs") {
            defer { decomposer.release.open() }
            // Rounds start GH-92's breakdown and GH-91's final verification; the round running it lasts until it ends.
            let rounds = Task {
                try await eventually("GH-91's final verification ending") {
                    _ = await reconciler.runRound(waitForAgents: false)
                    return checks.firstReturned.isOpen
                }
            }
            defer { rounds.cancel() }
            try await checks.firstReturned.wait(for: "the first final check failing while GH-92's breakdown runs")
            let run = try #require(await fixture.base.ledger.workingState().nodes[root]?.activeRun?.run)
            try await reconciler.stopRun(run, by: "Reviewer")
            #expect(!decomposer.release.isOpen, "The stop must not wait for GH-92's breakdown.")
            let finishes = await fixture.base.ledger.records(for: root).compactMap { record -> String? in
                guard case .runFinished(run, let outcome) = record.event.kind else { return nil }
                return outcome
            }
            #expect(finishes == ["stopped by Reviewer"])
            try await rounds.value
        }

        #expect(await checks.calls.count == 1)
        #expect(await fixture.base.ledger.workingState().nodes[root]?.requirementVerification == nil,
                "A stopped verification has no result; it waits for harness:retry.")
    }

    static func addRequirementReadyForBreakdown(to fixture: RoundFixture) async throws -> NodeID {
        let other = NodeSpec(
            id: "wn-GH-92", parent: nil, kind: .composite, title: "Print invoices",
            intent: "Print an invoice for every order.", acceptanceCriteria: ["Every order has an invoice."],
            touches: ["Invoice"]
        )
        try await fixture.base.ledger.append([
            LedgerEvent(node: other.id, by: .human("Reviewer"), kind: .nodeCreated(spec: other, ticket: "GH-92")),
            LedgerEvent(node: other.id, by: .human("Reviewer"), kind: .gateOpened(.breakdown)),
        ])
        return other.id
    }

    /// Returns the scripted results in order; the first waits until another requirement's agent is at work.
    actor ScriptedChecks: CheckRunner {
        struct Call: Sendable {
            let suite: String?
            let otherAtWork: Bool
        }
        let ledger: Ledger
        let other: NodeID?
        let otherStarted: TestGate?
        private var results: [Bool]
        private(set) var calls: [Call] = []
        nonisolated let firstReturned = TestGate()

        init(ledger: Ledger, other: NodeID?, otherStarted: TestGate?, results: [Bool]) {
            self.ledger = ledger
            self.other = other
            self.otherStarted = otherStarted
            self.results = results
        }

        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            let number = calls.count + 1
            if number == 1, let otherStarted {
                do { try await otherStarted.wait() }
                catch { return CheckOutput(passed: false, summary: "Check gate cancelled", log: "\(error)") }
            }
            let atWork = if let other { await ledger.workingState().nodes[other]?.activeRun != nil } else { false }
            calls.append(Call(suite: suite, otherAtWork: atWork))
            guard !results.isEmpty else {
                return CheckOutput(passed: false, summary: "Unexpected check \(number)", log: "")
            }
            let passed = results.removeFirst()
            defer { if number == 1 { firstReturned.open() } }
            return CheckOutput(passed: passed, summary: "check \(number) \(passed ? "passed" : "failed")",
                               log: "log of check \(number)")
        }
    }
}
