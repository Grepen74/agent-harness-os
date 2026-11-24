// API: GitHubIssuesTracker gains init(repo:transport:ledger:project:listInterval:) so accepted descriptions
// survive recreation of both tracker and Ledger. Existing ticket/context APIs return the accepted description;
// Reconciler uses it for previews, adoption, replanning and agents, and WorkingState.attentionList explains holds.
// GraphQL editor: null means no edit yet and must not create a description hold.
// Rendered AttentionList coverage for criterion 3 lives in AgentOSUITests/WorkPaneRootsTests.swift.
// Criterion 6 (real-repo-mode.md and 03-tracker-adapters.md §8 documentation) is source-only: review the diff.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite struct GH_119Tests {
    @Test func aNeverEditedIssueIsReadAsItIsWithoutADescriptionHoldOrNeedsAttentionEntry() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        #expect(await fixture.tracker.contextTickets().first { $0.key == "GH-7" }?.description
                == "Accepted requirement")
        try await fixture.adoptWithoutGates()

        try await fixture.round()

        var state = await fixture.ledger.workingState()
        #expect(try #require(state.node(forTicket: "GH-7")).flags.isEmpty)
        #expect(!state.attentionList.contains { $0.node.ticket == "GH-7" })

        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.clearHarnessLabels()
        try await fixture.round()

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        state = await fixture.ledger.workingState()
        #expect(try #require(state.node(forTicket: "GH-7")).flags.isEmpty)
        #expect(!state.attentionList.contains { $0.node.ticket == "GH-7" })
    }

    @Test(arguments: ["read", "triage", "none"])
    func anEditAfterWriteAccessApprovalKeepsTheAcceptedDescription(permission: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.setPermission(permission, for: "outsider")
        await fixture.github.label(.breakdown, by: "maintainer")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        await fixture.github.clearHarnessLabels()

        await fixture.github.edit("Unapproved replacement", by: "outsider")

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        #expect(await fixture.tracker.contextTickets().first { $0.key == "GH-7" }?.description
                == "Accepted requirement")
        #expect(await fixture.github.currentDescription == "Unapproved replacement",
                "Keeping the accepted description must not overwrite the person's edit on GitHub")
    }

    @Test(arguments: ["write", "maintain", "admin"])
    func theLastEditBySomeoneWithWriteAccessBecomesTheAcceptedDescription(permission: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        await fixture.github.setPermission(permission, for: "editor")

        await fixture.github.edit("Maintainer's revised requirement", by: "editor")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Maintainer's revised requirement")
        await fixture.github.edit("Later outside edit", by: "outsider")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Maintainer's revised requirement")
    }

    @Test func anUnapprovedDescriptionIsReadLiveUntilAWriteAccessLabelAcceptsIt() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.edit("First outside edit before approval", by: "outsider")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "First outside edit before approval")
        await fixture.github.edit("Second outside edit before approval", by: "outsider")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Second outside edit before approval")

        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Second outside edit before approval")
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("Outside edit after approval", by: "outsider")

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Second outside edit before approval")
    }

    @Test func aWriteAccessEditAcceptsADescriptionEvenWithoutAHarnessLabel() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.edit("Accepted by a maintainer edit", by: "maintainer")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted by a maintainer edit")
        await fixture.github.edit("Outside edit without any harness label", by: "outsider")

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted by a maintainer edit")
    }

    @Test func aLaterWriteAccessHarnessLabelAcceptsTheCurrentDescription() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("Held replacement", by: "outsider")
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")

        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Held replacement")
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("Another outside edit", by: "outsider")

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Held replacement")
    }

    @Test(arguments: ["read", "triage"])
    func aHarnessLabelFromSomeoneWithoutWriteAccessDoesNotAcceptAHeldEdit(permission: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        await fixture.github.setPermission(permission, for: "outsider")
        await fixture.github.edit("Outside replacement", by: "outsider")
        await fixture.github.label(.preview, by: "outsider")

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
    }

    @Test func theAcceptedDescriptionSurvivesTrackerAndLedgerRestartAfterTheLabelIsGone() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("Unapproved description seen before restart", by: "outsider")
        _ = await fixture.tracker.ticket("GH-7")

        let reloadedLedger = try Ledger(store: FileLedgerStore(fileURL: fixture.ledgerURL))
        let restarted = Self.tracker(fixture.github, ledger: reloadedLedger)

        #expect(await restarted.ticket("GH-7")?.description == "Accepted requirement")
        await fixture.github.edit("Another outside edit after restart", by: "outsider")
        #expect(await restarted.contextTickets().first { $0.key == "GH-7" }?.description
                == "Accepted requirement")
        #expect(await reloadedLedger.verifyChain().isIntact)
    }

    @Test func agentContextKeepsAcceptedDescriptionsForParentsAndLinkedIssues() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("Outside parent and linked issue instructions", by: "outsider")
        let parent = try #require(await fixture.tracker.ticket("GH-7"))
        let child = Ticket(key: "GH-8", title: "Child", description: "Related to #7",
                           acceptanceCriteria: ["Child works"], parentKey: "GH-7", createdBy: .human("maintainer"))
        let context = AgentContextBuilder.build(ticket: child, tickets: [parent, child],
                                                repository: "o/r", designDocumentPaths: [])

        #expect(context.parent?.description == "Accepted requirement")
        #expect(context.linkedIssues.first { $0.key == "GH-7" }?.description == "Accepted requirement")
    }

    @Test func aPreviewUsesTheDescriptionAcceptedWhenItsLabelWasAddedNotALaterOutsideEdit() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.edit("Outside replacement after preview approval", by: "outsider")

        try await fixture.round()

        let request = try #require(await fixture.agents.breakdowns.first)
        #expect(request.spec.intent == "Accepted requirement")
        let expected = NodeSpec(id: "wn-GH-7", parent: nil, kind: .composite, title: "Requirement",
                                intent: "Accepted requirement", acceptanceCriteria: ["The requirement works"])
        #expect(await fixture.ledger.workingState().previews["GH-7"]?.specHash == expected.specHash)
    }

    @Test func adoptionAndTheTestAuthorKeepTheDescriptionAcceptedBeforeAnOutsideEdit() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.breakdown, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.edit("Outside replacement before adoption", by: "outsider")

        try await fixture.round()
        #expect(await fixture.ledger.workingState().node(forTicket: "GH-7")?.spec.intent == "Accepted requirement")
        #expect(await fixture.agents.breakdowns.first?.spec.intent == "Accepted requirement")
        try await fixture.round()

        let task = try #require(await fixture.agents.authoredTasks.first)
        #expect(task.spec.intent == "Accepted requirement")
    }

    @Test func replanningKeepsTheDescriptionAcceptedBeforeALaterOutsideEdit() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        try await fixture.adoptWithoutGates()
        await fixture.github.label(.replan, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.edit("Outside replacement after replan was requested", by: "outsider")

        try await fixture.round()

        #expect(await fixture.ledger.workingState().node(forTicket: "GH-7")?.spec.intent == "Accepted requirement")
        #expect(await fixture.github.postedComments.contains { $0.contains("✅ harness:replan") })
    }

    @Test func anAdoptedTicketsHeldEditExplainsWhoMustConfirmInNeedsAttentionEvenAfterRestart() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        try await fixture.adoptWithoutGates()
        await fixture.github.edit("Held outside edit", by: "outsider")

        let restartedLedgerURL = fixture.root.appending(path: "restarted-ledger.jsonl")
        try FileManager.default.copyItem(at: fixture.ledgerURL, to: restartedLedgerURL)
        let ledger = try Ledger(store: FileLedgerStore(fileURL: restartedLedgerURL))
        let tracker = Self.tracker(fixture.github, ledger: ledger)
        let reconciler = Self.reconciler(ledger: ledger, tracker: tracker, agents: fixture.agents, root: fixture.root)
        #expect(await !ledger.workingState().attentionList.contains { $0.node.ticket == "GH-7" })

        try await fixture.round()

        let message = "GH-7: description edited by outsider, who doesn't have write access; the harness keeps building "
            + "from the description it accepted. A person with write access must confirm: edit the description, "
            + "or add harness:replan."
        #expect(await fixture.ledger.workingState().attentionList.contains {
            $0.node.ticket == "GH-7" && $0.reason == message
        })
        #expect(await fixture.ledger.workingState().node(forTicket: "GH-7")?.spec.intent == "Accepted requirement")

        try await withHangGuard("Restarted description observation") {
            let report = await reconciler.runRound(waitForAgents: true)
            #expect(report.safeStop == nil)
        }

        #expect(await ledger.workingState().attentionList.contains {
            $0.node.ticket == "GH-7" && $0.reason == message
        })
        #expect(await ledger.workingState().node(forTicket: "GH-7")?.spec.intent == "Accepted requirement")
    }

    @Test(arguments: ["write", "maintain", "admin"])
    func anAdoptedTicketsWriteAccessEditDoesNotAppearInNeedsAttention(permission: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        try await fixture.adoptWithoutGates()
        await fixture.github.setPermission(permission, for: "editor")
        await fixture.github.edit("An authorised revised description", by: "editor")

        try await fixture.round()

        #expect(await fixture.tracker.ticket("GH-7")?.description == "An authorised revised description")
        let state = await fixture.ledger.workingState()
        #expect(try #require(state.node(forTicket: "GH-7")).flags.isEmpty)
        #expect(!state.attentionList.contains { $0.node.ticket == "GH-7" })
    }

    @Test(arguments: ["edit", "replan"])
    func confirmingAHeldDescriptionWithWriteAccessClearsItsNeedsAttentionEntry(confirmation: String) async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.ticket("GH-7")
        await fixture.github.clearHarnessLabels()
        try await fixture.adoptWithoutGates()
        await fixture.github.edit("Held outside edit", by: "outsider")
        try await fixture.round()

        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        #expect(await fixture.ledger.workingState().attentionList.contains {
            $0.node.ticket == "GH-7" && $0.reason.contains("description edited by outsider")
        })

        let confirmedDescription: String
        if confirmation == "edit" {
            confirmedDescription = "Held outside edit\nConfirmed by maintainer"
            await fixture.github.edit(confirmedDescription, by: "maintainer")
        } else {
            confirmedDescription = "Held outside edit"
            await fixture.github.label(.replan, by: "maintainer")
        }
        try await fixture.round()

        #expect(await fixture.tracker.ticket("GH-7")?.description == confirmedDescription)
        #expect(await !fixture.ledger.workingState().attentionList.contains {
            $0.node.ticket == "GH-7" && $0.reason.contains("description edited by")
        })
        if confirmation == "replan" {
            #expect(await fixture.ledger.workingState().node(forTicket: "GH-7")?.spec.intent == confirmedDescription)
            #expect(await fixture.github.postedComments.contains { $0.contains("✅ harness:replan") })
        }

        try await fixture.round()

        #expect(await !fixture.ledger.workingState().attentionList.contains {
            $0.node.ticket == "GH-7" && $0.reason.contains("description edited by")
        })
    }

    @Test func unreadableEditorPermissionKeepsTheDescriptionForTheRoundAndIsRetriedNextRound() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        await fixture.github.label(.preview, by: "maintainer")
        _ = await fixture.tracker.pendingSignals()
        await fixture.github.clearHarnessLabels()
        await fixture.github.edit("A new maintainer's edit", by: "new-maintainer")
        await fixture.github.setPermission(nil, for: "new-maintainer")

        _ = await fixture.tracker.pendingSignals()
        #expect(await fixture.tracker.ticket("GH-7")?.description == "Accepted requirement")
        let failedRequests = await fixture.github.permissionRequests(for: "new-maintainer")
        #expect(failedRequests > 0)

        await fixture.github.setPermission("write", for: "new-maintainer")
        _ = await fixture.tracker.pendingSignals()

        #expect(await fixture.tracker.ticket("GH-7")?.description == "A new maintainer's edit")
        #expect(await fixture.github.permissionRequests(for: "new-maintainer") > failedRequests,
                "A failed permission lookup must not become a cached permanent denial")
    }

    @Test func theLocalTrackerAlwaysUsesTheCurrentDescriptionIncludingAfterApprovalAndRestart() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        let store = FileTicketStore(fileURL: fixture.root.appending(path: "local-tickets.json"))
        let local = LocalTracker(store: store)
        let ticket = await local.createTicket(title: "Local requirement", description: "Original local description",
                                              acceptanceCriteria: ["It works"], by: .human("owner"))
        let adapter = LocalTrackerAdapter(tracker: local)
        await local.addLabel("harness:breakdown", to: ticket.key, by: .human("owner"))
        _ = await adapter.pendingSignals()
        _ = await adapter.ticket(ticket.key)
        await local.removeLabel("harness:breakdown", from: ticket.key)
        await local.edit(ticket.key, title: ticket.title, description: "Current local description",
                         acceptanceCriteria: ticket.acceptanceCriteria, blockedBy: [])

        #expect(await adapter.ticket(ticket.key)?.description == "Current local description")
        #expect(await adapter.contextTickets().first?.description == "Current local description")
        let restarted = LocalTrackerAdapter(tracker: LocalTracker(store: store))
        #expect(await restarted.ticket(ticket.key)?.description == "Current local description")
    }

    @Test func theTransportAndAgentRecorderWorkWithTheExistingPreviewAPI() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        let existing = GitHubIssuesTracker(repo: "o/r", transport: fixture.github, listInterval: .zero)
        #expect(await existing.ticket("GH-7")?.description == "Accepted requirement")
        await fixture.github.label(.preview, by: "maintainer")
        let reconciler = Self.reconciler(ledger: fixture.ledger, tracker: existing,
                                        agents: fixture.agents, root: fixture.root)
        try await withHangGuard("Existing preview and fake transport") {
            #expect(await reconciler.runRound(waitForAgents: true).safeStop == nil)
        }

        #expect(await fixture.agents.breakdowns.first?.spec.intent == "Accepted requirement")
        #expect(await fixture.ledger.workingState().previews["GH-7"] != nil)
        #expect(await fixture.github.postedComments.contains { $0.contains("Preview #1") })
        #expect(await existing.pendingSignals().isEmpty)
    }
}
