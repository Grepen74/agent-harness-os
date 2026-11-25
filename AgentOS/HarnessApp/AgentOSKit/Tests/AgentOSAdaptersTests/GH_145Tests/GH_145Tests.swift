// API: HarnessCommand.updateTest labels harness:update-test; accepting it records
// EventKind.testUpdatesApproved(files: [String]) by the approving human, then resumes test authoring.
// Existing signal intake, broken-test routing and test-author seams exercise the real reconciler.
// Source-only criterion 6: README.md and docs/real-repo-mode.md describe the signal's applicability,
// recorded approval and next steps; review those documents against the implementation diff.

import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

@Suite struct GH_145Tests {
    @Test(arguments: [
        ("Tests/AgentOSAdaptersTests/GH_9Tests/Contract.swift", [String](), true),
        ("Tests/AgentOSCoreTests/Contract.swift", ["Tests/"], true),
        ("Tests/AgentOSCoreTests/Contract.swift", [], false),
        ("Tests/AgentOSAdaptersTestsExtra/Contract.swift", [], false),
    ])
    func conflictNextStepOffersBranchLocalApprovalOnlyInsideUpdatableAreas(
        file: String, extraAreas: [String], reachable: Bool
    ) async throws {
        let fixture = try await Fixture(file: file, extraAreas: extraAreas)
        defer { fixture.remove() }
        try await fixture.waitForConflict()

        #expect(HarnessCommand.updateTest.label == "harness:update-test")
        let comment = try #require(await fixture.tracker.comments.last {
            $0.text.contains("another test conflicts with this ticket")
        }?.text)
        let next = try #require(comment.components(separatedBy: "Next:").dropFirst().first)
        #expect(next.contains("harness:update-test") == reachable)
        #expect(next.contains("default branch"))
        #expect(next.contains("harness:retry"))
        if reachable {
            #expect(next.range(
                of: #"(?s)harness:update-test.{0,120}(?:guidance|comment)|(?:guidance|comment).{0,120}harness:update-test"#,
                options: [.regularExpression, .caseInsensitive]) != nil)
            #expect(next.localizedCaseInsensitiveContains("optional")
                || next.localizedCaseInsensitiveContains("if you like")
                || next.localizedCaseInsensitiveContains("if you want"))
            #expect(next.localizedCaseInsensitiveContains("test author"))
            #expect(next.localizedCaseInsensitiveContains("on this ticket's branch"))
        } else {
            #expect(!comment.contains("harness:update-test"))
        }
    }

    @Test(arguments: [false, true])
    func approvalRecordsTheExactFileAndHumanClearsFlagsAndReturnsToSpecified(escalated: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.waitForConflict()
        if escalated {
            try await fixture.append([
                .attemptFailed(summary: "first failed implementation"),
                .attemptFailed(summary: "second failed implementation"),
                .flagSet(.escalated, reason: "attempt budget exhausted"),
            ])
        }

        try await fixture.send(.updateTest)

        let node = try await fixture.node()
        #expect(node.phase == .specified)
        #expect(node.flags[.needsInput] == nil)
        #expect(node.flags[.escalated] == nil)
        #expect(node.failedAttempts == 0)
        let history = await fixture.history()
        let approval = try #require(history.first {
            if case .testUpdatesApproved = $0.event.kind { return true }
            return false
        })
        #expect(approval.event.node == Self.spec.id)
        #expect(approval.event.by == .human("Pat"))
        if case .testUpdatesApproved(let files) = approval.event.kind {
            #expect(files == [fixture.file])
        }
        #expect(history.filter { $0.position >= approval.position }.contains {
            if case .brokenTestRouted(Self.reportedTest, .sentBackToTestAuthor) = $0.event.kind { return true }
            return false
        })
        #expect(history.contains {
            if case .signalAccepted("GH-145", .updateTest, _) = $0.event.kind { return true }
            return false
        })
        if escalated {
            #expect(history.contains {
                if case .attemptsReset = $0.event.kind { return $0.event.by == .human("Pat") }
                return false
            })
        }
    }

    @Test
    func approvalWithoutACommentRestartsBothSameTestAndOverallBrokenReturnBudgets() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.waitForConflict()
        try await fixture.send(.updateTest)

        // The pre-approval history exhausted both budgets. Neither an answer nor an escalation is
        // needed for this approval to give the author another chance.
        for name in [Self.reportedTest, "AnotherTests.contract"] {
            try await fixture.route(name)
            let node = try await fixture.node()
            #expect(node.phase == .specified)
            #expect(node.flags[.needsInput] == nil)
            let lastRoute = await fixture.history().last {
                if case .brokenTestRouted = $0.event.kind { return true }
                return false
            }
            #expect(lastRoute.map {
                if case .brokenTestRouted(_, .sentBackToTestAuthor) = $0.event.kind { return true }
                return false
            } == true)
        }
    }

    @Test
    func guidanceAfterTheQuestionReachesTheRestartedAuthorsPromptAndItsUpdateIsCommitted() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.tracker.reply("An old discussion, not an answer to this conflict.")
        try await fixture.waitForConflict()
        let guidance = "Keep the negative cases, but expect the new identifier instead of the old one."
        await fixture.tracker.reply(guidance)
        await fixture.tracker.comment(on: "GH-145", "A harness status update is not the person's answer.")

        try await fixture.send(.updateTest)

        let answer = Clarification(questions: ["How to proceed with the conflicting test"], answer: guidance)
        #expect(try await fixture.node().clarifications.contains(answer))
        let answered = try #require(await fixture.history().first {
            if case .questionsAnswered(let value) = $0.event.kind { return value == answer }
            return false
        })
        #expect(answered.event.by == .human("Pat"))
        await fixture.author.update(fixture.file)
        try await fixture.authorTests()

        let task = try #require(await fixture.author.tasks.last)
        #expect(task.directory == fixture.directory)
        #expect(task.clarifications.contains(answer))
        let prompt = CopilotTestAuthor.prompt(for: task)
        let answersBlock = try #require(prompt.components(separatedBy: "<<<ANSWERS").dropFirst().first?
            .components(separatedBy: "ANSWERS>>>").first)
        #expect(answersBlock.contains("How to proceed with the conflicting test"))
        #expect(answersBlock.contains(guidance))
        #expect(!answersBlock.contains("An old discussion"))
        #expect(!answersBlock.contains("A harness status update"))

        let node = try await fixture.node()
        #expect(node.phase == .ready)
        #expect(node.flags[.escalated] == nil)
        #expect(node.updatedOtherTests.contains(fixture.file))
        #expect(await fixture.workspace.committedText(fixture.file) == Self.updatedTest)
        #expect(try String(contentsOf: fixture.directory.appending(path: fixture.file), encoding: .utf8) == Self.updatedTest)
        #expect(node.updatedOtherTestsDigest == Hashing.digest(ofFiles: [fixture.file], in: fixture.directory))
    }

    @Test(arguments: [NotWaiting.noInput, .unrelatedQuestions, .ownBrokenTest])
    func approvalIsRejectedUnlessThisNodeIsWaitingOnAnotherTest(situation: NotWaiting) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        switch situation {
        case .noInput:
            break
        case .unrelatedQuestions:
            try await fixture.append([
                .questionsRaised(role: .implementer, questions: ["Which identifier should be used?"]),
                .flagSet(.needsInput, reason: "An implementation question"),
            ])
        case .ownBrokenTest:
            try await fixture.append([
                .brokenTestReported(.init(testName: "GH_145Tests.contract", reason: "Own test problem")),
                .brokenTestRouted(testName: "GH_145Tests.contract", outcome: .waitingForPerson),
                .flagSet(.needsInput, reason: "Own acceptance tests need guidance"),
            ])
        }
        let before = try await fixture.node()

        try await fixture.send(.updateTest)

        let (reason, guidance) = try await fixture.rejection()
        #expect(reason.localizedCaseInsensitiveContains("isn't waiting")
            || reason.localizedCaseInsensitiveContains("not waiting"))
        #expect(reason.localizedCaseInsensitiveContains("conflicting test")
            || reason.localizedCaseInsensitiveContains("another test")
            || reason.localizedCaseInsensitiveContains("other test"))
        #expect(!guidance.contains("harness:update-test"))
        switch situation {
        case .noInput:
            #expect(guidance.contains("harness:build"))
        case .unrelatedQuestions:
            #expect(guidance.localizedCaseInsensitiveContains("answer"))
            #expect(guidance.localizedCaseInsensitiveContains("question"))
            #expect(guidance.localizedCaseInsensitiveContains("comment"))
            #expect(guidance.contains("harness:retry"))
        case .ownBrokenTest:
            #expect(guidance.localizedCaseInsensitiveContains("comment"))
            #expect(guidance.contains("harness:retry"))
        }
        let after = try await fixture.node()
        #expect(after.phase == before.phase)
        #expect(after.flags == before.flags)
        #expect(after.clarifications == before.clarifications)
        #expect(await fixture.author.tasks.isEmpty)
    }

    @Test(arguments: [
        ("Tests/AgentOSCoreTests/Contract.swift", [String]()),
        ("Tests/AgentOSAdaptersTests/GH_9Tests/Contract.swift", ["Contract.swift"]),
        ("Tests/AgentOSAdaptersTests/GH_9Tests/Contract.swift", ["Tests/AgentOSAdaptersTests/GH_9Tests/"]),
    ])
    func outsideOrProtectedTestsCannotBeApprovedAndRejectionSaysNoAgentMayChangeThem(
        file: String, protected: [String]
    ) async throws {
        let fixture = try await Fixture(file: file, protected: protected)
        defer { fixture.remove() }
        try await fixture.waitForConflict()

        try await fixture.send(.updateTest)

        let (reason, guidance) = try await fixture.rejection()
        #expect(reason.contains(file))
        #expect(reason.localizedCaseInsensitiveContains("no agent"))
        #expect(reason.localizedCaseInsensitiveContains("change"))
        #expect(guidance.localizedCaseInsensitiveContains("default branch"))
        #expect(guidance.contains("harness:retry"))
        #expect(!guidance.contains("harness:update-test"))
        #expect(try await fixture.node().flags[.needsInput] != nil)
        #expect(await fixture.workspace.committedText(file) == Self.originalTest)
    }

    @Test(arguments: [Phase.specified, .ready, .building, .checking, .landing])
    func anUnlandedOwnersTestCannotBeApprovedAndTheRejectionNamesItsTicket(ownerPhase: Phase) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.addOwner(phase: ownerPhase, landed: false)
        try await fixture.waitForConflict()

        try await fixture.send(.updateTest)

        let (reason, guidance) = try await fixture.rejection()
        #expect(reason.contains("GH-9"))
        #expect(reason.localizedCaseInsensitiveContains("land"))
        #expect(guidance.contains("GH-9"))
        #expect(guidance.localizedCaseInsensitiveContains("wait"))
        #expect(guidance.localizedCaseInsensitiveContains("land"))
        #expect(try await fixture.node().flags[.needsInput] != nil)
        #expect(await fixture.workspace.committedText(fixture.file) == Self.originalTest)
    }

    @Test
    func aLandedOwnersTestCanBeApprovedForThisTicketsTestAuthor() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.addOwner(phase: .proven, landed: true)
        try await fixture.waitForConflict()

        try await fixture.send(.updateTest)

        #expect(try await fixture.node().phase == .specified)
        #expect(try await fixture.node().flags[.needsInput] == nil)
        #expect(await fixture.history().contains {
            if case .testUpdatesApproved(let files) = $0.event.kind {
                return files == [fixture.file] && $0.event.by == .human("Pat")
            }
            return false
        })
    }

    @Test(arguments: [
        ("Tests/AgentOSAdaptersTests/GH_9Tests/Contract.swift", [String]()),
        ("Tests/AgentOSCoreTests/Contract.swift", ["Tests/"]),
    ])
    func whatYouCanDoNowListsUpdateTestWhileWaitingOnAReachableConflict(file: String, extraAreas: [String]) async throws {
        let fixture = try await Fixture(file: file, extraAreas: extraAreas)
        defer { fixture.remove() }
        try await fixture.waitForConflict()

        // A leaf cannot be broken down: its rejection must explain the currently applicable signal.
        try await fixture.send(.breakdown)

        let reply = try #require(await fixture.tracker.replies.last)
        let guidance = try #require(reply.components(separatedBy: "What you can do now:").dropFirst().first)
        #expect(guidance.contains("harness:update-test"))
    }

    @Test
    func fixtureExercisesExistingTestAuthorCommitAndDiscardBehavior() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.append([.phaseChanged(to: .specified)])

        try await fixture.authorTests()

        let node = try await fixture.node()
        #expect(node.phase == .ready)
        #expect(node.flags[.escalated] == nil)
        #expect(await fixture.workspace.committedText(Self.ownFile) == Self.newOwnTest)
        #expect(await fixture.workspace.committedText(Self.placeholderFile) == Self.originalPlaceholder)
        #expect(try String(contentsOf: fixture.directory.appending(path: Self.placeholderFile), encoding: .utf8)
            == Self.originalPlaceholder)
        let record = try #require(node.recordedTests)
        #expect(node.testsDigest == Hashing.digest(ofRecordedFiles: record.files, in: fixture.directory))
    }
}
