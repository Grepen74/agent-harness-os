// API contract: runRound(waitForAgents:) uses Policy.landingBatchSize and Workspace's
// supportsLandingBatches, createLandingBatch(for:), createLandingBatch(for:validating:)
// returning LandingBatchWorkspace, and landBatch(_:) returning LandingBatchMove.
// GH-103 supplies EventKind.landingBatchCheck and LandingBatchCheck's name/ordered nodes.
// GH-105 supplies quiet diagnosis. Parent GH-58's Fail step 3 and acceptance criterion 11
// require batch infrastructure failures (including empty selections) to escalate every node,
// without splitting or counting failed attempts. Runner crashes are a separate contract.
// EventKind.landingBatchSplit(batch:first:second:) and landingBatchOwnersRemoved(batch:removed:remaining:)
// are GH-106's API: ordered partitions, with labeled summaries displayed by LedgerPane.
// Results are observed through checks, ledger state/events, tracker comments and LedgerPane.
// Source-only review: criterion 1's one shared target-owner function used by single and batch
// diagnosis; criterion 6's docs/real-repo-mode.md explanation. Neither is source-text tested.
import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import Foundation
import SwiftUI
import Testing

@Suite struct GH_106Tests {
    @Test
    func failingOwnersAreRemovedTogetherAndSurvivorsAreRecheckedWithoutThem() async throws {
        let control = try await Fixture(mode: .passing, count: 1, batchSize: 1)
        defer { control.cleanUp() }
        try await control.round()
        try #require(await control.ledger.workingState().nodes[control.bad]?.phase == .proven,
                     "Validate the workspace/check fixtures through existing single landing")
        try #require(await control.tracker.comments(on: control.bad).contains { $0.contains("Landed") })

