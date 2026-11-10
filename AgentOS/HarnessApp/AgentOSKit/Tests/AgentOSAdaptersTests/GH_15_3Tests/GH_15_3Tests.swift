// API contract: MainMovementReworkCoordinator remembers the main commit of each passing check and
// coordinates a one-time, non-attempt-counting rework when a landing failure follows movement of main.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_15_3Tests {
    private let oldMain = "1111111111111111111111111111111111111111"
    private let checkedMain = "2222222222222222222222222222222222222222"
    private let latestMain = "3333333333333333333333333333333333333333"

    @Test
    func mostRecentPassingPreCheckOrLandingCheckIsTheComparisonPoint() async throws {
        let actions = LandingFailureActionsSpy()
        let coordinator = MainMovementReworkCoordinator(actions: actions)
        try await coordinator.recordPassingCheck(node: "leaf", kind: .preCheck, mainCommit: oldMain)
        try await coordinator.recordPassingCheck(node: "leaf", kind: .landingCheck, mainCommit: checkedMain)

        let recordedChecks = await actions.ledgerEvents.prefix(2)
        #expect(recordedChecks.count == 2)
        if case .passingCheckRecorded(let kind, let mainCommit) = recordedChecks[0].kind {
            #expect(kind == .preCheck)
            #expect(mainCommit == oldMain)
        } else {
            Issue.record("Expected the pre-check pass and its underlying main commit in the ledger")
        }
        if case .passingCheckRecorded(let kind, let mainCommit) = recordedChecks[1].kind {
            #expect(kind == .landingCheck)
            #expect(mainCommit == checkedMain)
        } else {
            Issue.record("Expected the landing-check pass and its underlying main commit in the ledger")
        }

        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "Tests failed",
            currentMainCommit: latestMain,
            landedWork: []
        )

        let context = try #require(await actions.reworkContexts.first)
        #expect(context.oldMainCommit == checkedMain)
        #expect(context.newMainCommit == latestMain)
    }

    @Test
    func firstFailureAfterMainMovesResetsFromLatestMainWithoutCountingAnAttempt() async throws {
        let actions = LandingFailureActionsSpy()
        let coordinator = MainMovementReworkCoordinator(actions: actions)
        try await coordinator.recordPassingCheck(node: "leaf", kind: .preCheck, mainCommit: oldMain)

        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "IntegrationTests failed",
            currentMainCommit: latestMain,
            landedWork: []
        )

        #expect(await actions.resets == [.init(node: "leaf", mainCommit: latestMain)])
        #expect(await actions.failedAttempts == [])
        #expect(await actions.reworkContexts.count == 1)
    }

    @Test
    func reworkReceivesFailureRangeAndLandedItemsOldestFirst() async throws {
        let actions = LandingFailureActionsSpy()
        let coordinator = MainMovementReworkCoordinator(actions: actions)
        let landedWork = [
            LandedWorkItem(ticket: "GH-10", title: "Add account cache", commit: "a1b2c3d4eeeeeeee"),
            LandedWorkItem(ticket: "GH-12", title: "Refresh stale sessions", commit: "b2c3d4e5ffffffff"),
        ]
        try await coordinator.recordPassingCheck(node: "leaf", kind: .preCheck, mainCommit: oldMain)

        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "SessionTests.testRefresh failed\nexpected active, got stale",
            currentMainCommit: latestMain,
            landedWork: landedWork
        )

        let context = try #require(await actions.reworkContexts.first)
        #expect(context.failureOutput == "SessionTests.testRefresh failed\nexpected active, got stale")
        #expect(context.mainCommitRange == "\(oldMain)..\(latestMain)")
        #expect(context.landedWork == landedWork)
        #expect(context.message.contains("\(oldMain)..\(latestMain)"))
        let first = try #require(context.message.range(of: "GH-10 Add account cache (a1b2c3d4)"))
        let second = try #require(context.message.range(of: "GH-12 Refresh stale sessions (b2c3d4e5)"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test
    func ticketAndLedgerRecordMainMovedWithBothCommitsAndInterveningWork() async throws {
        let actions = LandingFailureActionsSpy()
        let coordinator = MainMovementReworkCoordinator(actions: actions)
        let landedWork = [
            LandedWorkItem(ticket: "GH-10", title: "Add account cache", commit: "a1b2c3d4eeeeeeee"),
        ]
        try await coordinator.recordPassingCheck(node: "leaf", kind: .landingCheck, mainCommit: oldMain)

        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "IntegrationTests failed",
            currentMainCommit: latestMain,
            landedWork: landedWork
        )

        let comment = try #require(await actions.comments.first)
        #expect(comment.ticket == "GH-15.3")
        #expect(comment.text.contains("main moved"))
        #expect(comment.text.contains(oldMain))
        #expect(comment.text.contains(latestMain))
        #expect(comment.text.contains("GH-10 Add account cache (a1b2c3d4)"))

        let event = try #require(await actions.ledgerEvents.last)
        guard case .mainMovedRework(
            let recordedOldMain,
            let recordedNewMain,
            let recordedLandedWork
        ) = event.kind else {
            Issue.record("Expected a mainMovedRework ledger event")
            return
        }
        #expect(event.node == "leaf")
        #expect(recordedOldMain == oldMain)
        #expect(recordedNewMain == latestMain)
        #expect(recordedLandedWork == landedWork)
        #expect(event.kind.summary.contains("main moved"))
    }

    @Test
    func laterFailureAgainstTheSameMainCountsAsTheAgentsOwnMistake() async throws {
        let actions = LandingFailureActionsSpy()
        let coordinator = MainMovementReworkCoordinator(actions: actions)
        try await coordinator.recordPassingCheck(node: "leaf", kind: .preCheck, mainCommit: oldMain)

        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "First failure",
            currentMainCommit: latestMain,
            landedWork: []
        )
        try await coordinator.handleLandingFailure(
            node: "leaf",
            ticket: "GH-15.3",
            output: "Still failing",
            currentMainCommit: latestMain,
            landedWork: []
        )

        #expect(await actions.resets.count == 1)
        #expect(await actions.reworkContexts.count == 1)
        #expect(await actions.failedAttempts == [.init(node: "leaf", summary: "Still failing")])
        let ordinaryFailure = try #require(await actions.ledgerEvents.last)
        guard case .attemptFailed(let summary) = ordinaryFailure.kind else {
            Issue.record("Expected the repeated failure to use ordinary attempt counting")
            return
        }
        #expect(summary == "Still failing")
    }
}

private actor LandingFailureActionsSpy: MainMovementReworkActions {
    struct Reset: Equatable {
        let node: NodeID
        let mainCommit: String
    }

    struct TicketComment: Equatable {
        let ticket: String
        let text: String
    }

    struct FailedAttempt: Equatable {
        let node: NodeID
        let summary: String
    }

    private(set) var resets: [Reset] = []
    private(set) var reworkContexts: [MainMovedReworkContext] = []
    private(set) var comments: [TicketComment] = []
    private(set) var ledgerEvents: [LedgerEvent] = []
    private(set) var failedAttempts: [FailedAttempt] = []

    func resetImplementation(for node: NodeID, onto mainCommit: String) async throws {
        resets.append(.init(node: node, mainCommit: mainCommit))
    }

    func dispatchRework(for _: NodeID, context: MainMovedReworkContext) async throws {
        reworkContexts.append(context)
    }

    func comment(on ticket: String, text: String) async {
        comments.append(.init(ticket: ticket, text: text))
    }

    func appendToLedger(_ event: LedgerEvent) async throws {
        ledgerEvents.append(event)
        if case .attemptFailed(let summary) = event.kind, let node = event.node {
            failedAttempts.append(.init(node: node, summary: summary))
        }
    }
}
