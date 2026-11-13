// API contract: EffectivePolicy resolves review limits and settings provenance. AgentTeam.reviewer
// is assigned after its existing initializer (no new `reviewer:` initializer argument is required).
// Reconciler requests acceptance-test and change reviews through Reviewer.review(_:), using
// Workspace.reviewContext(in:against:) for the full diff, same-file history and UI evidence.
// Review results gate implementation/landing, feed findings back, and replay into NodeState.reviews.
// The complete signatures, policy JSON and unresolved product choices are in .agentos-report.json.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_28Tests {
    @Test
    func oldSettingsAndAnUnconfiguredRepoRequireAgentReviewByDefault() throws {
        let oldSettings = try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8))
        for harness in [HarnessSettings(), oldSettings] {
            let effective = EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
            #expect(effective.policy.review.level(for: ["Engine"]) == .agent)
            #expect(effective.problems.isEmpty)
            let row = try #require(effective.settings.first { $0.name == "Review level" })
            #expect(row.value == "agent")
            #expect(row.source == .harness)
        }
    }

    @Test(arguments: [
        ("none", "none"), ("none", "agent"), ("none", "agent+human"),
        ("agent", "agent"), ("agent", "agent+human"), ("agent+human", "agent+human"),
    ])
    func reposCanKeepOrTightenTheHarnessReviewMinimum(levels: (String, String)) throws {
        let effective = try resolve(minimum: levels.0, review: ["level": levels.1])
        #expect(effective.problems.isEmpty)
        #expect(effective.policy.review.level(for: ["Engine"]).rawValue == levels.1)
    }

    @Test(arguments: [("agent", "none"), ("agent+human", "none"), ("agent+human", "agent")])
    func aLooserRepoLevelIsAStartBlockerAndDoesNotLowerTheEffectiveLevel(
        levels: (String, String)
    ) throws {
        let effective = try resolve(minimum: levels.0, review: ["level": levels.1])
        #expect(effective.policy.review.level(for: ["Engine"]).rawValue == levels.0)
        let blocker = try #require(effective.problems.first {
            $0.check == "config.policy" && $0.severity == .blocker
        })
        #expect((blocker.title + blocker.detail).lowercased().contains("review"))
        #expect((blocker.title + blocker.detail).contains(levels.0))
        #expect(blocker.suggestion?.contains(RepoConfig.path) == true)
        let scan = ReadinessScan(branch: "main", commit: "base", findings: effective.problems)
        #expect(!scan.isReady)
        #expect(RepositorySession.blockers(scan).contains(blocker.title))
        let row = try #require(effective.settings.first { $0.name == "Review level" })
        #expect(row.source == .harness)
        #expect(row.note?.isEmpty == false)
    }

    @Test
    func theStrictestOfAllTouchedAreasAppliesRegardlessOfOrder() throws {
        let effective = try resolve(minimum: "none", review: [
            "level": "none", "areas": ["Engine": "agent", "AgentOSUI": "agent+human"],
        ])
        #expect(effective.problems.isEmpty)
        #expect(effective.policy.review.level(for: ["Unrelated"]).rawValue == "none")
        #expect(effective.policy.review.level(for: ["Engine"]).rawValue == "agent")
        #expect(effective.policy.review.level(for: ["Engine", "AgentOSUI"]).rawValue == "agent+human")
        #expect(effective.policy.review.level(for: ["AgentOSUI", "Engine"]).rawValue == "agent+human")
    }

    @Test
    func anAreaCannotWeakenEitherTheHarnessMinimumOrTheRepoOverallLevel() throws {
        for (minimum, overall) in [("agent", "agent"), ("none", "agent+human")] {
            let effective = try resolve(minimum: minimum, review: [
                "level": overall, "areas": ["AgentOSUI": "none"],
            ])
            #expect(effective.policy.review.level(for: ["AgentOSUI"]).rawValue == overall)
            #expect(effective.problems.contains { $0.severity == .blocker })
        }
    }

    @Test
    func reviewConfigurationIsRecognizedAndSurvivesSaving() throws {
        let object: [String: Any] = [
            "test": ["command": "swift test"],
            "review": [
                "level": "agent", "areas": ["AgentOSUI": "agent+human"],
                "instructions": ".agentos/review.md", "maxRounds": 2, "model": "offered-reviewer",
            ],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let parsed = try RepoConfig.parse(text)
        #expect(!parsed.unknownKeys.contains("review"))
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(parsed.config.json.utf8)) as? [String: Any]
        )
        let review = try #require(saved["review"] as? [String: Any])
        #expect(review["level"] as? String == "agent")
        #expect(review["areas"] as? [String: String] == ["AgentOSUI": "agent+human"])
        #expect(review["instructions"] as? String == ".agentos/review.md")
        #expect(review["maxRounds"] as? Int == 2)
        #expect(review["model"] as? String == "offered-reviewer")
    }

    @Test
    func theDefaultReviewerUsesAnOfferedModelDifferentFromTheImplementers() throws {
        var configured = try settings(minimum: "agent")
        configured.models[.implementer] = "model-a"
        configured.review.offeredModels = ["model-a", "model-b"]
        let policy = EffectivePolicy.resolve(harness: configured, repo: nil, defaultBranch: "main")
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: policy)
        let reviewer = try #require(team.reviewer as? CopilotReviewer)
        #expect(reviewer.cli.model == "model-b")
    }

    @Test
    func withoutOfferedReviewerModelsTheDefaultReviewerUsesTheCLIsDefaultModelNeverAMadeUpOne() throws {
        var configured = try settings(minimum: "agent")
        configured.models[.implementer] = "model-a"
        let policy = EffectivePolicy.resolve(harness: configured, repo: nil, defaultBranch: "main")
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: policy)
        let reviewer = try #require(team.reviewer as? CopilotReviewer)
        #expect(reviewer.cli.model == nil)
        let setting = try #require(policy.settings.first { $0.name == "Reviewer" })
        #expect(setting.value == "CLI default model")
        #expect(setting.note?.contains("offered reviewer models") == true)
    }

    @Test
    func theReviewerFallsBackToOtherOfferedModelsThenTheCLIsDefault() throws {
        var configured = try settings(minimum: "agent")
        configured.models[.implementer] = "model-a"
        configured.review.offeredModels = ["model-a", "model-b", "model-c"]
        let policy = EffectivePolicy.resolve(harness: configured, repo: nil, defaultBranch: "main")
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: policy)
        let reviewer = try #require(team.reviewer as? CopilotReviewer)
        #expect(reviewer.cli.model == "model-b")
        #expect(reviewer.cli.fallbackModels == ["model-c", nil])
    }

    @Test
    func aModelTheAccountDoesntOfferIsSkippedForTheNextOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gh28-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copilot = directory.appending(path: "copilot")
        try """
        #!/bin/sh
        model=default
        while [ $# -gt 0 ]; do [ "$1" = --model ] && model=$2; shift; done
        case $model in gone|also-gone) echo "Execution failed: Model \\"$model\\" is not available."; exit 1;; esac
        echo "ran with $model"
        """.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)

        let cli = CopilotCLI(executable: copilot.path, model: "gone", fallbackModels: ["also-gone", "working", nil])
        let run = try await cli.runFallingBack("review", in: directory)
        #expect(run.output.contains("ran with working"))
        #expect(run.model == "working")
        #expect(run.unavailableModels == ["gone", "also-gone"])

        let none = CopilotCLI(executable: copilot.path, model: "gone", fallbackModels: ["also-gone"])
        await #expect(throws: AgentFailure.self) { try await none.runFallingBack("review", in: directory) }
    }

    @Test
    func harnessSettingsCanChooseASpecificReviewerModelOrCommand() throws {
        let modelPolicy = try resolve(
            minimum: "agent",
            reviewer: ["type": "specific", "model": "chosen-model"]
        )
        let modelTeam = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: modelPolicy)
        let modelReviewer = try #require(modelTeam.reviewer as? CopilotReviewer)
        #expect(modelReviewer.cli.model == "chosen-model")

        let commandPolicy = try resolve(
            minimum: "agent",
            reviewer: ["type": "specific", "command": "local-review --stdin"]
        )
        let commandTeam = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: commandPolicy)
        let commandReviewer = try #require(commandTeam.reviewer as? CommandReviewer)
        #expect(commandReviewer.command == "local-review --stdin")
    }

    @Test
    func aRepoOfferedReviewerModelIsUsedByTheRealTeamFactory() throws {
        let effective = try resolve(
            minimum: "agent", review: ["level": "agent", "model": "offered-reviewer"],
            offered: ["offered-reviewer"]
        )
        #expect(effective.problems.isEmpty)
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: effective)
        #expect((team.reviewer as? CopilotReviewer)?.cli.model == "offered-reviewer")
        let row = try #require(effective.settings.first { $0.name == "Reviewer" })
        #expect(row.value.contains("offered-reviewer"))
        #expect(row.source == .repo)
    }

    @Test
    func unofferedReviewerModelsBlockStartAndKeepTheHarnessReviewer() throws {
        let effective = try resolve(
            minimum: "agent", review: ["model": "unoffered"],
            offered: ["offered-reviewer"], reviewer: ["type": "specific", "model": "harness-reviewer"]
        )
        let blocker = try #require(effective.problems.first { $0.severity == .blocker })
        #expect((blocker.title + blocker.detail).contains("unoffered"))
        #expect((blocker.title + blocker.detail).contains("offered-reviewer"))
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: effective)
        #expect((team.reviewer as? CopilotReviewer)?.cli.model == "harness-reviewer")
        let row = try #require(effective.settings.first { $0.name == "Reviewer" })
        #expect(row.source == .harness)
        #expect(row.note?.contains("unoffered") == true)
    }

    @Test
    func settingsRowsShowBothEffectiveValuesAndTheirIndependentSources() throws {
        let inherited = try resolve(minimum: "agent", reviewer: ["type": "specific", "model": "harness-model"])
        let overridden = try resolve(
            minimum: "agent", review: ["level": "agent+human", "model": "repo-model"],
            offered: ["repo-model"], reviewer: ["type": "specific", "model": "harness-model"]
        )
        for (policy, source, level, model) in [
            (inherited, EffectiveSetting.Source.harness, "agent", "harness-model"),
            (overridden, EffectiveSetting.Source.repo, "agent+human", "repo-model"),
        ] {
            let levelRow = try #require(policy.settings.first { $0.name == "Review level" })
            let reviewerRow = try #require(policy.settings.first { $0.name == "Reviewer" })
            #expect(levelRow.value == level)
            #expect(levelRow.source == source)
            #expect(reviewerRow.value.contains(model))
            #expect(reviewerRow.source == source)
        }
        let mixed = try resolve(minimum: "agent", review: ["level": "agent+human"])
        #expect(mixed.settings.first { $0.name == "Review level" }?.source == .repo)
        #expect(mixed.settings.first { $0.name == "Reviewer" }?.source == .harness)
    }

    @Test
    func repoRulesReachBothReviewStagesAlongsideTheBuiltInChecklist() async throws {
        let fixture = try await Fixture(review: ["instructions": ".agentos/review.md"])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        let requests = await fixture.reviewer.requests
        #expect(requests.contains { $0.stage == .acceptanceTests })
        #expect(requests.contains { $0.stage == .change })
        for request in requests {
            let prompt = CopilotReviewer.prompt(for: request)
            #expect(prompt.contains(Fixture.repoRules))
            #expect(prompt.contains(Fixture.spec.intent))
            #expect(prompt.lowercased().contains("regression"))
            #expect(prompt.lowercased().contains("allocation"))
        }
    }

    @Test(arguments: [
        ("@Test func size() { #expect(7 == 7) }", "Only checks a constant."),
        ("@Test func type() { #expect(String.self == String.self) }", "Only checks a type."),
        ("@Test func resize() { #expect(FakeWindow().resizes) }", "Made-up API does not exercise a window."),
        ("@Test func opens() { #expect(true) }", "Passes even when the window does not open."),
    ])
    func weakAcceptanceTestsAreReviewedBeforeAnyImplementationAndReturnedWithReasons(
        example: (String, String)
    ) async throws {
        let fixture = try await Fixture(
            testSource: example.0,
            testResults: [ReviewResult(passed: false, findings: [example.1]), .init(passed: true, findings: [])]
        )
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.reviewer.requests.count == 1 }
        #expect(await fixture.builder.tasks.isEmpty)
        #expect(await fixture.workspace.landedCount == 0)
        let request = try #require(await fixture.reviewer.requests.first)
        #expect(request.stage == .acceptanceTests)
        #expect(request.spec.acceptanceCriteria == Fixture.spec.acceptanceCriteria)
        #expect(request.acceptanceTests[Fixture.testFile] == example.0)
        let prompt = CopilotReviewer.prompt(for: request).lowercased()
        for alternatives in [["constant"], ["type"], ["made-up", "invented", "fabricated"], ["requirement"]] {
            #expect(alternatives.contains { prompt.contains($0) })
        }
        // Criteria the test author can't test (source layout, build settings) go to the change review instead.
        #expect(prompt.contains("source text") && prompt.contains("build settings")
                && prompt.contains("checked at the change stage"))
        try await fixture.advanceUntil { await fixture.author.tasks.count == 2 }
        let rewrite = try #require(await fixture.author.tasks.last)
        #expect(rewrite.previousFailure?.contains(example.1) == true)
        #expect(await fixture.builder.tasks.isEmpty)
        #expect(await fixture.tracker.comments.contains { $0.contains(example.1) })
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.builder.tasks.count == 1)
    }

    @Test
    func changeReviewRunsOnlyAfterChecksAndReceivesTheWholeDiffAndSameFileHistory() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        let request = try #require(await fixture.reviewer.requests.first { $0.stage == .change })
        #expect(request.spec == Fixture.spec)
        #expect(request.context.baseBranch == "agentos/main")
        #expect(request.context.fullDiff == Fixture.fullDiff)
        #expect(request.context.recentChanges == [Fixture.recentChange])
        #expect(request.context.changedFiles.contains(Fixture.productionFile))
        #expect(request.context.changedFiles.contains(Fixture.testFile))
        #expect(await fixture.workspace.requestedBases.allSatisfy { $0 == "agentos/main" })
        let events = await fixture.trace.events
        let testsReviewed = try #require(events.firstIndex(of: "review:tests"))
        let implemented = try #require(events.firstIndex(of: "implement"))
        let checked = try #require(events.firstIndex(of: "checks:all"))
        let reviewed = try #require(events.firstIndex(of: "review:change"))
        let landed = try #require(events.firstIndex(of: "land"))
        #expect(testsReviewed < implemented)
        #expect(implemented < checked)
        #expect(checked < reviewed)
        #expect(reviewed < landed)
    }

    @Test
    func aFailedCheckCannotBeBypassedByAPassingReviewer() async throws {
        let fixture = try await Fixture(checksPass: false)
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.checks.calls > 0 }
        #expect(await fixture.reviewer.requests.allSatisfy { $0.stage != .change })
        #expect(await fixture.workspace.landedCount == 0)
    }

    @Test
    func theBuiltInReviewPromptRequiresAllFourQualityChecksAndPracticalUIEvidence() async throws {
        let fixture = try await Fixture(ui: true, evidence: Self.completeUIEvidence)
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.reviewer.requests.contains { $0.stage == .change } }
        let request = try #require(await fixture.reviewer.requests.first { $0.stage == .change })
        let prompt = CopilotReviewer.prompt(for: request).lowercased()
        for required in [
            "regression", "constraint", "minimum", "permission", "i/o", "allocation",
            "line", "loop", "duplicat", "recent", "requirement", "snapshot", "open", "close",
        ] {
            #expect(prompt.contains(required), "The reviewer must be instructed about \(required)")
        }
        #expect(CopilotReviewer.prompt(for: request).contains(Fixture.fullDiff))
    }

    @Test(arguments: [0, 1, 2])
    func UIChangesCannotLandWithOnlyLogicTestsOrIncompleteWindowEvidence(missing: Int) async throws {
        var evidence = Self.completeUIEvidence
        switch missing {
        case 0: evidence.snapshotPaths = []
        case 1: evidence.windowsOpened = false
        default: evidence.windowsClosed = false
        }
        let fixture = try await Fixture(ui: true, evidence: evidence)
        defer { fixture.cleanUp() }
        await fixture.rounds(10)
        #expect(await fixture.workspace.landedCount == 0)
        let comments = await fixture.tracker.comments.joined(separator: "\n").lowercased()
        #expect(comments.contains("snapshot") || comments.contains("window"))
        #expect(comments.contains("harness:"))
    }

    @Test
    func aUIChangeWithSnapshotsAndWorkingWindowsCanPassAgentReview() async throws {
        let fixture = try await Fixture(ui: true, evidence: Self.completeUIEvidence)
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        let request = try #require(await fixture.reviewer.requests.first { $0.stage == .change })
        #expect(request.context.uiEvidence == Self.completeUIEvidence)
    }

    @Test
    func findingsGoBackToTheImplementerAndOnlyTheReviewedReplacementLands() async throws {
        let finding = "Opening the log file once per line causes unnecessary I/O."
        let fixture = try await Fixture(changeResults: [
            .init(passed: false, findings: [finding]), .init(passed: true, findings: []),
        ])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.reviewer.requests.filter { $0.stage == .change }.count == 1 }
        #expect(await fixture.workspace.landedCount == 0)
        try await fixture.advanceUntil { await fixture.builder.tasks.count == 2 }
        let retry = try #require(await fixture.builder.tasks.last)
        #expect(retry.previousFailure?.contains(finding) == true)
        #expect(await fixture.author.tasks.count == 1)
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        let reviews = await fixture.reviewer.requests.filter { $0.stage == .change }
        try #require(reviews.count == 2)
        #expect(reviews[0].context.commit != reviews[1].context.commit)
        #expect(reviews[0].earlierFindings.isEmpty && !CopilotReviewer.prompt(for: reviews[0]).contains("EARLIER FINDINGS"))
        #expect(reviews[1].earlierFindings == [[finding]])
        let followUp = CopilotReviewer.prompt(for: reviews[1])
        #expect(followUp.contains("review round 2") && followUp.contains(finding) && followUp.contains("\"New:\""))
        #expect(await fixture.workspace.landedCommit == reviews[1].context.commit)
    }

    @Test
    func followUpsAreReportedOnTheTicketOnceWithoutFailingTheReview() async throws {
        let followUp = "AppModel.swift (not touched by this ticket) repeats the date formatting."
        let parsed = try CopilotReviewer.result(from: #"{"passed": true, "findings": [], "followUps": ["\#(followUp)"]}"#)
        #expect(parsed.passed && parsed.followUps == [followUp])
        let fixture = try await Fixture(changeResults: [
            .init(passed: false, findings: ["Opening the log file once per line causes unnecessary I/O."],
                  followUps: [followUp]),
            .init(passed: true, findings: [], followUps: [followUp]),
        ])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.builder.tasks.count == 2)
        #expect(await fixture.tracker.comments.filter { $0.contains("don't block") && $0.contains(followUp) }.count == 1)
    }

    @Test
    func aReviewWithTestFindingsFailsEvenIfTheReviewerSaidPassed() throws {
        let clean = try CopilotReviewer.result(from: #"{"passed": true, "findings": [], "testFindings": []}"#)
        #expect(clean.passed && clean.testFindings == nil)
        let tests = try CopilotReviewer.result(from: #"{"passed": true, "findings": [], "testFindings": ["Order-dependent."]}"#)
        #expect(!tests.passed && tests.testFindings == ["Order-dependent."])
    }

    @Test
    func changeReviewFindingsInTheTicketsOwnTestsGoToTheTestAuthorNotTheImplementer() async throws {
        let testFinding = "The test requires B to start before C, though the ticket only bounds concurrency."
        let changeFinding = "Package.swift: the test target doesn't declare the module it imports."
        let fixture = try await Fixture(changeResults: [
            .init(passed: false, findings: [changeFinding], testFindings: [testFinding]), .init(passed: true, findings: []),
        ])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.author.tasks.count == 2 }
        let rewrite = try #require(await fixture.author.tasks.last)
        #expect(rewrite.previousFailure?.contains(testFinding) == true)
        #expect(await fixture.node()?.flags[.escalated] == nil)
        try await fixture.advanceUntil { await fixture.builder.tasks.count == 2 }
        let rebuild = try #require(await fixture.builder.tasks.last)
        #expect(rebuild.previousFailure?.contains(changeFinding) == true)
        #expect(rebuild.previousFailure?.contains(testFinding) != true)
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.tracker.comments.contains { $0.contains("sent back to the test author") && $0.contains(testFinding) })
    }

    @Test
    func anImplementerThatChangesNothingForReviewFindingsWaitsForAPersonInsteadOfRepeatingTheReview() async throws {
        let finding = "The test requires B to start before C, though the ticket only bounds concurrency."
        let fixture = try await Fixture(
            review: ["maxRounds": 3],
            changeResults: [.init(passed: false, findings: [finding])],
            builderReports: [AgentReport(), AgentReport(alreadySatisfied: true), AgentReport()]
        )
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.node()?.flags[.needsInput] != nil }
        await fixture.rounds(2)
        #expect(await fixture.builder.tasks.count == 2)
        #expect(await fixture.reviewer.requests.filter { $0.stage == .change }.count == 1)
        let stop = try #require(await fixture.tracker.comments.last)
        #expect(stop.contains(finding) && stop.contains("harness:retest") && stop.contains("harness:retry"))

        // The person says the code should change: the implementer, not the test author, runs again with that answer.
        let answer = "The finding is right: make the scheduler start whichever node is eligible first."
        await fixture.tracker.reply(answer, by: "Alice")
        await fixture.tracker.add(.retry, by: .human("Alice"))
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.author.tasks.count == 1)
        let rerun = try #require(await fixture.builder.tasks.last)
        #expect(rerun.clarifications.contains { $0.answer == answer })
    }

    @Test
    func afterARetestOnlyReviewsOfTheNewWorkCountTowardsMaxRounds() async throws {
        let old = ["The old test pins scheduling order.", "The old test sleeps."]
        let testFinding = "The new test skips the waiting branch."
        let fixture = try await Fixture(changeResults: old.map { .init(passed: false, findings: [$0]) }
            + [.init(passed: false, findings: [], testFindings: [testFinding])])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.node()?.flags[.escalated] != nil }
        await fixture.tracker.add(.retest, by: .human("Alice"))
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.author.tasks.count == 3)
        let comments = await fixture.tracker.comments
        #expect(comments.contains { $0.contains("sent back to the test author") && $0.contains(testFinding) })
        #expect(await fixture.node()?.flags[.escalated] == nil)
    }

    @Test
    func maxRoundsEscalatesWithAllFindingsAndDoesNotStartAnotherAutomaticAttempt() async throws {
        let findings = ["The minimum window size clips the Done button.", "Timestamp logic duplicates landed code."]
        let fixture = try await Fixture(
            review: ["maxRounds": 2],
            changeResults: findings.map { .init(passed: false, findings: [$0]) }
        )
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.node()?.flags[.escalated] != nil }
        await fixture.rounds(4)
        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.escalated])
        let comments = await fixture.tracker.comments.joined(separator: "\n")
        for finding in findings {
            #expect((reason + comments).contains(finding))
        }
        #expect(comments.contains("harness:retry"))
        #expect(comments.contains("split it into smaller tickets"))
        #expect(await fixture.reviewer.requests.filter { $0.stage == .change }.count == 2)
        #expect(await fixture.builder.tasks.count == 2)
        #expect(await fixture.workspace.landedCount == 0)
    }

    @Test
    func repeatedTestReviewFindingsAlsoStopAtMaxRoundsBeforeImplementation() async throws {
        let findings = ["The test only checks a constant.", "The replacement still does not exercise a window."]
        let fixture = try await Fixture(
            review: ["maxRounds": 2],
            testResults: findings.map { .init(passed: false, findings: [$0]) }
        )
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.node()?.flags[.escalated] != nil }
        await fixture.rounds(3)
        #expect(await fixture.author.tasks.count == 2)
        #expect(await fixture.builder.tasks.isEmpty)
        #expect(await fixture.workspace.landedCount == 0)
        #expect(await fixture.reviewer.requests.count == 2)
        let node = try #require(await fixture.node())
        let comments = await fixture.tracker.comments.joined(separator: "\n")
        for finding in findings {
            #expect(((node.flags[.escalated] ?? "") + comments).contains(finding))
        }
    }

    @Test
    func agentAndHumanWaitsInReviewDespiteAnAlreadyOpenBuildGateAndRejectsAgentApproval() async throws {
        let fixture = try await Fixture(review: ["level": "agent+human"])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.reviewer.requests.contains { $0.stage == .change } }
        await fixture.rounds(3)
        let state = await fixture.ledger.workingState()
        let node = try #require(state.nodes[Fixture.spec.id])
        #expect(node.gates.contains(.build))
        #expect(state.status(of: node) == "In review")
        #expect(await fixture.tracker.status == "In review")
        #expect(await fixture.workspace.landedCount == 0)
        #expect(node.reviews.contains { $0.stage == .change && $0.result.passed })
        #expect(await fixture.tracker.comments.contains { $0.contains("harness:build") })

        await fixture.tracker.add(.build, by: .agent(run: "spoof", role: .implementer))
        await fixture.rounds(2)
        #expect(await fixture.workspace.landedCount == 0)
        await fixture.tracker.add(.build, by: .human("Alice"))
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.node()?.phase == .proven)
    }

    @Test
    func actualUITouchesRaiseTheLevelEvenWhenTheDeclaredTouchSetMissesThem() async throws {
        let fixture = try await Fixture(
            review: ["level": "agent", "areas": ["AgentOSUI": "agent+human"]],
            ui: true, evidence: Self.completeUIEvidence
        )
        defer { fixture.cleanUp() }
        #expect(Fixture.spec.touches == ["Engine"])
        try await fixture.advanceUntil { await fixture.reviewer.requests.contains { $0.stage == .change } }
        await fixture.rounds(3)
        let node = try #require(await fixture.node())
        let state = await fixture.ledger.workingState()
        #expect(state.status(of: node) == "In review")
        #expect(await fixture.workspace.landedCount == 0)
        await fixture.tracker.add(.build, by: .human("Alice"))
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
    }

    @Test
    func humanUIReviewShowsTheAgentFindingsAndBothScreenshotsBeforeApproval() async throws {
        let fixture = try await Fixture(
            review: ["level": "agent+human"], ui: true, evidence: Self.completeUIEvidence
        )
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.reviewer.requests.contains { $0.stage == .change } }
        await fixture.rounds(2)
        let node = try #require(await fixture.node())
        let review = try #require(node.reviews.last { $0.stage == .change })
        #expect(review.result.passed)
        #expect(review.uiEvidence == Self.completeUIEvidence)
        let comments = await fixture.tracker.comments.joined(separator: "\n")
        #expect(comments.contains("before.png"))
        #expect(comments.contains("after.png"))
        #expect(comments.lowercased().contains("review"))
        #expect(await fixture.workspace.landedCount == 0)
    }

    @Test(arguments: [true, false])
    func humanUIReviewCannotBeApprovedWithoutBothScreenshots(missingBefore: Bool) async throws {
        var evidence = Self.completeUIEvidence
        if missingBefore { evidence.beforeScreenshot = nil } else { evidence.afterScreenshot = nil }
        let fixture = try await Fixture(review: ["level": "agent+human"], ui: true, evidence: evidence)
        defer { fixture.cleanUp() }
        await fixture.rounds(7)
        await fixture.tracker.add(.build, by: .human("Alice"))
        await fixture.rounds(3)
        #expect(await fixture.workspace.landedCount == 0)
        let comments = await fixture.tracker.comments.joined(separator: "\n").lowercased()
        #expect(comments.contains("screenshot"))
    }

    @Test
    func everyReviewAndItsFindingsAreLedgerEventsAndSurviveReloadingTheNode() async throws {
        let finding = "Tests do not prove the requirement."
        let fixture = try await Fixture(testResults: [
            .init(passed: false, findings: [finding]), .init(passed: true, findings: []),
        ])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        let records = await fixture.ledger.allRecords()
        let reviews = records.compactMap { record -> ReviewRecord? in
            guard record.event.node == Fixture.spec.id,
                  case .reviewRecorded(let review) = record.event.kind else { return nil }
            return review
        }
        try #require(reviews.count == 3)
        #expect(reviews.map(\.stage) == [.acceptanceTests, .acceptanceTests, .change])
        #expect(reviews[0].result.findings == [finding])
        #expect(!reviews[0].result.passed)
        #expect(reviews[1].result.passed && reviews[2].result.passed)
        let encoded = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([RecordedEvent].self, from: encoded)
        let store = InMemoryLedgerStore()
        store.append(decoded)
        let reloaded = try Ledger(store: store)
        let node = try #require(await reloaded.workingState().nodes[Fixture.spec.id])
        #expect(node.reviews == reviews)
        #expect(await reloaded.verifyChain().isIntact)
        #expect(records.contains { $0.event.kind.summary.contains(finding) })
    }

    @Test
    func noneSkipsBothReviewsButStillRunsChecksBeforeLanding() async throws {
        let fixture = try await Fixture(minimum: "none", review: ["level": "none"])
        defer { fixture.cleanUp() }
        try await fixture.advanceUntil { await fixture.workspace.landedCount == 1 }
        #expect(await fixture.reviewer.requests.isEmpty)
        #expect(await fixture.checks.calls > 0)
    }
}

