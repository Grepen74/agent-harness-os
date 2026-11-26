import AgentOSTestSupport
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@MainActor
struct WorkPaneRootsTests {
    private static func requirement(_ ticket: String, finalVerificationStarted: Bool) -> [LedgerEvent] {
        let root = NodeSpec(id: NodeID("wn-\(ticket)"), parent: nil, kind: .composite, title: ticket,
                            intent: "I", acceptanceCriteria: ["a"])
        let leaf = NodeSpec(id: NodeID("wn-\(ticket)-1"), parent: root.id, kind: .leaf, title: "\(ticket) leaf",
                            intent: "I", acceptanceCriteria: ["a"])
        var events = [
            LedgerEvent(node: root.id, by: .reconciler, kind: .nodeCreated(spec: root, ticket: ticket)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .nodeCreated(spec: leaf, ticket: "\(ticket).1")),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: .proven))
        ]
        if finalVerificationStarted {
            events.append(LedgerEvent(node: root.id, by: .reconciler, kind: .requirementVerificationStarted))
        }
        return events
    }

    @Test func hidingDoneItemsKeepsARequirementWhoseFinalVerificationNeedsAPerson() async throws {
        let ledger = try Ledger()
        try await ledger.append(Self.requirement("GH-58", finalVerificationStarted: true)
                                + Self.requirement("GH-57", finalVerificationStarted: false))
        let state = await ledger.workingState()
        try #require(state.attentionList.contains { $0.node.ticket == "GH-58" })

        #expect(WorkPane.roots(in: state, showingDone: false).map(\.ticket) == ["GH-58"])
        #expect(WorkPane.roots(in: state, showingDone: true).map(\.ticket) == ["GH-58", "GH-57"])
    }

    @Test func aHeldDescriptionShowsTheExactTicketMessageAlongsideAnotherReasonForTheSameNode() async throws {
        let spec = NodeSpec(id: "wn-GH-7", parent: nil, kind: .composite, title: "Requirement",
                            intent: "Accepted requirement", acceptanceCriteria: ["The requirement works"])
        let message = "GH-7: description edited by outsider, who doesn't have write access; the harness keeps building "
            + "from the description it accepted. A person with write access must confirm: edit the description, "
            + "or add harness:replan."
        let failure = "Publication failed. Fix the problem, then add harness:retry."
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: spec.id, by: .human("maintainer"), kind: .nodeCreated(spec: spec, ticket: "GH-7")),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .flagSet(.needsInput, reason: message)),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .requirementPublicationFailed(error: failure))
        ])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        let node = try #require(model.state.node(forTicket: "GH-7"))

        let text = try RenderedUI.text(of: AttentionList().environment(model),
                                       size: CGSize(width: 1800, height: 160))

        #expect(RenderedUI.shows("Needs attention", in: text))
        // Vision omits sentence-final dots and can read "from"/"confirm" as "trom"/"contirm" at caption size.
        #expect(RenderedUI.shows(String(message.dropLast()), in: text
            .replacingOccurrences(of: "trom", with: "from")
            .replacingOccurrences(of: "contirm", with: "confirm")),
                "The complete held-edit wording must be visible: \(text)")
        #expect(!RenderedUI.shows("\(node.displayName): \(node.ticket):", in: text),
                "The ticket key already in the held-edit message must not get another prefix: \(text)")
        #expect(RenderedUI.shows("\(node.displayName): \(failure)", in: text),
                "Another reason for the same node and flag must remain visible with its prefix: \(text)")
    }

    @Test func anOrdinaryFailureInNeedsAttentionStillShowsItsDisplayNamePrefix() async throws {
        let spec = NodeSpec(id: "wn-GH-8", parent: nil, kind: .leaf, title: "Build requirement",
                            intent: "Build it", acceptanceCriteria: ["It builds"])
        let reason = "Build failed. Fix the problem, then add harness:retry."
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: spec.id, by: .human("maintainer"), kind: .nodeCreated(spec: spec, ticket: "GH-8")),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .flagSet(.escalated, reason: reason))
        ])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        let node = try #require(model.state.node(forTicket: "GH-8"))

        let text = try RenderedUI.text(of: AttentionList().environment(model),
                                       size: CGSize(width: 1000, height: 120))

        #expect(RenderedUI.shows("Needs attention", in: text))
        #expect(RenderedUI.shows("\(node.displayName): \(reason)", in: text),
                "Ordinary attention reasons must identify their node: \(text)")
    }

    @Test func aRecordedSafeStopTellsWhyRunStoppedUntilARoundRunsWithoutOne() async throws {
        let reason = "Couldn't reconcile work: the worktree isn't clean"
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .safeStopChanged(reason: reason))])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()

        let text = try RenderedUI.text(of: AttentionList().environment(model), size: CGSize(width: 1000, height: 120))

        #expect(RenderedUI.shows("Needs attention", in: text))
        #expect(RenderedUI.shows("Run stopped: \(reason)", in: text), "\(text)")

        try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .safeStopChanged(reason: nil))])
        model.state = await ledger.workingState()
        #expect(model.state.safeStop == nil)
    }

    @Test func aSafeStopTheLedgerCouldntRecordStillTellsWhyRunStopped() async throws {
        let reason = "Ledger integrity check failed at #3: chain broken"
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .safeStopChanged(reason: "an older stop"))])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        model.unrecordedSafeStop = reason

        let text = try RenderedUI.text(of: AttentionList().environment(model), size: CGSize(width: 1000, height: 120))

        #expect(RenderedUI.shows("Run stopped: \(reason)", in: text), "\(text)")
    }
}
