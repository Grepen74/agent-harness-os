// Expected API: Comment.writeAccess distinguishes allowed, denied and unknown permission;
// EventKind.commentIgnored(ticket:commentID:author:) persists the observation. Existing
// Reconciler.runRound, TicketDetail and LedgerPane expose the resulting behaviour.
// GitHubIssuesTracker must preserve an unreadable permission as .unknown through GitHubTransport.
// All five criteria are observable; there are no source-only criteria in this item.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSUI
import Foundation
import SwiftUI
import Testing

@Suite struct GH_118Tests {
    @Test @MainActor
    func ticketDetailsListEachIgnoredCommentWithItsAuthorDateAndReason() throws {
        let first = Self.comment(author: "outside-reader", access: .denied, day: 0)
        let second = Self.comment(author: "outside-triager", access: .denied, day: 3)
        let trusted = Self.comment(author: "maintainer", access: .allowed, day: 1)
        let ticket = Self.ticket(comments: [trusted, first, second])
        let lines = try Self.detailLines(ticket)
        let text = lines.joined(separator: "\n")

        for comment in [first, second] {
            let ownLines = try Self.detailLines(Self.ticket(comments: [comment]))
            let ownText = ownLines.joined(separator: "\n")
            #expect(RenderedUI.shows(comment.author.label, in: ownText), "\(ownText)")
            #expect(Self.showsDate(comment.at, in: ownText), "\(ownText)")
            #expect(Self.ignoredNoticeCount(ownLines) == 1, "The notice belongs to this comment:\n\(ownText)")
            #expect(RenderedUI.shows(comment.author.label, in: text), "\(text)")
        }
        #expect(Self.ignoredNoticeCount(lines) == 2, "Each ignored comment needs its own notice:\n\(text)")
    }

    @Test(arguments: [false, true])
    func signalAndAdoptedTicketsRecordIgnoredCommentIDsAndAuthorsOnceAcrossRoundsAndRestarts(
        adopted: Bool
    ) async throws {
        let first = Self.comment(author: "outside-reader", access: .denied, day: 0)
        let second = Self.comment(author: "outside-reader", access: .denied, day: 0)
        let third = Self.comment(author: "outside-triager", access: .denied, day: 2)
        let trusted = Self.comment(author: "maintainer", access: .allowed, day: 1)
        let fixture = try await Self.fixture(adopted: adopted, comments: [first, second, third, trusted])
        defer { Self.removeFiles(fixture.directory) }
        let reconciler = fixture.reconciler()

        try await Self.round(reconciler)
        await Self.expectIgnored([first, second, third], in: fixture.ledger)
        try await Self.round(reconciler)
        try await Self.round(reconciler)
        await Self.expectIgnored([first, second, third], in: fixture.ledger)

        let edited = Self.replacingText(of: first, with: "Edited text, same tracker comment")
        await fixture.tracker.replaceComments([third, trusted, second, edited])
        try await Self.round(reconciler)
        await Self.expectIgnored([first, second, third], in: fixture.ledger)
        await reconciler.shutdown(reason: "Acceptance test restart")

        let restored = try Ledger(store: FileLedgerStore(fileURL: fixture.ledgerFile))
        #expect(await restored.verifyChain().isIntact)
        await Self.expectIgnored([first, second, third], in: restored)
        let restarted = fixture.reconciler(ledger: restored)
        _ = await restarted.recoverAfterRestart()
        try await Self.round(restarted)
        await Self.expectIgnored([first, second, third], in: restored)

        let later = Self.comment(author: "outside-reader", access: .denied, day: 4)
        await fixture.tracker.replaceComments([third, later, trusted, second, edited])
        if !adopted { await fixture.tracker.addSignal(.retry) }
        try await Self.round(restarted)
        try await Self.round(restarted)
        await Self.expectIgnored([first, second, third, later], in: restored)
    }