private extension GH_28Tests {
    static var completeUIEvidence: UIReviewEvidence {
        UIReviewEvidence(
            snapshotPaths: ["artifacts/log-snapshot.png"], windowsOpened: true, windowsClosed: true,
            beforeScreenshot: "artifacts/before.png", afterScreenshot: "artifacts/after.png"
        )
    }

    func settings(
        minimum: String, offered: [String] = [], reviewer: [String: String] = ["type": "default"]
    ) throws -> HarnessSettings {
        let reviewSettings: [String: Any] = [
            "level": minimum, "reviewer": reviewer, "offeredModels": offered,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["review": reviewSettings])
        return try JSONDecoder().decode(HarnessSettings.self, from: data)
    }

    func resolve(
        minimum: String, review: [String: Any]? = nil, offered: [String] = [],
        reviewer: [String: String] = ["type": "default"]
    ) throws -> EffectivePolicy {
        let harness = try settings(minimum: minimum, offered: offered, reviewer: reviewer)
        var json: [String: Any] = ["test": ["command": "swift test"]]
        if let review { json["review"] = review }
        let config = try JSONDecoder().decode(
            RepoConfig.self, from: JSONSerialization.data(withJSONObject: json)
        )
        return EffectivePolicy.resolve(harness: harness, repo: config, defaultBranch: "main")
    }

