// Expected API: EventKind.testUpdatesApproved(files: [String]) records repository-relative files;
// LedgerEvent.by/node identify the approving person and permitted test author. Its summary is shown
// in LedgerPane. ChildProposal.affectedTests is [String]?; NodeSpec.affectedTests is [String], defaulting to [].
// Existing signal intake, breakDown, ledger persistence and Workspace.testFolder APIs are reused.
// Criterion 5 (README.md and docs/real-repo-mode.md content) is source-only: review the diff.

import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite struct GH_143Tests {
    @Test
    func approvedFilesAndTheirHumanAuthorSurviveReopeningTheLedger() async throws {
        let fixture = try Fixture(children: Self.children())
        defer { fixture.cleanUp() }
        try await fixture.adopt()
        let files = ["Tests/Legacy/MoneyTests.swift", "Tests/Legacy/ReceiptTests.swift"]
        try await fixture.ledger.append([
            LedgerEvent(node: Self.rootID, by: .human("Morgan"),
                        kind: .testUpdatesApproved(files: files)),
        ])

        let reopened = try Ledger(store: fixture.store)
        let approvals = Self.approvals(in: await reopened.allRecords())
        let approval = try #require(Self.singleApproval(approvals))
        #expect(approval.node == Self.rootID)
        #expect(approval.by == .human("Morgan"))
        #expect(approval.files == files)
        #expect(await reopened.verifyChain().isIntact)
        let record = try #require(await reopened.records(for: Self.rootID).last)
        for file in files {
            #expect(record.event.kind.summary.contains(file),
                    "The ledger description must name each file, not just count approvals")
        }
    }

    @Test
    func anOlderLedgerWithoutTestUpdateApprovalsStillLoadsAndVerifies() async throws {
        let store = InMemoryLedgerStore()
        store.append(try Self.legacyRecords())

        let ledger = try Ledger(store: store)
        let node = try #require(await ledger.workingState().nodes[Self.rootID])
        #expect(node.ticket == "GH-143")
        #expect(node.spec.kind == .leaf)
        #expect(node.gates.contains(.breakdown))
        #expect(Self.approvals(in: await ledger.allRecords()).isEmpty)
        #expect(await ledger.verifyChain().isIntact,
                "Reading an old ledger must preserve its original canonical hash chain")
    }

    @Test
    @MainActor
    func theLedgerPaneNamesTheTestsApprovedByThePerson() async throws {
        let files = ["Tests/PriceTests.swift", "Tests/TaxTests.swift"]
        let event = LedgerEvent(node: Self.rootID, by: .human("Morgan"),
                                kind: .testUpdatesApproved(files: files))

        let text = try await Self.ledgerText(event)

        for file in files { #expect(RenderedUI.shows(file, in: text)) }
        #expect(RenderedUI.shows("Morgan", in: text))
    }

    @Test(arguments: [HarnessCommand.breakdown, .go], [false, true])
    func approvingTheSeenPreviewRecordsExactlyEachAffectedChildsFiles(
        _ command: HarnessCommand, _ alreadyAdopted: Bool
    ) async throws {
        let fixture = try Fixture(children: Self.children())
        defer { fixture.cleanUp() }
        if alreadyAdopted { try await fixture.adopt() }
        try await fixture.showPreview()
        await fixture.proposer.replace([
            Self.child("An unseen replacement", affected: ["Tests/Legacy/UnseenTests.swift"]),
        ])

        try await fixture.signal(command, by: "Morgan")
        try await fixture.breakDown()

        let state = await fixture.ledger.workingState()
        let root = try #require(state.nodes[Self.rootID])
        let children = root.children.compactMap { state.nodes[$0] }
        #expect(Set(children.map(\.spec.title)) == Set(Self.children().map(\.title)))
        #expect(await fixture.proposer.calls == 0, "Accept the preview, not a regenerated proposal")
        let approvals = Self.approvals(in: await fixture.ledger.allRecords())
        #expect(approvals.count == 2, "One event per affected child; none for nil or empty affectedTests")
        for (title, files) in [
            ("Change currency rounding", ["Tests/Legacy/MoneyTests.swift", "Tests/Legacy/TaxTests.swift"]),
            ("Change receipt layout", ["Tests/Legacy/ReceiptTests.swift"]),
        ] {
            let child = try #require(children.first { $0.spec.title == title })
            let approval = try #require(Self.singleApproval(approvals.filter { $0.node == child.id }))
            #expect(approval.by == .human("Morgan"))
            #expect(Set(approval.files) == Set(files))
            #expect(approval.files.count == files.count)
        }
        #expect(!approvals.contains { $0.node == Self.rootID },
                "Split parents do not receive their children's permissions")
    }

    @Test(arguments: [HarnessCommand.breakdown, .go])
    func aPreviewThatPassesTheLeafCheckApprovesTestsOnTheOriginalNode(_ command: HarnessCommand) async throws {
        let fixture = try Fixture(children: [
            Self.child("Change currency rounding", affected: ["MoneyTests.roundsAmounts"]),
        ])
        defer { fixture.cleanUp() }
        try await fixture.showPreview()

        try await fixture.signal(command, by: "Morgan")
        try await fixture.breakDown()

        let root = try #require(await fixture.ledger.workingState().nodes[Self.rootID])
        #expect(root.spec.kind == .leaf)
        #expect(root.children.isEmpty)
        #expect(await fixture.tracker.created.isEmpty)
        let approval = try #require(Self.singleApproval(Self.approvals(in: await fixture.ledger.allRecords())))
        #expect(approval.node == root.id)
        #expect(approval.by == .human("Morgan"))
        #expect(approval.files == ["Tests/Legacy/MoneyTests.swift"])
    }

    @Test(arguments: [HarnessCommand.breakdown, .go], [false, true])
    func aFreshBreakdownWithoutAMatchingPreviewDoesNotApproveAnyAffectedTests(
        _ command: HarnessCommand, _ stalePreview: Bool
    ) async throws {
        let fixture = try Fixture(children: Self.children())
        defer { fixture.cleanUp() }
        if stalePreview { try await fixture.showPreview(specHash: "an older ticket revision") }

        try await fixture.signal(command, by: "Morgan")
        try await fixture.breakDown()

        #expect(Self.approvals(in: await fixture.ledger.allRecords()).isEmpty)
        #expect(await fixture.proposer.calls > 0)
        let comment = try await fixture.breakdownComment()
        for child in Self.children() where !(child.affectedTests ?? []).isEmpty {
            let section = try Self.section(for: child.title, in: comment, children: Self.children())
            for test in child.affectedTests ?? [] {
                let resolvedFile = test == "MoneyTests.roundsAmounts" ? "Tests/Legacy/MoneyTests.swift" : test
                #expect(section.contains(test) || section.contains(resolvedFile),
                        "Name the affected test or its resolved file in its child's section")
            }
            #expect(section.localizedCaseInsensitiveContains("not approved"),
                    "Opening a gate before seeing the proposal does not approve test updates")
        }
    }

    @Test(arguments: [false, true])
    func anotherNodesTestIsExcludedOnlyWhileItsOwnerHasNotLanded(_ ownerLanded: Bool) async throws {
        let ownedFile = "Tests/GH_88Tests/OwnerTests.swift"
        let neighborFile = "Tests/GH_880Tests/NeighborTests.swift"
        let proposals = [
            Self.child("Change currency rounding", affected: [
                "MoneyTests.roundsAmounts", ownedFile, neighborFile,
            ]),
            Self.child("Change receipt layout", affected: [ownedFile]),
        ]
        let fixture = try Fixture(children: proposals)
        defer { fixture.cleanUp() }
        try fixture.writeTest(ownedFile, suite: "GH_88Tests", test: "oldContract")
        try fixture.writeTest(neighborFile, suite: "GH_880Tests", test: "neighborContract")
        let owner = NodeSpec(id: "wn-GH-88", kind: .leaf, title: "Existing owner",
                             intent: "Own its acceptance tests", acceptanceCriteria: ["Old contract"])
        try await fixture.ledger.append([
            LedgerEvent(node: owner.id, by: .human("Owner"),
                        kind: .nodeCreated(spec: owner, ticket: "GH-88")),
            LedgerEvent(node: owner.id, by: .agent(run: "owner-tests", role: .testAuthor),
                        kind: .testsFixed(digest: "locked-owner-tests")),
            LedgerEvent(node: owner.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
        ])
        if ownerLanded {
            try await fixture.ledger.append([
                LedgerEvent(node: owner.id, by: .reconciler, kind: .landed(commit: "owner-landed")),
            ])
        }
        try await fixture.showPreview()
        try await fixture.signal(.breakdown, by: "Morgan")

        try await fixture.breakDown()

        let state = await fixture.ledger.workingState()
        let child = try #require(state.nodes.values.first { $0.spec.title == proposals[0].title })
        let approvals = Self.approvals(in: await fixture.ledger.allRecords())
        let approval = try #require(Self.singleApproval(approvals.filter { $0.node == child.id }))
        let expected = ["Tests/Legacy/MoneyTests.swift", neighborFile] + (ownerLanded ? [ownedFile] : [])
        #expect(Set(approval.files) == Set(expected))
        #expect(approval.files.count == expected.count)
        #expect(approvals.allSatisfy { $0.by == .human("Morgan") })
        let otherChild = try #require(state.nodes.values.first { $0.spec.title == proposals[1].title })
        if ownerLanded {
            #expect(Self.singleApproval(approvals.filter { $0.node == otherChild.id })?.files == [ownedFile])
        } else {
            #expect(!approvals.contains { $0.node == otherChild.id },
                    "Do not record an empty approval when every affected test has an active owner")
            let comment = try await fixture.breakdownComment()
            for proposal in proposals {
                let section = try Self.section(for: proposal.title, in: comment, children: proposals)
                #expect(section.contains(ownedFile))
                #expect(section.contains("GH-88"), "Name the owning ticket, not just its internal node ID")
                #expect(section.localizedCaseInsensitiveContains("not approved"))
                #expect(section.localizedCaseInsensitiveContains("in progress"))
            }
        }
    }

    @Test
    @MainActor
    func theFixtureAndSharedRendererReadExistingBreakdownAndGateEvents() async throws {
        let proposals = [
            Self.child("Store currency", affected: nil),
            Self.child("Show receipt", affected: nil),
        ]
        let fixture = try Fixture(children: proposals)
        defer { fixture.cleanUp() }
        try await fixture.signal(.breakdown, by: "Morgan")
        try await fixture.breakDown()

        let root = try #require(await fixture.ledger.workingState().nodes[Self.rootID])
        #expect(root.phase == .split)
        #expect(root.children.count == 2)
        #expect(await fixture.tracker.created.count == 2)
        let comment = try await fixture.breakdownComment()
        for proposal in proposals {
            let section = try Self.section(for: proposal.title, in: comment, children: proposals)
            #expect(section.contains("Billing"), "The comment helper must read an existing child's content")
        }
        let text = try await Self.ledgerText(
            LedgerEvent(node: Self.rootID, by: .human("Morgan"), kind: .gateOpened(.breakdown)))
        #expect(RenderedUI.shows("breakdown gate opened", in: text))
        #expect(RenderedUI.shows("Morgan", in: text))
    }
}