        let batchControl = try await Fixture(mode: .passing, count: 2)
        defer { batchControl.cleanUp() }
        try await batchControl.round()
        try #require(await batchControl.workspace.landings == [batchControl.ids],
                     "Validate the delivered batch workspace API with an already-supported passing batch")
        for id in batchControl.ids {
            try #require(await batchControl.ledger.workingState().nodes[id]?.phase == .proven)
        }

        let fixture = try await Fixture(mode: .owners, count: 4)
        defer { fixture.cleanUp() }

        try await fixture.round()

        let original = try await fixture.batchCheck(for: fixture.ids)
        let removed = [fixture.ids[0], fixture.ids[2]]
        let survivors = [fixture.ids[1], fixture.ids[3]]
        let calls = await fixture.checks.calls
        let recheck = try #require(calls.first { $0.only == nil && $0.observation.nodes == survivors },
                                  "Rebuild and check the rest without either failing owner")
        #expect(removed.allSatisfy { !recheck.observation.contents.contains($0) })
        let state = await fixture.ledger.workingState()
        for id in survivors {
            #expect(state.nodes[id]?.phase == .proven)
            #expect(await fixture.tracker.comments(on: id).contains { $0.contains("Landed") })
        }
        for id in removed {
            #expect(state.nodes[id]?.phase != .proven)
            #expect(state.nodes[id]?.landedCommit == nil)
        }
        let decisions = await fixture.decisions(for: original.name, kind: .ownersRemoved)
        try #require(decisions.contains {
            $0.first == removed && $0.second == survivors
        }, "Record the removed owners and the remaining nodes under the batch's name")
        #expect(await fixture.decisions(for: original.name, kind: .split).isEmpty,
                "Known owners are taken out instead of halving the original batch")
    }

    @Test(arguments: [Mode.unowned, .underLoad, .disturbs, .memberOwnedUnderLoad, .memberOwnedDisturbs])
    func unownedLoadAndDisturbanceFailuresSplitAndSecondHalfUsesFirstHalfsLanding(mode: Mode) async throws {
        let fixture = try await Fixture(mode: mode, count: 4)
        defer { fixture.cleanUp() }

        try await fixture.round()

        let original = try await fixture.batchCheck(for: fixture.ids)
        let first = Array(fixture.ids.prefix(2))
        let second = Array(fixture.ids.suffix(2))
        let calls = await fixture.checks.calls
        let firstCheck = try #require(calls.first { $0.only == nil && $0.observation.nodes == first },
                                     "Check the first half on the requirement branch")
        #expect(firstCheck.observation.base.isEmpty)
        let secondCheck = try #require(calls.first { $0.only == nil && $0.observation.nodes == second },
                                      "Check the second half after landing the first")
        #expect(secondCheck.observation.base == first)
        for id in first {
            #expect(secondCheck.proven.contains(id))
            #expect(secondCheck.landedComments.contains(id),
                    "The first half is already Proven with its landed comments, not held for the second half")
        }
        let split = try #require(await fixture.decisions(for: original.name, kind: .split).first)
        #expect(split.first == first)
        #expect(split.second == second)
        #expect(await fixture.decisions(for: original.name, kind: .ownersRemoved).isEmpty,
                "A member-owned target that passes alone must cause splitting, not owner removal")
        let state = await fixture.ledger.workingState()
        for id in fixture.ids.dropLast() { #expect(state.nodes[id]?.phase == .proven) }
        #expect(state.nodes[fixture.bad]?.phase != .proven)
    }

    @Test
    func recursiveSplitsLandPassingGroupsBeforeHandlingTheFailingSingleton() async throws {
        let fixture = try await Fixture(mode: .unowned, count: 8)
        defer { fixture.cleanUp() }

        try await fixture.round()

        let calls = await fixture.checks.calls
        for group in [Array(fixture.ids[0..<4]), Array(fixture.ids[4..<6]), [fixture.ids[6]]] {
            #expect(calls.contains { $0.only == nil && $0.observation.nodes == group },
                    "Keep a passing smaller group together instead of restarting every node from scratch")
        }
        let singleton = try #require(calls.first {
            $0.only == nil && $0.observation.nodes == [fixture.bad]
        })
        for id in fixture.ids.dropLast() {
            #expect(singleton.proven.contains(id))
            #expect(singleton.landedComments.contains(id))
            #expect(singleton.observation.base.contains(id))
        }
        let records = await fixture.ledger.allRecords()
        let handled = try #require(records.first {
            guard $0.event.node == fixture.bad else { return false }
            if case .landingReworkNeeded = $0.event.kind { return true }
            if case .flagSet(.escalated, _) = $0.event.kind { return true }
            return false
        }, "The failing singleton receives the ordinary single-landing disposition")
        for id in fixture.ids.dropLast() {
            let landed = try #require(records.first {
                guard $0.event.node == id else { return false }
                if case .landed = $0.event.kind { return true }
                return false
            })
            #expect(landed.position < handled.position)
        }
        for nodes in [fixture.ids, Array(fixture.ids[4..<8]), Array(fixture.ids[6..<8])] {
            let batch = try await fixture.batchCheck(for: nodes)
            let split = try #require(await fixture.decisions(for: batch.name, kind: .split).first,
                                    "Every recursive split has an audit record, not just the first")
            #expect(split.first == Array(nodes.prefix(nodes.count / 2)))
            #expect(split.second == Array(nodes.suffix(nodes.count / 2)))
        }
    }

    @Test(arguments: Mode.singletonCases)
    func isolatedFailuresKeepSingleLandingCommentsAttemptsAndEscalation(mode: Mode) async throws {
        let single = try await Fixture(mode: mode, count: 1, batchSize: 1)
        let batch = try await Fixture(mode: mode, count: 2)
        defer { single.cleanUp(); batch.cleanUp() }

        try await single.round()
        try await batch.round()

        #expect(await batch.checks.calls.contains { $0.only == nil && $0.observation.nodes == batch.ids },
                "Exercise the singleton reached from a failing batch, not just the existing serial path")
        let expected = try #require(await single.ledger.workingState().nodes[single.bad])
        let actual = try #require(await batch.ledger.workingState().nodes[batch.bad])
        #expect(actual.phase == expected.phase)
        #expect(actual.failedAttempts == expected.failedAttempts)
        #expect(actual.reworks == expected.reworks)
        #expect(actual.landingReworkPending == expected.landingReworkPending)
        #expect(actual.landingRerunPending == expected.landingRerunPending)
        #expect((actual.flags[.escalated] != nil) == (expected.flags[.escalated] != nil))
        #expect(actual.evidence.last?.failureClassification == expected.evidence.last?.failureClassification)
        #expect(actual.activeRun == nil)
        let expectedComments = await single.tracker.comments(on: single.bad)
        let actualComments = await batch.tracker.comments(on: batch.bad)
        for marker in mode.commentMarkers {
            #expect(expectedComments.contains { $0.contains(marker) }, "Validate the existing single-landing oracle")
            #expect(actualComments.contains { $0.contains(marker) },
                    "Splitting must retain today's explanation and recovery instructions")
        }
        if mode == .requirementsConflict {
            #expect(await batch.tracker.comments(on: Fixture.provenID).contains {
                $0.contains("contradicts this ticket's acceptance criteria")
            })
        }
        if mode == .ownRerun || mode == .attemptLimit {
            #expect(actual.failedAttempts == 1)
            #expect((actual.flags[.escalated] != nil) == (mode == .attemptLimit))
        }
        let healthy = try #require(await batch.ledger.workingState().nodes[batch.ids[0]])
        #expect(healthy.phase == .proven)
        #expect(await batch.tracker.comments(on: healthy.id).contains { $0.contains("Landed") })
    }

    @Test(arguments: [Mode.requirementsConflict, .mixedOwnership, .mixedUnknownOwnership])
    func targetsOutsideTheBatchPreventOwnerRemovalAndKeepProvenOwnersProven(mode: Mode) async throws {
        let fixture = try await Fixture(mode: mode, count: 4)
        defer { fixture.cleanUp() }

        try await fixture.round()

        let original = try await fixture.batchCheck(for: fixture.ids)
        #expect(await fixture.decisions(for: original.name, kind: .ownersRemoved).isEmpty,
                "Do not remove the known owner when another failure has an owner outside this batch")
        #expect(await fixture.decisions(for: original.name, kind: .split).count > 0)
        let state = await fixture.ledger.workingState()
        #expect(state.nodes[Fixture.provenID]?.phase == .proven)
        #expect(state.nodes[Fixture.provenID]?.landedCommit == "established-commit")
        for id in fixture.ids.dropLast() { #expect(state.nodes[id]?.phase == .proven) }
        #expect(state.nodes[fixture.bad]?.phase != .proven)
    }

    @Test(arguments: [Mode.batchInfrastructure, .batchEmptySelection])
    func batchInfrastructureFailuresAreNotSplitOrAttributedToTestOwners(mode: Mode) async throws {
        let fixture = try await Fixture(mode: mode, count: 4)
        defer { fixture.cleanUp() }

        try await fixture.round()

        let original = try await fixture.batchCheck(for: fixture.ids)
        #expect(await fixture.decisions(for: original.name, kind: .split).isEmpty)
        #expect(await fixture.decisions(for: original.name, kind: .ownersRemoved).isEmpty)
        #expect(await fixture.workspace.landings.isEmpty)
        #expect(await fixture.checks.calls.allSatisfy {
            $0.observation.nodes.isEmpty || $0.observation.nodes == fixture.ids
        },
                "An infrastructure failure does not start smaller candidates")
        let state = await fixture.ledger.workingState()
        for id in fixture.ids {
            #expect(state.nodes[id]?.flags[.escalated] != nil)
            #expect(state.nodes[id]?.phase != .proven)
            #expect(state.nodes[id]?.failedAttempts == 0)
            #expect(state.nodes[id]?.landingReworkPending == false)
        }
    }

    @MainActor @Test
    func splitAndOwnerRemovalRecordsShowBatchAndEveryPartInTheLedgerPane() async throws {
        // Check the shared renderer against an existing ledger row before using it as UI evidence.
        let control = try Ledger()
        try await control.append([LedgerEvent(node: nil, by: .reconciler, kind: .flagSet(
            .escalated, reason: "Landing control message. First half: Control-A; Second half: Control-B"
        ))])
        let controlText = try await Self.ledgerText(control)
        try #require(RenderedUI.shows("Landing control message", in: controlText),
                     "The renderer must read the real ledger pane before testing new events")
        try Self.expectPartitions(in: controlText, labels: ("first", "second"),
                                  first: ["Control-A"], second: ["Control-B"])

        for mode in [Mode.owners, .unowned] {
            let fixture = try await Fixture(mode: mode, count: 4)
            defer { fixture.cleanUp() }
            try await fixture.round()
            let batch = try await fixture.batchCheck(for: fixture.ids)
            let decisions = await fixture.decisions(for: batch.name,
                                                   kind: mode == .owners ? .ownersRemoved : .split)
            try #require(!decisions.isEmpty)
            // A small ledger keeps these rows visible; it is populated with the actual emitted events.
            let display = try Ledger()
            try await display.append(decisions.map(\.record.event))
            let text = try await Self.ledgerText(display)
            #expect(RenderedUI.shows(batch.name, in: text))
            let first = mode == .owners ? [fixture.ids[0], fixture.ids[2]] : Array(fixture.ids.prefix(2))
            let second = mode == .owners ? [fixture.ids[1], fixture.ids[3]] : Array(fixture.ids.suffix(2))
            let labels = mode == .owners ? ("removed", "remaining") : ("first", "second")
            try Self.expectPartitions(in: text, labels: labels, first: first, second: second)
        }
    }

    @MainActor
    private static func expectPartitions(
        in text: String, labels: (String, String), first: [NodeID], second: [NodeID]
    ) throws {
        let normalized = text.filter { !$0.isWhitespace }.lowercased()
        let firstLabel = try #require(normalized.range(of: labels.0))
        let secondLabel = try #require(normalized.range(of: labels.1, range: firstLabel.upperBound..<normalized.endIndex))
        let firstPart = String(normalized[firstLabel.upperBound..<secondLabel.lowerBound])
        let secondPart = String(normalized[secondLabel.upperBound...])
        for id in first {
            #expect(RenderedUI.shows(id, in: firstPart), "Put \(id) under \(labels.0), not \(labels.1)")
            #expect(!RenderedUI.shows(id, in: secondPart))
        }
        for id in second {
            #expect(RenderedUI.shows(id, in: secondPart), "Put \(id) under \(labels.1), not \(labels.0)")
            #expect(!RenderedUI.shows(id, in: firstPart))
        }
    }

    @MainActor
    private static func ledgerText(_ ledger: Ledger) async throws -> String {
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        return try RenderedUI.text(of: LedgerPane().environment(model),
                                   size: CGSize(width: 1_600, height: 900))
    }
}