    @Test @MainActor
    func ledgerPaneDescribesEveryIgnoredEventWithTicketAuthorAndReason() async throws {
        let first = Self.comment(author: "outside-reader", access: .denied, day: 0)
        let second = Self.comment(author: "outside-triager", access: .denied, day: 2)
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: nil, by: .reconciler, kind: .commentIgnored(
                ticket: "GH-118", commentID: first.id, author: first.author)),
            LedgerEvent(node: nil, by: .reconciler, kind: .commentIgnored(
                ticket: "GH-119", commentID: second.id, author: second.author)),
        ])
        for record in await ledger.allRecords() {
            guard case .commentIgnored(let ticket, _, let author) = record.event.kind else { continue }
            let summary = record.event.kind.summary
            #expect(summary.contains(ticket), "Each event describes its own ticket.")
            #expect(summary.contains(author.label), "Each event describes its own comment author.")
            #expect(summary.contains(Self.reason), "Each event explains why its comment was ignored.")
        }
        let lines = try await Self.ledgerLines(ledger)
        let text = lines.joined(separator: "\n")

        for (key, author) in [("GH-118", first.author), ("GH-119", second.author)] {
            #expect(RenderedUI.shows(key, in: text), "\(text)")
            #expect(RenderedUI.shows(author.label, in: text), "\(text)")
        }
        #expect(lines.filter { RenderedUI.shows(Self.reason, in: $0) }.count == 2,
                "Each event must explain why the comment was ignored:\n\(text)")
    }

    @Test(arguments: [false, true])
    func recordingIgnoredCommentsCausesNoAdditionalTrackerCommentLabelOrStatusChange(
        adopted: Bool
    ) async throws {
        let ignored = Self.comment(author: "outside-reader", access: .denied, day: 0)
        let baseline = try await Self.fixture(adopted: adopted, comments: [])
        defer { Self.removeFiles(baseline.directory) }
        let observed = try await Self.fixture(adopted: adopted, comments: [ignored])
        defer { Self.removeFiles(observed.directory) }
        let baselineReconciler = baseline.reconciler()
        let observedReconciler = observed.reconciler()

        try await Self.round(baselineReconciler)
        try await Self.round(observedReconciler)
        try await Self.round(baselineReconciler)
        try await Self.round(observedReconciler)

        let observedWrites = await observed.tracker.mutations
        let baselineWrites = await baseline.tracker.mutations
        #expect(Dictionary(grouping: observedWrites, by: { $0 }).mapValues(\.count)
                == Dictionary(grouping: baselineWrites, by: { $0 }).mapValues(\.count),
                "The same legitimate signal/status projection is allowed; ignored input must add no writes.")
        if adopted {
            #expect(observedWrites.isEmpty, "A quiet adopted ticket must receive no tracker writes.")
        }
        let baselineTicket = await baseline.tracker.snapshot()
        let observedTicket = await observed.tracker.snapshot()
        #expect(Set(observedTicket.labels) == Set(baselineTicket.labels))
        #expect(observedTicket.status == baselineTicket.status)
        #expect(observedTicket.comments.filter { $0.author == .reconciler }.map(\.text).sorted()
                == baselineTicket.comments.filter { $0.author == .reconciler }.map(\.text).sorted())
        await Self.expectIgnored([ignored], in: observed.ledger)
    }

    @Test @MainActor
    func unreadablePermissionIsNotListedOrRecordedAsDeniedButALaterDenialIs() async throws {
        let unknown = Self.comment(author: "lookup-unavailable", access: .unknown, day: 0)
        let denied = Self.comment(author: "outside-reader", access: .denied, day: 1)
        let trusted = Self.comment(author: "maintainer", access: .allowed, day: 2)
        let fixture = try await Self.fixture(adopted: true, comments: [unknown, denied, trusted])
        defer { Self.removeFiles(fixture.directory) }
        let reconciler = fixture.reconciler()
        let unknownOnly = try Self.detailLines(Self.ticket(comments: [unknown]))
        #expect(Self.ignoredNoticeCount(unknownOnly) == 0,
                "An unreadable permission must not be described as a denial:\n\(unknownOnly)")
        let deniedOnly = try Self.detailLines(Self.ticket(comments: [denied]))
        #expect(Self.ignoredNoticeCount(deniedOnly) == 1,
                "A confirmed denial, unlike an unreadable permission, is listed:\n\(deniedOnly)")
        let before = try Self.detailLines(await fixture.tracker.snapshot())
        #expect(Self.ignoredNoticeCount(before) == 1,
                "Only confirmed denial, not an unreadable permission, is listed as ignored:\n\(before)")

        try await Self.round(reconciler)
        try await Self.round(reconciler)
        await Self.expectIgnored([denied], in: fixture.ledger)
        #expect(await Self.ignoredEvents(in: fixture.ledger).allSatisfy { $0.commentID != unknown.id })

        var resolved = unknown
        resolved.writeAccess = .denied
        await fixture.tracker.replaceComments([resolved, denied, trusted])
        try await Self.round(reconciler)
        await Self.expectIgnored([denied, resolved], in: fixture.ledger)
        let after = try Self.detailLines(await fixture.tracker.snapshot())
        #expect(Self.ignoredNoticeCount(after) == 2, "The later confirmed denial is visible:\n\(after)")
    }

    @Test @MainActor
    func githubPermissionLookupFailuresRemainUnknownAndAreNeitherListedNorRecorded() async throws {
        let fixture = try await Self.fixture(adopted: true, comments: [])
        defer { Self.removeFiles(fixture.directory) }
        let transport = GitHubPermissionFailureTransport(status: await fixture.tracker.snapshot().status)
        let tracker = GitHubIssuesTracker(
            repo: "acme/app", transport: transport, listInterval: .zero, now: { Self.instant })
        let ticket = try #require(await tracker.ticket("GH-118"))
        let unknown = try #require(ticket.comments.first { $0.author == .human("lookup-unavailable") })
        let denied = try #require(ticket.comments.first { $0.author == .human("outside-reader") })

        #expect(unknown.text == "Permission lookup failed")
        #expect(unknown.writeAccess == .unknown, "A failed GitHub permission lookup is not a confirmed denial.")
        #expect(!unknown.isHumanInput, "Unreadable permissions still exclude the comment from trusted input.")
        #expect(denied.writeAccess == .denied)
        #expect(await transport.failedPermissionReads > 0, "Exercise the real adapter's failing lookup.")
        let unknownOnly = try Self.detailLines(Self.ticket(comments: [unknown]))
        #expect(Self.ignoredNoticeCount(unknownOnly) == 0,
                "The adapter's unreadable permission must not be listed as ignored:\n\(unknownOnly)")
        let details = try Self.detailLines(ticket)
        #expect(Self.ignoredNoticeCount(details) == 1,
                "Only the confirmed denial is listed:\n\(details)")

        let reconciler = fixture.reconciler(tracker: tracker)
        for _ in 0..<2 {
            let previousReads = await transport.failedPermissionReads
            try await Self.round(reconciler)
            #expect(await transport.failedPermissionReads > previousReads,
                    "An unreadable permission must be checked again on the next round.")
            let observations = await Self.ignoredEvents(in: fixture.ledger)
            #expect(!observations.contains { $0.commentID == unknown.id },
                    "An unreadable permission must never produce an ignored-comment event.")
            await Self.expectIgnored([denied], in: fixture.ledger)
        }
    }

    @Test @MainActor
    func renderingHelpersReadExistingTicketAndLedgerContent() async throws {
        let trusted = Self.comment(author: "renderer-maintainer", access: .allowed, day: 0)
        let text = try Self.detailLines(Self.ticket(comments: [trusted])).joined(separator: "\n")
        #expect(RenderedUI.shows(trusted.author.label, in: text), "\(text)")
        #expect(RenderedUI.shows(trusted.text, in: text), "\(text)")

        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .signalRejected(
            ticket: "GH-118", command: .retry, reason: "Existing ledger renderer probe"), at: Self.instant)])
        let ledgerText = try await Self.ledgerLines(ledger).joined(separator: "\n")
        #expect(RenderedUI.shows("GH-118", in: ledgerText), "\(ledgerText)")
        #expect(RenderedUI.shows("Existing ledger renderer probe", in: ledgerText), "\(ledgerText)")
        #expect(RenderedUI.shows(Self.instant.formatted(date: .numeric, time: .standard), in: ledgerText),
                "\(ledgerText)")
        #expect(Self.showsDate(Self.instant, in: ledgerText), "\(ledgerText)")
        let dateText = try RenderedUI.text(
            of: Text(Self.instant.formatted(date: .abbreviated, time: .omitted)),
            size: CGSize(width: 400, height: 80))
        #expect(Self.showsDate(Self.instant, in: dateText), "\(dateText)")

        let notices = try RenderedUI.text(in: RenderedUI.image(of: VStack(alignment: .leading) {
            Text("Ignored: \(Self.reason)")
            Text("Ignored: \(Self.reason)")
        }, size: CGSize(width: 700, height: 150)))
        #expect(Self.ignoredNoticeCount(notices) == 2, "The notice-count helper reads both rows:\n\(notices)")
    }

    @Test
    func trackerSpyObservesRealCommentsLabelRemovalAndStatusChanges() async throws {
        var ticket = Self.ticket(comments: [])
        ticket.labels = [LabelMark(name: HarnessCommand.retry.label, setBy: .human("maintainer"))]
        let tracker = TrackerSpy(ticket)
        await tracker.comment(on: ticket.key, "Spy comment probe")
        await tracker.setStatus(of: ticket.key, to: "Probe status")
        await tracker.setStatus(of: ticket.key, to: "Probe status")
        await tracker.consume(Signal(ticket: ticket.key, command: .retry, setBy: .human("maintainer")),
                              reply: "Spy signal probe")
        #expect(await tracker.mutations == [
            .comment(ticket.key, "Spy comment probe"), .status(ticket.key, "Probe status"),
            .labelRemoved(ticket.key, HarnessCommand.retry.label), .comment(ticket.key, "Spy signal probe"),
        ])
        let updated = await tracker.snapshot()
        #expect(updated.labels.isEmpty)
        #expect(updated.status == "Probe status")
        #expect(updated.comments.map(\.text) == ["Spy comment probe", "Spy signal probe"])
        await tracker.addSignal(.retry)
        let pending = await tracker.pendingSignals()
        #expect(pending.contains { $0.ticket == ticket.key && $0.command == .retry
            && $0.setBy == .human("maintainer") })
    }
}
