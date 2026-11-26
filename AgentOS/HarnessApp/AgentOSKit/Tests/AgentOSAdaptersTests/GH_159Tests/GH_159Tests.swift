// API: Reconciler.runRound(waitForAgents:) pre-checks a submitted leaf through CheckRunner.runChecks(in:only:).
// EventKind.testsRecorded(files:suite:) supplies its selection; Ledger.workingState(), tracker comments,
// and stored Evidence expose the outcome. All APIs already exist; no new declarations are required.
// Criterion 6 (real-repo-mode.md documenting zero-test pre-check failures) is source-only, checked by review.

import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_159Tests {
    @Test(arguments: Selection.allCases)
    func precheckSelectsRecordedSuiteOrLegacySpecTarget(_ selection: Selection) async throws {
        let output = CheckOutput(
            passed: true, summary: "Selected tests passed",
            log: "Executed 0 tests, with 0 failures.\nTest run with 1 test passed."
        )
        try await Self.withFixture(selection: selection, output: output) { fixture in
            let node = try await fixture.precheck()
            try await fixture.expectSelectedBranch()
            #expect(node.evidence.last?.passed == true)
            #expect(node.phase == .landing)
            #expect(await fixture.ledger.workingState().landingQueue.contains { $0.id == node.id })
        }
    }

    @Test(arguments: Selection.allCases, ZeroCounts.runs)
    func zeroTestPrechecksFailAndNeverEnterLandingQueue(
        _ selection: Selection, _ run: ZeroCounts.Run
    ) async throws {
        let output = CheckOutput(
            passed: run.successfulExit,
            summary: run.successfulExit ? "Runner exited successfully" : "Runner exited with a failure",
            log: run.counts.log
        )
        try await Self.withFixture(selection: selection, output: output) { fixture in
            let node = try await fixture.precheck()
            try await fixture.expectSelectedBranch()
            let evidence = try #require(node.evidence.last)
            #expect(!evidence.passed)
            #expect(evidence.summary.contains("no tests matched suite \(selection.suite)"))
            #expect(node.phase == .ready)
            #expect(node.activeRun == nil)
            #expect(node.landedCommit == nil)
            #expect(!(await fixture.ledger.workingState()).landingQueue.contains { $0.id == node.id })
            let records = await fixture.ledger.records(for: node.id)
            #expect(!records.contains {
                if case .phaseChanged(to: .landing) = $0.event.kind { return true }
                return false
            })
        }
    }

    @Test(arguments: MixedCounts.allCases, [true, false])
    func nonzeroCountFromEitherRunnerPreservesExitStatusOutcome(
        _ counts: MixedCounts, _ successfulExit: Bool
    ) async throws {
        let output = CheckOutput(
            passed: successfulExit,
            summary: successfulExit ? "Tests passed" : "A selected test failed",
            log: counts.log
        )
        try await Self.withFixture(selection: .legacy, output: output) { fixture in
            let node = try await fixture.precheck()
            try await fixture.expectSelectedBranch()
            try await fixture.expectOriginalOutcome(node, output: output)
        }
    }

    @Test(arguments: [
        "Build complete! All checks passed.",
        "Custom runner: 0 examples, 0 errors.",
        "Test run with no selected cases; verification succeeded."
    ])
    func unrecognizedCountsDoNotFailPassingPrechecks(_ log: String) async throws {
        let output = CheckOutput(passed: true, summary: "Custom checks passed", log: log)
        try await Self.withFixture(selection: .legacy, output: output) { fixture in
            let node = try await fixture.precheck()
            try await fixture.expectSelectedBranch()
            try await fixture.expectOriginalOutcome(node, output: output)
            #expect(await fixture.ledger.workingState().landingQueue.contains { $0.id == node.id })
        }
    }

    @Test(arguments: ZeroCounts.allCases)
    func zeroTestFailureReturnsReadyAndPostsOwnMistakeFeedback(_ counts: ZeroCounts) async throws {
        let output = CheckOutput(passed: true, summary: "Runner exited successfully", log: counts.log)
        try await Self.withFixture(selection: .recorded, output: output) { fixture in
            let node = try await fixture.precheck()
            let evidence = try #require(node.evidence.last)
            #expect(node.phase == .ready)
            #expect(await fixture.ledger.workingState().status(of: node) == "Ready")
            #expect(await fixture.tracker.latestStatus(for: node.ticket) == "Ready")
            #expect(evidence.failureClassification == .ownMistake)
            #expect(node.failedAttempts == 1)
            #expect(node.recentFailures.contains(evidence.summary))
            #expect(node.flags[.escalated] == nil)
            #expect(await fixture.tracker.comments(on: node.ticket).contains {
                $0.contains("\u{1F501} Pre-check failed; this is the agent's own mistake: "
                    + "no tests matched suite \(Selection.recorded.suite)")
            })
            #expect(fixture.artifacts.contents(at: evidence.artifactPath) == Data(counts.log.utf8))
        }
    }

    @Test
    func zeroTestFailureCountsTowardEscalationLimit() async throws {
        let output = CheckOutput(
            passed: true, summary: "Runner exited successfully", log: ZeroCounts.both.log
        )
        try await Self.withFixture(selection: .recorded, output: output, maxAttempts: 1) { fixture in
            let node = try await fixture.precheck()
            #expect(node.failedAttempts == 1)
            #expect(node.phase == .ready)
            let reason = try #require(node.flags[.escalated])
            #expect(reason.contains("no tests matched suite \(Selection.recorded.suite)"))
            #expect(await fixture.ledger.workingState().status(of: node) == "Needs human")
            #expect(await fixture.tracker.latestStatus(for: node.ticket) == "Needs human")
            #expect(await fixture.tracker.comments(on: node.ticket).contains {
                $0.contains("Needs a human") && $0.contains("harness:retry")
            })
            #expect(!(await fixture.ledger.workingState()).landingQueue.contains { $0.id == node.id })
        }
    }
}
