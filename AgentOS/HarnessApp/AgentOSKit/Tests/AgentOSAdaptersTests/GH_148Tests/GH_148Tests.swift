// API: EventKind.testsRecorded(files: [String], suite: String) projects into
// NodeState.recordedTests: AcceptanceTestRecord? (files: [String], suite: String).
// Reconciler.authorTests records committed candidates before preflight/review; EventKind.summary
// supplies the ledger-pane description. Existing ledger bytes and locks retain their meaning.
// AC6's simulator build and existing-suite success are build/reviewer checks, not source-text tests;
// the simulated leaf's observable tests-written-to-proven lifecycle is exercised below.

import AgentOSAdapters
@testable import AgentOSCore
@testable import AgentOSSimulation
import AgentOSTestSupport
import Foundation
import Testing

@Suite
struct GH_148Tests {
    @Test(arguments: AuthorOutcome.allCases)
    func committedTestsAreRecordedBeforePreflightAndReviewEvenWhenReturned(outcome: AuthorOutcome) async throws {
        let fixture = try await Fixture(outcomes: [outcome])
        defer { fixture.cleanUp() }

        try await fixture.authorTests()

        let committed = await fixture.workspace.committedFiles
        #expect(committed[Self.firstFile] == Self.firstSource)
        #expect(committed[Self.lastFile] == Self.lastSource)
        #expect(committed[Self.otherFile] == "updated older test")
        #expect(committed["Sources/Placeholder.swift"] == nil)
        let observations = await fixture.probe.observations
        #expect(observations.map(\.stage) == (outcome == .preflightReturn ? ["preflight"] : ["preflight", "review"]))
        for observation in observations {
            #expect(observation.commitCount == 1, "The candidate must already be committed at \(observation.stage)")
            let records = Self.recordedEvents(observation.history)
            let record = try #require(records.last, "No test record existed when \(observation.stage) started")
            #expect(records.count == 1)
            #expect(record.node == Self.spec.id)
            #expect(record.files == [Self.firstFile, Self.lastFile])
            #expect(record.suite == Self.spec.testTarget)
            #expect(observation.node?.recordedTests?.files == record.files)
            #expect(observation.node?.recordedTests?.suite == record.suite)
            #expect(observation.node?.testsDigest == nil, "A candidate is not a lock")
        }

        let history = await fixture.ledger.records(for: Self.spec.id)
        let candidate = try #require(Self.recordedEvents(history).last)
        #expect(candidate.files == [Self.firstFile, Self.lastFile])
        let node = try await fixture.node()
        #expect(node.recordedTests?.files == candidate.files, "Returned tests must retain their candidate record")
        #expect(node.recordedTests?.suite == Self.spec.testTarget)
        if outcome == .accepted {
            #expect(node.testsDigest != nil)
            let fixed = try #require(history.first { if case .testsFixed = $0.event.kind { true } else { false } })
            #expect(candidate.position < fixed.position)
        } else {
            #expect(node.testsDigest == nil)
            #expect(node.latestTestFeedback != nil, "The failure path must actually have returned the tests")
        }
    }

    @Test
    func aLaterAuthorCommitReplacesTheRecordInsteadOfAccumulatingDeletedFiles() async throws {
        let replacement = "\(Self.folder)/Middle.swift"
        let fixture = try await Fixture(
            outcomes: [.preflightReturn, .accepted],
            drafts: [
                Draft(files: [Self.firstFile: Self.firstSource, Self.lastFile: Self.lastSource]),
                Draft(files: [replacement: "@Test func handlesRetry() {}"], removed: [Self.lastFile]),
            ]
        )
        defer { fixture.cleanUp() }

        try await fixture.authorTests()
        let first = try await fixture.node()
        #expect(first.recordedTests?.files == [Self.firstFile, Self.lastFile])
        try await fixture.authorTests()

        let candidates = Self.recordedEvents(await fixture.ledger.records(for: Self.spec.id))
        #expect(candidates.count == 2, "Every test-author commit gets its own ledger record")
        #expect(candidates.last?.files == [Self.firstFile, replacement])
        #expect(candidates.last?.suite == Self.spec.testTarget)
        let latest = try await fixture.node()
        #expect(latest.recordedTests?.files == [Self.firstFile, replacement])
        #expect(latest.recordedTests?.suite == Self.spec.testTarget)
        #expect(latest.testsDigest != nil)
    }

