import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_91Tests {
    @Test(arguments: [false, true], [false, true])
    func reconcilerPublishesOnlyAfterFinalChecksPassAndNeverCallsThePublisherWhenOff(
        enabled: Bool, finalChecksPass: Bool
    ) async throws {
        let fixture = try await Self.roundFixture(enabled: enabled, finalChecksPass: finalChecksPass)
        defer { fixture.removeFiles() }
        try await Self.verifyPublisherRecorder(fixture)

        try await fixture.settle()
        #expect(await fixture.checks.calls.isEmpty, "A requirement with an unfinished leaf is not ready.")
        #expect(await fixture.publisher.calls.isEmpty)
        try await fixture.proveLastLeaf()

        try await withHangGuard("GH-91 final verification and publication") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await fixture.settle() }
                defer { fixture.checks.release.open() }
                try await fixture.checks.started.wait(for: "Reconciler reaching final checks")
                #expect(await fixture.publisher.calls.isEmpty, "Publication cannot precede the final check result.")
                #expect(await fixture.base.git.commands.isEmpty)
                #expect(await fixture.base.github.mutations.isEmpty)
                fixture.checks.release.open()
                try await group.waitForAll()
            }
        }

        let verification = try await fixture.expectFinalVerification(passed: finalChecksPass)
        if enabled && finalChecksPass {
            let calls = await fixture.publisher.calls
            try #require(!calls.isEmpty, "The reconciler must invoke its publisher after final verification passes.")
            for call in calls {
                #expect(call.requirement == fixture.identity)
                #expect(call.branch == fixture.base.branch)
                #expect(call.commit == Self.tip)
                #expect(call.verification == verification, "The successful check must be durable before publishing.")
                #expect(call.allLeavesProven)
            }
            let pushes = await fixture.base.git.commands
            try #require(pushes.count == 1, "A real completed round must push the requirement once.")
            try Self.expectSafePush(pushes[0], branch: fixture.base.branch)
            let pr = try #require(Self.single(await fixture.base.github.pullRequests))
            #expect(pr.head == fixture.base.branch)
            #expect(pr.base == "main")
            #expect(pr.body.contains(verification.commit))
            #expect(pr.body.contains(verification.artifactSHA256))
            #expect(pr.body.contains(URL(fileURLWithPath: verification.artifactPath).lastPathComponent))
        } else {
            #expect(await fixture.publisher.calls.isEmpty,
                    "The reconciler itself must gate publication; a no-op inside the coordinator is not enough.")
            #expect(await fixture.base.git.commands.isEmpty)
            #expect(await fixture.base.github.mutations.isEmpty)
        }
        try await fixture.settle()
        #expect(await fixture.base.git.commands.count == (enabled && finalChecksPass ? 1 : 0))
        #expect(await fixture.base.github.createAttempts == (enabled && finalChecksPass ? 1 : 0))
        #expect(await fixture.checks.calls.count == (finalChecksPass ? 1 : 2),
                "A failed check runs once more with no other work running, then never again by itself.")
        #expect(await fixture.agents.calls.isEmpty)
        #expect(await fixture.base.github.unexpectedRequests.isEmpty)
    }

    @Test(arguments: [FailurePoint.push, .open, .lostOpenResponse])
    func reconcilerRoutesHumanRetryToPublicationWithoutReverificationOrAgentRework(
        point: FailurePoint
    ) async throws {
        let fixture = try await Self.roundFixture()
        defer { fixture.removeFiles() }
        fixture.checks.release.open()
        try await fixture.proveLastLeaf()
        if point == .push { await fixture.base.git.failNextPush() }
        else { await fixture.base.github.failNext(point) }
        try await fixture.settle()

        let verification = try await fixture.expectFinalVerification(passed: true)
        let state = await fixture.base.ledger.workingState()
        try #require(state.attentionList.contains {
            $0.node.id == fixture.identity.nodeID && $0.reason.contains(point.message)
        }, "A publication failure after real final verification must wait for a person.")
        #expect(try #require(await fixture.base.tracker.ticket("GH-91")).comments.contains {
            $0.text.contains(point.message) && $0.text.contains("harness:retry")
        })
        let pushesBeforeRetry = await fixture.base.git.commands.count
        let mutationsBeforeRetry = await fixture.base.github.mutations.count
        let replay = try await Self.replay(fixture.base.ledger)
        let restarted = fixture.makeReconciler(ledger: replay)
        try await fixture.settle(using: restarted)
        try await fixture.settle(using: restarted)
        #expect(await fixture.base.git.commands.count == pushesBeforeRetry)
        #expect(await fixture.base.github.mutations.count == mutationsBeforeRetry)
        #expect(await fixture.checks.calls.count == 1)

        await fixture.base.tracker.local.addLabel("harness:retry", to: "GH-91", by: .human("Reviewer"))
        try await fixture.settle(using: restarted)
        #expect(await fixture.base.tracker.pendingSignals().isEmpty)
        #expect(await fixture.base.git.commands.count == pushesBeforeRetry + 1,
                "The signal must traverse Reconciler intake and authorize another push.")
        let pr = try #require(Self.single(await fixture.base.github.pullRequests))
        #expect(pr.head == fixture.base.branch)
        #expect(await fixture.base.github.successfulCreates == 1)
        #expect(await fixture.base.github.createAttempts == (point == .open ? 2 : 1))
        #expect(!(await replay.workingState().attentionList.contains {
            $0.node.id == fixture.identity.nodeID && $0.reason.contains(point.message)
        }))
        let records = await replay.records(for: fixture.identity.nodeID)
        #expect(records.contains {
            if case .signalAccepted(_, .retry, _) = $0.event.kind { return true }
            return false
        }, "The reconciler, rather than a direct coordinator call, accepts harness:retry.")
        #expect(records.filter {
            if case .requirementVerificationFinished = $0.event.kind { return true }
            return false
        }.count == 1)
        #expect(await replay.workingState().nodes[fixture.identity.nodeID]?.requirementVerification == verification)
        #expect(await fixture.checks.calls.count == 1, "Publication retry must not rerun final verification.")
        #expect(await fixture.agents.calls.isEmpty, "Publication retry must not start agent rework.")
        try await fixture.settle(using: restarted)
        #expect(await fixture.base.git.commands.count == pushesBeforeRetry + 1)
        #expect(await fixture.base.github.successfulCreates == 1)
        #expect(await fixture.base.github.unexpectedRequests.isEmpty)
    }
}
