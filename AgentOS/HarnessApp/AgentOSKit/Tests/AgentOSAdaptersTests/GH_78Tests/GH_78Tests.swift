// API contract: NodeSpec.predictedPaths: [String] defaults to []; EventKind adds
// overlapHoldStarted(waitingFor: NodeID, paths: [String], components: [String]) and
// overlapHoldEnded(waitingFor: NodeID, paths: [String], components: [String]).
// Reconciler records these transitions durably, comments once per hold reason, and
// projects the current explanation into the existing work-pane NodeDetail view.
// In progress follows the parent GH-74 contract: building, checking, review and
// landing, including .landing with humanReviewRequested. Escalated, needs-input,
// replanned and tracker-closed nodes no longer block, even with review pending.
// Release is observed after reconciliation settles, not in a particular round.
// AC6 (docs/real-repo-mode.md describing holds, compared paths, touch-set fallback,
// automatic starts and reporting) is checked during change-stage diff review.

import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSUI
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(2)))
struct GH_78Tests {
    private static let firstPath = "Sources/Engine/Planner.swift"
    private static let secondPath = "Sources/Engine/Queue.swift"

    @Test("Fixture probe: existing ready-leaf execution and hidden work-detail rendering work")
    @MainActor
    func acceptanceHelpersWorkAgainstExistingBehavior() async throws {
        try await Self.withFixture { f in
            try await f.seedReady(paths: [])
            let initial = try Self.detailText(state: await f.ledger.workingState(), node: f.nodeID(f.leaf))
            try #require(RenderedUI.shows(f.leaf, in: initial))
            try #require(RenderedUI.shows("Engine", in: initial))
            let barrier = BuildBarrier()
            await f.implementation.pauseNextCall(using: barrier)
            let execution = Task { try await f.settle() }
            defer {
                barrier.release()
                execution.cancel()
            }
            try await barrier.waitForEntry()
            #expect(await f.ledger.workingState().nodes[f.nodeID(f.leaf)]?.phase == .building)
            barrier.release()
            try await execution.value
            #expect(await f.implementation.calls == [f.nodeID(f.leaf)])
            #expect(await f.ledger.workingState().nodes[f.nodeID(f.leaf)]?.lastSubmission != nil)
            let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
            #expect(await reopened.verifyChain().isIntact)
        }
    }

