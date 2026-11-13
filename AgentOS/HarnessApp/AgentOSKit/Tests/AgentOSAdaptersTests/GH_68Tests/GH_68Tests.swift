// API contract: Ledger.records(for:) returns complete, ordered node history. The @MainActor
// HarnessViewModel.refreshHistory(from:) bridge refreshes complete legacy records and indexed
// records(for:); AgentRuns.runs(of:in: HarnessViewModel) uses that history, not a ledger page.
// The existing array overload remains supported. Reconciler decision seams are tested via @testable.

import AgentOSAdapters
import Foundation
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite struct GH_68Tests {
    @Test
    func indexedHistoryIncludesLoadedAndNewInterleavedRecordsInLedgerOrder() async throws {
        let directory = try Self.temporaryDirectory()
        defer { Self.remove(directory) }
        let store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
        let original = try Ledger(store: store)
        let initial = [
            Self.creation(),
            Self.creation(Self.other),
            LedgerEvent(node: Self.spec.id, by: .reconciler,
                        kind: .runStarted(run: "a", role: .implementer), at: Date(timeIntervalSince1970: 20)),
            Self.event(.runStarted(run: "b", role: .testAuthor), node: Self.other),
            Self.event(.externalDependencyResolved(ref: "global"), node: nil),
            LedgerEvent(node: Self.spec.id, by: .reconciler,
                        kind: .runFinished(run: "a", outcome: "submitted"), at: Date(timeIntervalSince1970: 10)),
        ]
        let loaded = try await original.append(initial)
        let reopened = try Ledger(store: store)
        #expect(await reopened.records(for: Self.spec.id).map(\.event.id)
            == [initial[0].id, initial[2].id, initial[5].id])

        let tail = try await reopened.append([
            Self.event(.runFinished(run: "b", outcome: "tests committed"), node: Self.other),
            Self.event(.attemptsReset),
            Self.event(.externalDependencyResolved(ref: "another global"), node: nil),
        ])
        let history = await reopened.records(for: Self.spec.id)
        #expect(history.map(\.position) == [loaded[0].position, loaded[2].position, loaded[5].position, tail[1].position])
        #expect(history.map(\.hash) == [loaded[0].hash, loaded[2].hash, loaded[5].hash, tail[1].hash])
        #expect(history.allSatisfy { $0.event.node == Self.spec.id })
        #expect(await reopened.records(for: Self.other).map(\.event.id)
            == [initial[1].id, initial[3].id, tail[0].event.id])
        #expect(await reopened.records(for: "unknown-node").isEmpty)
        #expect(await reopened.verifyChain().isIntact)
    }

    @Test
    func successfulAppendsAndIdempotentRetriesIndexEachRecordExactlyOnce() async throws {
        let store = InMemoryLedgerStore()
        let original = try Ledger(store: store)
        let created = Self.creation()
        try await original.append([created])
        let ledger = try Ledger(store: store)
        let fresh = Self.event(.phaseChanged(to: .ready))

        let appended = try await ledger.append([created, fresh])
        #expect(appended.map(\.event.id) == [fresh.id])
        #expect(try await ledger.append([created, fresh], expecting: [Self.spec.id: -999]).isEmpty)
        #expect(await ledger.records(for: Self.spec.id).map(\.event.id) == [created.id, fresh.id])

        let next = Self.event(.attemptsReset)
        try await ledger.append([fresh, next])
        try await ledger.append([next])
        #expect(await ledger.records(for: Self.spec.id).map(\.event.id) == [created.id, fresh.id, next.id])
        let reopened = try Ledger(store: store)
        #expect(await reopened.records(for: Self.spec.id).map(\.event.id) == [created.id, fresh.id, next.id])
    }

    @Test
    func rejectedBatchesLeaveEveryNodeIndexUnchanged() async throws {
        let ledger = try Ledger()
        let baseline = try await ledger.append([Self.creation(), Self.creation(Self.other)])
        let valid = Self.event(.phaseChanged(to: .ready))
        let forbidden = Self.event(.gateOpened(.build), node: Self.other)

        await #expect(throws: LedgerError.self) {
            try await ledger.append([valid, forbidden])
        }
        await #expect(throws: LedgerError.self) {
            try await ledger.append([valid], expecting: [Self.spec.id: -999])
        }
        #expect(await ledger.records(for: Self.spec.id).map(\.event.id) == [baseline[0].event.id])
        #expect(await ledger.records(for: Self.other).map(\.event.id) == [baseline[1].event.id])
        #expect(await ledger.allRecords().map(\.hash) == baseline.map(\.hash))

        try await ledger.append([valid])
        #expect(await ledger.records(for: Self.spec.id).map(\.event.id) == [baseline[0].event.id, valid.id])
    }

    @Test
    func failedStorageWriteDoesNotPoisonIndexesOrConsumeIdempotencyKeys() async throws {
        let store = FailingStore()
        let ledger = try Ledger(store: store)
        let baseline = try await ledger.append([Self.creation(), Self.creation(Self.other)])
        let batch = [
            Self.event(.phaseChanged(to: .ready)),
            Self.event(.phaseChanged(to: .ready), node: Self.other),
        ]
        store.failNextAppend()
        await #expect(throws: StorageFailure.self) { try await ledger.append(batch) }

        #expect(await ledger.records(for: Self.spec.id).map(\.hash) == [baseline[0].hash])
        #expect(await ledger.records(for: Self.other).map(\.hash) == [baseline[1].hash])
        #expect(await ledger.allRecords().map(\.hash) == baseline.map(\.hash))
        #expect(try store.loadAll().map(\.hash) == baseline.map(\.hash))

        let retried = try await ledger.append(batch)
        #expect(retried.map(\.event.id) == batch.map(\.id))
        #expect(try await ledger.append(batch).isEmpty)
        #expect(await ledger.records(for: Self.spec.id).map(\.event.id) == [baseline[0].event.id, batch[0].id])
        #expect(await ledger.records(for: Self.other).map(\.event.id) == [baseline[1].event.id, batch[1].id])
        let reopened = try Ledger(store: store)
        #expect(await reopened.records(for: Self.spec.id).map(\.hash) == [baseline[0].hash, retried[0].hash])
        #expect(await reopened.verifyChain().isIntact)
    }

    @Test
    func allRecordsRetainsItsCompleteOrderedSnapshotContract() async throws {
        let ledger = try Ledger()
        let first = try await ledger.append([Self.creation(), Self.creation(Self.other)])
        let snapshot = await ledger.allRecords()
        let more = try await ledger.append(Self.noise(count: 205) + [Self.event(.attemptsReset)])
        #expect(snapshot.map(\.hash) == first.map(\.hash))
        #expect(await ledger.allRecords().map(\.hash) == (first + more).map(\.hash))
    }

    @Test(arguments: [false, true])
    func waitingOnAnotherTicketsTestsSurvivesUnrelatedHistory(beganAnotherOwnRun: Bool) async throws {
        var history = [
            Self.event(.runStarted(run: "builder", role: .implementer)),
            Self.event(.brokenTestReported(.init(testName: "OtherTests.contract", reason: "conflicting expectation"))),
        ]
        if beganAnotherOwnRun { history.append(Self.event(.runStarted(run: "new-builder", role: .implementer))) }
        history += [
            Self.event(.flagSet(.needsInput, reason: "waiting for a person")),
            Self.event(.brokenTestReported(.init(testName: "GH_68Tests.ownTest", reason: "unrelated")), node: Self.other),
            Self.event(.runStarted(run: "other-run", role: .implementer), node: Self.other),
        ] + Self.noise()
        let fixture = try await Fixture(history: history)
        defer { Self.remove(fixture.directory) }
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == !beganAnotherOwnRun)
        try await fixture.ledger.append([Self.event(.flagCleared(.needsInput), by: .human("Alice"))])
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == false)
    }

    @Test
    func ownAcceptanceTestReportsDoNotBecomeOtherTestWaits() async throws {
        let fixture = try await Fixture(history: [
            Self.event(.brokenTestReported(.init(testName: "GH_68Tests.contract", reason: "own test"))),
            Self.event(.flagSet(.needsInput, reason: "review these tests")),
        ] + Self.noise())
        defer { Self.remove(fixture.directory) }
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == false)
    }

    @Test(arguments: [0, 1, 2])
    func disputedReviewClassificationUsesOnlyTheCurrentNodesRunHistory(scenario: Int) async throws {
        var history = [Self.event(.runFinished(run: "builder", outcome: "made no changes for the review findings"))]
        if scenario == 1 { history.append(Self.event(.runStarted(run: "new-builder", role: .implementer))) }
        if scenario == 2 { history.append(Self.event(.runFinished(run: "new-builder", outcome: "submitted"))) }
        history += [
            Self.event(.flagSet(.needsInput, reason: "comment with guidance, then add harness:retry")),
            Self.event(.runFinished(run: "other", outcome: "submitted"), node: Self.other),
        ] + Self.noise()
        let fixture = try await Fixture(history: history)
        defer { Self.remove(fixture.directory) }
        #expect(await fixture.reconciler.isDisputingReviewFindings(try await fixture.node()) == (scenario == 0))
        try await fixture.ledger.append([Self.event(.flagCleared(.needsInput), by: .human("Alice"))])
        #expect(await fixture.reconciler.isDisputingReviewFindings(try await fixture.node()) == false)
    }

    @Test(arguments: BrokenReportReset.allCases)
    func reworkedBrokenTestsWaitForAPersonUnlessThatPersonResetThisNode(reset: BrokenReportReset) async throws {
        var history = [
            Self.event(.brokenTestReported(.init(testName: "GH_68Tests.original", reason: "original conflict"))),
            Self.event(.testsFixed(digest: "rewritten-tests")),
            Self.event(.attemptsReset, node: Self.other, by: .human("Alice")),
        ]
        if let kind = reset.kind { history.append(Self.event(kind, by: .human("Alice"))) }
        history += Self.noise()
        let fixture = try await Fixture(history: history)
        defer { Self.remove(fixture.directory) }

        _ = try await fixture.reconciler.routeBrokenTest(
            .init(testName: "GH_68Tests.rewritten", reason: "still conflicting"),
            from: try await fixture.node(), run: "builder",
            author: .agent(run: "builder", role: .implementer), directory: fixture.directory)

        let node = try await fixture.node()
        #expect(node.failedAttempts == 0)
        #expect(node.phase == (reset == .none ? .ready : .specified))
        #expect((node.flags[.needsInput] != nil) == (reset == .none))
        let records = await fixture.ledger.records(for: Self.spec.id)
        let routes = records.compactMap { record -> BrokenTestRoutingOutcome? in
            if case .brokenTestRouted(_, let outcome) = record.event.kind { return outcome }
            return nil
        }
        #expect(routes == [reset == .none ? .waitingForPerson : .sentBackToTestAuthor])
        #expect(await fixture.tracker.comments().contains {
            $0.contains(reset == .none ? "original conflict" : "sent back to the test author")
        })
    }

    @Test(arguments: [
        EventKind.attemptsReset, .flagCleared(.needsInput), .phaseChanged(to: .specified),
    ])
    func compilationRetryAccountingHonorsHumanResetsWithoutCountingOtherNodes(reset: EventKind) async throws {
        let fixture = try await Fixture(history: [
            Self.event(.runStarted(run: "old-author", role: .testAuthor)),
            Self.event(.runFinished(run: "old-author", outcome: "acceptance tests did not compile")),
            Self.event(reset, by: .human("Alice")),
            Self.event(.runStarted(run: "other-author-1", role: .testAuthor), node: Self.other),
            Self.event(.runStarted(run: "other-author-2", role: .testAuthor), node: Self.other),
        ] + Self.noise())
        defer { Self.remove(fixture.directory) }

        _ = try await fixture.reconciler.authorTests(try await fixture.node())
        let first = try await fixture.node()
        #expect(first.flags[.needsInput] == nil)
        #expect(first.failedAttempts == 0)
        try await fixture.ledger.append([Self.event(.attemptsReset, node: Self.other, by: .human("Alice"))])
        _ = try await fixture.reconciler.authorTests(try await fixture.node())
        let second = try await fixture.node()
        #expect(second.flags[.needsInput]?.contains("Acceptance tests don't compile") == true)
        #expect(second.failedAttempts == 0)
        let failures = await fixture.ledger.records(for: Self.spec.id).filter {
            if case .acceptanceTestPreflightFailed = $0.event.kind { return true }
            return false
        }
        #expect(failures.count == 2)
    }

    @Test(arguments: [EventKind.attemptsReset, .replanned(spec: GH_68Tests.spec), .phaseChanged(to: .specified)])
    func reviewAccountingKeepsOnlyThisStagesFailuresSinceThisNodesReset(reset: EventKind) async throws {
        let fixture = try await Fixture(history: [
            Self.event(.reviewRecorded(Self.reviewRecord("discarded finding"))),
            Self.event(reset, by: .human("Alice")),
            Self.event(.reviewRecorded(Self.reviewRecord("wrong stage", stage: .acceptanceTests))),
            Self.event(.reviewRecorded(Self.reviewRecord("current finding"))),
            Self.event(.reviewRecorded(Self.reviewRecord("other node finding")), node: Self.other),
            Self.event(.attemptsReset, node: Self.other, by: .human("Alice")),
        ] + Self.noise(), reviewResult: .init(passed: false, findings: ["new finding"]))
        defer { Self.remove(fixture.directory) }

        let result = try await fixture.reconciler.review(
            try await fixture.node(), stage: .change, context: Fixture.context,
            in: fixture.directory, run: "review")
        #expect(await fixture.reviewer.earlierFindings() == [[["current finding"]]])
        _ = try await fixture.reconciler.returnReviewFindings(
            result, stage: .change, node: try await fixture.node(), run: "review")
        let reason = try #require(try await fixture.node().flags[.escalated])
        #expect(reason.contains("current finding"))
        #expect(reason.contains("new finding"))
        #expect(!reason.contains("discarded finding"))
        #expect(!reason.contains("wrong stage"))
        #expect(!reason.contains("other node finding"))
        #expect(reason.contains("harness:retry"))
    }

    @Test
    func repeatedReviewFollowUpsAreSuppressedAcrossStagesButNotAcrossNodes() async throws {
        let fixture = try await Fixture(history: [
            Self.event(.reviewRecorded(Self.reviewRecord("old", stage: .acceptanceTests, followUps: ["already reported"]))),
            Self.event(.reviewRecorded(Self.reviewRecord("other", followUps: ["only on other ticket"])), node: Self.other),
        ] + Self.noise(), reviewResult: .init(
            passed: true, findings: [], followUps: ["already reported", "only on other ticket", "new follow-up"]))
        defer { Self.remove(fixture.directory) }

        _ = try await fixture.reconciler.review(
            try await fixture.node(), stage: .change, context: Fixture.context,
            in: fixture.directory, run: "review-1")
        let comments = await fixture.tracker.comments()
        #expect(comments.count == 1)
        #expect(comments[0].contains("only on other ticket"))
        #expect(comments[0].contains("new follow-up"))
        #expect(!comments[0].contains("already reported"))
        try await fixture.ledger.append([Self.event(.attemptsReset, by: .human("Alice"))])
        _ = try await fixture.reconciler.review(
            try await fixture.node(), stage: .change, context: Fixture.context,
            in: fixture.directory, run: "review-2")
        #expect(await fixture.tracker.comments() == comments)
    }

    @MainActor @Test
    func agentHistoryBridgeKeepsOldRunsAndRefreshesOutcomesBeyondALedgerPage() async throws {
        let store = InMemoryLedgerStore()
        let initial = try Ledger(store: store)
        try await initial.append([
            Self.creation(), Self.creation(Self.other),
            Self.event(.runStarted(run: "author", role: .testAuthor)),
            Self.event(.runFinished(run: "author", outcome: "acceptance tests committed")),
            Self.event(.runStarted(run: "checker", role: .verifier)),
            Self.event(.runFinished(run: "checker", outcome: "passed")),
            Self.event(.runStarted(run: "builder", role: .implementer)),
            Self.event(.runFinished(run: "author", outcome: "unrelated outcome"), node: Self.other),
        ])
        let ledger = try Ledger(store: store)
        let model = HarnessViewModel()
        await model.refreshHistory(from: ledger)
        try await ledger.append(Self.noise(count: 241))
        await model.refreshHistory(from: ledger)
        let all = await ledger.allRecords()
        let nodeHistory = await ledger.records(for: Self.spec.id)
        #expect(model.records.map(\.hash) == all.map(\.hash))
        #expect(model.records(for: Self.spec.id).map(\.hash) == nodeHistory.map(\.hash))
        #expect(model.records(for: "unknown-node").isEmpty)
        #expect(AgentRuns.runs(of: Self.spec.id, in: Array(all.suffix(200))).isEmpty)

        let runs = AgentRuns.runs(of: Self.spec.id, in: model)
        #expect(runs.map(\.run) == ["author", "builder"])
        #expect(runs.map(\.role) == [.testAuthor, .implementer])
        #expect(runs.map(\.outcome) == ["acceptance tests committed", nil])
        let legacy = AgentRuns.runs(of: Self.spec.id, in: model.records)
        #expect(legacy.map(\.run) == runs.map(\.run))
        #expect(legacy.map(\.outcome) == runs.map(\.outcome))

        try await ledger.append([Self.event(.runFinished(run: "builder", outcome: "submitted"))])
        await model.refreshHistory(from: ledger)
        await model.refreshHistory(from: ledger)
        let updated = AgentRuns.runs(of: Self.spec.id, in: model)
        #expect(updated.map(\.run) == ["author", "builder"])
        #expect(updated.map(\.outcome) == ["acceptance tests committed", "submitted"])
        let refreshed = await ledger.allRecords()
        #expect(model.records.map(\.hash) == refreshed.map(\.hash))
    }

    @MainActor @Test
    func refreshingTheBridgeWithAnotherLedgerDoesNotLeakPreviousHistory() async throws {
        let first = try Ledger()
        try await first.append([Self.creation(), Self.event(.runStarted(run: "old", role: .implementer))])
        let model = HarnessViewModel()
        await model.refreshHistory(from: first)
        #expect(AgentRuns.runs(of: Self.spec.id, in: model).map(\.run) == ["old"])
        let replacement = try Ledger()
        await model.refreshHistory(from: replacement)
        #expect(model.records.isEmpty)
        #expect(model.records(for: Self.spec.id).isEmpty)
        #expect(AgentRuns.runs(of: Self.spec.id, in: model).isEmpty)
    }
}
