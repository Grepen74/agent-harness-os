// Expected API: persisted HarnessSettings.pullRequests: Bool (default false),
// RepoConfig.pullRequests: Bool?, Policy.pullRequests: Bool, and
// AgentOSUI.PushPullRequestsToggle(settings: Binding<HarnessSettings>).
// Workspace supplies requirementWorktree(for: NodeIdentity) async throws -> URL and
// requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool.
// Reconciler accepts publisher: (any RequirementPublisher)? = nil; that protocol exposes
// publish(requirement: NodeIdentity, branch: String, commit: String) async throws.
// Existing round, evidence, status, artifact and retry APIs expose final verification.
// Reviewer-only: SettingsView embeds the editable control and its existing SettingsModel
// saves it with the other settings. App-window wiring is outside the package test target.
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite(.serialized)
struct GH_90Tests {
    @Test
    func newAndLegacyHarnessSettingsDoNotPermitPublishing() throws {
        #expect(!HarnessSettings().pullRequests)
        let legacy = try JSONDecoder().decode(HarnessSettings.self, from: Data(
            #"{"maxParallelAgents":4,"maxAttempts":2}"#.utf8
        ))
        #expect(!legacy.pullRequests)
        #expect(legacy.maxParallelAgents == 4)
        #expect(legacy.maxAttempts == 2)
        #expect(try !JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8)).pullRequests)
    }