    @Test("AC1: a path hold names the blocker and every overlap, and explains automatic resumption",
          arguments: [false, true])
    func heldLeafGetsOneActionableExplanation(waitForAgents: Bool) async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath, Self.secondPath])
            try await f.settle(waitForAgents: waitForAgents)
            let comments = await f.tracker.comments(on: f.leaf)
            try #require(comments.count == 1, "The held leaf needs exactly one explanatory ticket comment")
            Self.expectExplanation(comments[0], blocker: f.blocker,
                                   details: [Self.firstPath, Self.secondPath])
            #expect(await f.implementation.calls.isEmpty, "A held leaf must not start implementation")
        }
    }

    @Test("AC1: touch-set fallback names shared components rather than inventing file paths")
    func touchSetHoldExplainsEverySharedComponent() async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [], touches: ["Engine", "Storage"])
            try await f.settle()
            let comments = await f.tracker.comments(on: f.leaf)
            try #require(comments.count == 1, "Missing touch-set hold explanation")
            Self.expectExplanation(comments[0], blocker: f.blocker, details: ["Engine", "Storage"])
            #expect(Self.matches(comments[0], #"component|touch.set"#))
            let hold = try #require(await f.startedHolds().first)
            #expect(hold.paths.isEmpty)
            #expect(Set(hold.components) == ["Engine", "Storage"])
            #expect(await f.implementation.calls.isEmpty)
        }
    }

    @Test("AC2: unchanged holds are not repeated across rounds or a real ledger reopen")
    func unchangedHoldIsNotRepeatedAfterRestart() async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath])
            try await f.settle()
            try #require(await f.startedHolds().count == 1,
                         "The original hold must be recorded before checking restart deduplication")
            try await f.settle()
            try #require(await f.tracker.comments(on: f.leaf).count == 1,
                         "The original hold must be reported before checking deduplication")
            await f.reconciler.shutdown(reason: "GH-78 restart")
            let reopened = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
            let restarted = f.makeReconciler(ledger: reopened)
            _ = await restarted.recoverAfterRestart()
            for _ in 0..<3 {
                try await f.settle(using: restarted)
            }
            #expect(await f.tracker.comments(on: f.leaf).count == 1)
            #expect(await f.startedHolds(in: reopened).count == 1)
            #expect(await f.implementation.calls.isEmpty)
        }
    }

    @Test("AC2: the same blocker changing overlapping paths warrants one new explanation")
    func changedOverlappingPathsAreReportedOnce() async throws {
        try await Self.withFixture { f in
            try await f.seedReview(f.blocker, paths: [Self.firstPath])
            try await f.seedReady(paths: [Self.firstPath, Self.secondPath])
            try await f.settle()
            try #require(await f.tracker.comments(on: f.leaf).count == 1)
            await f.workspace.setFiles([Self.firstPath, Self.secondPath], for: f.blocker)
            try await f.record(f.blocker, [
                .changeSubmitted(run: "revised", commit: "revised-candidate"),
                .humanReviewRequested(commit: "revised-candidate"),
            ])
            try await f.settle()
            try await f.settle()
            let comments = await f.tracker.comments(on: f.leaf)
            try #require(comments.count == 2, "Changed overlapping paths need one, not zero or repeated, update")
            Self.expectExplanation(comments[1], blocker: f.blocker,
                                   details: [Self.firstPath, Self.secondPath])
            let holds = await f.startedHolds()
            #expect(holds.map { Set($0.paths) } == [
                Set([Self.firstPath]), Set([Self.firstPath, Self.secondPath]),
            ])
        }
    }

    @Test("AC2: a different blocking node warrants one new explanation, even for the same path")
    func changedBlockingNodeIsReportedOnce() async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath])
            try await f.settle()
            try #require(await f.tracker.comments(on: f.leaf).count == 1)
            try await f.record(f.blocker, [.landed(commit: "landed-first"), .phaseChanged(to: .proven)])
            let next = "GH-78.3"
            try await f.seedReview(next, paths: [Self.firstPath])
            try await f.settle()
            try await f.settle()
            let comments = await f.tracker.comments(on: f.leaf)
            try #require(comments.count == 2)
            Self.expectExplanation(comments[1], blocker: next, details: [Self.firstPath])
            #expect(await f.startedHolds().map(\.waitingFor) == [f.nodeID(f.blocker), f.nodeID(next)])
            #expect(await f.implementation.calls.isEmpty)
        }
    }

    @Test("AC3: hold start and end retain the blocking node and paths through ledger replay",
          arguments: Release.allCases)
    func ledgerRecordsHoldAndItsEndWhenBlockerStopsBeingInProgress(release: Release) async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath])
            try await f.settle()
            let start = try #require(await f.startedHolds().first, "The hold must have a typed ledger event")
            #expect(start.waitingFor == f.nodeID(f.blocker))
            #expect(start.paths == [Self.firstPath])
            #expect(start.components.isEmpty)
            try await f.releaseBlocker(release)
            try await f.settle()
            let records = await f.ledger.records(for: f.nodeID(f.leaf))
            let ends = records.compactMap { record -> Hold? in
                guard case .overlapHoldEnded(let waitingFor, let paths, let components) = record.event.kind else {
                    return nil
                }
                return Hold(waitingFor: waitingFor, paths: paths, components: components)
            }
            #expect(ends == [start], "End events must preserve the reason, not just say that a hold ended")
            #expect(await f.implementation.calls == [f.nodeID(f.leaf)],
                    "The leaf must resume without another human signal")
            #expect(records.contains {
                if case .runStarted(_, .implementer) = $0.event.kind { return true }
                return false
            })
            let replayed = try Ledger(store: FileLedgerStore(fileURL: f.ledgerURL))
            #expect(await replayed.records(for: f.nodeID(f.leaf)).map(\.hash) == records.map(\.hash))
            #expect(await replayed.verifyChain().isIntact)
        }
    }

    @Test("AC4: work-pane detail shows the ticket explanation and removes it when no longer held",
          arguments: [false, true])
    @MainActor
    func workPaneShowsOnlyTheCurrentHold(closeInsteadOfStarting: Bool) async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath])
            let initial = await f.ledger.workingState()
            let probe = try Self.detailText(state: initial, node: f.nodeID(f.leaf))
            try #require(RenderedUI.shows(f.leaf, in: probe),
                         "Validate the shared renderer against the existing Ticket field first")
            try await f.settle()
            try #require(await f.startedHolds().count == 1, "Render an actual hold before testing its removal")
            let comment = try #require(await f.tracker.comments(on: f.leaf).first,
                                       "The ticket explanation must exist before comparing the pane")
            Self.expectExplanation(comment, blocker: f.blocker, details: [Self.firstPath])
            let held = try Self.detailText(state: await f.ledger.workingState(), node: f.nodeID(f.leaf))
            Self.expectRenderedExplanation(blocker: f.blocker, details: [Self.firstPath], in: held)
            let cleared: String
            if closeInsteadOfStarting {
                await f.tracker.setClosed(f.leaf)
                try await f.settle()
                cleared = try Self.detailText(state: await f.ledger.workingState(), node: f.nodeID(f.leaf))
            } else {
                let barrier = BuildBarrier()
                await f.implementation.pauseNextCall(using: barrier)
                try await f.releaseBlocker(.landed)
                let execution = Task { try await f.settle() }
                defer {
                    barrier.release()
                    execution.cancel()
                }
                try await barrier.waitForEntry()
                let started = await f.ledger.workingState()
                try #require(started.nodes[f.nodeID(f.leaf)]?.phase == .building)
                cleared = try Self.detailText(state: started, node: f.nodeID(f.leaf))
                barrier.release()
                try await execution.value
            }
            #expect(!RenderedUI.shows(f.blocker, in: cleared),
                    "The work pane must stop naming the former blocker once the hold ends")
        }
    }

    @Test("AC5: an overlap hold remains Ready on the ticket, in state, and in the work tree")
    @MainActor
    func heldLeafKeepsReadyStatusWithoutHumanAttentionFlags() async throws {
        try await Self.withFixture { f in
            try await f.seedPair(paths: [Self.firstPath])
            try await f.settle()
            try #require(await f.startedHolds().count == 1, "Exercise a real hold, not an ordinary ready leaf")
            let state = await f.ledger.workingState()
            let leaf = try #require(state.nodes[f.nodeID(f.leaf)])
            #expect(leaf.phase == .ready)
            #expect(state.status(of: leaf) == "Ready")
            #expect(leaf.flags.isEmpty, "Overlap is not a request for human intervention or a dependency block")
            #expect(await f.tracker.status(of: f.leaf) == "Ready")
            let model = HarnessViewModel()
            model.state = state
            let text = try RenderedUI.text(of: WorkPane().environment(model),
                                           size: CGSize(width: 1_200, height: 900))
            #expect(RenderedUI.shows("Ready", in: text))
        }
    }

    @Test("AC1 boundary: disjoint predicted files are not held merely for sharing a component",
          arguments: [false, true])
    func disjointPathsDoNotProduceHoldCommentsOrEvents(waitForAgents: Bool) async throws {
        try await Self.withFixture { f in
            try await f.seedReview(f.blocker, paths: [Self.firstPath])
            try await f.seedReady(paths: [Self.secondPath])
            try await f.settle(waitForAgents: waitForAgents)
            #expect(await f.implementation.calls == [f.nodeID(f.leaf)])
            #expect(await f.startedHolds().isEmpty)
            #expect(await f.endedHolds().isEmpty)
            let comments = await f.tracker.comments(on: f.leaf)
            #expect(!comments.contains { Self.matches($0, #"wait|held|overlap"#) },
                    "Ordinary progress comments are allowed, but not a spurious hold explanation")
        }
    }

    @Test("AC1 boundary: a leaf without predicted paths or a touch set is never held")
    func noOverlapInformationDoesNotInventAHold() async throws {
        try await Self.withFixture { f in
            try await f.seedReview(f.blocker, paths: [Self.firstPath])
            try await f.seedReady(paths: [], touches: [])
            try await f.settle()
            #expect(await f.implementation.calls == [f.nodeID(f.leaf)])
            #expect(await f.startedHolds().isEmpty)
            #expect(await f.endedHolds().isEmpty)
            #expect(await f.tracker.comments(on: f.leaf).allSatisfy {
                !Self.matches($0, #"wait|held|overlap"#)
            })
        }
    }

    @Test("AC1 boundary: a predicted directory overlapping a blocker's file gets an explanation")
    func directoryPrefixOverlapIsReported() async throws {
        try await Self.withFixture { f in
            try await f.seedReview(f.blocker, paths: [Self.firstPath])
            try await f.seedReady(paths: ["Sources/Engine/"])
            try await f.settle()
            let comments = await f.tracker.comments(on: f.leaf)
            try #require(comments.count == 1, "A directory prediction must not bypass overlap reporting")
            #expect(comments[0].contains(f.blocker))
            #expect(comments[0].contains("Sources/Engine"))
            #expect(await f.implementation.calls.isEmpty)
            let hold = try #require(await f.startedHolds().first)
            #expect(hold.waitingFor == f.nodeID(f.blocker))
            #expect(!hold.paths.isEmpty)
            #expect(hold.paths.allSatisfy {
                $0 == "Sources/Engine/" || $0 == "Sources/Engine" || $0 == Self.firstPath
            })
            #expect(hold.components.isEmpty)
        }
    }

    private static func expectExplanation(_ message: String, blocker: String, details: [String]) {
        #expect(message.contains(blocker), "Identify the blocking node by its human-facing ticket identity")
        for detail in details { #expect(message.contains(detail), "Name every overlapping path or component") }
        #expect(Self.matches(message, #"wait|held|hold"#))
        #expect(Self.matches(message, #"automat|by itself|on its own"#), "Explain that the leaf starts itself")
        #expect(Self.matches(message, #"land"#))
        #expect(Self.matches(message, #"no longer|stops? being|ceases?|leaves?.{0,30}(progress|active)"#),
                "Explain that landing is not the only way the blocking work can stop")
        #expect(Self.matches(message, #"nothing.{0,60}(do|need)|no.{0,30}(action|intervention).{0,30}(need|required)"#),
                "Say explicitly that no human action is needed")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "(?s)" + pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @MainActor
    private static func detailText(state: WorkingState, node: NodeID) throws -> String {
        let model = HarnessViewModel()
        model.state = state
        let value = try #require(state.nodes[node])
        return try RenderedUI.text(of: NodeDetail(node: value).environment(model),
                                   size: CGSize(width: 1_800, height: 1_200))
    }

    @MainActor
    private static func expectRenderedExplanation(blocker: String, details: [String], in rendered: String) {
        for fragment in [blocker] + details + ["by itself", "nothing needs to be done"] {
            #expect(RenderedUI.shows(fragment, in: rendered),
                    "Show the ticket explanation's key fragment: \(fragment)")
        }
    }
}
