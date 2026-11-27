import AgentOSAdapters
import AgentOSCore
import AgentOSUI
import Foundation
import Testing

/// Two harnesses on one repo storage fork the ledger's chain; the storage lock keeps the second one out, a broken
/// ledger takes no more records, and a person can cut it back to its intact part.
struct LedgerForkTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "ledger-fork-\(UUID().uuidString)")
    private var store: FileLedgerStore { FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl")) }

    private func note(_ text: String) -> LedgerEvent {
        LedgerEvent(node: nil, by: .reconciler, kind: .mainFetchWarningChanged(warning: text))
    }

    /// Two ledgers opened on one file, each appending from its own memory: the second record at the same position.
    private func forkedLedger() async throws {
        let first = try Ledger(store: store)
        try await first.append([note("one"), note("two")])
        let window = try Ledger(store: store)
        let otherWindow = try Ledger(store: store)
        try await window.append([note("from this window")])
        try await otherWindow.append([note("from the other window")])
    }

    @Test func aSecondHarnessOnTheSameStorageIsKeptOutUntilTheFirstLetsGo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try StorageLock(directory: directory)

        let busy = #expect(throws: StorageLock.Busy.self) { try StorageLock(directory: directory) }
        #expect(busy?.description.contains("pid \(ProcessInfo.processInfo.processIdentifier)") == true,
                "\(String(describing: busy))")

        lock.release()
        do {
            try StorageLock(directory: directory).release()
        } catch let stillBusy as StorageLock.Busy {
            // Only another reference to the closed descriptor can keep the lock, e.g. a child process that was handed
            // its number. Name who has the file open so a failure points at the leak.
            let holders = try await ProcessRunner.run(
                "/usr/sbin/lsof", ["-F", "pcf", directory.appending(path: "harness.lock").path], in: directory
            )
            Issue.record("\(stillBusy)\nOpen by:\n\(holders.output)")
        }
    }

    @Test func aForkedLedgerReportsTheBreakAndTakesNoMoreRecords() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await forkedLedger()

        let reopened = try Ledger(store: store)

        let problem = try #require(await reopened.chainProblem()?.problem)
        #expect(problem.position == 2)
        await #expect(throws: LedgerError.self) { try await reopened.append([note("on top of the break")]) }
        #expect(try store.loadAll().count == 4)
    }

    @Test func cuttingBackKeepsTheIntactPartAndMovesTheRestUnchanged() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await forkedLedger()
        let before = try String(contentsOf: store.fileURL, encoding: .utf8).split(separator: "\n")

        let cut = try #require(try store.cutBackToIntactPart())

        #expect(cut.keptRecords == 3)
        #expect(cut.movedRecords == 1)
        #expect(cut.movedTo.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(cut.movedTo.lastPathComponent.hasPrefix("ledger.removed-"))
        let moved = try String(contentsOf: cut.movedTo, encoding: .utf8).split(separator: "\n")
        #expect(moved == Array(before[3...]))
        let ledger = try Ledger(store: store)
        #expect(await ledger.chainProblem() == nil)
        try await ledger.append([LedgerEvent(node: nil, by: .human("Alice"), kind: .ledgerCutBack(
            keptRecords: cut.keptRecords, movedRecords: cut.movedRecords, movedTo: cut.movedTo.lastPathComponent))])
        #expect(await ledger.verifyChain().isIntact)
        #expect(try store.cutBackToIntactPart() == nil)
    }

    @Test func aCutBackAlsoMovesALineThatCantBeRead() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Ledger(store: store).append([note("one"), note("two")])
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"half a record\n".utf8))
        try handle.close()
        #expect(throws: (any Error).self) { try Ledger(store: store) }

        let cut = try #require(try store.cutBackToIntactPart())

        #expect(cut.keptRecords == 2)
        #expect(cut.movedRecords == 1)
        #expect(try String(contentsOf: cut.movedTo, encoding: .utf8) == "{\"half a record\n")
        #expect(try await Ledger(store: store).chainProblem() == nil)
    }

    @MainActor @Test func historyOfAForkedLedgerLoadsDespiteRepeatedPositions() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await forkedLedger()
        let model = HarnessViewModel()

        await HarnessLedgerSession(view: model, source: try Ledger(store: store)).refresh()

        #expect(model.records.count == 4)
    }

    @Test func onlyAPersonCanRecordACutBack() async throws {
        let ledger = try Ledger()
        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .ledgerCutBack(
                keptRecords: 1, movedRecords: 1, movedTo: "ledger.removed.jsonl"))])
        }
    }
}