    @Test(arguments: [false, true])
    func retestAndReplanClearTheRecordUntilAnotherCandidateIsCommitted(replan: Bool) async throws {
        let store = InMemoryLedgerStore()
        let ledger = try Ledger(store: store)
        try await Self.createNode(in: ledger)
        let sibling = NodeSpec(
            id: "wn-GH-148-sibling", parent: nil, kind: .leaf, title: "Other leaf",
            intent: "Keep its own record", acceptanceCriteria: ["Independent tests"]
        )
        try await ledger.append([
            LedgerEvent(node: sibling.id, by: .human("Alice"), kind: .nodeCreated(spec: sibling, ticket: "OTHER")),
            LedgerEvent(node: sibling.id, by: .reconciler,
                        kind: .testsRecorded(files: ["Tests/Other/Own.swift"], suite: sibling.testTarget)),
        ])
        try await Self.append([
            .testsRecorded(files: [Self.firstFile], suite: Self.spec.testTarget),
            .testsFixed(digest: "old-lock"),
        ], to: ledger)

        let reset: EventKind = replan
            ? .replanned(spec: Self.spec)
            : .signalAccepted(ticket: "GH-148", command: .retest, reply: "start tests over")
        try await Self.append([reset], to: ledger, by: .human("Alice"))
        var node = try #require(await ledger.workingState().nodes[Self.spec.id])
        #expect(node.recordedTests == nil)
        #expect(await ledger.workingState().nodes[sibling.id]?.recordedTests?.files == ["Tests/Other/Own.swift"])
        try await Self.append([
            .runStarted(run: "new-author", role: .testAuthor),
            .runFinished(run: "new-author", outcome: "no tests committed yet"),
        ], to: ledger)
        node = try #require(await ledger.workingState().nodes[Self.spec.id])
        #expect(node.recordedTests == nil, "Starting or finishing an agent run does not restore an old record")

        try await Self.append([
            .testsRecorded(files: [Self.lastFile], suite: Self.spec.testTarget),
        ], to: ledger)
        let replayed = try Ledger(store: store)
        node = try #require(await replayed.workingState().nodes[Self.spec.id])
        #expect(node.recordedTests?.files == [Self.lastFile])
        #expect(node.recordedTests?.suite == Self.spec.testTarget)
        #expect(node.testsDigest == nil)
    }

    @Test
    func candidatesDoNotLockAndLockOrRenewalEventsDoNotReplaceTheirRecord() async throws {
        let ledger = try Ledger()
        try await Self.createNode(in: ledger)
        try await Self.append([.testsFixed(digest: "previous-lock")], to: ledger)
        try await Self.append([
            .testsRecorded(files: [Self.firstFile, Self.lastFile], suite: Self.spec.testTarget),
        ], to: ledger)
        var node = try #require(await ledger.workingState().nodes[Self.spec.id])
        #expect(node.testsDigest == nil, "Recording a new candidate must not leave the previous lock in force")
        #expect(node.recordedTests?.files == [Self.firstFile, Self.lastFile])

        for event: EventKind in [
            .testsFixed(digest: "new-lock"),
            .otherTestsUpdated(files: [Self.otherFile], digest: "other-lock"),
            .catchUpSucceeded(main: "main-2", newAgentOSMainTip: "tip-2", method: .automatic),
            .testsFixed(digest: "renewed-lock"),
        ] {
            try await Self.append([event], to: ledger)
            node = try #require(await ledger.workingState().nodes[Self.spec.id])
            #expect(node.recordedTests?.files == [Self.firstFile, Self.lastFile])
            #expect(node.recordedTests?.suite == Self.spec.testTarget)
            #expect(node.testsDigest != nil)
        }
        try await ledger.append([LedgerEvent(
            node: nil, by: .reconciler,
            kind: .catchUpSucceeded(main: "main-3", newAgentOSMainTip: "tip-3", method: .manual)
        )])
        node = try #require(await ledger.workingState().nodes[Self.spec.id])
        #expect(node.recordedTests?.files == [Self.firstFile, Self.lastFile])
        #expect(node.recordedTests?.suite == Self.spec.testTarget)
        #expect(node.testsDigest == "renewed-lock")
    }

    @Test
    func aFrozenPreChangeLedgerVerifiesAndReencodesToItsStoredBytesWithoutInventingRecords() async throws {
        let root = try Self.scratchDirectory()
        defer { Self.cleanUp(root) }
        let file = root.appending(path: "ledger.jsonl")
        try Self.legacyLedger.write(to: file, atomically: true, encoding: .utf8)
        let ledger = try Ledger(store: FileLedgerStore(fileURL: file))

        #expect(await ledger.verifyChain().isIntact)
        let records = await ledger.allRecords()
        #expect(records.count == 6)
        for (record, storedLine) in zip(records, Self.legacyLedger.split(separator: "\n")) {
            // Exact bytes are the compatibility contract: hashes use the re-encoded event payload.
            #expect(Hashing.canonicalJSON(record) == Data(storedLine.utf8))
            #expect(record.isIntact)
        }
        let state = await ledger.workingState()
        #expect(state.nodes.values.allSatisfy { $0.recordedTests == nil })
        let node = try #require(state.nodes["wn-legacy-148"])
        #expect(node.testsDigest == "legacy-folder-digest")
        #expect(node.updatedOtherTests == ["Tests/OlderTests/Older.swift"])
        #expect(node.updatedOtherTestsDigest == "legacy-other-digest")
        #expect(node.phase == .ready)
        #expect(node.gates.contains(.build))
        #expect(node.lastCatchUpSuccess?.mainSHA == "old-main")
    }

