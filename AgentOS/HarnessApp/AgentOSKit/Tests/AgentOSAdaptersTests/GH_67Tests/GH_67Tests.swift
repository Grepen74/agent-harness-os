// Expected API: Ledger.verifyIncrementally() -> ChainReport and
// Ledger.verificationStatistics() -> LedgerVerificationStatistics, whose cumulative
// decodedRecords and hashedRecords count verification work (including opening, not appending).
// Existing verifyChain() remains full; failed checks persist until a successful full check/reopen.
import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite struct GH_67Tests {
    @Test func openingChecksTheFullChainAndInvalidDecodableHistoryRemainsInspectable() async throws {
        let files = try Files()
        defer { files.remove() }
        let records = try await history()
        try files.write(records)
        let valid = try Ledger(store: files.store)
        #expect(await valid.verificationStatistics().hashedRecords == records.count)

        var damaged = records
        damaged[1] = try changedContent(records[1])
        try files.write(damaged)
        let opened = try Ledger(store: files.store)
        #expect(await opened.allRecords().count == records.count)
        #expect(await opened.allRecords()[1].event.kind.summary.contains("tampered"))
        let harness = Harness(ledger: opened)
        let report = await harness.reconciler.runRound(waitForAgents: true)
        let stop = try #require(report.safeStop)
        #expect(stop.hasPrefix("Ledger integrity check failed at #1: "))
        #expect(stop.hasSuffix(". Safe stop: nothing will happen until a human investigates."))
        #expect(await harness.workspace.preparations == 0)
        #expect(await harness.tracker.signalReads == 0)
    }

    @Test func undecodableStorageThrowsAnExplicitLoadError() throws {
        let files = try Files()
        defer { files.remove() }
        try Data("{\"event\":".utf8).write(to: files.url)
        do {
            _ = try Ledger(store: files.store)
            Issue.record("Opening undecodable JSONL must throw, not return an empty ledger.")
        } catch {
            #expect(String(describing: error).contains("Ledger unreadable"))
            #expect(String(describing: error).contains("line 1"))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func successfulQuickChecksOnlyValidateTheNewTailAndUnchangedRoundsDoNoHistoricalWork(
        fileBacked: Bool
    ) async throws {
        let files = try Files()
        defer { files.remove() }
        let store: any LedgerStore = fileBacked ? files.store : InMemoryLedgerStore()
        let ledger = try Ledger(store: store)
        try await ledger.append((0..<4).map { event("original-\($0)") })
        try #require(await ledger.verifyIncrementally().isIntact)
        let verified = await ledger.verificationStatistics()
        let harness = Harness(ledger: ledger)
        for _ in 0..<3 {
            #expect(await harness.reconciler.runRound(waitForAgents: true).safeStop == nil)
        }
        let unchanged = await ledger.verificationStatistics()
        #expect(unchanged.decodedRecords == verified.decodedRecords)
        #expect(unchanged.hashedRecords == verified.hashedRecords)

        let new = try await ledger.append([event("tail-one"), event("tail-two")])
        let beforeCheck = await ledger.verificationStatistics()
        let tail = await ledger.verifyIncrementally()
        try #require(tail.isIntact)
        #expect(tail.checked == 6)
        #expect(new.first?.previousHash == (await ledger.allRecords())[3].hash)
        let afterCheck = await ledger.verificationStatistics()
        #expect(afterCheck.hashedRecords - beforeCheck.hashedRecords == 2)
        #expect(afterCheck.decodedRecords - beforeCheck.decodedRecords == (fileBacked ? 2 : 0))
        #expect(await ledger.verifyIncrementally().isIntact)
        let repeated = await ledger.verificationStatistics()
        #expect(repeated.hashedRecords == afterCheck.hashedRecords)
        #expect(repeated.decodedRecords == afterCheck.decodedRecords)
    }

    @Test(.timeLimit(.minutes(1)), arguments: HistoricalDamage.allCases)
    func theNextQuickCheckDetectsEveryHistoricalMutationAndStopsBeforeIntake(
        damage: HistoricalDamage
    ) async throws {
        let files = try Files()
        defer { files.remove() }
        let ledger = try Ledger(store: files.store)
        let original = try await ledger.append((0..<4).map { event("original-\($0)") })
        try #require(await ledger.verifyIncrementally().isIntact)
        let harness = Harness(ledger: ledger)
        try await damageFile(damage, original: original, files: files)
        let failed = await ledger.verifyIncrementally()
        try #require(!failed.isIntact)
        try await expectSafeStop(harness, matching: failed)
    }

    @Test func sameSizeHistoricalEditsRemainDetectableAfterALegitimateAppend() async throws {
        let files = try Files()
        defer { files.remove() }
        let ledger = try Ledger(store: files.store)
        let records = try await ledger.append((0..<4).map { event("original-\($0)") })
        try #require(await ledger.verifyIncrementally().isIntact)
        let before = try Data(contentsOf: files.url)
        let edited = Data(String(decoding: before, as: UTF8.self)
            .replacingOccurrences(of: "original-1", with: "tampered-1").utf8)
        try #require(edited.count == before.count)
        try edited.write(to: files.url)
        let appended = try await ledger.append([event("legitimate-tail")])
        #expect(appended.first?.previousHash == records.last?.hash)
        let failed = await ledger.verifyIncrementally()
        try #require(!failed.isIntact)
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test(.timeLimit(.minutes(1)), arguments: TailDamage.allCases)
    func newRecordsMustHaveValidContentPositionsAndLinksToTheVerifiedTerminalHash(
        damage: TailDamage
    ) async throws {
        let files = try Files()
        defer { files.remove() }
        let ledger = try Ledger(store: files.store)
        _ = try await ledger.append([event("original-0"), event("original-1")])
        try #require(await ledger.verifyIncrementally().isIntact)
        var records = await ledger.allRecords()
        let tail = try await ledger.append([event("tail-one"), event("tail-two")])
        records += tail
        switch damage {
        case .content:
            records[2] = try changedContent(records[2])
        case .position:
            records[2] = try rehashed(records[2], position: 42, previousHash: records[1].hash)
        case .firstPredecessor:
            records[2] = try rehashed(records[2], position: 2, previousHash: String(repeating: "a", count: 64))
        case .laterPredecessor:
            records[3] = try rehashed(records[3], position: 3, previousHash: records[1].hash)
        }
        if damage != .content {
            #expect(records[damage == .laterPredecessor ? 3 : 2].isIntact)
        }
        try files.write(records)
        let failed = await ledger.verifyIncrementally()
        let problem = try #require(failed.problem)
        #expect(problem.position == records[damage == .laterPredecessor ? 3 : 2].position)
        #expect(problem.reason.contains(damage == .content ? "content" : "chain"))
        // Neither append nor a failed verification may advance past unchecked records.
        #expect(!(await ledger.verifyIncrementally()).isIntact)
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test func inMemoryStoreAlsoRejectsForgedAppendedRecords() async throws {
        let store = InMemoryLedgerStore()
        let ledger = try Ledger(store: store)
        let records = try await ledger.append([event("original")])
        try #require(await ledger.verifyIncrementally().isIntact)
        let validTail = try rehashed(records[0], position: 1, previousHash: records[0].hash)
        store.append([try changedContent(validTail)])
        let failed = await ledger.verifyIncrementally()
        let problem = try #require(failed.problem)
        #expect(problem.position == 1)
        #expect(problem.reason.contains("content"))
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test(.timeLimit(.minutes(1)), arguments: CompatibilityDamage.allCases)
    func storesImplementingOnlyLoadAllAndAppendDetectTamperingThroughTheFullReadFallback(
        damage: CompatibilityDamage
    ) async throws {
        let records = try await history()
        let store = CompatibilityStore(records)
        let ledger = try Ledger(store: store)
        try #require(await ledger.verifyIncrementally().isIntact)
        let reads = store.readCount
        #expect(await ledger.verifyIncrementally().isIntact)
        #expect(store.readCount > reads)
        var changed = records
        switch damage {
        case .changed: changed[1] = try changedContent(changed[1])
        case .missing: changed.remove(at: 1)
        case .reordered: changed.swapAt(1, 2)
        case .truncated: changed.removeLast()
        case .replaced: changed = try await history(prefix: "replaced")
        case .forged:
            let valid = try rehashed(records[0], position: records.count, previousHash: records.last!.hash)
            changed.append(try changedContent(valid))
        }
        store.replace(changed)
        let failed = await ledger.verifyIncrementally()
        try #require(!failed.isIntact)
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test func compatibilityStoreReadFailuresAreFailedReportsNotSuccessfulEmptyResults() async throws {
        let store = CompatibilityStore(try await history())
        let ledger = try Ledger(store: store)
        try #require(await ledger.verifyIncrementally().isIntact)
        store.failNextRead()
        let failed = await ledger.verifyIncrementally()
        let problem = try #require(failed.problem)
        #expect(problem.position == -1)
        #expect(problem.reason.contains("transient ledger read failure"))
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test func fileReadFailuresStopRoundsAndDoNotMasqueradeAsAnEmptyLedger() async throws {
        let files = try Files()
        defer { files.remove() }
        let ledger = try Ledger(store: files.store)
        try await ledger.append([event("original")])
        try #require(await ledger.verifyIncrementally().isIntact)
        try FileManager.default.removeItem(at: files.url)
        try FileManager.default.createDirectory(at: files.url, withIntermediateDirectories: false)
        let failed = await ledger.verifyIncrementally()
        try #require(!failed.isIntact)
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test func fullManualVerificationStillChecksEveryRecordAndCannotBeBypassedByQuickChecks() async throws {
        let store = CompatibilityStore(try await history())
        let ledger = try Ledger(store: store)
        try #require(await ledger.verifyIncrementally().isIntact)
        let before = await ledger.verificationStatistics()
        let full = await ledger.verifyChain()
        try #require(full.isIntact)
        #expect(full.checked == 4)
        #expect(await ledger.verificationStatistics().hashedRecords - before.hashedRecords == 4)

        let unchanged = try store.loadAll()
        store.failNextRead()
        let failedManual = await ledger.verifyChain()
        let problem = try #require(failedManual.problem)
        #expect(problem.reason.contains("transient ledger read failure"))
        // The failure is transient: a subsequent full-read fallback sees exactly the verified history.
        #expect(try store.loadAll().map(\.hash) == unchanged.map(\.hash))
        let harness = Harness(ledger: ledger)
        try await expectSafeStop(harness, matching: failedManual)
        #expect(!(await ledger.verifyIncrementally()).isIntact)
    }

    @Test func fullFileVerificationRechecksHistoricalHashesEvenAfterAnUnchangedQuickCheck() async throws {
        let files = try Files()
        defer { files.remove() }
        try files.write(try await history())
        let ledger = try Ledger(store: files.store)
        try #require(await ledger.verifyIncrementally().isIntact)
        let before = await ledger.verificationStatistics()
        let full = await ledger.verifyChain()
        #expect(full.isIntact)
        #expect(full.checked == 4)
        let after = await ledger.verificationStatistics()
        #expect(after.decodedRecords - before.decodedRecords == 4)
        #expect(after.hashedRecords - before.hashedRecords == 4)
        var records = await ledger.allRecords()
        records[0] = try changedContent(records[0])
        try files.write(records)
        let failed = await ledger.verifyChain()
        #expect(failed.problem?.position == 0)
        try await expectSafeStop(Harness(ledger: ledger), matching: failed)
    }

    @Test func existingJSONLRetainsCanonicalEncodingAndRecordHashesAndBackupCanBeReopened() async throws {
        let files = try Files()
        defer { files.remove() }
        let historical = Data(Self.historicalJSONL.utf8)
        try historical.write(to: files.url)
        let opened = try Ledger(store: files.store)
        let records = await opened.allRecords()
        #expect(records.map(\.previousHash) == [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "f01dc673d73d03c3c5b32d8c241886dcad5ca0af1729c5dd65931cc89f648287",
        ])
        #expect(records.map(\.hash) == [
            "f01dc673d73d03c3c5b32d8c241886dcad5ca0af1729c5dd65931cc89f648287",
            "4520feeaa59d18d6798cd04ca67ae9b446425adcc292f870485b9f33944728f1",
        ])
        let persisted = Self.historicalJSONL.split(separator: "\n")
        for (record, line) in zip(records, persisted) {
            let encoded = try #require(
                JSONSerialization.jsonObject(with: Hashing.canonicalJSON(record)) as? NSDictionary)
            let old = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
            #expect(encoded == old)
        }
        #expect(await opened.verifyChain().isIntact)
        #expect(await opened.verifyIncrementally().isIntact)
        #expect(try Data(contentsOf: files.url) == historical)

        let backup = files.url.appendingPathExtension("before-tamper")
        try FileManager.default.copyItem(at: files.url, to: backup)
        try files.write([try changedContent(records[0]), records[1]])
        #expect(!(await opened.verifyChain()).isIntact)
        _ = try FileManager.default.replaceItemAt(files.url, withItemAt: backup)
        let reopened = try Ledger(store: files.store)
        #expect(await reopened.verifyChain().isIntact)
        #expect(await reopened.verifyIncrementally().isIntact)
        let harness = Harness(ledger: reopened)
        #expect(await harness.reconciler.runRound(waitForAgents: true).safeStop == nil)
        #expect(await harness.workspace.preparations == 1)
        #expect(await harness.tracker.signalReads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cliVerifyKeepsItsFullCheckPresentationAndSuccessAndFailureExitStatuses() async throws {
        let files = try Files()
        defer { files.remove() }
        try Data(Self.historicalJSONL.utf8).write(to: files.url)
        let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "agentos"),
            package.appending(path: ".build/debug/agentos"),
        ]
        let executable = try #require(candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }, "Build the package's existing agentos executable before running CLI acceptance tests.")
        let intact = try await ProcessRunner.run(
            executable.path, ["verify", "--dir", files.directory.path],
            in: files.directory, timeout: .seconds(30))
        #expect(intact.status == 0)
        #expect(intact.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Intact: 2 records")
        var records = try files.store.loadAll()
        records[0] = try changedContent(records[0])
        try files.write(records)
        let broken = try await ProcessRunner.run(
            executable.path, ["verify", "--dir", files.directory.path],
            in: files.directory, timeout: .seconds(30))
        #expect(broken.status == 1)
        #expect(broken.output.hasPrefix("Broken at #0: "))
        #expect(broken.output.contains("content"))
    }
}