    @Test(arguments: [false, true])
    func thePublishingChoiceIsSavedAndRestoredWithOtherHarnessSettings(enabled: Bool) throws {
        var settings = HarnessSettings()
        settings.pullRequests = enabled
        settings.maxParallelAgents = 4
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["pullRequests"] as? Bool == enabled)
        let restored = try JSONDecoder().decode(HarnessSettings.self, from: data)
        #expect(restored.pullRequests == enabled)
        #expect(restored.maxParallelAgents == 4)
    }

    @Test(arguments: [false, true])
    func theRepoPublishingKeyIsRecognizedAndRoundTripsAsABoolean(enabled: Bool) throws {
        let parsed = try RepoConfig.parse(Self.configJSON(enabled))
        #expect(parsed.unknownKeys.isEmpty)
        #expect(parsed.config.pullRequests == enabled)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(parsed.config.json.utf8)) as? [String: Any]
        )
        #expect(object["pullRequests"] as? Bool == enabled)
        #expect(try RepoConfig.parse(parsed.config.json).config.pullRequests == enabled)
    }

    @Test(arguments: [#""true""#, "1", "{}", "[]"])
    func theRepoPublishingKeyRefusesNonBooleanValues(value: String) {
        #expect(throws: RepoConfig.ParseError.self) {
            try RepoConfig.parse(#"{"test":{"command":"swift test"},"pullRequests":\#(value)}"#)
        }
    }

    @Test(arguments: [false, true])
    func anAbsentRepoPublishingKeyInheritsTheHarnessChoice(enabled: Bool) throws {
        for repo in [nil, try RepoConfig.parse(#"{"test":{"command":"swift test"}}"#).config] {
            let effective = Self.resolve(enabled, repo: repo)
            #expect(effective.policy.pullRequests == enabled)
            let row = try Self.publishingSetting(effective)
            #expect(row.value == (enabled ? "On" : "Off"))
            #expect(row.source == .harness)
            #expect(effective.problems.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func repoFalseDisablesPublishingRegardlessOfTheHarnessChoice(harnessEnabled: Bool) throws {
        let repo = try RepoConfig.parse(Self.configJSON(false)).config
        let effective = Self.resolve(harnessEnabled, repo: repo)
        #expect(!effective.policy.pullRequests)
        #expect(try Self.publishingSetting(effective).value == "Off")
        #expect(effective.problems.isEmpty)
    }

    @Test
    func repoTrueIsAllowedOnlyWithinAnEnabledHarnessSetting() throws {
        let repo = try RepoConfig.parse(Self.configJSON(true)).config
        let enabled = Self.resolve(true, repo: repo)
        #expect(enabled.policy.pullRequests)
        #expect(try Self.publishingSetting(enabled).value == "On")
        #expect(enabled.problems.isEmpty)

        let refused = Self.resolve(false, repo: repo)
        #expect(!refused.policy.pullRequests, "A looser repo value must have no effect.")
        #expect(try Self.publishingSetting(refused).value == "Off")
        let blocker = try #require(refused.problems.first {
            $0.check == "config.policy" && $0.severity == .blocker
        })
        let explanation = (blocker.title + " " + blocker.detail).lowercased()
        #expect(explanation.contains("pullrequests") || explanation.contains("pull request"))
        #expect(blocker.suggestion?.contains(RepoConfig.path) == true)

        let snapshot = RepositorySnapshot(
            branch: "main", commit: "base-90", files: [RepoConfig.path],
            contents: [RepoConfig.path: Self.configJSON(true)]
        )
        let assessment = ReadinessRules.assess(snapshot, harness: Self.harness(false), baseline: nil)
        #expect(assessment.findings.contains(blocker), "The refusal must reach the readiness scan.")
        #expect(!ReadinessScan(branch: "main", commit: "base-90", findings: assessment.findings).isReady)
    }

    @Test(arguments: [Optional<Failure>.none, .tests, .lint])
    func fixtureProbeRunsRealConfiguredCommandsAndPersistsTheirLogsWithoutGitOrNetwork(
        failure: Failure?
    ) async throws {
        let f = try Fixture(failure: failure)
        defer { f.removeFiles() }
        _ = try await f.seedSingleLeaf()
        let directory = try await f.workspace.requirementWorktree(for: f.requirement)
        let output = await f.checks.runChecks(in: directory, only: nil)
        #expect(output.passed == (failure == nil))
        let expectedCommands = failure == .tests ? ["tests"]
            : failure == .lint ? ["tests", "lint"] : ["tests", "lint", "format"]
        #expect(try f.commandTrace().sorted() == expectedCommands.sorted())
        #expect(output.log.contains("FULL-TESTS tip-90"))
        #expect(output.log.contains(failure?.output ?? "FORMAT tip-90"))
        let artifact = try f.artifacts.put(named: "probe.log", contents: Data(output.log.utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: artifact.path)) == Data(output.log.utf8))
        #expect(artifact.sha256 == Hashing.sha256(Data(output.log.utf8)))
        let evidence = Evidence(
            check: "fixture check", passed: output.passed, summary: output.summary,
            specHash: f.spec(kind: .leaf).specHash, builtBy: "fixture-builder", checkedBy: "fixture-verifier",
            artifactPath: artifact.path, artifactSHA256: artifact.sha256, commit: f.tip
        )
        try await f.ledger.append([
            LedgerEvent(node: f.requirement.nodeID, by: .agent(run: "fixture-verifier", role: .verifier),
                        kind: .evidenceRecorded(evidence)),
        ])
        let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
        try Self.expectEvidence(
            await f.requirementEvidence(in: reopened), in: f, passed: output.passed,
            containing: failure?.output ?? "FORMAT tip-90"
        )
        #expect(await reopened.verifyChain().isIntact)
        #expect(try await f.workspace.head(of: directory) == f.tip)
        #expect(try await f.workspace.head(of: f.workspace.worktree(for: f.requirement.nodeID)) != f.tip)
        try await f.publisher.publish(requirement: f.requirement, branch: "probe-only", commit: f.tip)
        #expect(await f.publisher.calls.count == 1, "Validate the publishing spy before relying on zero calls.")
        await f.tracker.addRetry(for: f.requirement.ticketKey)
        let signal = try #require(await f.tracker.pendingSignals().first)
        await f.tracker.consume(signal, reply: "probe consumed")
        #expect(await f.tracker.pendingSignals().isEmpty)
        #expect(await f.tracker.comments(on: f.requirement.ticketKey).contains("probe consumed"))
    }

    @Test(arguments: [false, true], [false, true])
    func onlyTheLastLeafTriggersFullVerificationOnTheRequirementTip(
        nested: Bool, publishingEnabled: Bool
    ) async throws {
        let f = try Fixture(policy: Self.resolve(publishingEnabled).policy)
        defer { f.removeFiles() }
        let leaves = try await f.seedComposite(nested: nested)
        try await f.prove(leaves[0])
        try await f.settle()
        #expect(await f.checks.calls.isEmpty, "A proven sibling is not a finished requirement.")
        #expect(await f.publisher.calls.isEmpty)
        #expect(await f.requirementEvidence().isEmpty)

        try await f.prove(leaves[1])
        try await f.settle()
        try await Self.expectFullVerification(f)
        #expect(await f.agents.calls.isEmpty)
        if !publishingEnabled { #expect(await f.publisher.calls.isEmpty) }
        let records = await f.ledger.allRecords()
        let completion = try #require(records.first {
            guard $0.event.node == leaves[1].id else { return false }
            if case .phaseChanged(to: .proven) = $0.event.kind { return true }
            return false
        })
        let verification = try #require(records.first {
            guard $0.event.node == f.requirement.nodeID else { return false }
            if case .evidenceRecorded = $0.event.kind { return true }
            return false
        })
        #expect(verification.position > completion.position)
    }

    @Test
    func aTopLevelLeafAlsoGetsFinalVerificationAfterItsLandingCheck() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        let spec = try await f.seedSingleLeaf()
        let previous = Evidence(
            check: "landing check", passed: true, summary: "leaf landing passed",
            specHash: spec.specHash, builtBy: "builder-90", checkedBy: "landing-verifier-90",
            artifactPath: "previous-leaf-check.log", artifactSHA256: "previous-digest", commit: f.tip
        )
        try await f.ledger.append([
            LedgerEvent(node: spec.id, by: .agent(run: "landing-verifier-90", role: .verifier),
                        kind: .evidenceRecorded(previous)),
        ])
        try await f.prove(spec)
        try await f.settle()
        #expect(try f.commandTrace().sorted() == ["format", "lint", "tests"],
                "A successful leaf landing check does not replace final verification.")
        let evidence = await f.requirementEvidence().filter { $0.checkedBy != previous.checkedBy }
        try #require(!evidence.isEmpty, "Final verification needs its own durable evidence.")
        try Self.expectEvidence(evidence, in: f, passed: true, containing: "FORMAT tip-90")
        #expect(await f.checks.calls.count == 1)
        #expect(await f.checks.calls.first?.suite == nil)
        #expect(await f.publisher.calls.isEmpty)
    }

    @Test
    func successfulFinalVerificationSurvivesRestartWithoutRerunningChecks() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        try await f.settle()
        try await Self.expectFullVerification(f)
        let evidence = await f.requirementEvidence()
        await f.reconciler.shutdown(reason: "GH-90 restart")
        let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
        let restarted = f.makeReconciler(ledger: reopened)
        _ = await restarted.recoverAfterRestart()
        try await f.settle(using: restarted)
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 1)
        #expect(await f.requirementEvidence(in: reopened).count == evidence.count)
        #expect(await reopened.verifyChain().isIntact)
        let state = await reopened.workingState()
        let root = try #require(state.nodes[f.requirement.nodeID])
        #expect(state.status(of: root) == "In review")
        #expect(await f.publisher.calls.isEmpty)
    }

    @Test(arguments: [Failure.tests, .lint], [false, true])
    func finalVerificationFailureWaitsWithEvidenceAndNeverStartsAgentRework(
        failure: Failure, publishingEnabled: Bool
    ) async throws {
        let f = try Fixture(failure: failure, policy: Self.resolve(publishingEnabled).policy)
        defer { f.removeFiles() }
        let leaves = try await f.seedCompletedComposite()
        try await f.settle()
        let evidence = await f.requirementEvidence()
        try #require(evidence.contains { !$0.passed }, "Final failure must be recorded on the requirement.")
        try Self.expectEvidence(evidence, in: f, passed: false, containing: failure.output)
        let state = await f.ledger.workingState()
        #expect(state.attentionList.contains { $0.node.id == f.requirement.nodeID })
        let root = try #require(state.nodes[f.requirement.nodeID])
        #expect(state.status(of: root) != "Done")
        #expect(state.status(of: root) != "In review")
        #expect(await f.tracker.ticket(f.requirement.ticketKey)?.status == state.status(of: root))
        let comments = await f.tracker.comments(on: f.requirement.ticketKey)
        #expect(comments.contains { $0.contains(failure.output) && $0.contains("harness:retry") })
        for leaf in leaves {
            #expect(state.nodes[leaf.id]?.phase == .proven)
            #expect(state.nodes[leaf.id]?.reworks == 0)
        }
        #expect(await f.agents.calls.isEmpty)
        #expect(await f.publisher.calls.isEmpty)
        #expect(await f.checks.calls.count == 2, "A failed check runs once more with no other work running.")

        await f.reconciler.shutdown(reason: "GH-90 failure restart")
        let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
        let restarted = f.makeReconciler(ledger: reopened)
        _ = await restarted.recoverAfterRestart()
        try await f.settle(using: restarted)
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 2, "Failure must not retry automatically, including after restart.")
        #expect(await f.agents.calls.isEmpty)
        #expect(await reopened.workingState().attentionList.contains { $0.node.id == f.requirement.nodeID })
        try f.clearFailure(failure)
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 2, "Fixing the command alone does not authorize another final check.")
        #expect(await f.publisher.calls.isEmpty)
        #expect(await reopened.workingState().attentionList.contains { $0.node.id == f.requirement.nodeID })
    }

    @Test
    func humanRetryRerunsFinalVerificationAndCanFailAgainBeforeSucceeding() async throws {
        let f = try Fixture(failure: .lint)
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        try await f.settle()
        try #require(await f.requirementEvidence().contains { !$0.passed })
        await f.reconciler.shutdown(reason: "GH-90 retry after restart")
        let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
        let restarted = f.makeReconciler(ledger: reopened)
        _ = await restarted.recoverAfterRestart()
        await f.tracker.addRetry(for: f.requirement.ticketKey)
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 4)
        #expect(await reopened.workingState().attentionList.contains { $0.node.id == f.requirement.nodeID })
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 4, "A second failure still needs another human retry.")

        try f.clearFailure(.lint)
        await f.tracker.addRetry(for: f.requirement.ticketKey)
        try await f.settle(using: restarted)
        #expect(await f.checks.calls.count == 5)
        #expect(await f.checks.calls.allSatisfy { $0.suite == nil && $0.directory == f.requirementDirectory })
        #expect(try f.commandTrace().sorted() == ["format"] + Array(repeating: "lint", count: 5)
            + Array(repeating: "tests", count: 5))
        let evidence = await f.requirementEvidence(in: reopened)
        #expect(evidence.contains { !$0.passed })
        #expect(evidence.contains { $0.passed })
        let state = await reopened.workingState()
        #expect(!state.attentionList.contains { $0.node.id == f.requirement.nodeID })
        #expect(state.status(of: try #require(state.nodes[f.requirement.nodeID])) == "In review")
        #expect(await f.agents.calls.isEmpty)
        #expect(await f.publisher.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func publishingOffKeepsTheVerifiedRequirementLocalAndInReviewUntilAManualMerge(
        disabledByRepo: Bool
    ) async throws {
        let repo = try disabledByRepo ? RepoConfig.parse(Self.configJSON(false)).config : nil
        let f = try Fixture(policy: Self.resolve(disabledByRepo, repo: repo).policy)
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        try await f.settle()
        try await Self.expectFullVerification(f)
        let before = await f.ledger.workingState()
        #expect(before.status(of: try #require(before.nodes[f.requirement.nodeID])) == "In review")
        #expect(await f.tracker.ticket(f.requirement.ticketKey)?.status == "In review")
        try await f.settle()
        #expect(await f.publisher.calls.isEmpty, "No push or pull-request request is permitted.")
        #expect(await f.workspace.mergeWrites == 0, "Only a person merges into main.")
        #expect(await f.workspace.mergeQueries.contains(f.requirement))
        await f.workspace.personMergesRequirementIntoMain()
        try await f.settle()
        let after = await f.ledger.workingState()
        #expect(after.status(of: try #require(after.nodes[f.requirement.nodeID])) == "Done")
        #expect(await f.tracker.ticket(f.requirement.ticketKey)?.status == "Done")
        #expect(await f.publisher.calls.isEmpty)
        #expect(await f.checks.calls.count == 1)
    }

    // WORK-1..3 finished before requirement branches existed; their new branches only ever held main.
    @Test
    func aRequirementAlreadyInMainIsMergedWithoutFinalVerification() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        await f.workspace.personMergesRequirementIntoMain()
        try await f.settle()
        let state = await f.ledger.workingState()
        let root = try #require(state.nodes[f.requirement.nodeID])
        #expect(await f.checks.calls.isEmpty, "Main's baseline already checks what main contains.")
        #expect(root.requirementMerged && !root.requirementVerificationStarted)
        #expect(state.status(of: root) == "Done")
        #expect(await f.tracker.ticket(f.requirement.ticketKey)?.status == "Done")
        #expect(await f.publisher.calls.isEmpty)
    }

    // Nobody can add harness:retry to a requirement whose ticket is no longer on the tracker (WORK-3).
    @Test
    func aFailedFinalVerificationStopsNeedingAPersonOnceTheRequirementIsInMain() async throws {
        let f = try Fixture(failure: .tests)
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        try await f.settle()
        let failed = await f.ledger.workingState()
        try #require(failed.status(of: try #require(failed.nodes[f.requirement.nodeID])) == "Needs input")
        try #require(failed.attentionList.contains { $0.node.id == f.requirement.nodeID })

        await f.workspace.personMergesRequirementIntoMain()
        try await f.settle()
        let state = await f.ledger.workingState()
        let root = try #require(state.nodes[f.requirement.nodeID])
        #expect(root.requirementMerged)
        #expect(state.status(of: root) == "Done")
        #expect(!state.attentionList.contains { $0.node.id == f.requirement.nodeID })
        #expect(await f.checks.calls.count == 2, "No verification of what main's baseline checks after the recheck.")
    }

    @Test
    func finalVerificationShowsAsARunningCheckAndAsInterruptedOnlyAfterARestart() async throws {
        let f = try Fixture(failure: .tests)
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        try await f.settle()
        let records = await f.ledger.allRecords()
        let startIndex = try #require(records.firstIndex {
            if case .runStarted(_, .verifier) = $0.event.kind { $0.event.node == f.requirement.nodeID } else { false }
        })
        guard case .runStarted(let run, _) = records[startIndex].event.kind else { return }
        #expect(records.contains {
            if case .runFinished(run, "failed") = $0.event.kind { true } else { false }
        })

        let running = try Ledger()
        try await running.append(records[...startIndex].map(\.event))
        let during = await running.workingState()
        let root = try #require(during.nodes[f.requirement.nodeID])
        #expect(during.status(of: root) == "In progress")
        #expect(during.running.map(\.id) == [root.id], "The work pane lists the check with the running agents.")
        #expect(!during.attentionList.contains { $0.node.id == root.id }, "Running is not interrupted.")

        _ = await f.makeReconciler(ledger: running).recoverAfterRestart()
        let restarted = await running.workingState()
        #expect(restarted.attentionList.contains { $0.node.id == root.id && $0.reason.contains("interrupted") })
        #expect(restarted.status(of: try #require(restarted.nodes[root.id])) == "Needs input")
    }

    @Test
    func stoppingARunningFinalVerificationFinishesItsRunAndLeavesItInterrupted() async throws {
        let f = try Fixture()
        defer { f.removeFiles() }
        _ = try await f.seedCompletedComposite()
        let hold = f.requirementDirectory.appending(path: "hold")
        try Data().write(to: hold)
        let round = Task { await f.reconciler.runRound(waitForAgents: true) }
        let run = try await withHangGuard("final verification starting") {
            while true {
                if let active = await f.ledger.workingState().nodes[f.requirement.nodeID]?.activeRun { return active.run }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await f.reconciler.stopRun(run, by: "Jane")
        try FileManager.default.removeItem(at: hold) // Without a working stop, the check then finishes: no hang.
        _ = await round.value

        let state = await f.ledger.workingState()
        let root = try #require(state.nodes[f.requirement.nodeID])
        #expect(root.activeRun == nil && root.requirementVerification == nil)
        #expect(await f.ledger.records(for: root.id).contains {
            if case .runFinished(run, "stopped by Jane") = $0.event.kind { true } else { false }
        })
        #expect(state.attentionList.contains { $0.node.id == root.id && $0.reason.contains("interrupted") })
        #expect(state.status(of: root) == "Needs input")
        #expect(await f.reconciler.busyNodes.isEmpty)
    }
}