    @Test
    func aLedgerMixingLegacyAndRecordedEventsVerifiesAndReplaysTheLatestCandidate() async throws {
        let root = try Self.scratchDirectory()
        defer { Self.cleanUp(root) }
        let file = root.appending(path: "ledger.jsonl")
        try Self.legacyLedger.write(to: file, atomically: true, encoding: .utf8)
        let ledger = try Ledger(store: FileLedgerStore(fileURL: file))
        try await ledger.append([
            LedgerEvent(node: "wn-legacy-148", by: .reconciler,
                        kind: .testsRecorded(files: ["Tests/Legacy/New.swift"], suite: "LegacyTests")),
            LedgerEvent(node: "wn-legacy-148", by: .reconciler, kind: .testsFixed(digest: "new-lock")),
        ])

        let replayed = try Ledger(store: FileLedgerStore(fileURL: file))
        #expect(await replayed.verifyChain().isIntact)
        let node = try #require(await replayed.workingState().nodes["wn-legacy-148"])
        #expect(node.recordedTests?.files == ["Tests/Legacy/New.swift"])
        #expect(node.recordedTests?.suite == "LegacyTests")
        #expect(node.testsDigest == "new-lock")
        #expect(Self.recordedEvents(await replayed.allRecords()).last?.suite == "LegacyTests")
    }

    @Test
    func theTicketCommentNamesTheBranchAndSuiteAndStillListsEachFilesTests() async throws {
        let fixture = try await Fixture(outcomes: [.accepted])
        defer { fixture.cleanUp() }
        try await fixture.authorTests()

        let comments = await fixture.tracker.comments
        let comment = try #require(comments.first { $0.hasPrefix("🧪 Acceptance tests written") })
        #expect(comment.hasPrefix(
            "🧪 Acceptance tests written on branch \(fixture.workspace.branch(for: Self.spec.id)) in suite \(Self.spec.testTarget):"
        ))
        #expect(comment.contains("- \(Self.firstFile)\n  - returnsGreeting"))
        #expect(comment.contains("- \(Self.lastFile)\n  - rejectsEmpty"))
    }

    @Test
    func theLedgerDescriptionNamesTheRecordedSuiteAndEveryFile() {
        let event = EventKind.testsRecorded(files: [Self.firstFile, Self.lastFile], suite: Self.spec.testTarget)
        #expect(event.summary == "recorded acceptance tests \(Self.spec.testTarget): \(Self.firstFile), \(Self.lastFile)")
    }

    @Test
    func aScriptedLeafStillProgressesFromTestsWrittenThroughToProven() async throws {
        let root = try Self.scratchDirectory()
        defer { Self.cleanUp(root) }
        let checks = ScriptedChecks()
        let simulation = try Simulation(directory: root, team: .scripted, checks: checks)
        let ticket = await simulation.tracker.createTicket(
            title: "Greeting", description: "Greet callers", acceptanceCriteria: ["Says hello"],
            by: .human("Alice")
        )
        try await withHangGuard("GH148 scripted acceptance tests") {
            await simulation.tracker.addLabel(HarnessCommand.breakdown.label, to: ticket.key, by: .human("Alice"))
            let reports = await simulation.runUntilFinished()
            #expect(reports.allSatisfy { $0.safeStop == nil })
        }
        let ready = try #require(await simulation.ledger.workingState().node(forTicket: ticket.key))
        #expect(ready.phase == .ready)
        #expect(ready.testsDigest != nil)
        let red = await checks.runChecks(in: simulation.workspace.worktree(for: ready.id), only: ready.spec.testTarget)
        #expect(!red.passed, "The check fake must detect the scripted tests' missing implementation")
        #expect(red.failingTargets.contains(ready.spec.testTarget))

        try await withHangGuard("GH148 scripted implementation and landing") {
            await simulation.tracker.addLabel(HarnessCommand.build.label, to: ticket.key, by: .human("Alice"))
            let reports = await simulation.runUntilFinished()
            #expect(reports.allSatisfy { $0.safeStop == nil })
        }
        let proven = try #require(await simulation.ledger.workingState().node(forTicket: ticket.key))
        #expect(proven.phase == .proven)
        #expect(proven.evidence.contains { $0.passed })
        #expect(proven.landedCommit != nil)
        #expect(await simulation.ledger.verifyChain().isIntact)
    }
}
