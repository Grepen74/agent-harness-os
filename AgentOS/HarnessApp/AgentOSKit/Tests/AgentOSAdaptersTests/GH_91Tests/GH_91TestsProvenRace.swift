import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_91Tests {
    /// GH-109: the step that marks a requirement proven still posts its comment when the next round starts final
    /// verification. The step's finish then closed the verifier's run as "task ended without recording a finish"
    /// and escalated the requirement, while the verification went on to pass.
    @Test
    func finalVerificationWaitsForTheStepThatProvedTheRequirement() async throws {
        let fixture = try await Self.roundFixture(enabled: false)
        defer { fixture.removeFiles() }
        let tracker = HeldProvenComment(forwarding: fixture.base.tracker)
        let reconciler = fixture.makeReconciler(tracker: tracker)
        try await fixture.proveLastLeaf()

        try await withHangGuard("GH-109 final verification after the proven step") {
            defer {
                tracker.release.open()
                fixture.checks.release.open()
            }
            let firstRound = Task { await reconciler.runRound(waitForAgents: false) }
            try await tracker.held.wait(for: "The root's step posting its Proven comment")

            // Either both rounds end with the step still running, or one of them starts final verification.
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    _ = await firstRound.value
                    _ = await reconciler.runRound(waitForAgents: false)
                    return false
                }
                group.addTask {
                    do { try await fixture.checks.started.wait(); return true } catch { return false }
                }
                if try #require(await group.next()) {
                    Issue.record("Final verification started while the root's step was still running.")
                    tracker.release.open()
                    try await tracker.escalated.wait(for: "The step's finish closing the verifier's run")
                    fixture.checks.release.open()
                } else {
                    group.cancelAll()
                }
                try await group.waitForAll()
            }
            tracker.release.open()
            fixture.checks.release.open()
            while true {
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                if report.isIdle { break }
            }
        }

        let root = try #require(await fixture.base.ledger.workingState().nodes[fixture.identity.nodeID])
        #expect(root.flags[.escalated] == nil, "\(root.flags)")
        #expect(root.activeRun == nil)
        _ = try await fixture.expectFinalVerification(passed: true)
    }

    /// Holds the "Proven" comment until released; reports a run closed by the harness as an escalation.
    struct HeldProvenComment: TrackerAdapter {
        let forwarding: Tracker
        let held = TestGate()
        let release = TestGate()
        let escalated = TestGate()

        var contextRepository: String { forwarding.contextRepository }
        func contextTickets() async -> [Ticket] { await forwarding.contextTickets() }
        func pendingSignals() async -> [Signal] { await forwarding.pendingSignals() }
        func ticket(_ key: String) async -> Ticket? { await forwarding.ticket(key) }
        func consume(_ signal: Signal, reply: String) async { await forwarding.consume(signal, reply: reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            try await forwarding.createChildTicket(parent: parent, spec: spec, by: by)
        }
        func comment(on key: String, _ text: String) async {
            if text.hasPrefix("✅ Proven") {
                held.open()
                try? await release.wait()
            }
            if text.contains("without recording a finish") { escalated.open() }
            await forwarding.comment(on: key, text)
        }
        func setStatus(of key: String, to status: String) async { await forwarding.setStatus(of: key, to: status) }
        func setPullRequestStatus(of key: String, to status: String) async {
            await forwarding.setPullRequestStatus(of: key, to: status)
        }
        func close(_ key: String, saying text: String) async { await forwarding.close(key, saying: text) }
        func isClosed(_ key: String) async -> Bool { await forwarding.isClosed(key) }
    }
}