    final class Fixture: Sendable {
        static let spec = NodeSpec(
            id: "wn-GH-28", parent: nil, kind: .leaf, title: "Resizable log window",
            intent: "Keep the Log window usable while resizing.",
            acceptanceCriteria: ["The Log window resizes without clipping Done and can be closed."],
            touches: ["Engine"]
        )
        static let folder = "Tests/AgentOSAdaptersTests/GH_28Tests"
        static let testFile = folder + "/WindowTests.swift"
        static let productionFile = "Sources/Engine/Log.swift"
        static let repoRules = "Review rule: preserve keyboard dismissal and the existing minimum window size."
        static let recentChange = LandedWorkItem(ticket: "GH-23", title: "Timestamp Log lines", commit: "recent-log-change")
        static let fullDiff = """
        diff --git a/Sources/Engine/Log.swift b/Sources/Engine/Log.swift
        --- a/Sources/Engine/Log.swift
        +++ b/Sources/Engine/Log.swift
        @@ -1 +1 @@
        -let minimumWidth = 480
        +let minimumWidth = 0
        diff --git a/Tests/AgentOSAdaptersTests/GH_28Tests/WindowTests.swift b/Tests/AgentOSAdaptersTests/GH_28Tests/WindowTests.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/AgentOSAdaptersTests/GH_28Tests/WindowTests.swift
        @@ -0,0 +1 @@
        +@Test func windowRemainsUsable() { /* exercise real window */ }
        """

