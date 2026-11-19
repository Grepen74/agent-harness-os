// Expected API: RequirementPullRequest(number:url:state:), with State.open/merged/closed;
// RequirementPullRequestService reads, pushes, opens and reopens PRs, injected into Reconciler
// with a `pullRequests:` initializer argument. EventKind.requirementPullRequestOpened,
// requirementPullRequestMerged, requirementPullRequestClosed and requirementPullRequestReopened
// carry (number: Int, url: String). WorkingState.status(of:) projects these ledger events.
// All five criteria have observable behavior; there are no reviewer-only criteria.
import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_92Tests {
    @Test(arguments: [false, true], [false, true])
    func anOpenPullRequestShowsInReviewInLabelsCommentsAndTheMappedBoard(
        hasProject: Bool, composite: Bool
    ) async throws {
        let fixture = try await GH92Fixture.make(
            hasProject: hasProject, composite: composite, alreadyPublished: false
        )
        try await fixture.settle()

        let state = await fixture.ledger.workingState()
        let requirement = try #require(state.nodes[GH92Fixture.nodeID])
        #expect(state.status(of: requirement) == "In review")
        #expect(await fixture.tracker.ticket(GH92Fixture.ticket)?.status == "In review")
        #expect(await fixture.github.statusLabels() == ["agentos: In review"])
        #expect(await fixture.github.labels.contains("bug"))
        #expect(
            await fixture.github.comments.contains {
                $0.localizedCaseInsensitiveContains("In review")
            })
        if hasProject {
            #expect(
                await fixture.github.boardStatus == "Awaiting approval",
                "Use statusMap, not the board's default In review option.")
        } else {
            #expect(await fixture.github.boardWrites.isEmpty)
        }
        let publicationWrites = await fixture.service.writes
        try await fixture.settle()
        #expect(
            await fixture.service.writes == publicationWrites,
            "Once open, an unchanged PR must not be republished by idle rounds.")

        let replay = try await fixture.reloadedLedger()
        let restored = await replay.workingState()
        #expect(restored.status(of: try #require(restored.nodes[GH92Fixture.nodeID])) == "In review")
    }

    @Test(arguments: [false, true], [false, true])
    func mergingThePullRequestMarksTheRequirementDoneAndDurablyRecordsTheMerge(
        hasProject: Bool, githubAlreadyClosedTheIssue: Bool
    ) async throws {
        let fixture = try await GH92Fixture.make(hasProject: hasProject)
        try await fixture.settle()
        await fixture.service.observe(.merged)
        await fixture.github.setIssueClosed(githubAlreadyClosedTheIssue)
        try await fixture.settle()

        let state = await fixture.ledger.workingState()
        #expect(state.status(of: try #require(state.nodes[GH92Fixture.nodeID])) == "Done")
        #expect(await fixture.tracker.ticket(GH92Fixture.ticket)?.status == "Done")
        if hasProject {
            #expect(await fixture.github.boardStatus == "Completed")
        } else {
            #expect(await fixture.github.statusLabels() == ["agentos: Done"])
            #expect(await fixture.github.boardWrites.isEmpty)
        }
        let records = await fixture.ledger.allRecords()
        #expect(
            records.contains {
                guard $0.event.node == GH92Fixture.nodeID,
                    case .requirementPullRequestMerged(let number, let url) = $0.event.kind
                else { return false }
                return number == GH92Fixture.prNumber && url == GH92Fixture.prURL
            })
        #expect(await fixture.service.writes.isEmpty, "Only a person merges; observing a merge publishes nothing.")

        let replay = try await fixture.reloadedLedger()
        #expect(await replay.verifyChain().isIntact)
        let restored = await replay.workingState()
        #expect(restored.status(of: try #require(restored.nodes[GH92Fixture.nodeID])) == "Done")
    }

    @Test(arguments: [false, true])
    func closingWithoutMergingWaitsForAPersonWithALinkAndADurableClose(
        hasProject: Bool
    ) async throws {
        let fixture = try await GH92Fixture.make(hasProject: hasProject)
        try await fixture.settle()
        await fixture.service.observe(.closed)
        try await fixture.settle()

        let state = await fixture.ledger.workingState()
        let requirement = try #require(state.nodes[GH92Fixture.nodeID])
        #expect(state.status(of: requirement) == "Needs input")
        #expect(requirement.flags[.needsInput] != nil)
        #expect(await fixture.github.statusLabels() == ["agentos: Needs input"])
        if hasProject {
            #expect(await fixture.github.boardStatus == "Needs input")
        } else {
            #expect(await fixture.github.boardWrites.isEmpty)
        }
        #expect(
            await fixture.github.comments.contains {
                $0.contains(GH92Fixture.prURL) && $0.localizedCaseInsensitiveContains("closed")
                    && $0.contains(HarnessCommand.retry.label)
            }, "Explain the close and the explicit retry action, linking the closed PR.")
        #expect(
            await fixture.ledger.allRecords().contains {
                guard $0.event.node == GH92Fixture.nodeID,
                    case .requirementPullRequestClosed(let number, let url) = $0.event.kind
                else { return false }
                return number == GH92Fixture.prNumber && url == GH92Fixture.prURL
            })
        try await fixture.settle()
        #expect(await fixture.service.writes.isEmpty, "A closed PR stays closed until a person retries.")

        let replay = try await fixture.reloadedLedger()
        #expect(await replay.verifyChain().isIntact)
        let restored = await replay.workingState()
        #expect(restored.status(of: try #require(restored.nodes[GH92Fixture.nodeID])) == "Needs input")
    }

    @Test
    func retryAfterAnUnmergedClosePushesAndReopensTheSamePullRequestEvenAfterRestart() async throws {
        let fixture = try await GH92Fixture.make()
        try await fixture.settle()
        await fixture.service.observe(.closed)
        try await fixture.settle()

        let replay = try await fixture.reloadedLedger()
        let restarted = fixture.reconciler(using: replay)
        await fixture.github.addHumanSignal(.retry)
        try await fixture.settle(restarted)

        let writes = await fixture.service.writes
        let pushIndex = try #require(writes.firstIndex {
            if case .push = $0 { return true }
            return false
        })
        let reopenIndex = try #require(writes.firstIndex(of: .reopen(GH92Fixture.prNumber)))
        #expect(pushIndex < reopenIndex, "Push again before reopening the original PR.")
        #expect(!writes.contains {
            if case .open = $0 { return true }
            return false
        }, "Never open a replacement PR.")
        #expect(writes.count == 2, "Retry only pushes once and reopens the original PR once.")
        let records = await replay.allRecords()
        #expect(
            records.contains {
                guard $0.event.node == GH92Fixture.nodeID,
                    case .requirementPullRequestReopened(let number, let url) = $0.event.kind
                else { return false }
                return number == GH92Fixture.prNumber && url == GH92Fixture.prURL
            })
        #expect(
            records.filter {
                if case .requirementPullRequestOpened = $0.event.kind { return true }
                return false
            }.count == 1)
        let state = await replay.workingState()
        let requirement = try #require(state.nodes[GH92Fixture.nodeID])
        #expect(requirement.flags[.needsInput] == nil)
        #expect(state.status(of: requirement) == "In review")
        #expect(await fixture.github.statusLabels() == ["agentos: In review"])
        try await fixture.settle(restarted)
        #expect(
            await fixture.service.writes == writes,
            "Later idle rounds must not push or reopen it again.")
    }

    @Test(
        arguments: [
            HarnessCommand.retry, .build, .go, .retest, .replan,
        ], [false, true])
    func mergedRequirementsRefuseBuildSignalsWithTheMergedLinkAndAFollowUpTicket(
        command: HarnessCommand, firstObservedWithSignal: Bool
    ) async throws {
        let fixture = try await GH92Fixture.make()
        try await fixture.settle()
        await fixture.service.observe(.merged)
        if !firstObservedWithSignal {
            try await fixture.settle()
        }
        // A person may reopen an auto-closed issue to add a signal. That must not unmerge its PR.
        await fixture.github.setIssueClosed(false)
        await fixture.github.addHumanSignal(command)
        try await fixture.settle()

        let records = await fixture.ledger.allRecords()
        #expect(
            records.contains {
                guard $0.event.node == GH92Fixture.nodeID,
                    case .signalRejected(let ticket, let rejected, let reason) = $0.event.kind
                else { return false }
                return ticket == GH92Fixture.ticket && rejected == command && Self.isFollowUpReply(reason)
            })
        #expect(
            !records.contains {
                guard case .signalAccepted(let ticket, let accepted, _) = $0.event.kind else { return false }
                return ticket == GH92Fixture.ticket && accepted == command
            })
        #expect(await fixture.github.comments.contains { Self.isFollowUpReply($0) })
        #expect(!(await fixture.tracker.pendingSignals()).contains { $0.command == command })
        #expect(await fixture.service.writes.isEmpty)
        #expect(await fixture.workspace.mutations.isEmpty)
        #expect(await fixture.agents.calls.isEmpty)
        #expect(await fixture.checks.calls == 0)
        let state = await fixture.ledger.workingState()
        #expect(state.status(of: try #require(state.nodes[GH92Fixture.nodeID])) == "Done")
    }

    @Test
    func theInMemoryTransportExercisesExistingTrackerLabelsCommentsSignalsAndBoardMapping() async throws {
        let github = GH92GitHub()
        let tracker = GitHubIssuesTracker(repo: GH92Fixture.repo, transport: github, listInterval: .zero)
        #expect(await tracker.ticket(GH92Fixture.ticket)?.title == "Deliver greeting")
        await tracker.setStatus(of: GH92Fixture.ticket, to: "Needs input")
        #expect(await github.statusLabels() == ["agentos: Needs input"])
        await tracker.comment(on: GH92Fixture.ticket, "Existing comment probe")
        #expect(
            await tracker.ticket(GH92Fixture.ticket)?.comments.contains {
                $0.text.contains("Existing comment probe") && $0.author == .reconciler
            } == true)
        await github.addHumanSignal(.retry)
        let signal = try #require(await tracker.pendingSignals().first { $0.command == .retry })
        #expect(signal.setBy == .human("reviewer"))
        await tracker.consume(signal, reply: "Existing signal probe")
        #expect(await tracker.pendingSignals().isEmpty)
        #expect(await github.comments.contains { $0.contains("Existing signal probe") })

        let boardTracker = GitHubIssuesTracker(
            repo: GH92Fixture.repo, transport: github,
            project: .init(
                owner: "owner", number: 7,
                statusMap: [
                    "Ready": "Queue", "In review": "Awaiting approval",
                    "Done": "Completed", "Needs input": "Needs input",
                ]),
            listInterval: .zero
        )
        await boardTracker.setStatus(of: GH92Fixture.ticket, to: "Ready")
        #expect(await github.boardStatus == "Queue")
        await boardTracker.setStatus(of: GH92Fixture.ticket, to: "In review")
        #expect(await github.boardStatus == "Awaiting approval")
        await boardTracker.setStatus(of: GH92Fixture.ticket, to: "Done")
        #expect(await github.boardStatus == "Completed")
        await boardTracker.setStatus(of: GH92Fixture.ticket, to: "Needs input")
        #expect(await github.boardStatus == "Needs input")
        #expect(await tracker.takeProblems().isEmpty)
        #expect(await boardTracker.takeProblems().isEmpty)
    }

    private static func isFollowUpReply(_ text: String) -> Bool {
        let normalized = text.lowercased().replacingOccurrences(of: "-", with: " ")
        return text.contains(GH92Fixture.prURL) && normalized.contains("follow up")
            && (normalized.contains("ticket") || normalized.contains("issue"))
    }
}