        let directory: URL
        let ledger: Ledger
        let tracker: Tracker
        let author: Author
        let builder: Builder
        let reviewer: RecordingReviewer
        let workspace: TestWorkspace
        let checks: Checks
        let trace: Trace
        let reconciler: Reconciler

        init(
            minimum: String = "agent", review: [String: Any] = [:],
            testSource: String = "@Test func windowRemainsUsable() { /* exercise real window */ }",
            testResults: [ReviewResult] = [], changeResults: [ReviewResult] = [],
            builderReports: [AgentReport] = [],
            ui: Bool = false, evidence: UIReviewEvidence? = nil, checksPass: Bool = true
        ) async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "agentos-gh28-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory.appending(path: ".agentos"), withIntermediateDirectories: true)
            try Self.repoRules.write(to: directory.appending(path: ".agentos/review.md"), atomically: true, encoding: .utf8)
            ledger = try Ledger()
            trace = Trace()
            tracker = Tracker()
            author = Author(source: testSource, trace: trace)
            builder = Builder(reports: builderReports, trace: trace)
            workspace = TestWorkspace(directory: directory, ui: ui, evidence: evidence, trace: trace)
            checks = Checks(passed: checksPass, trace: trace)
            reviewer = RecordingReviewer(testResults: testResults, changeResults: changeResults, trace: trace)
            var configuration = review
            if configuration["level"] == nil { configuration["level"] = minimum }
            if configuration["maxRounds"] == nil { configuration["maxRounds"] = 2 }
            let effective = try GH_28Tests().resolve(minimum: minimum, review: configuration)
            var policy = effective.policy
            policy.guesswork = .autonomous
            var team = AgentTeam(name: "acceptance", decomposer: Services(), testAuthor: author, implementer: builder)
            team.reviewer = reviewer
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: Services(), workspace: workspace,
                artifacts: Services(), checks: checks, team: team, policy: policy
            )
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-28")),
                LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            ])
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
        func node() async -> NodeState? { await ledger.workingState().nodes[Self.spec.id] }
        func rounds(_ count: Int) async {
            for _ in 0..<count { _ = await reconciler.runRound(waitForAgents: true) }
        }
        func advanceUntil(_ condition: () async -> Bool) async throws {
            for _ in 0..<30 {
                if await condition() { return }
                let report = await reconciler.runRound(waitForAgents: true)
                #expect(report.safeStop == nil)
            }
            #expect(await condition(), "The expected observable state was not reached within 30 rounds")
            throw AgentFailure("GH_28Tests fixture did not reach its expected state")
        }
    }

    actor Trace {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    actor Tracker: TrackerAdapter {
        private(set) var comments: [String] = []
        private var thread: [AgentOSCore.Comment] = []
        private(set) var status = ""
        private var signals: [Signal] = []
        func add(_ command: HarnessCommand, by person: Participant) {
            signals.append(Signal(ticket: "GH-28", command: command, setBy: person))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? {
            var ticket = Ticket(key: key, title: Fixture.spec.title, description: Fixture.spec.intent,
                                acceptanceCriteria: Fixture.spec.acceptanceCriteria, createdBy: .human("Alice"))
            ticket.comments = thread
            return ticket
        }
        func reply(_ text: String, by person: String) { thread.append(AgentOSCore.Comment(author: .human(person), text: text)) }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("Leaf fixture must not create children")
        }
        func comment(on key: String, _ text: String) {
            comments.append(text)
            thread.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { self.status = status }
    }

    actor Author: TestAuthor {
        let source: String
        let trace: Trace
        private(set) var tasks: [AgentTask] = []
        init(source: String, trace: Trace) { self.source = source; self.trace = trace }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            tasks.append(task)
            await trace.add("author")
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try source.write(to: folder.appending(path: "WindowTests.swift"), atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    actor Builder: Implementer {
        static let unchangedMarker = ".unchanged"
        let trace: Trace
        private var reports: [AgentReport]
        private(set) var tasks: [AgentTask] = []
        init(reports: [AgentReport], trace: Trace) { self.reports = reports; self.trace = trace }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            tasks.append(task)
            await trace.add("implement")
            let report = reports.isEmpty ? AgentReport() : reports.removeFirst()
            if report.alreadySatisfied {
                try Data().write(to: task.directory.appending(path: Self.unchangedMarker))
            }
            return report
        }
    }

    actor RecordingReviewer: Reviewer {
        let trace: Trace
        private var testResults: [ReviewResult]
        private var changeResults: [ReviewResult]
        private(set) var requests: [ReviewRequest] = []
        init(testResults: [ReviewResult], changeResults: [ReviewResult], trace: Trace) {
            self.testResults = testResults
            self.changeResults = changeResults
            self.trace = trace
        }
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            requests.append(request)
            switch request.stage {
            case .acceptanceTests:
                await trace.add("review:tests")
                return testResults.isEmpty ? .init(passed: true, findings: []) : testResults.removeFirst()
            case .change:
                await trace.add("review:change")
                return changeResults.isEmpty ? .init(passed: true, findings: []) : changeResults.removeFirst()
            }
        }
    }

    actor Checks: CheckRunner {
        let passed: Bool
        let trace: Trace
        private(set) var calls = 0
        init(passed: Bool, trace: Trace) { self.passed = passed; self.trace = trace }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            calls += 1
            await trace.add(testTarget == nil ? "checks:all" : "checks:own")
            return CheckOutput(passed: passed, summary: passed ? "Checks passed" : "Window test failed", log: "check log")
        }
    }

    actor TestWorkspace: Workspace {
        nonisolated let directory: URL
        let ui: Bool
        let evidence: UIReviewEvidence?
        let trace: Trace
        private var implemented = false
        private var revision = 0
        private(set) var landedCount = 0
        private(set) var landedCommit: String?
        private(set) var requestedBases: [String] = []
        init(directory: URL, ui: Bool, evidence: UIReviewEvidence?, trace: Trace) {
            self.directory = directory; self.ui = ui; self.evidence = evidence; self.trace = trace
        }
        nonisolated var testArea: String { "Tests/AgentOSAdaptersTests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { directory }
        nonisolated func testFolder(for spec: NodeSpec) -> String { Fixture.folder }
        nonisolated func existingComponents() -> [String] { ["Engine", "AgentOSUI"] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws { implemented = false }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let unchanged = directory.appending(path: Builder.unchangedMarker)
            if FileManager.default.fileExists(atPath: unchanged.path) {
                try FileManager.default.removeItem(at: unchanged)
                return nil
            }
            if !message.contains("acceptance tests") { implemented = true }
            revision += 1
            return "revision-\(revision)"
        }
        func head(of directory: URL) async throws -> String { "revision-\(revision)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            guard implemented else { return [Fixture.testFile] }
            return [Fixture.testFile, Fixture.productionFile] + (ui ? ["Sources/AgentOSUI/LogWindow.swift"] : [])
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws { implemented = false }
        func prepareBuild(in directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            landedCount += 1
            landedCommit = "revision-\(revision)"
            await trace.add("land")
            return "revision-\(revision)"
        }
        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
            requestedBases.append(branch)
            return ReviewContext(
                baseBranch: branch, commit: "revision-\(revision)", fullDiff: Fixture.fullDiff,
                changedFiles: try await changedFiles(in: directory), recentChanges: [Fixture.recentChange],
                uiEvidence: evidence
            )
        }
    }

    struct Services: Decomposer, ExternalDependencySource, ArtifactStore {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("Leaf fixture must not decompose")
        }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
